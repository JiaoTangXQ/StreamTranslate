import http from 'node:http';
import {createHash, randomBytes, timingSafeEqual} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const hash = s => createHash('sha256').update(s).digest('hex');
const equal = (a,b) => typeof a==='string' && typeof b==='string' && a.length===b.length && timingSafeEqual(Buffer.from(a),Buffer.from(b));
const token = () => randomBytes(32).toString('hex');
const validToken = s => typeof s==='string' && /^[a-f0-9]{64}$/.test(s);
const validStream = s => typeof s==='string' && /^[a-f0-9]{32}$/.test(s);
const validBase64 = s => typeof s==='string' && /^[A-Za-z0-9+/]+={0,2}$/.test(s);
const limit = 256*1024;
const day = 86400000, deviceLifetime = 90*day, renewBelow = 80*day, maxDevices = 5;
const macTimeout = 10000, idleRoom = 10*60000, abandonedRoom = 7*day;
const audioQueue = 40, audioPerSecond = 192*1024, audioWait = 1500;
// Personal relay: only ciphertext; no plaintext captions, audio, analytics or disk history.
// Browser authorization lives in memory as cookie hashes. The Mac keeps the
// same hashes and re-registers them when it opens its room, so pairing
// survives relay restarts without the relay storing anything on disk.
export function createRelay({secret, origin, assets, insecureTest=false, now=()=>Date.now()}) {
  if(!validToken(secret) || (!origin.startsWith('https://') && !insecureTest)) throw Error('Invalid relay configuration');
  const rooms=new Map(), cookies=new Map(), attempts=new Map();
  const headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer',
    'Content-Security-Policy':"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
    'Permissions-Policy':'camera=(), microphone=(self), geolocation=()'};
  const send=(res,code,value={},extra={})=>{res.writeHead(code,{...headers,...extra,'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify(value));};
  const event=(res,name,data)=>res.write(`event: ${name}\ndata: ${JSON.stringify(data)}\n\n`);
  const cookieHeader=(value,expires)=>`__Host-stremote=${value}; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=${Math.max(0,Math.floor((expires-now())/1000))}`;
  const online=room=>now()-room.macSeen<macTimeout;
  function device(room,expires){return {room,expires,created:now(),streams:new Set(),seen:0,recovery:null,recoveryAttempts:[],audio:{since:0,bytes:0}};}
  function endStreams(room){for(const c of cookies.values())if(c.room===room)for(const s of c.streams)s.end();}
  function wake(room){const waiting=room.waiters;room.waiters=[];for(const w of waiting)w();}
  function drop(room) {
    for(const [key,c] of cookies) if(c.room===room){for(const s of c.streams)s.end();cookies.delete(key);}
    rooms.delete(room.id); room.frames=[]; room.audio=[]; wake(room);
  }
  function devices(room){return [...cookies.entries()].filter(([,c])=>c.room===room&&c.expires>now()).map(([hash,c])=>({hash,expires:c.expires}));}
  function viewers(room) {return [...cookies.values()].filter(c=>c.room===room&&c.streams.size&&now()-c.seen<8000).length;}
  function status(room) {
    return {viewers:viewers(room),devices:devices(room),recoveries:[...cookies.values()].filter(c=>c.room===room&&c.recovery&&
      c.recovery.expires>now()&&!c.recovery.answer).map(c=>({id:c.recovery.id,publicKey:c.recovery.publicKey}))};
  }
  async function body(req) {
    if(!/^application\/json(?:;|$)/i.test(req.headers['content-type']||'')) throw 415;
    let size=0, chunks=[];
    for await(const chunk of req){size+=chunk.length;if(size>limit)throw 413;chunks.push(chunk);}
    try{return JSON.parse(Buffer.concat(chunks).toString());}catch{throw 400;}
  }
  function cookieValue(req){return (req.headers.cookie||'').match(/(?:^|;\s*)__Host-stremote=([a-f0-9]{64})(?:;|$)/)?.[1];}
  function client(req) {
    const value=cookieValue(req), c=value&&cookies.get(hash(value));
    return c&&rooms.get(c.room.id)===c.room&&c.expires>now()?c:null;
  }
  function open(id,list) {
    let room=rooms.get(id);
    if(!room) {
      // Two rooms at most; a room whose Mac has been gone for ten minutes
      // gives way (its Mac re-registers its devices when it comes back).
      if(rooms.size>=2) {
        const stale=[...rooms.values()].filter(r=>now()-r.macSeen>idleRoom).sort((a,b)=>a.macSeen-b.macSeen)[0];
        if(!stale)return null;
        drop(stale);
      }
      room={id,macSeen:now(),frames:[],seq:0,ticket:null,audio:[],waiters:[]};rooms.set(id,room);
    }
    room.macSeen=now();
    const t=now(), listed=new Set();
    for(const d of Array.isArray(list)?list.slice(0,maxDevices):[]) {
      if(!validToken(d?.hash)||!Number.isFinite(d.expires)||d.expires<=t)continue;
      const expires=Math.min(d.expires,t+deviceLifetime);listed.add(d.hash);
      const existing=cookies.get(d.hash);
      if(existing&&existing.room!==room)continue;
      if(existing)existing.expires=Math.max(existing.expires,expires);else cookies.set(d.hash,device(room,expires));
    }
    // The Mac's list is authoritative, except for a browser paired in the
    // last minute that the Mac may not have saved yet.
    for(const [key,c] of cookies)if(c.room===room&&!listed.has(key)&&t-c.created>60000&&Array.isArray(list)){for(const s of c.streams)s.end();cookies.delete(key);}
    return room;
  }
  const server=http.createServer(async(req,res)=>{
    try {
      if(req.headers.host!==new URL(origin).host) return send(res,421);
      if(req.headers.origin && req.headers.origin!==origin) return send(res,403);
      const url=new URL(req.url,origin), route=url.pathname;
      if(url.search) return send(res,400);
      if(req.method==='GET'&&route==='/healthz')return send(res,200,{ok:true,protocol:2});
      if(req.method==='GET'&&assets.has(route)) {
        const a=assets.get(route);res.writeHead(200,{...headers,'Content-Type':a.type});return res.end(a.data);
      }
      if(req.method==='POST'&&route.startsWith('/publisher/')) {
        if(!equal(req.headers.authorization,'Bearer '+secret))return send(res,401);
        const b=await body(req);
        if(!validToken(b.room))return send(res,400);
        if(route==='/publisher/open') {
          const room=open(b.room,b.devices);
          if(!room)return send(res,429);
          return send(res,200,{seq:room.seq,...status(room)});
        }
        const room=rooms.get(b.room);
        if(!room)return send(res,404);
        if(route==='/publisher/close'){drop(room);return send(res,200);}
        if(route==='/publisher/offline'){room.macSeen=0;room.frames=[];room.audio=[];room.ticket=null;endStreams(room);wake(room);return send(res,200);}
        room.macSeen=now();
        if(route==='/publisher/invite') {
          if(b.ticket!==null&&!validToken(b.ticket))return send(res,400);
          room.ticket=b.ticket?{hash:hash(b.ticket),expires:now()+120000}:null;
          return send(res,200);
        }
        if(route==='/publisher/status')return send(res,200,status(room));
        if(route==='/publisher/audio') {
          // Long poll: the Mac waits here for encrypted phone audio.
          if(!room.audio.length) await new Promise(resolve=>{
            const done=()=>{clearTimeout(timer);resolve();};const timer=setTimeout(done,audioWait);
            room.waiters.push(done);res.on('close',done);
          });
          room.macSeen=now();
          const items=room.audio;room.audio=[];
          return send(res,200,{items});
        }
        if(route==='/publisher/recover') {
          const c=[...cookies.values()].find(c=>c.room===room&&c.recovery?.id===b.id&&c.recovery.expires>now());
          if(!c)return send(res,404);
          if(typeof b.publicKey!=='string'||!/^[A-Za-z0-9+/]{87}=$/.test(b.publicKey)||
            typeof b.data!=='string'||!/^[A-Za-z0-9+/]{80}$/.test(b.data))return send(res,400);
          // Only an encrypted 32-byte room key; the relay never receives the clear key.
          c.recovery.answer={publicKey:b.publicKey,data:b.data};return send(res,200);
        }
        if(route==='/publisher/publish') {
          const f=b.frame;
          if(!f||!Number.isSafeInteger(f.seq)||f.seq<1||!['snapshot','change'].includes(f.kind)||typeof f.data!=='string'||
              f.data.length>220000||!validBase64(f.data)||Buffer.from(f.data,'base64').length<28)return send(res,400);
          // Retries after a lost HTTP response must not duplicate a frame.
          if(f.seq===room.seq&&room.frames.at(-1)?.data===f.data)return send(res,200,status(room));
          if(f.seq!==room.seq+1 || (f.kind==='change'&&(!room.frames.length||room.frames.length>=21)))return send(res,409);
          const bytes=room.frames.reduce((n,v)=>n+v.data.length,0)+f.data.length;
          if(f.kind==='change'&&bytes>2*1024*1024)return send(res,409);
          room.seq=f.seq;room.frames=f.kind==='snapshot'?[f]:[...room.frames,f];
          for(const c of cookies.values())if(c.room===room)for(const s of c.streams){
            if(s.writableLength>limit){s.destroy();continue;}
            event(s,'sealed',f);
          }
          return send(res,200,status(room));
        }
        return send(res,404);
      }
      if(req.method==='POST'&&req.headers.origin!==origin)return send(res,403);
      if(req.method==='POST'&&route==='/api/pair') {
        const ip=req.socket.remoteAddress, t=now();
        // Bounds remain effective even behind a proxy; a global budget is intentional.
        const a=attempts.get(ip)||{count:0,since:t};
        if(t-a.since>60000){a.count=0;a.since=t;}
        attempts.set(ip,a);if(++a.count>20)return send(res,429);
        const b=await body(req),room=rooms.get(b.room), ticket=room?.ticket;
        if(!validToken(b.ticket)||!ticket||ticket.expires<t||!equal(hash(b.ticket),ticket.hash))return send(res,401);
        if(devices(room).length>=maxDevices)return send(res,409);
        room.ticket=null;
        const value=token(), expires=t+deviceLifetime;cookies.set(hash(value),device(room,expires));
        return send(res,200,{},{'Set-Cookie':cookieHeader(value,expires)});
      }
      const c=client(req);if(!c)return send(res,401);
      if(req.method==='GET'&&route==='/api/state') {
        // Opening the page keeps a regularly used phone paired.
        if(c.expires-now()<renewBelow){c.expires=now()+deviceLifetime;return send(res,200,{room:c.room.id,online:online(c.room)},{'Set-Cookie':cookieHeader(cookieValue(req),c.expires)});}
        return send(res,200,{room:c.room.id,online:online(c.room)});
      }
      if(req.method==='POST'&&route==='/api/restore') {
        const b=await body(req),t=now();
        if(!validToken(b.id)||typeof b.publicKey!=='string'||!/^[A-Za-z0-9+/]{87}=$/.test(b.publicKey)||
          Buffer.from(b.publicKey,'base64')[0]!==4)return send(res,400);
        if(!c.recovery||c.recovery.id!==b.id||c.recovery.expires<=t) {
          c.recoveryAttempts=c.recoveryAttempts.filter(v=>t-v<60000);
          if(c.recoveryAttempts.length>=3)return send(res,429);
          c.recoveryAttempts.push(t);
          c.recovery={id:b.id,publicKey:b.publicKey,expires:t+60000,answer:null};
        }
        if(c.recovery.publicKey!==b.publicKey)return send(res,409);
        return send(res,c.recovery.answer?200:202,{room:c.room.id,id:b.id,...c.recovery.answer});
      }
      if(req.method==='POST'&&route==='/api/seen') {
        const b=await body(req);
        if(!Number.isSafeInteger(b.seq)||b.seq<1||b.seq>c.room.seq||!c.streams.size)return send(res,400);
        c.seen=now();return send(res,200);
      }
      if(req.method==='POST'&&route==='/api/audio') {
        const b=await body(req), room=c.room, t=now();
        if(!validStream(b.stream)||!Number.isSafeInteger(b.seq)||b.seq<1||!validBase64(b.data)||b.data.length>60000)return send(res,400);
        if(!online(room))return send(res,503);
        if(t-c.audio.since>=1000){c.audio.since=t;c.audio.bytes=0;}
        // About four times real time, so a phone can catch up after a
        // network stall. A refused upload does not count; the phone retries it.
        if(c.audio.bytes+b.data.length>audioPerSecond)return send(res,429);
        c.audio.bytes+=b.data.length;
        // A Mac that falls behind loses the oldest audio, never the newest.
        room.audio.push({stream:b.stream,seq:b.seq,data:b.data});
        if(room.audio.length>audioQueue)room.audio.splice(0,room.audio.length-audioQueue);
        wake(room);
        return send(res,200);
      }
      if(req.method==='GET'&&route==='/api/events') {
        if(!online(c.room))return send(res,503);
        // Safari and its Home Screen copy can share a cookie. Do not kick each other off.
        if(c.streams.size>=3)return send(res,429);
        c.streams.add(res);
        res.writeHead(200,{...headers,'Content-Type':'text/event-stream','X-Accel-Buffering':'no','Connection':'keep-alive'});
        res.flushHeaders();
        for(const f of c.room.frames)event(res,'sealed',f);
        event(res,'pulse',{});
        res.on('close',()=>{c.streams.delete(res);if(!c.streams.size)c.seen=0;});return;
      }
      send(res,404);
    }catch(e){if(!res.headersSent)send(res,typeof e==='number'?e:400);else res.destroy();}
  });
  server.requestTimeout=10000;server.headersTimeout=10000;server.maxConnections=48;
  const timer=setInterval(()=>{
    const t=now();
    for(const room of rooms.values()) {
      if(t-room.macSeen>abandonedRoom){drop(room);continue;}
      // Ciphertext is not kept for a Mac that has gone away.
      if(t-room.macSeen>idleRoom&&(room.frames.length||room.audio.length)){room.frames=[];room.audio=[];}
    }
    for(const [key,c] of cookies) {
      if(c.expires<=t){for(const s of c.streams)s.end();cookies.delete(key);continue;}
      if(c.recovery?.expires<=t)c.recovery=null;
      for(const s of c.streams){if(!online(c.room))s.end();else event(s,'pulse',{});}
    }
    for(const [ip,a] of attempts)if(t-a.since>60000)attempts.delete(ip);
  },2000);timer.unref();server.on('close',()=>{clearInterval(timer);for(const room of rooms.values())drop(room);});
  return server;
}

if(process.argv[1]===fileURLToPath(import.meta.url)) {
  const base=path.dirname(fileURLToPath(import.meta.url));
  const secret=readFileSync(process.env.RELAY_SECRET_FILE||'/etc/streamtranslate-relay/publisher-token','utf8').trim();
  const assets=new Map(Object.entries({'/':['index.html','text/html; charset=utf-8'],'/app.js':['app.js','application/javascript'],
    '/remote.js':['remote.js','application/javascript'],'/mic-worklet.js':['mic-worklet.js','application/javascript'],
    '/style.css':['style.css','text/css'],'/icon.svg':['icon.svg','image/svg+xml'],
    '/manifest.webmanifest':['manifest.webmanifest','application/manifest+json']}).map(([url,[file,type]])=>[url,{type,data:readFileSync(path.join(base,'public',file))}]));
  const server=createRelay({secret,origin:process.env.RELAY_ORIGIN,assets});
  server.listen(Number(process.env.RELAY_PORT||18447),'127.0.0.1');
  process.on('SIGTERM',()=>{server.close();setTimeout(()=>process.exit(0),1000).unref();});
}

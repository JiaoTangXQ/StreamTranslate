import http from 'node:http';
import {createHash, randomBytes, timingSafeEqual} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const hash = s => createHash('sha256').update(s).digest('hex');
const equal = (a,b) => typeof a==='string' && typeof b==='string' && a.length===b.length && timingSafeEqual(Buffer.from(a),Buffer.from(b));
const token = () => randomBytes(32).toString('hex');
const validToken = s => typeof s==='string' && /^[a-f0-9]{64}$/.test(s);
const limit = 256*1024;
// Personal relay: no audio, models, plaintext captions, analytics or disk history.
export function createRelay({secret, origin, assets, insecureTest=false}) {
  if(!validToken(secret) || (!origin.startsWith('https://') && !insecureTest)) throw Error('Invalid relay configuration');
  const rooms=new Map(), cookies=new Map(), attempts=new Map();
  const headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer',
    'Content-Security-Policy':"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
    'Permissions-Policy':'camera=(), microphone=(), geolocation=()'};
  const send=(res,code,value={})=>{res.writeHead(code,{...headers,'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify(value));};
  const event=(res,name,data)=>res.write(`event: ${name}\ndata: ${JSON.stringify(data)}\n\n`);
  function drop(room) {
    for(const [key,c] of cookies) if(c.room===room){for(const s of c.streams)s.end();cookies.delete(key);}
    rooms.delete(room.id); room.frames=[];
  }
  function viewers(room) {return [...cookies.values()].filter(c=>c.room===room&&c.streams.size&&Date.now()-c.seen<8000).length;}
  function status(room) {
    return {viewers:viewers(room),recoveries:[...cookies.values()].filter(c=>c.room===room&&c.recovery&&
      c.recovery.expires>Date.now()&&!c.recovery.answer).map(c=>({id:c.recovery.id,publicKey:c.recovery.publicKey}))};
  }
  async function body(req) {
    if(!/^application\/json(?:;|$)/i.test(req.headers['content-type']||'')) throw 415;
    let size=0, chunks=[];
    for await(const chunk of req){size+=chunk.length;if(size>limit)throw 413;chunks.push(chunk);}
    try{return JSON.parse(Buffer.concat(chunks).toString());}catch{throw 400;}
  }
  function client(req) {
    const value=(req.headers.cookie||'').match(/(?:^|;\s*)__Host-stremote=([a-f0-9]{64})(?:;|$)/)?.[1];
    const c=value&&cookies.get(hash(value));
    return c&&rooms.get(c.room.id)===c.room&&c.room.expires>Date.now()?c:null;
  }
  const server=http.createServer(async(req,res)=>{
    try {
      if(req.headers.host!==new URL(origin).host) return send(res,421);
      if(req.headers.origin && req.headers.origin!==origin) return send(res,403);
      const url=new URL(req.url,origin), route=url.pathname;
      if(url.search) return send(res,400);
      if(req.method==='GET'&&route==='/healthz')return send(res,200,{ok:true,protocol:1});
      if(req.method==='GET'&&assets.has(route)) {
        const a=assets.get(route);res.writeHead(200,{...headers,'Content-Type':a.type});return res.end(a.data);
      }
      if(req.method==='POST'&&route.startsWith('/publisher/')) {
        if(!equal(req.headers.authorization,'Bearer '+secret))return send(res,401);
        const b=await body(req);
        if(!validToken(b.room))return send(res,400);
        if(route==='/publisher/open') {
          if(!rooms.has(b.room)) {
            if(rooms.size>=2)return send(res,429);
            rooms.set(b.room,{id:b.room,expires:Date.now()+12*3600000,macSeen:Date.now(),frames:[],seq:0,ticket:null});
          }
          return send(res,200,{expires:rooms.get(b.room).expires,seq:rooms.get(b.room).seq});
        }
        const room=rooms.get(b.room);
        if(!room||room.expires<=Date.now())return send(res,404);
        room.macSeen=Date.now();
        if(route==='/publisher/close'){drop(room);return send(res,200);}
        if(route==='/publisher/invite') {
          if(b.ticket!==null&&!validToken(b.ticket))return send(res,400);
          room.ticket=b.ticket?{hash:hash(b.ticket),expires:Date.now()+120000}:null;
          return send(res,200);
        }
        if(route==='/publisher/status')return send(res,200,status(room));
        if(route==='/publisher/recover') {
          const c=[...cookies.values()].find(c=>c.room===room&&c.recovery?.id===b.id&&c.recovery.expires>Date.now());
          if(!c)return send(res,404);
          if(typeof b.publicKey!=='string'||!/^[A-Za-z0-9+/]{87}=$/.test(b.publicKey)||
            typeof b.data!=='string'||!/^[A-Za-z0-9+/]{80}$/.test(b.data))return send(res,400);
          // Only an encrypted 32-byte room key; the relay never receives the clear key.
          c.recovery.answer={publicKey:b.publicKey,data:b.data};return send(res,200);
        }
        if(route==='/publisher/publish') {
          const f=b.frame;
          if(!f||!Number.isSafeInteger(f.seq)||f.seq<1||!['snapshot','change'].includes(f.kind)||typeof f.data!=='string'||
              f.data.length>220000||!/^[A-Za-z0-9+/]+={0,2}$/.test(f.data)||Buffer.from(f.data,'base64').length<28)return send(res,400);
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
        const ip=req.socket.remoteAddress, now=Date.now();
        // Bounds remain effective even behind a proxy; a global budget is intentional.
        const a=attempts.get(ip)||{count:0,since:now};
        if(now-a.since>60000){a.count=0;a.since=now;}
        attempts.set(ip,a);if(++a.count>20)return send(res,429);
        const b=await body(req),room=rooms.get(b.room), t=room?.ticket;
        if(!validToken(b.ticket)||!t||t.expires<now||room.expires<now||!equal(hash(b.ticket),t.hash))return send(res,401);
        if([...cookies.values()].filter(c=>c.room===room).length>=3)return send(res,409);
        room.ticket=null;
        const value=token();cookies.set(hash(value),{room,streams:new Set(),seen:0,recovery:null,recoveryAttempts:[]});
        res.setHeader('Set-Cookie',`__Host-stremote=${value}; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=${Math.floor((room.expires-now)/1000)}`);
        return send(res,200);
      }
      const c=client(req);if(!c)return send(res,401);
      if(req.method==='GET'&&route==='/api/state')return send(res,200,{room:c.room.id});
      if(req.method==='POST'&&route==='/api/restore') {
        const b=await body(req),now=Date.now();
        if(!validToken(b.id)||typeof b.publicKey!=='string'||!/^[A-Za-z0-9+/]{87}=$/.test(b.publicKey)||
          Buffer.from(b.publicKey,'base64')[0]!==4)return send(res,400);
        if(!c.recovery||c.recovery.id!==b.id||c.recovery.expires<=now) {
          c.recoveryAttempts=c.recoveryAttempts.filter(t=>now-t<60000);
          if(c.recoveryAttempts.length>=3)return send(res,429);
          c.recoveryAttempts.push(now);
          c.recovery={id:b.id,publicKey:b.publicKey,expires:now+60000,answer:null};
        }
        if(c.recovery.publicKey!==b.publicKey)return send(res,409);
        return send(res,c.recovery.answer?200:202,{room:c.room.id,id:b.id,...c.recovery.answer});
      }
      if(req.method==='POST'&&route==='/api/seen') {
        const b=await body(req);
        if(!Number.isSafeInteger(b.seq)||b.seq<1||b.seq>c.room.seq||!c.streams.size)return send(res,400);
        c.seen=Date.now();return send(res,200);
      }
      if(req.method==='GET'&&route==='/api/events') {
        if(Date.now()-c.room.macSeen>10000)return send(res,503);
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
    const now=Date.now();
    for(const room of rooms.values())if(room.expires<now||now-room.macSeen>10*60000)drop(room);
    for(const c of cookies.values()){
      if(c.recovery?.expires<=now)c.recovery=null;
      for(const s of c.streams){if(now-c.room.macSeen>10000)s.end();else event(s,'pulse',{});}
    }
    for(const [ip,a] of attempts)if(now-a.since>60000)attempts.delete(ip);
  },2000);timer.unref();server.on('close',()=>{clearInterval(timer);for(const room of rooms.values())drop(room);});
  return server;
}

if(process.argv[1]===fileURLToPath(import.meta.url)) {
  const base=path.dirname(fileURLToPath(import.meta.url));
  const secret=readFileSync(process.env.RELAY_SECRET_FILE||'/etc/streamtranslate-relay/publisher-token','utf8').trim();
  const assets=new Map(Object.entries({'/':['index.html','text/html; charset=utf-8'],'/app.js':['app.js','application/javascript'],
    '/remote.js':['remote.js','application/javascript'],'/style.css':['style.css','text/css'],'/icon.svg':['icon.svg','image/svg+xml'],
    '/manifest.webmanifest':['manifest.webmanifest','application/manifest+json']}).map(([url,[file,type]])=>[url,{type,data:readFileSync(path.join(base,'public',file))}]));
  const server=createRelay({secret,origin:process.env.RELAY_ORIGIN,assets});
  server.listen(Number(process.env.RELAY_PORT||18447),'127.0.0.1');
  process.on('SIGTERM',()=>{server.close();setTimeout(()=>process.exit(0),1000).unref();});
}

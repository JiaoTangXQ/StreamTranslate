import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes,createHash,hkdfSync,createDecipheriv} from 'node:crypto';
import {createRelay} from './server.mjs';

const token=()=>randomBytes(32).toString('hex');
const sha=s=>createHash('sha256').update(s).digest('hex');
let port=18460;

async function start(options={}) {
  const secret=options.secret||token(), p=port++, origin=`http://127.0.0.1:${p}`;
  const relay=createRelay({secret,origin,assets:new Map(),insecureTest:true,...options});
  await new Promise(resolve=>relay.listen(p,'127.0.0.1',resolve));
  const call=(path,body,extra={})=>fetch(origin+path,{method:body===undefined?'GET':'POST',
    headers:{Origin:origin,...(body===undefined?{}:{'Content-Type':'application/json'}),...extra},
    body:body===undefined?undefined:JSON.stringify(body)});
  const pub=(room,op,body={})=>call('/publisher/'+op,{room,...body},{Authorization:'Bearer '+secret});
  const close=async()=>{relay.closeAllConnections();await new Promise(resolve=>relay.close(resolve));};
  return {secret,origin,call,pub,close};
}

async function pair(relay,room) {
  const ticket=token();
  assert.equal((await relay.pub(room,'invite',{ticket})).status,200);
  const r=await relay.call('/api/pair',{room,ticket});assert.equal(r.status,200);
  const value=r.headers.get('set-cookie').match(/__Host-stremote=([a-f0-9]{64})/)[1];
  return {value,cookie:{Cookie:'__Host-stremote='+value}};
}

test('pairing lasts 90 days and is reported to the Mac',async()=>{
  const clock=Date.now();
  const secret=token(), room=token();
  const first=await start({secret,now:()=>clock});
  try {
    assert.equal((await first.pub(room,'open',{devices:[]})).status,200);
    const {value,cookie}=await pair(first,room);
    const status=await (await first.pub(room,'status')).json();
    assert.deepEqual(status.devices.map(d=>d.hash),[sha(value)]);
    assert(Math.abs(status.devices[0].expires-(clock+90*86400000))<5000);
    const state=await first.call('/api/state',undefined,cookie);
    assert.equal(state.status,200);assert.equal((await state.json()).online,true);
    assert.equal(state.headers.get('set-cookie'),null,'fresh cookie is not rewritten');
  } finally {await first.close();}
});

test('the Mac re-registers paired browsers after a relay restart',async()=>{
  let clock=Date.now();
  const secret=token(), room=token();
  const first=await start({secret,now:()=>clock});
  let saved, cookie;
  try {
    await first.pub(room,'open',{devices:[]});
    const paired=await pair(first,room);cookie=paired.cookie;
    saved=(await (await first.pub(room,'status')).json()).devices;
  } finally {await first.close();}
  const second=await start({secret,now:()=>clock});
  try {
    assert.equal((await second.call('/api/state',undefined,cookie)).status,401);
    const opened=await (await second.pub(room,'open',{devices:saved})).json();
    assert.deepEqual(opened.devices,saved);
    assert.equal((await second.call('/api/state',undefined,cookie)).status,200);
    // Close to expiry, opening the page renews the same cookie value.
    clock+=15*86400000;
    const renewed=await second.call('/api/state',undefined,cookie);
    assert.equal(renewed.status,200);
    const header=renewed.headers.get('set-cookie');
    assert.match(header,new RegExp(cookie.Cookie.split('=')[1]));
    assert.match(header,/Max-Age=7776000/);
    const later=(await (await second.pub(room,'status')).json()).devices[0];
    assert(later.expires>saved[0].expires+14*86400000);
    // The Mac's list is authoritative: a browser it no longer lists is removed.
    clock+=2*60000;
    await second.pub(room,'open',{devices:[]});
    assert.equal((await second.call('/api/state',undefined,cookie)).status,401);
    // Expired cookies stop working even if the Mac still lists them.
    await second.pub(room,'open',{devices:[{hash:saved[0].hash,expires:clock-1}]});
    assert.equal((await second.call('/api/state',undefined,cookie)).status,401);
  } finally {await second.close();}
});

test('a browser paired in the last minute is kept until the Mac saves it',async()=>{
  const relay=await start(), room=token();
  try {
    await relay.pub(room,'open',{devices:[]});
    const {cookie}=await pair(relay,room);
    await relay.pub(room,'open',{devices:[]});
    assert.equal((await relay.call('/api/state',undefined,cookie)).status,200);
  } finally {await relay.close();}
});

test('offline Mac: phones stay paired, see offline and cannot upload',async()=>{
  const relay=await start(), room=token();
  try {
    await relay.pub(room,'open',{devices:[]});
    const {cookie}=await pair(relay,room);
    assert.equal((await relay.pub(room,'offline')).status,200);
    const state=await relay.call('/api/state',undefined,cookie);
    assert.equal(state.status,200);assert.equal((await state.json()).online,false);
    assert.equal((await relay.call('/api/events',undefined,cookie)).status,503);
    assert.equal((await relay.call('/api/audio',{stream:'a'.repeat(32),seq:1,data:'AAAA'},cookie)).status,503);
    await relay.pub(room,'status');
    assert.equal((await (await relay.call('/api/state',undefined,cookie)).json()).online,true);
  } finally {await relay.close();}
});

test('phone audio: authenticated, ordered, bounded, long-polled ciphertext',async()=>{
  const relay=await start(), room=token();
  try {
    await relay.pub(room,'open',{devices:[]});
    const {cookie}=await pair(relay,room);
    const stream=randomBytes(16).toString('hex'), data=randomBytes(300).toString('base64');
    assert.equal((await relay.call('/api/audio',{stream,seq:1,data})).status,401);
    assert.equal((await relay.call('/api/audio',{stream,seq:1,data},{...cookie,Origin:'https://evil.example'})).status,403);
    for(const bad of [{stream:'XYZ',seq:1,data},{stream,seq:0,data},{stream,seq:1,data:'***'},{stream,seq:1,data:'A'.repeat(60004)}])
      assert.equal((await relay.call('/api/audio',bad,cookie)).status,400);
    // An empty long poll waits, then returns nothing.
    const began=Date.now();
    assert.deepEqual((await (await relay.pub(room,'audio')).json()).items,[]);
    assert(Date.now()-began>=1200,'empty poll should wait');
    // A waiting poll returns as soon as audio arrives.
    const waiting=relay.pub(room,'audio');
    await new Promise(r=>setTimeout(r,100));
    const sent=Date.now();
    assert.equal((await relay.call('/api/audio',{stream,seq:1,data},cookie)).status,200);
    const first=await (await waiting).json();
    assert(Date.now()-sent<500);
    assert.deepEqual(first.items,[{stream,seq:1,data}]);
    // Ordered and bounded: a Mac that falls behind keeps the newest 40.
    for(let seq=2;seq<=50;seq++)assert.equal((await relay.call('/api/audio',{stream,seq,data:'AAAA'},cookie)).status,200);
    const items=(await (await relay.pub(room,'audio')).json()).items;
    assert.equal(items.length,40);assert.equal(items[0].seq,11);assert.equal(items.at(-1).seq,50);
    // Upload rate is limited per browser (about four times real time).
    const big=randomBytes(44000).toString('base64');let limited=false;
    for(let i=0;i<4;i++){const r=await relay.call('/api/audio',{stream,seq:100+i,data:big},cookie);if(r.status===429)limited=true;}
    assert(limited,'more than ~192 KB/s must be refused');
    const policy=(await relay.call('/healthz')).headers.get('permissions-policy');
    assert.match(policy,/microphone=\(self\)/);assert.match(policy,/camera=\(\)/);
  } finally {await relay.close();}
});

test('browser WebCrypto audio sealing matches the Mac format',async()=>{
  // Same steps as remote.js, using the standard WebCrypto API.
  const room='a'.repeat(64), stream='b'.repeat(32), seq=7, key=Uint8Array.from({length:32},(_,i)=>i);
  const base=await crypto.subtle.importKey('raw',key,'HKDF',false,['deriveKey']);
  const uplink=await crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt:new TextEncoder().encode(room),
    info:new TextEncoder().encode('StreamTranslate phone audio v1')},base,{name:'AES-GCM',length:256},true,['encrypt']);
  const raw=new Uint8Array(await crypto.subtle.exportKey('raw',uplink));
  assert.deepEqual(Buffer.from(raw),Buffer.from(hkdfSync('sha256',key,Buffer.from(room),Buffer.from('StreamTranslate phone audio v1'),32)));
  const samples=new Int16Array([0,1000,-1000,32767,-32768]);
  const clear=new Uint8Array(10+samples.byteLength);
  clear.set([83,84,65,49,0,0,1,2,1,0]);clear.set(new Uint8Array(samples.buffer),10);
  const iv=new Uint8Array(12).fill(9);
  const aad=new TextEncoder().encode(`${room}:${stream}:${seq}:audio`);
  const sealed=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad},uplink,clear));
  const combined=Buffer.concat([Buffer.from(iv),Buffer.from(sealed)]);
  const d=createDecipheriv('aes-256-gcm',Buffer.from(raw),combined.subarray(0,12));
  d.setAAD(Buffer.from(aad));d.setAuthTag(combined.subarray(-16));
  const opened=Buffer.concat([d.update(combined.subarray(12,-16)),d.final()]);
  assert.deepEqual(opened,Buffer.from(clear));
  // Vector checked by the Swift test PhoneAudioBatch.open.
  assert.equal(combined.toString('base64'),'CQkJCQkJCQkJCQkJDrTDiI0c9YNgb4tvfdtFKsiRG2B+C7GsH+y8lKEMrops4Z5v');
});

// Integration checks against --web-fixture only. No real transcripts/accounts.
// Secrets are read from a private fixture directory, never logged.
import {readFileSync, writeFileSync} from 'node:fs';
import {execFileSync, spawn} from 'node:child_process';
import assert from 'node:assert/strict';
const directory=process.argv[2];
if(!directory)throw Error('Pass a running --web-fixture private directory');
const address=readFileSync(`${directory}/address.txt`,'utf8');
const secure=address.startsWith('https:');
const ca=`${directory}/root.pem`;
const tls=secure?['--cacert',ca]:[];
let cookie='', serial=0;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function command(value){writeFileSync(`${directory}/command.txt`,value+'\n'+' '.repeat(++serial));await sleep(1300);}
function request(path,{method='GET',body,origin=address,host,authenticated=false}={}){
 const args=['--noproxy','*',...tls,'--max-time','8','-sS','-i',`${address}${path}`,'-X',method];
 if(origin)args.push('-H',`Origin: ${origin}`);
 if(host)args.push('-H',`Host: ${host}`);
 if(authenticated)args.push('-H',`Cookie: ${cookie}`);
 if(body!==undefined)args.push('-H','Content-Type: application/json','--data-binary',JSON.stringify(body));
 const response=execFileSync('curl',args,{encoding:'utf8'}), split=response.indexOf('\r\n\r\n');
 const headers=response.slice(0,split), text=response.slice(split+4);
 return {code:Number(headers.split(' ')[1]),headers,text};
}
function pass(text){console.log(`PASS: ${text}`);}
await command('reset');
assert.equal(request('/api/state').code,401);
assert.equal(request('/api/events').code,401);
assert.equal(request('/',{host:'attacker.example'}).code,403);
assert.equal(request('/',{origin:'https://attacker.example'}).code,403);
assert.equal(request('/api/pair',{method:'POST',body:{invitation:'invalid'},origin:null}).code,403);
pass('Unauthenticated captions, Host spoofing and cross-origin requests rejected');
await command('invite');
const invitation=decodeURIComponent(new URL(readFileSync(`${directory}/invitation.txt`,'utf8')).hash.slice(1));
const paired=request('/api/pair',{method:'POST',body:{invitation}});
assert.equal(paired.code,200);
assert.match(paired.headers,secure?/Secure; HttpOnly; SameSite=Strict/:/Path=\/; HttpOnly; SameSite=Strict; Max-Age=43200/);
if(!secure)assert.doesNotMatch(paired.headers,/__Host-|; Secure;/);
cookie=paired.headers.match(/Set-Cookie: ([^;]+)/)[1];
assert.equal(request('/api/pair',{method:'POST',body:{invitation}}).code,403);
assert.equal(request('/api/state',{authenticated:true}).code,200);
const savedCookie=cookie;
cookie=cookie.replace(secure?'__Host-stcaption':'stcaption_lan',secure?'stcaption_lan':'__Host-stcaption');
assert.equal(request('/api/state',{authenticated:true}).code,401);cookie=savedCookie;
pass('One-time invitation, transport-specific HttpOnly cookie; other transport credential rejected');
async function stream(){
 return await new Promise((resolve,reject)=>{
  const p=spawn('curl',['--noproxy','*',...tls,'--max-time','5','-sSN','-H',`Cookie: ${cookie}`,`${address}/api/events`]);
  let output='';p.stdout.on('data',b=>output+=b);p.on('error',reject);p.on('close',()=>resolve(output));
 });
}
const first=await stream();
assert.match(first,/event: snapshot/);assert.match(first,/event: change/);
// Heartbeats may be deliberately skipped during an in-flight caption write.
// Test liveness during silence, not at an arbitrary phase of periodic updates.
await command('pause-updates');
assert.match(await stream(),/event: pulse/);
await command('resume-updates');
const snapshot=JSON.parse(first.split('\n').find(l=>l.startsWith('data: ')).slice(6));
assert.equal(snapshot.captions.length,2);const oldSession=snapshot.sessionID;
pass(`${secure?'TLS':'Plain HTTP'} SSE snapshot, incremental update and heartbeat`);
await command('refine');
const refined=await stream();assert.match(refined,/精修字幕仅供自己阅读/);
await command('new-session');
const next=await stream();const nextSnapshot=JSON.parse(next.split('\n').find(l=>l.startsWith('data: ')).slice(6));
assert.equal(nextSnapshot.captions.length,0);assert.notEqual(nextSnapshot.sessionID,oldSession);
pass('Refinement survives reconnect; new meeting removes old captions');
await command('stop');await command('start');
assert.equal(request('/api/state',{authenticated:true}).code,secure?200:401);
pass(secure?'Server restart preserves encrypted browser authorization':'Quick authorization is discarded on service restart');
if(!secure){
 await command('invite');
 const code=readFileSync(`${directory}/code.txt`,'utf8');
 const repaired=request('/api/pair',{method:'POST',body:{invitation:code}});
 assert.equal(repaired.code,200);cookie=repaired.headers.match(/Set-Cookie: ([^;]+)/)[1];
 assert.equal(request('/api/state',{authenticated:true}).code,200);
 pass('Manual short-code fallback re-pairs quick browser');
}
await command('revoke');
assert.equal(request('/api/state',{authenticated:true}).code,401);
await command('invite');
const valid=readFileSync(`${directory}/code.txt`,'utf8');
for(let i=0;i<6;i++)assert.equal(request('/api/pair',{method:'POST',body:{invitation:'invalid'}}).code,403);
assert.equal(request('/api/pair',{method:'POST',body:{invitation:valid}}).code,403);
pass('Revocation denies saved credential; six wrong codes cancel invitation');
await command('invite');
console.log('WEB API INTEGRATION PASSED — local synthetic fixture, not iPhone Wi-Fi acceptance');

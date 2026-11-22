// Full phone-microphone path against a loopback relay:
// headless Chrome (WAV file as its microphone) → real phone page → relay →
// production Mac code in Tools/PhoneMicrophoneProbe (relay client, phone
// coordinator, bilingual Apple recognizer, Apple Translation, publisher) →
// relay → the same page shows the captions.
//   node Relay/phone-mac.e2e.mjs <public dir> <probe executable> <48k-s16.wav>
import {createRelay} from './server.mjs';
import {readFileSync,writeFileSync,mkdtempSync,rmSync,existsSync} from 'node:fs';
import {randomBytes} from 'node:crypto';
import {spawn} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';

const [publicDir,probe,input,mode]=process.argv.slice(2);
const provisioned=mode==='--public';
const secret=randomBytes(32).toString('hex'), port=18490, origin=`http://127.0.0.1:${port}`;
const types={'.js':'application/javascript','.css':'text/css','.html':'text/html','.svg':'image/svg+xml','.webmanifest':'application/manifest+json'};
const files={'/':'index.html','/app.js':'app.js','/remote.js':'remote.js','/mic-worklet.js':'mic-worklet.js','/style.css':'style.css','/icon.svg':'icon.svg','/manifest.webmanifest':'manifest.webmanifest'};
const assets=new Map(Object.entries(files).map(([url,file])=>[url,{data:readFileSync(path.join(publicDir,file)),type:types[path.extname(file)]}]));
// --public: the deployed HTTPS relay and the Mac's real provisioning instead.
const relay=provisioned?null:createRelay({secret,origin,assets,insecureTest:true});
if(relay)await new Promise(resolve=>relay.listen(port,'127.0.0.1',resolve));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const work=mkdtempSync(path.join(tmpdir(),'st-phone-mac-'));
const mac=spawn(probe,provisioned?['provisioned','-',work]:[origin,secret,work],{stdio:['ignore','inherit','inherit']});
const macExit=new Promise(resolve=>mac.on('exit',resolve));
const status=()=>{try{return JSON.parse(readFileSync(path.join(work,'status.json'),'utf8'));}catch{return {};}};
const profile=mkdtempSync(path.join(tmpdir(),'st-chrome-'));
let chrome, socket, id=0; const pending=new Map();
const cdp=(method,params={},sessionId)=>{const m={id:++id,method,params};if(sessionId)m.sessionId=sessionId;socket.send(JSON.stringify(m));
  return new Promise((resolve,reject)=>pending.set(m.id,{resolve,reject}));};
try {
  for(let i=0;i<300&&!existsSync(path.join(work,'invitation.txt'));i++)await sleep(200);
  const invitation=readFileSync(path.join(work,'invitation.txt'),'utf8');
  console.log('PASS: Mac relay client opened its room and created an invitation');
  chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--remote-debugging-port=9335',
    `--user-data-dir=${profile}`,'--no-first-run','--no-default-browser-check','--use-fake-ui-for-media-stream',
    '--use-fake-device-for-media-stream',`--use-file-for-fake-audio-capture=${path.resolve(input)}`,
    '--disable-features=AudioServiceOutOfProcess,AudioServiceSandbox','--autoplay-policy=no-user-gesture-required','about:blank'],{stdio:'ignore'});
  let version;
  for(let i=0;i<50&&!version;i++){try{version=await (await fetch('http://127.0.0.1:9335/json/version')).json();}catch{await sleep(200);}}
  socket=new WebSocket(version.webSocketDebuggerUrl);
  await new Promise(r=>socket.addEventListener('open',r));
  socket.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);m.error?p.reject(Error(m.error.message)):p.resolve(m.result);}});
  const {targetId}=await cdp('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await cdp('Target.attachToTarget',{targetId,flatten:true});
  const evaluate=async(expression,gesture=false)=>(await cdp('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true,userGesture:gesture},sessionId)).result.value;
  const expect=async(expression,label,tries=100)=>{for(let i=0;i<tries;i++){if(await evaluate(expression)===true){console.log('PASS: '+label);return;}await sleep(200);}
    console.log('PAGE',await evaluate('JSON.stringify({rows:document.getElementById("rows").textContent.slice(-300),status:document.getElementById("mic-status").textContent,connection:document.getElementById("connection").textContent,live:document.body.classList.contains("live"),dock:document.getElementById("dock").hidden,mic:document.getElementById("mic").hidden,hint:document.getElementById("empty-hint").textContent,secure:isSecureContext,remote:!!globalThis.StreamTranslateRemote?.microphone})'));
    console.log('MAC',JSON.stringify(status()).slice(0,600));throw Error(label);};
  const began=Date.now();
  await cdp('Page.navigate',{url:invitation},sessionId);
  await expect('document.body.classList.contains("live")&&!document.getElementById("mic").hidden','Phone pairs with the Mac and is offered the microphone');
  for(let i=0;i<20&&status().paired!==1;i++)await sleep(250);
  assert.equal(status().paired,1,'Mac saved the paired browser');console.log('PASS: Mac saved the paired browser for later restarts');
  await evaluate('document.getElementById("mic").click();true',true);
  await expect('document.getElementById("mic").getAttribute("aria-pressed")==="true"','Phone microphone starts');
  for(let i=0;i<50&&status().source!=='phoneMicrophone';i++)await sleep(200);
  assert.equal(status().source,'phoneMicrophone');console.log('PASS: Mac started recognition from the phone stream');
  await expect('document.getElementById("mic-status").textContent.includes("电脑正在识别")','Phone shows the Mac is recognizing it');
  await expect('/most important thing/i.test(document.getElementById("rows").textContent)','English heard by the phone appears as a caption on the phone',150);
  await expect('/最重要/.test(document.getElementById("rows").textContent)','Its Chinese translation reaches the phone',150);
  console.log(`PASS: first translated caption on the phone after ${((Date.now()-began)/1000).toFixed(1)} s (audio starts at the tap)`);
  // Wait for a finished sentence with its final translation, not just a draft.
  let final=null;
  for(let i=0;i<100&&!final;i++){final=(status().captions||[]).find(c=>/faster than before/i.test(c.original)&&/[\u4e00-\u9fff]{6}/.test(c.translation));if(!final)await sleep(250);}
  assert(final,'Mac committed a complete sentence with its translation');
  console.log('PASS: Mac committed',JSON.stringify(final));
  await expect(`document.getElementById("rows").textContent.includes(${JSON.stringify(final.translation)})`,'The final translation replaces the draft on the phone');
  await evaluate('document.getElementById("mic").click();true',true);
  for(let i=0;i<60&&status().recording;i++)await sleep(250);
  assert.equal(status().recording,false,'stopping on the phone stops the Mac capture');
  console.log('PASS: stopping on the phone ends the Mac capture');
  console.log('MAC CAPTIONS',JSON.stringify((status().captions||[]).slice(0,4)));
} finally {
  writeFileSync(path.join(work,'command.txt'),'stop');
  await Promise.race([macExit,sleep(8000)]);mac.kill();
  socket?.close();chrome?.kill();if(relay){relay.closeAllConnections();await new Promise(resolve=>relay.close(resolve));}
  await sleep(300);rmSync(profile,{recursive:true,force:true});rmSync(work,{recursive:true,force:true});
}

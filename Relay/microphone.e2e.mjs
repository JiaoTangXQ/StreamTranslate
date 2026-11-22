// End-to-end: headless Chrome plays a WAV file as its microphone into the
// real phone page (remote.js + mic-worklet.js), through the relay, to a Node
// stand-in for the Mac that decrypts the audio exactly as CompanionKit does.
//   node Relay/microphone.e2e.mjs <exported public dir> <48k-s16.wav> <output.wav>
import {createRelay} from './server.mjs';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {randomBytes,createCipheriv,createDecipheriv,hkdfSync} from 'node:crypto';
import {spawn} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';

const [publicDir,input,output]=process.argv.slice(2);
if(!publicDir||!input||!output)throw Error('usage: microphone.e2e.mjs PUBLIC_DIR INPUT_WAV OUTPUT_WAV');
const token=()=>randomBytes(32).toString('hex');
const secret=token(), room=token(), ticket=token(), key=randomBytes(32), port=18481, origin=`http://127.0.0.1:${port}`;
const types={'.js':'application/javascript','.css':'text/css','.html':'text/html','.svg':'image/svg+xml','.webmanifest':'application/manifest+json'};
const files={'/':'index.html','/app.js':'app.js','/remote.js':'remote.js','/mic-worklet.js':'mic-worklet.js','/style.css':'style.css','/icon.svg':'icon.svg','/manifest.webmanifest':'manifest.webmanifest'};
const assets=new Map(Object.entries(files).map(([url,file])=>[url,{data:readFileSync(path.join(publicDir,file)),type:types[path.extname(file)]}]));
const relay=createRelay({secret,origin,assets,insecureTest:true});
await new Promise(resolve=>relay.listen(port,'127.0.0.1',resolve));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const pub=async(op,body={})=>(await fetch(origin+'/publisher/'+op,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+secret},body:JSON.stringify({room,...body})})).json();
let seq=0;
async function publish(phoneMicrophone,captions=[]) {
  const snapshot={sessionID:'00000000-0000-0000-0000-000000000001',sequence:++seq,captions,status:'stopped',phoneMicrophone,
    mindMap:{revision:1,topics:[{title:'发布计划',summary:'推迟到月底',advertisement:false,branches:[{title:'原因',points:['性能问题']}]}]}};
  const iv=randomBytes(12),c=createCipheriv('aes-256-gcm',key,iv);c.setAAD(Buffer.from(`${room}:${seq}:snapshot`));
  await pub('publish',{frame:{seq,kind:'snapshot',data:Buffer.concat([iv,c.update(JSON.stringify(snapshot)),c.final(),c.getAuthTag()]).toString('base64')}});
}
const uplink=Buffer.from(hkdfSync('sha256',key,Buffer.from(room),Buffer.from('StreamTranslate phone audio v1'),32));
function open(item) {
  const box=Buffer.from(item.data,'base64'),d=createDecipheriv('aes-256-gcm',uplink,box.subarray(0,12));
  d.setAAD(Buffer.from(`${room}:${item.stream}:${item.seq}:audio`));d.setAuthTag(box.subarray(-16));
  const clear=Buffer.concat([d.update(box.subarray(12,-16)),d.final()]);
  assert.equal(clear.subarray(0,4).toString(),'STA1');
  return {first:clear.readUInt32BE(4),end:(clear[8]&1)===1,samples:new Int16Array(clear.buffer.slice(clear.byteOffset+10,clear.byteOffset+clear.length))};
}

// Minimal Chrome DevTools Protocol client over Node's built-in WebSocket.
const profile=mkdtempSync(path.join(tmpdir(),'st-mic-'));
const chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--remote-debugging-port=9334',
  `--user-data-dir=${profile}`,'--no-first-run','--no-default-browser-check',
  // No fake permission UI: the test grants or denies the microphone itself.
  '--use-fake-device-for-media-stream',...(input==='beep'?[]:[`--use-file-for-fake-audio-capture=${path.resolve(input)}`]),'--autoplay-policy=no-user-gesture-required','--disable-features=AudioServiceOutOfProcess,AudioServiceSandbox','about:blank'],{stdio:'ignore'});
let socket, id=0; const pending=new Map(), uploads=[];
async function cdp(method,params={},sessionId) {
  const message={id:++id,method,params};if(sessionId)message.sessionId=sessionId;
  socket.send(JSON.stringify(message));
  return new Promise((resolve,reject)=>pending.set(message.id,{resolve,reject}));
}
try {
  let version;
  for(let i=0;i<50&&!version;i++){try{version=await (await fetch('http://127.0.0.1:9334/json/version')).json();}catch{await sleep(200);}}
  socket=new WebSocket(version.webSocketDebuggerUrl);
  await new Promise(r=>socket.addEventListener('open',r));
  socket.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);m.error?p.reject(Error(m.error.message)):p.resolve(m.result);}
    if(m.method==='Network.responseReceived'&&m.params.response.url.endsWith('/api/audio'))uploads.push(m.params.response.status);});
  await pub('open',{devices:[]});await pub('invite',{ticket});await publish('ready');
  const heartbeat=setInterval(()=>pub('status').catch(()=>{}),1000);
  const {targetId}=await cdp('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await cdp('Target.attachToTarget',{targetId,flatten:true});
  const evaluate=async(expression,gesture=false)=>(await cdp('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true,userGesture:gesture},sessionId)).result.value;
  const expect=async(expression,label)=>{for(let i=0;i<60;i++){if(await evaluate(expression)===true){console.log('PASS: '+label);return;}await sleep(150);}
    console.log('STATE',await evaluate('JSON.stringify({status:document.getElementById("mic-status").textContent,label:document.getElementById("mic-label").textContent,connection:document.getElementById("connection").textContent,errors:globalThis.__errors||[],level:document.querySelector("#mic-level i")?.style.width,levelMax:globalThis.__level,hidden:document.getElementById("mic-level").hidden})'));
    throw Error(label);};
  // Injected scripts only run with the Page domain enabled.
  await cdp('Page.enable',{},sessionId);
  await cdp('Page.addScriptToEvaluateOnNewDocument',{source:'globalThis.__errors=[];globalThis.__level=0;globalThis.__inTap=[];addEventListener("error",e=>__errors.push(String(e.message)));addEventListener("unhandledrejection",e=>__errors.push(String(e.reason)));new MutationObserver(()=>{const w=parseFloat(document.querySelector("#mic-level i")?.style.width)||0;if(w>__level)__level=w;}).observe(document,{subtree:true,attributes:true,attributeFilter:["style"]});const gum=navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);navigator.mediaDevices.getUserMedia=c=>{__inTap.push(globalThis.event?.type==="click");return gum(c);};'},sessionId);
  await cdp('Page.navigate',{url:`${origin}/#${room}.${ticket}.${key.toString('hex')}`},sessionId);
  await expect('document.body.classList.contains("live")&&!document.getElementById("mic").hidden','Paired page shows the phone microphone control');
  await expect('document.getElementById("map-button").textContent==="脑图 1"','Mind map button reflects the Mac map');
  await evaluate('document.getElementById("map-button").click();true',true);
  await expect('!document.getElementById("mindmap").hidden&&document.getElementById("map-topics").textContent.includes("推迟到月底")','Phone shows the mind map');
  await evaluate('document.getElementById("map-close").click();true',true);
  // A denied microphone names the failing step; allowing it and tapping again works.
  await cdp('Browser.setPermission',{permission:{name:'microphone'},setting:'denied',origin});
  await evaluate('document.getElementById("mic").click();true',true);
  await expect('document.getElementById("mic-status").textContent.includes("麦克风被拒绝（NotAllowedError）")&&document.querySelector("#mic-status .mic-detail")?.textContent.includes("网站权限 denied")&&document.getElementById("mic").getAttribute("aria-pressed")==="false"','Denied microphone is reported with its error name and the site permission');
  console.log('DIAGNOSIS',await evaluate('document.getElementById("mic-status").textContent'));
  await cdp('Browser.setPermission',{permission:{name:'microphone'},setting:'granted',origin});
  await evaluate('document.getElementById("mic").click();true',true);
  await expect('document.getElementById("mic").getAttribute("aria-pressed")==="true"','Microphone starts from a tap');
  const inTap=JSON.parse(await evaluate('JSON.stringify(globalThis.__inTap??"missing")'));
  assert.deepEqual(inTap,[true,true],'the microphone is requested inside the tap, before any await: '+JSON.stringify(inTap));
  console.log('PASS: The microphone is requested synchronously inside the tap');
  await cdp('Network.enable',{},sessionId);
  // From 4 s to 7 s the phone loses its network. The page keeps up to five
  // seconds of audio, so the Mac must still receive every frame.
  const offline=on=>cdp('Network.emulateNetworkConditions',{offline:on,latency:0,downloadThroughput:-1,uploadThroughput:-1},sessionId);
  const started=Date.now(), batches=[];let stream=null, level=0, stall=0, sawRetry=false;
  while(Date.now()-started<12000) {
    if(stall===0&&Date.now()-started>4000){await offline(true);stall=1;}
    if(stall===1&&Date.now()-started>7000){await offline(false);stall=2;}
    if(stall===1&&!sawRetry)sawRetry=(await evaluate('document.getElementById("mic-status").textContent')).startsWith('网络不稳定');
    for(const item of (await pub('audio')).items){stream??=item.stream;assert.equal(item.stream,stream);batches.push({...item,...open(item)});}
    level=Math.max(level,parseFloat(await evaluate('document.querySelector("#mic-level i").style.width'))||0);
  }
  assert(sawRetry,'phone shows that it is retrying while offline');console.log('PASS: Phone shows it is retrying during a 3 s network loss');
  await expect('document.getElementById("mic-status").textContent.startsWith("已开始收音")','Phone recovers its status after the network returns');
  const elapsed=(Date.now()-started)/1000;
  {let e=0,n=0,peak=0;for(const b of batches)if(!b.end)for(const s of b.samples){e+=(s/32768)**2;n++;peak=Math.max(peak,Math.abs(s));}console.log('RECEIVED',batches.length,'batches',n,'samples rms',Math.sqrt(e/Math.max(1,n)),'peak',peak);}
  assert(level>0,'level meter moves with the input');console.log('PASS: Level meter moves with the input (max '+level+'%)');
  await publish('listening');
  await expect('document.getElementById("mic-status").textContent.includes("电脑正在识别")','Phone shows the Mac is recognizing its audio');
  await evaluate('document.getElementById("mic").click();true',true);
  for(let i=0;i<10&&!batches.some(b=>b.end);i++)for(const item of (await pub('audio')).items)batches.push({...item,...open(item)});
  clearInterval(heartbeat);
  // Ordered, contiguous 100 ms frames at 16 kHz, roughly real time.
  const audio=batches.filter(b=>!b.end);
  for(let i=1;i<audio.length;i++){assert(audio[i].seq>audio[i-1].seq);assert.equal(audio[i].first,audio[i-1].first+audio[i-1].samples.length/1600);}
  const total=audio.reduce((n,b)=>n+b.samples.length,0);
  assert(total%1600===0,'whole frames');
  assert(total/16000>elapsed*0.75&&total/16000<elapsed*1.15,`real-time rate: ${total/16000}s audio in ${elapsed}s`);
  let energy=0;for(const b of audio)for(const s of b.samples)energy+=(s/32768)**2;
  const rms=Math.sqrt(energy/total);assert(rms>0.01,`audible input, rms=${rms}`);
  assert(batches.some(b=>b.end),'stop sends an end marker');
  assert(!uploads.includes(429),'catching up stays under the relay rate limit');
  console.log('PASS: no frame lost across the network loss; upload statuses',JSON.stringify(uploads.reduce((m,s)=>(m[s]=(m[s]||0)+1,m),{})));
  console.log(`PASS: ${audio.length} encrypted batches, ${(total/16000).toFixed(1)} s of 16 kHz audio in ${elapsed.toFixed(1)} s, rms ${rms.toFixed(3)}`);
  // Save what the Mac received, to check that it is still recognizable speech.
  const pcm=Buffer.concat(audio.map(b=>Buffer.from(b.samples.buffer,b.samples.byteOffset,b.samples.byteLength)));
  const header=Buffer.alloc(44);header.write('RIFF',0);header.writeUInt32LE(36+pcm.length,4);header.write('WAVEfmt ',8);
  header.writeUInt32LE(16,16);header.writeUInt16LE(1,20);header.writeUInt16LE(1,22);header.writeUInt32LE(16000,24);
  header.writeUInt32LE(32000,28);header.writeUInt16LE(2,32);header.writeUInt16LE(16,34);header.write('data',36);header.writeUInt32LE(pcm.length,40);
  writeFileSync(output,Buffer.concat([header,pcm]));
  console.log('Wrote',output);
} finally {
  socket?.close();chrome.kill();relay.closeAllConnections();await new Promise(resolve=>relay.close(resolve));
  await sleep(300);rmSync(profile,{recursive:true,force:true});
}

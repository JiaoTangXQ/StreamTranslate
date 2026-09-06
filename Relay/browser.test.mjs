import {createRelay} from './server.mjs';
import {readFileSync} from 'node:fs';
import {randomBytes,createCipheriv,createECDH,hkdfSync} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import path from 'node:path';
import assert from 'node:assert/strict';
const exec=promisify(execFile), token=()=>randomBytes(32).toString('hex');
const secret=token(), room=token(), ticket=token(), key=randomBytes(32), origin='http://127.0.0.1:18449';
const names={'/':'index.html','/app.js':'app.js','/remote.js':'remote.js','/style.css':'style.css','/icon.svg':'icon.svg','/manifest.webmanifest':'manifest.webmanifest'};
const assets=new Map(Object.entries(names).map(([url,file])=>[url,{data:readFileSync('build/remote-relay/public/'+file),type:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'}]));
const relay=createRelay({secret,origin,assets,insecureTest:true});
await new Promise(resolve=>relay.listen(18449,'127.0.0.1',resolve));
const session='st-remote-'+Date.now(), executable=path.resolve('build/web-browser-tools/node_modules/.bin/agent-browser');
const env={...process.env,PATH:path.resolve('build/web-browser-tools/node_modules/.bin')+':'+process.env.PATH};
const browser=async(...args)=>(await exec(executable,['--session',session,...args],{env,timeout:20000})).stdout.trim();
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const pub=async(op,body={})=>{
  const r=await fetch(origin+'/publisher/'+op,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+secret},body:JSON.stringify({room,...body})});assert.equal(r.status,200);return r.json();
};
async function expect(js,label){for(let i=0;i<30;i++){if(await browser('eval',js)==='true'){console.log('PASS: '+label);return;}await sleep(150);}throw Error(label);}
async function restoreReaders() {
  const status=await pub('status');
  for(const request of status.recoveries||[]) {
    const ecdh=createECDH('prime256v1');ecdh.generateKeys();
    const context=Buffer.from(`StreamTranslate recovery v1:${room}:${request.id}`);
    const wrapping=Buffer.from(hkdfSync('sha256',ecdh.computeSecret(Buffer.from(request.publicKey,'base64')),Buffer.from(room),context,32));
    const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',wrapping,iv);cipher.setAAD(context);
    const data=Buffer.concat([iv,cipher.update(key),cipher.final(),cipher.getAuthTag()]).toString('base64');
    await pub('recover',{id:request.id,publicKey:ecdh.getPublicKey().toString('base64'),data});
  }
}
let seq=0,timer;
async function publish(text='手机流量也能显示私密字幕',bad=false){
  const snapshot={sessionID:'synthetic',sequence:++seq,captions:[{id:'row',original:'Private <script>not code</script>',translation:text}],status:'listening'};
  const iv=randomBytes(12),c=createCipheriv('aes-256-gcm',key,iv);c.setAAD(Buffer.from(`${room}:${seq}:snapshot`));
  const data=Buffer.concat([iv,c.update(JSON.stringify(snapshot)),c.final(),c.getAuthTag()]);if(bad)data[13]^=1;
  await pub('publish',{frame:{seq,kind:'snapshot',data:data.toString('base64')}});
}
try {
  await pub('open');await pub('invite',{ticket});await publish();
  timer=setInterval(()=>restoreReaders().catch(()=>{}),1000);
  await browser('--executable-path','/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','open',origin);
  await browser('set','viewport','393','852');
  await expect('!document.getElementById("pairing").hidden','Unpaired reader is blocked');
  await browser('eval',`location.hash=${JSON.stringify(room+'.'+ticket+'.'+key.toString('hex'))};true`);
  await expect('document.body.classList.contains("live")&&document.getElementById("rows").textContent.includes("手机流量")&&location.hash===""','QR pairs, browser decrypts, fragment removed');
  await expect('!document.querySelector("#rows script")&&document.getElementById("reader").clientHeight===innerHeight&&document.getElementById("topbar").hidden','Full viewport; text is not executed as HTML');
  await browser('click','#reader');await expect('!document.getElementById("topbar").hidden','Tap reveals settings');
  await sleep(3300);await expect('document.getElementById("topbar").hidden','Controls hide again without taking layout space');
  await browser('reload');await expect('document.body.classList.contains("live")','Reload reconnects without rescanning');
  // iOS Add to Home Screen copies cookies, not localStorage (WebKit 17.2+).
  await browser('eval','localStorage.removeItem("streamtranslate.remote.v1");true');
  await browser('reload');
  await expect('document.body.classList.contains("live")','Home-screen launch restores key with retained authorization cookie');
  await browser('reload');await expect('document.body.classList.contains("live")','Recovered Home Screen credentials survive reopen');
  await browser('eval',`location.hash=${JSON.stringify(room+'.'+ticket+'.'+key.toString('hex'))};true`);
  await expect('document.body.classList.contains("live")&&location.hash===""','Consumed QR in bookmark reuses valid authorization');
  await browser('eval',`location.hash=${JSON.stringify(token()+'.'+token()+'.'+token())};true`);
  await expect('document.body.classList.contains("live")&&location.hash===""','Obsolete room bookmark falls back to current valid authorization');
  await publish('修订后的译文');await expect('document.getElementById("rows").textContent.includes("修订后的译文")&&document.querySelectorAll(".caption").length===1','Refinement replaces same caption');
  await expect('!JSON.stringify(localStorage).includes("修订后的译文")&&!document.cookie.includes("stremote")','No transcript storage; cookie hidden from JS');
  await browser('screenshot','build/remote-reader.png');
  await publish('不应展示的篡改字幕',true);await expect('!document.body.classList.contains("live")&&!document.getElementById("rows").textContent.includes("篡改")','Tampered ciphertext fails closed and clears text');
  await publish('恢复连接');await expect('document.body.classList.contains("live")&&document.getElementById("rows").textContent.includes("恢复连接")','Recovers after authenticated fresh snapshot');
  await pub('close');await expect('!document.body.classList.contains("live")&&!document.getElementById("rows").textContent','Stopping relay clears phone text');
  await browser('eval','document.getElementById("topbar").hidden=false;document.getElementById("settings").hidden=false;true');
  await browser('click','#retry');
  await expect('!document.getElementById("pairing").hidden&&!document.getElementById("pair-form").hidden&&document.getElementById("settings").hidden','Expired authorization: retry reveals actionable pairing, not a hidden dead end');
  await pub('open');const newTicket=token();await pub('invite',{ticket:newTicket});seq=0;await publish('粘贴链接配对成功');
  await browser('fill','#pair-code',origin+'/#'+room+'.'+newTicket+'.'+key.toString('hex'));
  await browser('click','#pair-submit');
  await expect('document.body.classList.contains("live")&&document.getElementById("rows").textContent.includes("粘贴链接")','Standalone without auth can pair in place using pasted fresh link');
} finally {clearInterval(timer);await browser('close').catch(()=>{});relay.closeAllConnections();await new Promise(resolve=>relay.close(resolve));}

// Explicit isolated Chromium UI regression against CompanionProbe --web-fixture.
// TLS identity validation is separately tested by curl --cacert and iOS Safari.
import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import path from 'node:path';
const directory=process.argv[2];
if(!directory)throw Error('Pass a running --web-fixture private directory');
const executable=path.resolve('build/web-browser-tools/node_modules/.bin/agent-browser');
const address=readFileSync(`${directory}/address.txt`,'utf8'),host=new URL(address).hostname;
const secure=address.startsWith('https:');
const artifact=secure?'web-reader':'web-quick-reader';
const session=`st-web-regression-${Date.now()}`;
const env={...process.env,PATH:path.resolve('build/web-browser-tools/node_modules/.bin')+':'+process.env.PATH};
const browser=(...args)=>execFileSync(executable,['--session',session,...args],{encoding:'utf8',env,timeout:20000});
const evalJS=js=>browser('eval',js).trim();
const sleep=ms=>new Promise(r=>setTimeout(r,ms));let serial=0;
let cdp=null, cdpPage=null, cdpSerial=0;
const pending=new Map();
async function protocol(method,params={},sessionId){
 const id=++cdpSerial;
 return new Promise((resolve,reject)=>{
  const timer=setTimeout(()=>{pending.delete(id);reject(Error('CDP timeout: '+method));},8000);
  pending.set(id,{resolve:result=>{clearTimeout(timer);resolve(result);},reject:error=>{clearTimeout(timer);reject(error);}});
  cdp.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));
 });
}
async function attachInput(){
 // Only the isolated browser created above; never discover a user's browser.
 const endpoint=browser('get','cdp-url').trim();
 assert.equal(new URL(endpoint).hostname,'127.0.0.1');
 cdp=new WebSocket(endpoint);
 await new Promise((resolve,reject)=>{cdp.addEventListener('open',resolve,{once:true});cdp.addEventListener('error',reject,{once:true});});
 cdp.addEventListener('message',event=>{const m=JSON.parse(event.data),p=pending.get(m.id);if(p){pending.delete(m.id);if(m.error)p.reject(Error(m.error.message));else p.resolve(m.result);}});
 const {targetInfos}=await protocol('Target.getTargets');
 const target=targetInfos.find(t=>t.type==='page'&&t.url.startsWith(address+'/'));
 assert.ok(target,'Isolated fixture page exists');
 cdpPage=(await protocol('Target.attachToTarget',{targetId:target.targetId,flatten:true})).sessionId;
}
async function wheel(deltaY,x=180,y=180){
 // agent-browser 0.36's separate mouse wheel command delivers at (0,0), even
 // after mouse move. Supply actual coordinates through the same browser CDP.
 await protocol('Input.dispatchMouseEvent',{type:'mouseWheel',x,y,deltaX:0,deltaY},cdpPage);
 await sleep(250);
}
async function touch(points){
 await protocol('Emulation.setTouchEmulationEnabled',{enabled:true,maxTouchPoints:1},cdpPage);
 await protocol('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:points[0][0],y:points[0][1]}]},cdpPage);
 for(const [x,y] of points.slice(1)){await protocol('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x,y}]},cdpPage);await sleep(60);}
 await protocol('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]},cdpPage);
 await sleep(400);
}
async function command(value){writeFileSync(`${directory}/command.txt`,value+'\n'+' '.repeat(++serial));await sleep(1300);}
async function expect(js,label){for(let i=0;i<30;i++){if(evalJS(js)==='true'){console.log('PASS: '+label);return;}await sleep(200);}throw Error('UI assertion: '+label);}
try {
 await command('reset');
 const args=['--executable-path','/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '--args',`--host-resolver-rules=MAP ${host} 127.0.0.1,--no-proxy-server,--disable-gpu`];
 if(secure)args.push('--ignore-https-errors');
 browser(...args,'open',address+'/');
 await attachInput();
 browser('set','viewport','393','852');
 await expect('!document.getElementById("pairing").hidden && !document.body.classList.contains("live")','Unpaired browser never displays captions');
 if(!secure)await expect('document.getElementById("transport-note").textContent.includes("HTTP 未加密") && document.getElementById("keep-awake").disabled','Plain HTTP clearly labelled; unsupported wake-lock control disabled');
 await command('invite');
 const hash=new URL(readFileSync(`${directory}/invitation.txt`,'utf8')).hash;
 evalJS(`location.hash=${JSON.stringify(hash)};true`);
 await expect('document.body.classList.contains("live") && location.hash===""','Already-open page accepts QR fragment and erases invitation from URL');
 await expect('document.querySelectorAll(".caption").length===3 && document.querySelectorAll("#rows script").length===0 && document.getElementById("rows").textContent.includes("<script>")','Literal untrusted text, not HTML execution');
 console.log('Reading baseline: '+evalJS('JSON.stringify({topbarHeight:document.getElementById("topbar").getBoundingClientRect().height,readerHeight:document.getElementById("reader").clientHeight,viewport:innerHeight})'));
 evalJS('dispatchEvent(new Event("wheel"));true');
 await expect('document.getElementById("follow").hidden','A gesture without leaving live position does not show return-to-live');
 await expect('document.getElementById("topbar").hidden && document.getElementById("connection").hidden && document.getElementById("reader").clientHeight>=innerHeight-1','Idle reading uses the full viewport without fixed header');
 browser('screenshot',`build/${artifact}-final.png`);
 browser('click','#reader');
 await expect('!document.getElementById("topbar").hidden','Tap reveals reading controls');
 browser('click','#settings-button');
 evalJS('const o=document.getElementById("show-original");o.checked=false;o.dispatchEvent(new Event("change"));const f=document.getElementById("font-size");f.value="34";f.dispatchEvent(new Event("input"));true');
 await expect('getComputedStyle(document.querySelector(".original")).display==="none" && getComputedStyle(document.querySelector(".translation")).fontSize==="34px"','Original toggle and font setting update display');
 browser('set','viewport','393','320');
 await wheel(400,190,265);
 await expect('document.getElementById("settings").scrollTop>0 && document.getElementById("follow").hidden && document.getElementById("reader").clientHeight===innerHeight','Settings scroll does not pause captions or consume reader layout');
 await sleep(3300);
 await expect('!document.getElementById("settings").hidden','Open settings stay available while adjusting preferences');
 browser('screenshot',`build/${artifact}-settings.png`);
 browser('set','viewport','393','852');
 browser('reload');
 await expect('document.body.classList.contains("live") && document.getElementById("font-size").value==="34" && !document.getElementById("show-original").checked','Reload restores pairing and reading preferences');
 await expect('!document.cookie.includes("stcaption") && Object.keys(localStorage).every(k=>["font","original","awake"].includes(k))','Credential inaccessible to JS; no captions stored in localStorage');
 await command('refine');
 await expect('document.getElementById("rows").textContent.includes("精修字幕") && document.querySelectorAll(".caption").length===3','Same-row refinement does not duplicate captions');
 await command('long-history');
 await command('grow-draft');
 await expect('document.querySelectorAll(".caption").length===21 && document.getElementById("follow").hidden','Growing text and overflow alone never enter history mode');
 browser('screenshot',`build/${artifact}-immersive.png`);
 // A small viewport guarantees actual overflow even with short test captions.
 browser('set','viewport','393','320');
 browser('mouse','move','180','180');
 await wheel(-20000);
 await expect('!document.getElementById("follow").hidden && document.getElementById("reader").scrollTop<30','Actual history scroll pauses live following');
 await sleep(2200);
 await expect('!document.getElementById("follow").hidden && document.getElementById("reader").scrollTop<30','Continuous updates do not pull history to live');
 await wheel(20000);
 await expect('document.getElementById("follow").hidden','Manually scrolling to latest hides the hint');
 evalJS('window.hintFlashed=false;window.hintObserver=new MutationObserver(()=>{if(!document.getElementById("follow").hidden)window.hintFlashed=true;});window.hintObserver.observe(document.getElementById("follow"),{attributes:true,attributeFilter:["hidden"]});true');
 await sleep(2200);
 await expect('document.getElementById("follow").hidden && document.getElementById("reader").scrollHeight-document.getElementById("reader").scrollTop-document.getElementById("reader").clientHeight<48','Continuous updates retain live following without hint');
 await expect('!window.hintFlashed','No transient return-to-live hint during growing updates');
 evalJS('window.hintObserver.disconnect();true');
 await wheel(-500);
 await expect('!document.getElementById("follow").hidden','History hint returns only after leaving latest');
 browser('click','#follow');
 await expect('document.getElementById("follow").hidden','Return-to-live control resumes following');
 browser('set','viewport','393','852');
 browser('click','#reader');
 await expect('!document.getElementById("topbar").hidden','Tap can reveal controls after scrolling');
 await sleep(3500);
 await expect('document.getElementById("topbar").hidden','Inactive controls disappear without reserving space');
 await touch([[170,500]]);
 await expect('!document.getElementById("topbar").hidden','Touchscreen tap also reveals controls');
 await touch([[170,500],[170,550],[170,610],[170,690]]);
 await expect('document.getElementById("topbar").hidden && !document.getElementById("follow").hidden','Actual touch drag reviews history without opening settings');
 browser('click','#follow');
 await expect('document.getElementById("follow").hidden','Touch history can return to live');
 await touch([[170,500],[170,450],[170,400]]);
 await expect('document.getElementById("follow").hidden','Touch overscroll at latest does not show history hint');
 browser('press','Tab');
 await expect('!document.getElementById("topbar").hidden','Keyboard users can discover hidden controls');
 browser('press','Escape');
 await expect('document.getElementById("topbar").hidden','Escape dismisses controls');
 evalJS('dispatchEvent(new Event("pagehide"));true');
 await expect('!document.getElementById("privacy").hidden && document.querySelectorAll(".caption").length===0','Page-hide handler covers and clears captions');
 browser('reload');await expect('document.body.classList.contains("live")','Reload resumes current snapshot');
 browser('set','viewport','852','393');
 await expect('document.documentElement.scrollWidth<=innerWidth && document.getElementById("reader").clientHeight>=innerHeight-1 && document.getElementById("topbar").hidden','Landscape also uses the full viewport');
 browser('screenshot',`build/${artifact}-landscape-final.png`);
 await command('new-session');
 await expect('document.querySelectorAll(".caption").length===1 && !document.getElementById("rows").textContent.includes("精修字幕")','New meeting removes prior meeting text');
 await command('stop');
 await expect('!document.body.classList.contains("live") && document.querySelectorAll(".caption").length===0','Lost connection hides stale text');
 browser('screenshot',`build/${artifact}-offline-final.png`);
 await command('start');
 if(secure)await expect('document.body.classList.contains("live")','Service restart automatically reconnects');
 else{
  await expect('!document.getElementById("pairing").hidden && !document.body.classList.contains("live")','Quick service restart requires a fresh invitation');
  await command('invite');
  const newHash=new URL(readFileSync(`${directory}/invitation.txt`,'utf8')).hash;
  evalJS(`location.hash=${JSON.stringify(newHash)};true`);
  await expect('document.body.classList.contains("live")','New QR restores quick reader after service restart');
 }
 await command('revoke');
 await expect('!document.getElementById("pairing").hidden && !document.body.classList.contains("live")','Revocation returns to pairing');
 console.log('WEB READER REGRESSIONS PASSED; viewport emulation and dispatched lifecycle events are not physical iPhone tests');
} catch(error) {
 console.log('Reader failure geometry: '+evalJS('JSON.stringify(Object.fromEntries(["reader","settings","topbar","follow"].map(id=>{const e=document.getElementById(id);return [id,{hidden:e.hidden,top:e.getBoundingClientRect().top,height:e.clientHeight,scroll:e.scrollTop,content:e.scrollHeight}]})))'));
 browser('screenshot',`build/${artifact}-failure.png`);
 throw error;
} finally {cdp?.close();browser('close');}

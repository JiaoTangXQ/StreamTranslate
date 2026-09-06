import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync} from 'node:fs';
import path from 'node:path';
const directory=process.argv[2], session='st-public-'+Date.now();
const executable=path.resolve('build/web-browser-tools/node_modules/.bin/agent-browser');
const env={...process.env,PATH:path.resolve('build/web-browser-tools/node_modules/.bin')+':'+process.env.PATH};
const browser=(...args)=>execFileSync(executable,['--session',session,...args],{env,encoding:'utf8',timeout:20000}).trim();
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function expect(js,label){for(let i=0;i<30;i++){if(browser('eval',js)==='true'){console.log('PASS: '+label);return;}await sleep(200);}throw Error(label);}
try {
  let invitation;
  for(let i=0;i<30;i++){try{invitation=readFileSync(path.join(directory,'invitation.txt'),'utf8');break;}catch{await sleep(500);}}
  if(!invitation)throw Error('Swift fixture did not create invitation');
  const url=new URL(invitation);
  // Real public certificate validation: no ignore-https-errors or host mapping.
  browser('--executable-path','/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','open',url.origin);
  browser('set','viewport','393','852');
  browser('eval',`location.hash=${JSON.stringify(url.hash)};true`);
  await expect('document.body.classList.contains("live")&&document.getElementById("rows").textContent.includes("跨网络加密字幕测试")','Swift CryptoKit → public HTTPS relay → browser WebCrypto');
  await expect('isSecureContext&&location.hash===""&&document.getElementById("reader").clientHeight===innerHeight&&document.getElementById("topbar").hidden','Trusted HTTPS and full-screen reading layout');
  const old=browser('eval','document.getElementById("rows").textContent');
  for(let i=0;i<30&&browser('eval','document.getElementById("rows").textContent')===old;i++)await sleep(300);
  if(browser('eval','document.getElementById("rows").textContent')===old)throw Error('Live update missing');
  console.log('PASS: encrypted incremental live updates');
  browser('reload');await expect('document.body.classList.contains("live")','Public reload restores pairing and decrypts cached base/deltas');
  browser('eval','localStorage.removeItem("streamtranslate.remote.v1");true');
  browser('reload');
  await expect('document.body.classList.contains("live")&&document.getElementById("rows").textContent.includes("跨网络加密字幕测试")','Home Screen cookie-only launch: Swift P-256/HKDF wraps key, WebCrypto recovers over public HTTPS');
  browser('reload');await expect('document.body.classList.contains("live")','Recovered standalone credentials survive reopen');
  browser('eval',`location.hash=${JSON.stringify(url.hash)};true`);
  await expect('document.body.classList.contains("live")&&location.hash===""','Public saved QR bookmark does not reuse consumed invitation');
  browser('eval','location.hash="0".repeat(64)+"."+"1".repeat(64)+"."+"2".repeat(64);true');
  await expect('document.body.classList.contains("live")&&location.hash===""','Public obsolete-room bookmark preserves current authorization');
  browser('screenshot','build/remote-public-reader.png');
  for(let i=0;i<20&&readFileSync(path.join(directory,'connected.txt'),'utf8')!=='yes';i++)await sleep(300);
  if(readFileSync(path.join(directory,'connected.txt'),'utf8')!=='yes')throw Error('Mac did not see browser acknowledgement');
  console.log('PASS: Mac confirms connected only after browser acknowledgement');
  writeFileSync(path.join(directory,'command.txt'),'stop');
  await expect('!document.body.classList.contains("live")&&document.getElementById("rows").textContent===""','Mac stops: public phone clears captions');
} finally {browser('close');writeFileSync(path.join(directory,'command.txt'),'stop');}

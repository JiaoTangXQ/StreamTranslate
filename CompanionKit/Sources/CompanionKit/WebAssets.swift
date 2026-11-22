#if os(macOS)
enum WebAssets {
    static let manifest = ##"{"id":"/","name":"StreamTranslate 私密字幕","short_name":"私密字幕","start_url":"/","scope":"/","display":"standalone","background_color":"#111516","theme_color":"#111516","icons":[{"src":"/icon.svg","sizes":"any","type":"image/svg+xml","purpose":"any"}]}"##
    static let icon = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192"><rect width="192" height="192" rx="44" fill="#111516"/><rect x="36" y="46" width="120" height="90" rx="18" fill="none" stroke="#83e9bd" stroke-width="10"/><path d="M56 77h80M56 105h50M75 153h42" stroke="#83e9bd" stroke-width="10" stroke-linecap="round"/></svg>"##
    static let html = #"""
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="theme-color" content="#111516"><meta name="apple-mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-status-bar-style" content="black-translucent"><title>私密字幕 · StreamTranslate</title><link rel="manifest" href="/manifest.webmanifest"><link rel="icon" href="/icon.svg"><link rel="stylesheet" href="/style.css"><script src="/app.js" defer></script></head>
<body><div id="connection" role="status">正在连接电脑…</div>
<div id="topbar" hidden><button id="settings-button" aria-label="字幕设置" aria-expanded="false" aria-controls="settings">Aa</button>
<section id="settings" aria-label="字幕设置" hidden><div class="settings-heading"><strong>阅读设置</strong><button id="settings-close" aria-label="关闭设置">完成</button></div><label>译文字号 <input id="font-size" type="range" min="18" max="42" value="27"></label><label><input id="show-original" type="checkbox" checked> 显示原文</label><label><input id="keep-awake" type="checkbox" checked> 阅读时保持亮屏</label><p id="wake-status"></p><p id="engine"></p>
<p id="transport-note" class="muted">局域网字幕连接</p><p id="browser-note" class="muted" hidden>微信内若连接失败，请点右上角菜单在 Safari 打开，或用 iPhone 自带相机重新扫码。</p>
<p>音频与模型留在 Mac，这里只接收文字。Safari 分享 → 添加到主屏幕，可创建快捷入口。字幕只保存在当前页面内存。</p><button id="retry">重新连接</button></section>
</div><main><section id="pairing" hidden><span class="eyebrow">YOUR MAC. YOUR SUBTITLES.</span><h2>电脑翻译，<br>手机安静地看。</h2><p>在 Mac 的“手机字幕”点击连接按钮，用相机扫二维码即自动配对；也可输入两分钟有效的配对码。</p><form id="pair-form"><label for="pair-code">8 位配对码</label><input id="pair-code" inputmode="numeric" autocomplete="off" maxlength="8" placeholder="00000000" required pattern="[0-9]{8}"><button type="submit" id="pair-submit">连接我的 Mac</button></form><p id="pair-error" role="alert"></p><p class="muted">同一可互通局域网 · 不上传音频</p></section>
<section id="waiting"><h2>等待电脑字幕</h2><p>Mac 需要保持唤醒并开启网页字幕。连接恢复后显示当前内容，不重播旧字幕。</p></section>
<section id="reader" aria-label="实时双语字幕，轻点显示设置" tabindex="0" hidden><div id="rows"></div><p id="empty-hint" hidden></p><div id="bottom"></div></section></main>
<div id="dock" hidden><button id="mic" aria-pressed="false" hidden><span id="mic-dot"></span><span id="mic-label">用手机收音</span></button><span id="mic-level" aria-hidden="true" hidden><i></i></span><button id="map-button" aria-label="打开对话脑图">脑图</button></div>
<p id="mic-status" role="status" hidden></p>
<section id="mindmap" aria-label="对话脑图" hidden><div class="map-heading"><strong>对话脑图</strong><button id="map-close">完成</button></div><div id="map-topics"></div></section>
<button id="follow" hidden>↓ 回到实时字幕</button><div id="privacy" hidden>私密字幕已暂停</div></body></html>
"""#
    static let css = #"""
:root{color-scheme:dark;--font:27px;--ink:#f0f1ea;--muted:#9da8a4;--accent:#83e9bd;background:#111516;color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
*{box-sizing:border-box}body{margin:0;height:100vh;height:100dvh;overflow:hidden}main{height:100%;overflow:auto}p{line-height:1.65;color:var(--muted)}h2{font-size:32px;line-height:1.3;letter-spacing:-1px}.eyebrow{font-size:10px;letter-spacing:1.6px;color:var(--muted)}.muted{font-size:12px}
button{font:inherit;background:#24352ef5;border:1px solid #3a5347;border-radius:12px;color:var(--accent);padding:10px 16px;min-height:44px;min-width:44px;cursor:pointer}button:disabled{opacity:.5;cursor:wait}button:focus-visible,input:focus-visible,#reader:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}input{accent-color:var(--accent)}input[type=range]{flex:1;min-width:80px}
#topbar{position:fixed;top:max(10px,env(safe-area-inset-top));right:max(12px,env(safe-area-inset-right));z-index:5;display:flex;flex-direction:column;align-items:flex-end;gap:8px;max-width:calc(100% - 24px)}#settings-button{font-family:Georgia,serif;font-size:22px;box-shadow:0 4px 18px #0008}#settings{width:360px;max-width:100%;max-height:calc(100dvh - max(10px,env(safe-area-inset-top)) - max(12px,env(safe-area-inset-bottom)) - 60px);overflow:auto;overscroll-behavior:contain;padding:14px 16px;background:#1a2220fa;border:1px solid #3a5347;border-radius:16px;box-shadow:0 8px 32px #0009}.settings-heading{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:8px}#settings label{display:flex;gap:12px;align-items:center;min-height:44px;font-size:15px}#settings p{font-size:12px}
#connection{position:fixed;top:max(12px,env(safe-area-inset-top));left:max(16px,env(safe-area-inset-left));right:76px;z-index:4;font-size:13px;color:var(--muted)}#pairing,#waiting{max-width:650px;margin:auto;padding:max(64px,env(safe-area-inset-top)) max(20px,env(safe-area-inset-right)) max(24px,env(safe-area-inset-bottom)) max(20px,env(safe-area-inset-left))}form{display:grid;gap:12px;margin-top:24px}form label{font-size:13px;color:var(--muted)}#pair-code{font:24px ui-monospace,monospace;letter-spacing:8px;padding:16px;border-radius:10px;border:1px solid #52655b;color:var(--ink);background:#1a2220;width:100%;min-width:0}#pair-error{color:#ffb6a6;font-size:14px}
#reader{height:100%;overflow-y:auto;overscroll-behavior-y:contain;overflow-anchor:none;padding:max(10px,env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) max(12px,env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left));-webkit-overflow-scrolling:touch}#rows,#bottom{max-width:828px;margin-inline:auto}.caption{padding:16px 0;border-bottom:1px solid #29342e}.caption:first-child{padding-top:0}.caption:last-child{border-bottom:0;padding-bottom:0}.original{font-size:max(16px,calc(var(--font)*.65));line-height:1.6;color:var(--muted);white-space:pre-wrap;overflow-wrap:anywhere;margin-bottom:8px}.translation{font-size:var(--font);line-height:1.55;white-space:pre-wrap;overflow-wrap:anywhere;font-weight:550}.draft-label{color:var(--accent);font-size:11px;margin-top:8px}body.no-original .original{display:none}
#follow{position:fixed;z-index:3;bottom:max(12px,env(safe-area-inset-bottom));left:50%;transform:translateX(-50%);box-shadow:0 5px 22px #000a;white-space:nowrap;background:#243d31f5}#privacy{position:fixed;inset:0;background:#111516;z-index:20;display:grid;place-content:center;font-size:24px}[hidden]{display:none!important}@media(prefers-reduced-motion:no-preference){button{transition:background .15s}}
#dock{position:fixed;z-index:6;left:50%;transform:translateX(-50%);bottom:max(14px,env(safe-area-inset-bottom));display:flex;gap:10px;align-items:center;padding:7px;background:#1a2220f2;border:1px solid #3a5347;border-radius:999px;box-shadow:0 6px 24px #000a;white-space:nowrap}#dock button{border-radius:999px}#mic{display:flex;gap:9px;align-items:center;padding:10px 18px;font-weight:600}#mic[aria-pressed=true]{background:#6f2621;border-color:#a8473f;color:#fff}#mic-dot{width:10px;height:10px;border-radius:50%;background:var(--accent)}#mic[aria-pressed=true] #mic-dot{background:#ff6b5e}#mic-level{width:46px;height:6px;border-radius:3px;background:#2c3a34;overflow:hidden}#mic-level i{display:block;height:100%;width:0;background:var(--accent)}
.mic-detail{font-size:11px;opacity:.75}#mic-status{position:fixed;z-index:6;left:50%;transform:translateX(-50%);bottom:calc(max(14px,env(safe-area-inset-bottom)) + 66px);margin:0;padding:6px 12px;border-radius:10px;background:#1a2220f2;border:1px solid #2f4a3d;font-size:13px;line-height:1.4;color:var(--ink);max-width:92vw;text-align:center}body.docked #reader{padding-bottom:calc(max(12px,env(safe-area-inset-bottom)) + 120px)}body.docked #follow{bottom:calc(max(12px,env(safe-area-inset-bottom)) + 70px)}#empty-hint{max-width:560px;margin:18vh auto 0;text-align:center;font-size:16px}
#mindmap{position:fixed;inset:0;z-index:15;background:#111516;overflow:auto;overscroll-behavior:contain;padding:max(16px,env(safe-area-inset-top)) max(18px,env(safe-area-inset-right)) max(28px,env(safe-area-inset-bottom)) max(18px,env(safe-area-inset-left))}.map-heading{display:flex;justify-content:space-between;align-items:center;max-width:828px;margin:0 auto 14px;font-size:18px}.map-topic{max-width:828px;margin:0 auto 14px;padding:14px 16px;border:1px solid #2f4a3d;border-radius:14px;background:#16201c}.map-topic h3{margin:0 0 4px;font-size:19px;line-height:1.4}.map-summary{margin:0 0 6px;font-size:14px}.map-branch{margin:10px 0 0 4px;padding-left:12px;border-left:2px solid #2f6f55}.map-branch strong{color:var(--accent);font-size:14px}.map-branch ul{margin:4px 0 0;padding-left:18px}.map-branch li{font-size:15px;line-height:1.55;padding:2px 0}.map-ad{opacity:.65}.map-empty{max-width:560px;margin:20vh auto;text-align:center}
"""#
    static let js = #"""
'use strict';
(() => {
 const $ = id => document.getElementById(id);
 const remote=globalThis.StreamTranslateRemote;
 const encrypted=location.protocol==='https:';
 $('transport-note').textContent=encrypted?'HTTPS 加密 · 音频留在 Mac':'快速连接 · HTTP 未加密 · 仅用于可信局域网';
 if(!encrypted)$('transport-note').style.color='#e9bb83';
 $('browser-note').hidden=!/MicroMessenger/i.test(navigator.userAgent);
 if(!encrypted){$('keep-awake').disabled=true;$('wake-status').textContent='快速连接不支持自动保持亮屏；锁屏后重新打开页面即可恢复。';}
 let source=null, generation=0, retryTimer=null, watchdog=null, attempts=0, lastBeat=0, live=false, following=true, session=null, rows=new Map(), wake=null, ackPending=false, latest=null;
 let mic=null, micStarting=false, mapRevision=-1;
 const canRecord=!!remote?.microphone&&!!navigator.mediaDevices?.getUserMedia&&isSecureContext;
 const reader=$('reader');
 let controlsTimer=null, scrollTimer=null, scrollFrame=null, scrollIntent=false, touching=false, keyboardControls=false, tapStart=null, dragged=false;
 const atLatest=()=>reader.scrollHeight-reader.scrollTop-reader.clientHeight<=48;
 function followLatest(){
  if(scrollFrame!==null)return;
  scrollFrame=requestAnimationFrame(()=>{scrollFrame=null;if(live&&following&&!scrollIntent&&$('settings').hidden){reader.scrollTop=reader.scrollHeight;$('follow').hidden=true;}});
 }
 function hideControls(){clearTimeout(controlsTimer);$('settings').hidden=true;$('topbar').hidden=true;$('settings-button').setAttribute('aria-expanded','false');followLatest();}
 function deferHide(){clearTimeout(controlsTimer);if(!$('settings').hidden)return;controlsTimer=setTimeout(()=>{if(!keyboardControls||!$('topbar').contains(document.activeElement))hideControls();},3000);}
 function showControls(){ $('topbar').hidden=false;deferHide(); }
 function finishScroll(){clearTimeout(scrollTimer);scrollTimer=setTimeout(()=>{if(touching)return;scrollIntent=false;if(following)followLatest();},180);}
 function beginScroll(){if(!live)return;scrollIntent=true;if($('settings').hidden)hideControls();finishScroll();}
 const labels={ready:'已就绪',preparing:'电脑正在准备翻译',listening:'正在聆听',finishing:'正在完成最后一句',stopped:'电脑已停止翻译',unavailable:'请在电脑上检查翻译设置'};
 const save=(key,value)=>{try{localStorage.setItem(key,String(value));}catch{}};
 const read=(key,fallback)=>{try{return localStorage.getItem(key)??fallback;}catch{return fallback;}};
 $('font-size').value=String(Math.min(42,Math.max(18,Number(read('font','27'))||27)));
 $('show-original').checked=read('original','true')==='true';
 $('keep-awake').checked=read('awake','true')==='true';
 function preferences(){document.documentElement.style.setProperty('--font',$('font-size').value+'px');document.body.classList.toggle('no-original',!$('show-original').checked);followLatest();}
 preferences();
 async function updateWake(){
  const should=(live||mic!==null)&&!document.hidden&&$('keep-awake').checked;
  if(!should){if(wake){const old=wake;wake=null;await old.release().catch(()=>{});}return;}
  if(!encrypted){$('wake-status').textContent='快速连接不支持自动保持亮屏；锁屏后重新打开页面即可恢复。';return;}
  if(!navigator.wakeLock){$('wake-status').textContent='此系统不支持网页保持亮屏，请在手机设置中调整自动锁定。';return;}
  if(wake)return;
  try{const lock=await navigator.wakeLock.request('screen');if(!live||document.hidden||!$('keep-awake').checked){await lock.release();return;}wake=lock;$('wake-status').textContent='阅读时保持亮屏已启用';lock.addEventListener('release',()=>{if(wake===lock)wake=null;$('wake-status').textContent='系统已释放亮屏保持，可重新开启；低电量等情况可能限制此功能。';});}
  catch{$('wake-status').textContent='系统未允许保持亮屏，请检查自动锁定或低电量模式。';}
 }
 $('font-size').oninput=()=>{save('font',$('font-size').value);preferences();};
 $('show-original').onchange=()=>{save('original',$('show-original').checked);preferences();};
 $('keep-awake').onchange=()=>{save('awake',$('keep-awake').checked);updateWake();};
 $('settings-button').onclick=()=>{if(!$('settings').hidden){hideControls();return;}$('settings').hidden=false;$('settings-button').setAttribute('aria-expanded','true');clearTimeout(controlsTimer);};
 $('settings-close').onclick=()=>{reader.focus({preventScroll:true});hideControls();};
 document.addEventListener('pointerdown',e=>{keyboardControls=false;tapStart={x:e.clientX,y:e.clientY};dragged=false;},{passive:true});
 document.addEventListener('pointermove',e=>{if(tapStart&&Math.hypot(e.clientX-tapStart.x,e.clientY-tapStart.y)>10)dragged=true;},{passive:true});
 document.addEventListener('pointercancel',()=>{dragged=true;tapStart=null;},{passive:true});
 document.addEventListener('click',e=>{
  if(e.target.closest('button,input,label,form,#settings,#dock,#mindmap,#mic-status'))return;
  if(dragged||!getSelection()?.isCollapsed)return;
  if($('topbar').hidden)showControls();else hideControls();
 });
 document.addEventListener('keydown',e=>{
  if(e.key==='Tab'){keyboardControls=true;showControls();}
  if(e.key==='Escape'){reader.focus({preventScroll:true});hideControls();}
  if((e.key==='Enter'||e.key===' ')&&e.target===reader){e.preventDefault();showControls();$('settings-button').focus({preventScroll:true});}
 });
 function clearCaptions(){rows.clear();$('rows').replaceChildren();reader.hidden=true;$('follow').hidden=true;following=true;scrollIntent=false;touching=false;clearTimeout(scrollTimer);session=null;latest=null;if(!mic){$('dock').hidden=true;document.body.classList.remove('docked');}$('mindmap').hidden=true;mapRevision=-1;}
 function micStatus(text,detail){const box=$('mic-status');box.textContent=text||'';if(text&&detail){const small=document.createElement('small');small.className='mic-detail';small.textContent=detail;box.append(document.createElement('br'),small);}box.hidden=!text;}
 function micListening(){micStatus(latest?.phoneMicrophone==='listening'?'电脑正在识别手机声音':'已开始收音，等待电脑开始识别…');}
 function micButton(){const on=mic!==null;$('mic').setAttribute('aria-pressed',String(on));$('mic-label').textContent=micStarting?'正在打开麦克风…':on?'停止收音':'用手机收音';$('mic').disabled=micStarting;$('mic-level').hidden=!on;if(!on)$('mic-level').firstElementChild.style.width='0';}
 async function stopMic(reason){const handle=mic;mic=null;micButton();updateWake();if(handle)await handle.stop().catch(()=>{});micStatus(reason);}
 async function startMic(){
  if(mic||micStarting||!canRecord)return;micStarting=true;micButton();micStatus('');
  try{
   const handle=await remote.microphone.start({
    onLevel:rms=>{$('mic-level').firstElementChild.style.width=Math.min(100,Math.round(Math.sqrt(rms)*260))+'%';},
    onState:s=>{if(mic===null)return;
     if(s==='offline')micStatus('电脑离线，声音暂时无法送达；电脑上线后继续');
     else if(s==='network')micStatus('网络不稳定，正在重试…');
     else if(s==='unauthorized')stopMic('授权已失效，请在 Mac 重新扫码配对');
     else if(s==='ended')stopMic('麦克风已被系统停止');
     else if(s==='sending'&&/^(网络|电脑离线)/.test($('mic-status').textContent))micListening();}
   });
   mic=handle;micListening();
  }catch(error){micStatus(micError(error),micDetail(error));}
  finally{micStarting=false;micButton();updateWake();}
 }
 // The error name is shown so a screenshot tells which step failed.
 function micBrowser(){
  const ua=navigator.userAgent;
  if(/MicroMessenger/.test(ua))return '微信';if(/DingTalk/.test(ua))return '钉钉';if(/Lark|Feishu/.test(ua))return '飞书';
  if(/EdgiOS|Edg\//.test(ua))return 'Edge';if(/CriOS|Chrome\//.test(ua))return 'Chrome';if(/FxiOS|Firefox\//.test(ua))return 'Firefox';
  if(navigator.standalone||matchMedia('(display-mode: standalone)').matches)return '主屏幕图标';
  return /Version\/[\d.]+.*Safari\//.test(ua)?'Safari':'应用内浏览器';
 }
 function micDetail(e){
  const ua=navigator.userAgent, ios=(ua.match(/OS (\d+)_(\d+)/)||[]).slice(1).join('.'), version=(ua.match(/Version\/([\d.]+)/)||[])[1];
  return ['诊断：'+micBrowser(),version&&'版本 '+version,ios&&'iOS '+ios,e?.permission&&'网站权限 '+e.permission,e?.message&&String(e.message).slice(0,90)].filter(Boolean).join(' · ');
 }
 function micError(e){
  const name=e?.name||'Error', tag=`（${name}）`, app=micBrowser();
  if(e?.stage==='microphone'){
   if(name==='NotAllowedError'){
    if(/iPhone|iPad/.test(navigator.userAgent)&&!['Safari','主屏幕图标'].includes(app))return `${app}里打开的网页用不了麦克风${tag}。请在右上角菜单选「在 Safari 中打开」，或用相机扫码。`;
    if(e.permission==='denied')return `麦克风被拒绝${tag}。浏览器仍把这个网站记为拒绝：地址栏点「大小」→ 网站设置 → 麦克风，选「允许」，再关掉这个标签页重新打开。`;
    if(e.permission==='granted')return `麦克风被拒绝${tag}。网站已获允许，但被系统拦下：请检查 设置 → 屏幕使用时间 → 内容与隐私访问限制 → 麦克风。`;
    return `麦克风被拒绝${tag}。请关掉这个标签页（不是刷新）重新打开再点；仍不行时，在地址栏点「大小」→ 网站设置 → 麦克风，选「允许」。`;
   }
   if(name==='NotFoundError'||name==='OverconstrainedError')return `没有找到可用的麦克风${tag}`;
   if(name==='NotReadableError'||name==='AbortError')return `麦克风正被通话或其他应用占用，结束后再试${tag}`;
   if(name==='NotSupportedError')return `这个浏览器不能在网页里录音，请用 Safari 打开${tag}`;
   if(name==='InvalidStateError')return `手机暂时不允许网页录音，回到此页面后再点一次${tag}`;
  }
  return `声音处理没能启动，请再点一次${tag}`;
 }
 $('mic').onclick=()=>{if(mic)stopMic('已停止收音');else startMic();};
 function renderMap(){
  const map=latest?.mindMap, box=$('map-topics');
  const count=map?.topics?.filter(t=>!t.advertisement).length||0;
  $('map-button').textContent=count?`脑图 ${count}`:'脑图';
  if($('mindmap').hidden||!map&&mapRevision===-2)return;
  if(map&&map.revision===mapRevision)return;
  mapRevision=map?map.revision:-2;box.replaceChildren();
  if(!map||!map.topics.length){const p=document.createElement('p');p.className='map-empty';p.textContent='说几句话后，电脑会在这里整理出对话脑图。';box.append(p);return;}
  for(const topic of map.topics){
   const card=document.createElement('article');card.className='map-topic'+(topic.advertisement?' map-ad':'');
   const h=document.createElement('h3');h.textContent=(topic.advertisement?'广告 · ':'')+topic.title;card.append(h);
   if(topic.summary){const s=document.createElement('p');s.className='map-summary';s.textContent=topic.summary;card.append(s);}
   for(const branch of topic.branches){
    const b=document.createElement('div');b.className='map-branch';const t=document.createElement('strong');t.textContent=branch.title;b.append(t);
    const ul=document.createElement('ul');for(const point of branch.points){const li=document.createElement('li');li.textContent=point;ul.append(li);}b.append(ul);card.append(b);
   }
   box.append(card);
  }
 }
 $('map-button').onclick=()=>{$('mindmap').hidden=false;mapRevision=-1;renderMap();};
 $('map-close').onclick=()=>{$('mindmap').hidden=true;};
 function state(text,isLive=false){live=isLive;$('connection').textContent=text;$('connection').hidden=live;document.body.classList.toggle('live',live);updateWake();}
 function stop(){generation++;source?.close();source=null;clearTimeout(retryTimer);clearInterval(watchdog);retryTimer=null;watchdog=null;clearCaptions();live=false;document.body.classList.remove('live');updateWake();}
 async function api(path,body){if(remote)return remote.api(path,body);const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),6000);try{return await fetch(path,{method:body===undefined?'GET':'POST',credentials:'same-origin',cache:'no-store',headers:body===undefined?{}:{'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:controller.signal});}finally{clearTimeout(timer);}}
 function unavailable(){stop();state(remote?.recovering?'正在恢复此入口的授权，请保持 Mac 在线…':'连接中断，正在恢复…');$('waiting').hidden=false;$('pairing').hidden=true;if(!document.hidden)retryTimer=setTimeout(connect,Math.min(10000,700*2**Math.min(attempts++,4))+Math.random()*300);}
 function needPair(){stop();hideControls();
  if(mic)stopMic('');
  // After a relay restart while the Mac is offline, a paired phone looks
  // unpaired until the Mac re-registers it. Keep trying in the background.
  const known=!!remote?.hasCredentials;
  state(known?'电脑可能离线 · 上线后自动恢复，也可重新扫码':remote?'此入口需要配对 · 请使用下方连接入口':'尚未配对 · 请在 Mac 生成配对码');
  $('pairing').hidden=false;$('waiting').hidden=true;
  if(known&&!document.hidden)retryTimer=setTimeout(connect,15000);}
 async function acknowledge(){if(ackPending||!live)return;ackPending=true;const g=generation;try{const r=await api('/api/seen',{});if(g===generation&&r.status===401)needPair();}catch{}finally{ackPending=false;}}
 function render(snapshot){
  if(!snapshot||!Array.isArray(snapshot.captions)||snapshot.captions.length>60||!snapshot.sessionID)throw Error('Invalid snapshot');
  if(session!==snapshot.sessionID){clearCaptions();following=true;session=snapshot.sessionID;}
  latest=snapshot;
  const values=snapshot.captions.concat(snapshot.streaming?[{...snapshot.streaming,draft:true}]:[]),keep=new Set();
  for(const row of values){if(typeof row.id!=='string'||typeof row.original!=='string'||typeof row.translation!=='string')throw Error('Invalid caption');
   keep.add(row.id);let node=rows.get(row.id);
   if(!node){node=document.createElement('article');node.className='caption';node.dataset.id=row.id;for(const cls of ['original','translation','draft-label']){const p=document.createElement('div');p.className=cls;node.append(p);}rows.set(row.id,node);}
   const texts=[row.original,row.translation||row.original||'翻译中…',row.draft?'实时草稿 · 后续可能修订':''];
   texts.forEach((text,i)=>{if(node.children[i].textContent!==text)node.children[i].textContent=text;});
   node.children[2].hidden=!row.draft;
  }
  for(const [id,node] of rows){if(!keep.has(id)){node.remove();rows.delete(id);}}
  // Move only out-of-order nodes; keep selection and history position intact.
  let cursor=$('rows').firstElementChild;
  for(const row of values){const node=rows.get(row.id);if(node!==cursor)$('rows').insertBefore(node,cursor);cursor=node.nextElementSibling;}
  $('engine').textContent=labels[snapshot.status]||'等待电脑';$('reader').hidden=false;$('waiting').hidden=true;$('pairing').hidden=true;
  const phone=snapshot.phoneMicrophone;
  $('dock').hidden=false;document.body.classList.add('docked');
  $('mic').hidden=!canRecord||!phone||phone==='unavailable';
  if(mic&&phone==='refused')stopMic(snapshot.notice||'电脑没有接受手机收音');
  else if(mic&&phone==='listening'&&$('mic-status').textContent.startsWith('已开始收音'))micStatus('电脑正在识别手机声音');
  const empty=!values.length;$('empty-hint').hidden=!empty;
  if(empty)$('empty-hint').textContent=canRecord&&phone&&phone!=='unavailable'?'点下方「用手机收音」，电脑识别并翻译后，字幕会显示在这里。':'等待电脑开始翻译。';
  renderMap();
  state(encrypted?'已连接 · HTTPS 加密':'已连接 · 局域网未加密',true);attempts=0;lastBeat=Date.now();acknowledge();
  $('follow').hidden=following;followLatest();
 }
 async function connect(){stop();if(document.hidden)return;const g=generation;state('正在连接电脑…');$('waiting').hidden=false;
  try{const r=await api('/api/state');if(g!==generation)return;if(r.status===401){needPair();return;}if(!r.ok)throw Error();
   try{if((await r.clone().json()).online===false){state('电脑离线 · 上线后自动连接');$('waiting').hidden=false;retryTimer=setTimeout(connect,5000);return;}}catch{}
   const es=remote?remote.events():new EventSource('/api/events');source=es;lastBeat=Date.now();
   es.addEventListener('snapshot',e=>{if(g!==generation)return;try{render(JSON.parse(e.data));}catch{unavailable();}});
   es.addEventListener('change',e=>{if(g!==generation)return;try{const d=JSON.parse(e.data);if(!latest||d.sessionID!==latest.sessionID||d.sequence!==latest.sequence+1)throw Error('Sequence gap');const map=new Map(latest.captions.map(row=>[row.id,row]));for(const row of d.upserts)map.set(row.id,row);const captions=d.retainedIDs.map(id=>map.get(id));if(captions.some(row=>!row))throw Error('Missing row');render({...d,captions,mindMap:d.mindMap??latest.mindMap});}catch{unavailable();}});
   es.addEventListener('pulse',()=>{if(g!==generation)return;lastBeat=Date.now();acknowledge();});
   es.onerror=()=>{if(g===generation)unavailable();};
   watchdog=setInterval(()=>{if(Date.now()-lastBeat>10000)unavailable();},1500);
  }catch{if(g===generation)unavailable();}
 }
 async function pair(value){stop();const g=generation;$('pair-submit').disabled=true;$('pair-error').textContent='';
  try{const r=await api('/api/pair',{invitation:value});if(g!==generation)return;if(!r.ok){needPair();$('pair-error').textContent=await r.text();return;}$('pair-code').value='';attempts=0;connect();}
  catch{if(g===generation){needPair();$('pair-error').textContent=remote?'暂时无法连接，请检查手机网络并稍后重试。':'无法连接 Mac，请检查服务和局域网。';}}
  finally{$('pair-submit').disabled=false;}
 }
 $('pair-form').onsubmit=e=>{e.preventDefault();pair($('pair-code').value.trim());};
 $('retry').onclick=()=>{attempts=0;hideControls();$('pair-error').textContent='';connect();};
 // Gesture intent alone never means history mode. Only an actual reader scroll
 // away from its latest position pauses following; settings scroll is unrelated.
 reader.addEventListener('touchstart',()=>{touching=true;},{passive:true});
 reader.addEventListener('touchmove',()=>{dragged=true;beginScroll();},{passive:true});
 for(const event of ['touchend','touchcancel'])reader.addEventListener(event,()=>{touching=false;finishScroll();},{passive:true});
 reader.addEventListener('wheel',beginScroll,{passive:true});
 reader.addEventListener('keydown',e=>{if(['ArrowUp','ArrowDown','PageUp','PageDown','Home','End'].includes(e.key))beginScroll();});
 reader.addEventListener('scroll',()=>{
  if(!live)return;
  if(scrollIntent){following=atLatest();$('follow').hidden=following;finishScroll();}
  else if(!following&&atLatest()){following=true;$('follow').hidden=true;}
 },{passive:true});
 $('follow').onclick=()=>{following=true;scrollIntent=false;clearTimeout(scrollTimer);$('follow').hidden=true;followLatest();};
 // Font changes, rotation and growing translations must not masquerade as a
 // user dragging into history. Re-anchor only when already following live.
 new ResizeObserver(followLatest).observe($('rows'));
 new ResizeObserver(followLatest).observe(reader);
 addEventListener('resize',followLatest);
 document.addEventListener('visibilitychange',()=>{$('privacy').hidden=!document.hidden;if(document.hidden){hideControls();if(mic)stopMic('锁屏或切换应用后已停止收音，回来后点按钮继续');stop();state('已暂停，重新打开后恢复');}else{attempts=0;connect();}});
 addEventListener('pagehide',()=>{$('privacy').hidden=false;hideControls();if(mic)stopMic('');stop();});
 addEventListener('pageshow',e=>{if(e.persisted){$('privacy').hidden=false;attempts=0;connect();$('privacy').hidden=true;}});
 function consumeInvitation(){let invitation='';try{invitation=decodeURIComponent(location.hash.slice(1));}catch{}
  if(location.hash)history.replaceState(null,'','/');
  if(invitation){pair(invitation);return true;}return false;
 }
 // Scanning while Safari already has this page open can be a same-document
 // fragment navigation, not a reload. Process both entry paths.
 addEventListener('hashchange',consumeInvitation);
 if(!consumeInvitation())connect();
})();
"""#
}
#endif

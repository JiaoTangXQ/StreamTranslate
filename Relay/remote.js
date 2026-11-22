'use strict';
(() => {
  // Only keys/connection metadata are persisted; never transcript text.
  const storage='streamtranslate.remote.v1';
  let credentials=null, seq=0, recovery=null, epoch=0;
  const valid=s=>typeof s==='string'&&/^[a-f0-9]{64}$/.test(s);
  const unhex=s=>Uint8Array.from(s.match(/../g),v=>parseInt(v,16));
  const hex=b=>Array.from(b,v=>v.toString(16).padStart(2,'0')).join('');
  const base64=b=>{let s='';for(let i=0;i<b.length;i+=8192)s+=String.fromCharCode(...b.subarray(i,i+8192));return btoa(s);};
  const unbase64=s=>Uint8Array.from(atob(s),v=>v.charCodeAt(0));
  const remember=value=>{credentials=value;try{localStorage.setItem(storage,JSON.stringify(value));}catch{}};
  try{const c=JSON.parse(localStorage.getItem(storage));if(valid(c?.room)&&valid(c?.key))credentials=c;}catch{}
  async function request(path,body){
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),6000);
    try{return await fetch(path,{method:body===undefined?'GET':'POST',credentials:'same-origin',cache:'no-store',
      headers:body===undefined?{}:{'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:controller.signal});}
    finally{clearTimeout(timer);}
  }
  async function restore(room) {
    const current=epoch;
    if(!recovery||recovery.room!==room||Date.now()-recovery.started>55000) {
      const pair=await crypto.subtle.generateKey({name:'ECDH',namedCurve:'P-256'},false,['deriveBits']);
      if(current!==epoch)return new Response('',{status:409});
      recovery={room,id:hex(crypto.getRandomValues(new Uint8Array(32))),pair,
        publicKey:base64(new Uint8Array(await crypto.subtle.exportKey('raw',pair.publicKey))),started:Date.now()};
    }
    const pending=recovery;
    document.getElementById('connection').textContent='正在恢复此入口的连接授权…';
    const response=await request('/api/restore',{id:pending.id,publicKey:pending.publicKey});
    if(current!==epoch||pending!==recovery)return new Response('',{status:409});
    if(response.status===202)return new Response('',{status:503}); // existing bounded reconnect loop polls
    if(!response.ok)return response;
    const answer=await response.json();
    if(answer.room!==room||answer.id!==pending.id)throw Error('Invalid recovery answer');
    const peer=await crypto.subtle.importKey('raw',unbase64(answer.publicKey),{name:'ECDH',namedCurve:'P-256'},false,[]);
    const shared=await crypto.subtle.deriveBits({name:'ECDH',public:peer},pending.pair.privateKey,256);
    const hkdf=await crypto.subtle.importKey('raw',shared,'HKDF',false,['deriveKey']);
    const context=new TextEncoder().encode(`StreamTranslate recovery v1:${room}:${pending.id}`);
    const wrapping=await crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt:new TextEncoder().encode(room),info:context},hkdf,{name:'AES-GCM',length:256},false,['decrypt']);
    const combined=unbase64(answer.data);
    const key=new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv:combined.slice(0,12),additionalData:context},wrapping,combined.slice(12)));
    if(key.length!==32||current!==epoch||pending!==recovery)throw Error('Invalid recovery');
    remember({room,key:hex(key)});recovery=null;
    return new Response('{}',{status:200});
  }
  globalThis.StreamTranslateRemote={
    get recovering(){return recovery!==null;},
    get hasCredentials(){return credentials!==null;},
    microphone:{
      /// Starts the phone microphone. Must be called from a tap, and the
      /// microphone is requested before anything is awaited: Safari treats
      /// only a request made directly in the tap as the user's, and once a
      /// page has been denied it refuses later requests without asking.
      /// A rejected start carries `stage` ('microphone' or 'audio').
      async start({onLevel=()=>{},onState=()=>{}}={}) {
        if(!credentials)throw Error('Not paired');
        if(!navigator.mediaDevices?.getUserMedia)throw Object.assign(Error('No microphone API'),{name:'NotSupportedError',stage:'microphone'});
        // Meeting rooms: let the phone suppress noise and level distant voices.
        const asked=navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true,autoGainControl:true}});
        asked.catch(()=>{});
        const context=new AudioContext({latencyHint:'interactive'});
        context.resume().catch(()=>{});
        const {room}=credentials, stream=hex(crypto.getRandomValues(new Uint8Array(16)));
        // Every 100 ms frame carries its capture number, so a batch that has
        // to be retried keeps its place and the Mac sees real gaps as gaps.
        let media=null, closed=false, sending=false, seq=0, captured=0, frames=[], timer=null, key=null, holdUntil=0;
        const stopAll=()=>{closed=true;clearInterval(timer);asked.then(m=>m.getTracks().forEach(t=>t.stop()),()=>{});context.close().catch(()=>{});};
        try {
          const base=await crypto.subtle.importKey('raw',unhex(credentials.key),'HKDF',false,['deriveKey']);
          key=await crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt:new TextEncoder().encode(room),
            info:new TextEncoder().encode('StreamTranslate phone audio v1')},base,{name:'AES-GCM',length:256},false,['encrypt']);
          try{media=await asked;}catch(error){
            // Safari's own view of this site, for the diagnosis shown on the page.
            let permission='';
            try{permission=(await navigator.permissions.query({name:'microphone'})).state;}catch{}
            throw Object.assign(error,{stage:'microphone',permission});
          }
          if(!context.audioWorklet)throw Object.assign(Error('No AudioWorklet'),{name:'NotSupportedError'});
          await context.audioWorklet.addModule('/mic-worklet.js');
          const source=context.createMediaStreamSource(media), node=new AudioWorkletNode(context,'streamtranslate-capture');
          const mute=context.createGain();mute.gain.value=0;
          source.connect(node);node.connect(mute);mute.connect(context.destination);
          node.port.onmessage=e=>{
            if(closed)return;
            frames.push({n:captured++,pcm:new Int16Array(e.data.pcm)});onLevel(e.data.rms);
            // Keep at most five seconds while the network catches up; the
            // Mac turns the dropped frames into a short silence.
            if(frames.length>50)frames.splice(0,frames.length-50);
          };
          // Resumed in the tap above as well; capture also lets Safari start
          // Web Audio. Never wait forever on a context that stays suspended.
          await Promise.race([context.resume(),new Promise(r=>setTimeout(r,3000))]);
          if(context.state!=='running')throw Object.assign(Error('AudioContext '+context.state),{name:'AudioContextError',stage:'audio'});
          media.getAudioTracks()[0]?.addEventListener('ended',()=>{if(!closed){stopAll();onState('ended');}});
        } catch(error) {stopAll();throw error;}
        async function upload(first,samples,end) {
          const clear=new Uint8Array(10+samples.byteLength);
          clear.set([83,84,65,49,first>>>24&255,first>>>16&255,first>>>8&255,first&255,end?1:0,0]);
          clear.set(new Uint8Array(samples.buffer,samples.byteOffset,samples.byteLength),10);
          const number=++seq, iv=crypto.getRandomValues(new Uint8Array(12));
          const aad=new TextEncoder().encode(`${room}:${stream}:${number}:audio`);
          const sealed=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad},key,clear));
          const combined=new Uint8Array(12+sealed.length);combined.set(iv);combined.set(sealed,12);
          const response=await request('/api/audio',{stream,seq:number,data:base64(combined)});
          if(response.status===503)onState('offline');
          else if(response.status===401)onState('unauthorized');
          else if(response.ok)onState('sending');
          return response.status;
        }
        // Up to one second of consecutive frames from the front of the queue.
        function take(){
          let count=1;
          while(count<10&&count<frames.length&&frames[count].n===frames[0].n+count)count++;
          const batch=frames.splice(0,count), samples=new Int16Array(batch.reduce((n,f)=>n+f.pcm.length,0));
          let offset=0;for(const f of batch){samples.set(f.pcm,offset);offset+=f.pcm.length;}
          return {batch,samples};
        }
        async function flush(){
          if(sending||closed||!frames.length||Date.now()<holdUntil)return;
          sending=true;
          const {batch,samples}=take();
          try{
            const status=await upload(batch[0].n,samples,false);
            if(status!==200){
              // Not delivered: keep the audio and retry it first. A busy or
              // offline relay is given a second before the next attempt.
              frames=batch.concat(frames);
              if(status===429||status===503)holdUntil=Date.now()+1000;
            }
          }
          catch{frames=batch.concat(frames);onState('network');holdUntil=Date.now()+500;}
          finally{sending=false;}
        }
        timer=setInterval(flush,250);
        return {
          stream,
          async stop(){
            if(closed)return;
            stopAll();
            for(let i=0;i<20&&sending;i++)await new Promise(r=>setTimeout(r,50));
            // The last words are still queued: send them before the end mark.
            for(let i=0;i<3&&frames.length;i++){
              const {batch,samples}=take();
              try{if(await upload(batch[0].n,samples,false)!==200){frames=batch.concat(frames);break;}}
              catch{frames=batch.concat(frames);break;}
            }
            try{await upload(frames.length?frames[0].n:captured,new Int16Array(0),true);}catch{}
          }
        };
      }
    },
    async api(path,body) {
      if(path==='/api/pair') {
        let invitation=String(body.invitation).trim();
        if(invitation.includes('://')) {
          try{const url=new URL(invitation);if(url.origin!==location.origin||url.pathname!=='/'||url.search)throw Error();invitation=url.hash.slice(1);}
          catch{return new Response('请粘贴这台 Mac 生成的完整连接链接。',{status:400});}
        }
        const parts=invitation.split('.');
        if(parts.length!==3||!parts.every(valid))return new Response('请在 Mac 重新显示二维码，用手机相机扫码。',{status:400});
        const [room,ticket,key]=parts;
        // A bookmark may still contain its consumed QR fragment. Reuse valid auth,
        // not the one-use ticket; never treat knowledge of the key alone as auth.
        const state=await request('/api/state');
        const authorizedRoom=state.ok?(await state.json()).room:null;
        if(authorizedRoom===room){epoch++;recovery=null;if(credentials?.room!==room)remember({room,key});return new Response('{}',{status:200});}
        epoch++;recovery=null;
        const r=await request(path,{room,ticket});
        if(r.ok)remember({room,key});
        // After a Mac restart, a saved QR can name a dead room. A fresh valid
        // invitation still switches rooms; an expired one cannot break current auth.
        if(r.status===401&&valid(authorizedRoom))return new Response('{}',{status:200});
        return r.ok?r:new Response(r.status===409?'授权浏览器已满，请在 Mac 关闭再开启跨网络连接。':'二维码已使用或过期，请在 Mac 显示新的二维码。',{status:r.status});
      }
      if(path==='/api/state') {
        const r=await request(path);
        if(!r.ok)return r;
        const {room}=await r.clone().json();
        if(!valid(room))throw Error('Invalid room');
        return credentials?.room===room?r:restore(room);
      }
      if(!credentials)return new Response('',{status:401});
      return request(path,path==='/api/seen'?{seq}:body);
    },
    events() {
      const events=new EventTarget(), es=new EventSource('/api/events');
      let closed=false, chain=Promise.resolve(), last=0;
      const key=crypto.subtle.importKey('raw',unhex(credentials.key),'AES-GCM',false,['decrypt']);
      const room=credentials.room;
      const error=()=>{if(closed)return;events.onerror?.();};
      events.close=()=>{closed=true;es.close();};
      es.onerror=error;
      es.addEventListener('pulse',()=>{if(!closed)events.dispatchEvent(new Event('pulse'));});
      es.addEventListener('sealed',e=>{
        chain=chain.then(async()=>{
          if(closed)return;
          const f=JSON.parse(e.data);
          if(!Number.isSafeInteger(f.seq)||f.seq<=last||!['snapshot','change'].includes(f.kind)||f.data.length>220000)throw Error('Invalid frame');
          if(f.kind==='change'&&f.seq!==last+1)throw Error('Sequence gap');
          const combined=Uint8Array.from(atob(f.data),c=>c.charCodeAt(0));
          const aad=new TextEncoder().encode(`${room}:${f.seq}:${f.kind}`);
          const clear=await crypto.subtle.decrypt({name:'AES-GCM',iv:combined.slice(0,12),additionalData:aad},await key,combined.slice(12));
          if(closed)return;
          const text=new TextDecoder('utf-8',{fatal:true}).decode(clear), payload=JSON.parse(text);
          if(payload.sequence!==f.seq)throw Error('Invalid sequence');
          last=f.seq;seq=f.seq;events.dispatchEvent(new MessageEvent(f.kind,{data:text}));
        }).catch(()=>{error();events.close();});
      });
      return events;
    }
  };
  document.addEventListener('DOMContentLoaded',()=>{
    document.getElementById('transport-note').textContent='跨网络 · HTTPS + 字幕与音频加密';
    const form=document.getElementById('pair-form');form.hidden=false;
    form.querySelector('label').textContent='无法在此窗口扫码？粘贴 Mac 的连接链接';
    const input=document.getElementById('pair-code');input.removeAttribute('pattern');input.maxLength=500;input.inputMode='url';
    input.placeholder='https://…/#…';input.style.fontSize='16px';input.style.letterSpacing='normal';input.autocapitalize='off';input.spellcheck=false;
    document.querySelector('#pairing p').textContent='此入口尚未配对。在 Mac 打开新的二维码，用相机扫码；桌面图标里可直接粘贴 Mac 的连接链接完成配对，不必删除图标。';
    document.querySelector('#pairing .muted').textContent='配对一次可用 90 天，经常打开会自动续期。连接链接两分钟、一次有效，请勿转发。Mac 需联网并保持唤醒。';
  });
})();

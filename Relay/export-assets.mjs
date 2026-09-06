import {readFileSync,mkdirSync,writeFileSync,copyFileSync} from 'node:fs';
import path from 'node:path';
const source=readFileSync(new URL('../CompanionKit/Sources/CompanionKit/WebAssets.swift',import.meta.url),'utf8');
const out=process.argv[2];if(!out)throw Error('Pass a generated asset directory');mkdirSync(out,{recursive:true});
for(const [name,file] of Object.entries({html:'index.html',css:'style.css',js:'app.js',icon:'icon.svg',manifest:'manifest.webmanifest'})) {
  const pattern=new RegExp('static let '+name+' = (#*)"("{2})?([\\s\\S]*?)"(?:"{2})?\\1(?=\\s*\\n)');
  const match=source.match(pattern);if(!match)throw Error('Cannot extract '+name);
  let text=match[3].replace(/^\n|\n$/g,'');
  if(name==='html')text=text.replace('<script src="/app.js" defer>', '<script src="/remote.js" defer></script><script src="/app.js" defer>');
  writeFileSync(path.join(out,file),text);
}
copyFileSync(new URL('./remote.js',import.meta.url),path.join(out,'remote.js'));

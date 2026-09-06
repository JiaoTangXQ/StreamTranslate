import {mkdirSync,writeFileSync,existsSync,chmodSync} from 'node:fs';
import {randomBytes} from 'node:crypto';
import {homedir} from 'node:os';
import path from 'node:path';
// Run once on the developer's Mac. No cloud AccessKey is used by the app.
const origin=process.argv[2], output=process.argv[3];
if(!origin?.startsWith('https://')||!output)throw Error('Expected HTTPS origin and private output directory');
const base=path.join(homedir(),'Library/Application Support/StreamTranslate'),config=path.join(base,'RemoteRelay.json');
if(existsSync(config)||existsSync(path.join(output,'publisher-token')))throw Error('Existing provisioning: refusing to rotate credentials');
mkdirSync(base,{recursive:true});mkdirSync(output,{recursive:true,mode:0o700});chmodSync(output,0o700);
const token=randomBytes(32).toString('hex');
writeFileSync(config,JSON.stringify({origin,token}),{mode:0o600,flag:'wx'});
writeFileSync(path.join(output,'publisher-token'),token+'\n',{mode:0o600,flag:'wx'});
console.log('Created private runtime credentials; no secrets printed.');

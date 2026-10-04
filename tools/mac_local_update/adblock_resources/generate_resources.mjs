// Match Brave's CRX packager resource assembly using its pinned uBlock checkout.
import fs from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL, fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
const {values: options}=parseArgs({options:{'adblock-resources':{type:'string'},ublock:{type:'string'},'output-dir':{type:'string'}}});
if(!options.ublock || !options['adblock-resources']) throw Error('--ublock and --adblock-resources are required');
const ublock=path.resolve(options.ublock);
const {default:redirects}=await import(pathToFileURL(path.join(ublock,'src/js/redirect-resources.js')));
const {builtinScriptlets}=await import(pathToFileURL(path.join(ublock,'src/js/resources/scriptlets.js')));
const {readResources}=await import(pathToFileURL(path.resolve(options['adblock-resources'],'index.js')));
const mime={css:'text/css',gif:'image/gif',html:'text/html',js:'application/javascript',json:'application/json',mp3:'audio/mp3',mp4:'video/mp4',png:'image/png',txt:'text/plain',xml:'text/xml'};
const resources=[];
for(const [name,info] of redirects){
 if(info.params || name==='google-ima-dai.js')continue;
 let data=await fs.readFile(path.join(ublock,'src/web_accessible_resources',name));
 const type=mime[path.extname(name).slice(1)]??'application/octet-stream';
 if(['application/javascript','text/html','text/plain'].includes(type)) data=Buffer.from(new TextDecoder('utf-8',{fatal:true}).decode(data).replaceAll('\r',''));
 resources.push({name,aliases:Array.isArray(info.alias)?info.alias:info.alias?[info.alias]:[],kind:{mime:type},content:data.toString('base64'),dependencies:[],permission:0});
}
resources.push(...readResources());
for(const s of builtinScriptlets){
 for(const dependency of s.dependencies??[]) if(!builtinScriptlets.some(x=>x.name===dependency))throw Error('Missing scriptlet dependency: '+dependency);
 resources.push({name:s.name,aliases:s.aliases??[],kind:{mime:'application/javascript'},content:Buffer.from(s.fn.toString()).toString('base64'),dependencies:s.dependencies??[]});
}
const names=new Set(); for(const x of resources){if(names.has(x.name))throw Error('Duplicate resource: '+x.name);names.add(x.name);}
const output=path.resolve(options['output-dir'] ?? path.dirname(fileURLToPath(import.meta.url)));await fs.mkdir(output,{recursive:true});
await fs.writeFile(path.join(output,'resources.json'),JSON.stringify(resources));
console.log(JSON.stringify({resources:resources.length,bytes:(await fs.stat(path.join(output,'resources.json'))).size}));

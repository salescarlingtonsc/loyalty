/* Find `const {data,error}=await sb.rpc(...)` sites that guard `error` but then read a property
 * off `data` without guarding null. A PostgREST RPC that returns SQL NULL yields
 * {data:null,error:null}, so these throw a TypeError on a SUCCESSFUL call. */
import {readFile} from 'node:fs/promises';
const src=await readFile('/home/user/loyalty/app/app.js','utf8');
const lines=src.split('\n');
const fns=[];lines.forEach((l,i)=>{const m=l.match(/^(?:async\s+)?function\s+([A-Za-z0-9_$]+)/);if(m)fns.push({line:i+1,name:m[1]});});
const which=n=>{let b=null;for(const f of fns){if(f.line<=n)b=f;else break}return b?b.name:'(top)'};

const findings=[];
lines.forEach((l,i)=>{
  const m=l.match(/const\s*\{\s*data(?:\s*:\s*([A-Za-z0-9_$]+))?\s*,\s*error(?:\s*:\s*([A-Za-z0-9_$]+))?\s*\}\s*=\s*await\s+(sb|preAuthSb)\.rpc\(\s*'([a-z_0-9]+)'/);
  if(!m)return;
  const varName=m[1]||'data', errName=m[2]||'error', rpc=m[4];
  /* look ahead up to 6 lines for the first use of the data variable */
  for(let j=i;j<Math.min(lines.length,i+7);j++){
    const seg=j===i?lines[j].slice(lines[j].indexOf('=await')):lines[j];
    /* guarded forms we accept */
    if(new RegExp(`${varName}\\s*\\?\\.`).test(seg))return;                 // data?.x
    if(new RegExp(`!${varName}\\b`).test(seg))return;                        // if(!data)
    if(new RegExp(`${varName}\\s*\\|\\|`).test(seg))return;                  // data||{}
    if(new RegExp(`Array\\.isArray\\(\\s*${varName}`).test(seg))return;      // Array.isArray(data)
    if(new RegExp(`\\(\\s*${varName}\\s*&&`).test(seg))return;               // (data && ...)
    if(new RegExp(`${varName}\\s*\\?\\s`).test(seg))return;                  // data ? a : b
    if(new RegExp(`typeof\\s+${varName}`).test(seg))return;
    /* an UNGUARDED property/method read is the defect */
    const bad=seg.match(new RegExp(`(?<![.\\w])${varName}\\.([A-Za-z0-9_$]+)`));
    if(bad){
      findings.push({line:j+1,fn:which(j+1),rpc,expr:`${varName}.${bad[1]}`,src:lines[j].trim().slice(0,110)});
      return;
    }
  }
});
console.log(`${findings.length} unguarded reads of a successful-but-null RPC payload\n`);
const byFn={};
findings.forEach(f=>{(byFn[f.fn]=byFn[f.fn]||[]).push(f)});
Object.entries(byFn).sort().forEach(([fn,fs])=>{
  console.log(`${fn}`);
  fs.forEach(f=>console.log(`   L${String(f.line).padEnd(6)} ${f.rpc.padEnd(38)} reads ${f.expr}`));
});

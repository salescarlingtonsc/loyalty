import {readFile,writeFile} from 'node:fs/promises';
const WRITE=process.argv.includes('--write');
const src=await readFile('app/app.js','utf8');
const lines=src.split('\n');
let n=0;
const out=lines.map((l,i)=>{
  const t=l.trim();
  if(t.startsWith('*')||t.startsWith('//')||t.startsWith('/*'))return l;
  if(l.includes('confirmActionV386')||l.includes('confirmDeliberateV288'))return l;
  // `!confirm(` -> `!await confirmActionV386(`
  if(/(?:^|[!(=,&|?:{[\s])confirm\(/.test(l)){
    const next=l.replace(/(^|[!(=,&|?:{[\s])confirm\(/g,'$1await confirmActionV386(');
    if(next!==l){n++;console.log(`L${i+1}  ${t.slice(0,92)}`);}
    return next;
  }
  return l;
});
console.log(`\n${n} call sites ${WRITE?'converted':'would convert'}`);
if(WRITE)await writeFile('app/app.js',out.join('\n'));

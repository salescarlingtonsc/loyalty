import {chromium} from 'playwright';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {extname,join,normalize} from 'node:path';
const ROOT='/home/user/loyalty',PORT=4191;
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.webmanifest':'application/manifest+json'};
const srv=createServer(async(q,s)=>{try{const p=normalize(decodeURIComponent(q.url.split('?')[0])).replace(/^(\.\.[/\\])+/,'');
 if(p==='/sb-double.js'){s.writeHead(200,{'content-type':'text/javascript'});return s.end(await readFile(join(ROOT,'tools/qa-sweep/sb-double.js')))}
 const f=join(ROOT,p==='/'?'/app/index.html':(p.startsWith('/app/')?p:'/app'+p));const b=await readFile(f);
 s.writeHead(200,{'content-type':MIME[extname(f)]||'application/octet-stream'});s.end(b)}catch{s.writeHead(404);s.end('nf')}});
await new Promise(r=>srv.listen(PORT,'127.0.0.1',r));
const br=await chromium.launch({headless:true,executablePath:'/opt/pw-browsers/chromium-1194/chrome-linux/chrome'});
const open=async(route,w=1280)=>{const p=await br.newPage({viewport:{width:w,height:900}});
  await p.route(/4191\/(#.*)?$|index\.html/,async r=>{const rs=await r.fetch();let h=await rs.text();
    h=h.replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/,'<script src="/sb-double.js"></script>');
    await r.fulfill({status:200,contentType:'text/html',body:h})});
  await p.route('**/fonts.googleapis.com/**',r=>r.fulfill({status:200,contentType:'text/css',body:''}));
  await p.goto(`http://127.0.0.1:${PORT}/#/${route}`,{waitUntil:'domcontentloaded'});
  await p.waitForTimeout(1500);return p;};

// A. error cards — what do they actually say?
for(const route of ['dashboard','customer-interface','staffmembers']){
  const p=await open(route);
  const t=await p.evaluate(()=>[...document.querySelectorAll('button,a[href]')]
    .map(e=>({t:(e.getAttribute('aria-label')||e.textContent||'').trim().replace(/\s+/g,' ').slice(0,40),h:Math.round(e.getBoundingClientRect().height),c:e.className.slice(0,44)}))
    .filter(x=>x.h>0&&x.h<44));
  console.log(`${route}:`, t.length?t:'no sub-44px controls'); await p.close();
}
// B. do my six rulings hold in a real render?
const p=await open('services');
const r=await p.evaluate(()=>{
  const cs=getComputedStyle(document.documentElement);
  const g=s=>document.querySelector(s);
  return {
    brandRed:cs.getPropertyValue('--brand-red').trim(),
    coralResolves:cs.getPropertyValue('--coral').trim(),
    peekaaResolves:cs.getPropertyValue('--peekaa-red').trim(),
    pageHeaderHasIcon:!!g('.cui-page-title svg, .topbar .cui-page-title svg'),
    h1:g('h1')?.textContent?.trim(),
    numCells:document.querySelectorAll('td.num,th.num').length,
    statusWords:[...document.querySelectorAll('.pill')].map(e=>e.textContent.trim()).filter(t=>/^(On|Off|Live|Active|Inactive|active|off)$/.test(t)).slice(0,6),
    turnOnOff:[...document.querySelectorAll('button')].map(b=>b.textContent.trim()).filter(t=>/^Turn (on|off)$/.test(t)).length,
    oldVerbs:[...document.querySelectorAll('button')].map(b=>b.textContent.trim()).filter(t=>/^(Enable|Disable|Pause|Resume|Archive|Retire)$/.test(t)),
    btnHeights:[...document.querySelectorAll('.btn')].map(b=>Math.round(b.getBoundingClientRect().height)).filter(h=>h>0),
  };
});
console.log('\n=== rulings verified in a real render (#/services) ===');
console.log(JSON.stringify(r,null,1));
await p.close();await br.close();srv.close();

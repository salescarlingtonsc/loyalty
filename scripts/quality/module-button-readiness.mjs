#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const repoRoot=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const read=relative=>fs.readFileSync(path.join(repoRoot,relative),'utf8');
const app=read('app/index.html');
const platform=read('app/platform-console.js');

const between=(source,start,end)=>{
  const from=source.indexOf(start);
  const to=source.indexOf(end,from+start.length);
  if(from<0||to<0)throw new Error(`Could not find source section: ${start}`);
  return source.slice(from,to);
};

const parseArrayStrings=(source,name)=>{
  const match=source.match(new RegExp(`const ${name}=\\[([\\s\\S]*?)\\];`));
  if(!match)throw new Error(`Could not parse ${name}`);
  return [...match[1].matchAll(/'([a-z][a-z0-9_-]*)'/g)].map(item=>item[1]);
};

const allModules=parseArrayStrings(app,'ALLMODS');
const hiddenModules=[...between(app,'const HIDDEN_BUSINESS_SURFACES','const FINANCE_MODULES').matchAll(/'([a-z][a-z0-9_-]*)'/g)].map(item=>item[1]);
const routeMap=between(app,'  const P={dashboard,till:','  const pageFn=').replace(/^\s*const P=\{/,'').replace(/};\s*$/,'');
const splitTopLevel=(value)=>{
  const parts=[];let start=0,depth=0,quote='',escaped=false;
  for(let index=0;index<value.length;index+=1){
    const character=value[index];
    if(quote){
      if(escaped)escaped=false;
      else if(character==='\\')escaped=true;
      else if(character===quote)quote='';
      continue;
    }
    if(character==="'"||character==='"'||character==='`'){quote=character;continue}
    if(character==='('||character==='['||character==='{')depth+=1;
    else if(character===')'||character===']'||character==='}')depth-=1;
    else if(character===','&&depth===0){parts.push(value.slice(start,index));start=index+1}
  }
  parts.push(value.slice(start));return parts;
};
const mappedBusinessRoutes=new Set(splitTopLevel(routeMap).map(item=>item.trim().match(/^([a-z][a-z0-9]*)/)?.[1]).filter(Boolean));
const specialBusinessRoutes=['branches','settings','setup','studio','storedvalue','promotions'];
const expectedBusinessRoutes=[...new Set([...allModules.filter(key=>!hiddenModules.includes(key)),...specialBusinessRoutes])];
const missingBusinessRoutes=expectedBusinessRoutes.filter(key=>!mappedBusinessRoutes.has(key));

const platformRoutesSection=between(platform,'  const routes = Object.freeze([','  const platformModuleKeys');
const platformRoutes=[...platformRoutesSection.matchAll(/\{key:'([a-z][a-z0-9_-]*)'/g)].map(item=>item[1]);
const missingPlatformRoutes=platformRoutes.filter(key=>{
  if(key==='overview')return !/activeKey\s*===\s*'overview'/.test(platform);
  return !new RegExp(`activeKey\\s*===\\s*'${key}'`).test(platform);
});

function staticControls(source,file){
  const controls=[];
  const patterns=[
    ['button',/<button\b([^>]*)>([\s\S]*?)<\/button>/gi],
    ['a',/<a\b([^>]*)>([\s\S]*?)<\/a>/gi]
  ];
  for(const [kind,pattern] of patterns){
    for(const match of source.matchAll(pattern)){
      const attrs=match[1],body=match[2];
      if(/\$\{[\s\S]*?<\/(?:button|a)>/.test(match[0]))continue;
      const offset=match.index??0;
      const line=source.slice(0,offset).split('\n').length;
      const id=attrs.match(/\bid=["']([^"'$]+)["']/)?.[1]||'';
      const href=attrs.match(/\bhref=["']([^"']*)["']/)?.[1]||'';
      const data=[...attrs.matchAll(/\b(data-[a-z0-9-]+)(?:=|\s|$)/gi)].map(item=>item[1]);
      const classes=(attrs.match(/\bclass=["']([^"'$]+)["']/)?.[1]||'').split(/\s+/).filter(Boolean);
      const label=attrs.match(/\baria-label=["']([^"'$]+)["']/)?.[1]
        ||attrs.match(/\btitle=["']([^"'$]+)["']/)?.[1]
        ||body.replace(/\$\{[^}]*\}/g,' ').replace(/<[^>]+>/g,' ').replace(/&[a-z0-9#]+;/gi,' ').replace(/\s+/g,' ').trim();
      const type=attrs.match(/\btype=["']([^"']+)["']/)?.[1]||'';
      const inline=/\bonclick\s*=/.test(attrs);
      let wired=kind==='a'?Boolean(href):type==='submit'||inline||/\bdisabled(?:\s|=|$)/.test(attrs);
      if(!wired&&id)wired=(source.match(new RegExp(`\\b${id}\\b`,'g'))||[]).length>1;
      if(!wired&&data.length)wired=data.some(attribute=>(source.match(new RegExp(`\\b${attribute}\\b`,'g'))||[]).length>1);
      if(!wired&&classes.length)wired=classes.some(className=>{
        if(!/^[a-z][a-z0-9_-]*$/i.test(className))return false;
        return new RegExp(`querySelector(?:All)?\\(['\"][^'\"]*\\.${className}\\b`).test(source);
      });
      controls.push({file,line,kind,id,label,href,type,data,wired,attrs:attrs.replace(/\s+/g,' ').trim().slice(0,220)});
    }
  }
  return controls;
}

const controls=[...staticControls(app,'app/index.html'),...staticControls(platform,'app/platform-console.js')];
const unlabeled=controls.filter(control=>!control.label);
const unwired=controls.filter(control=>!control.wired);
const invalidAnchors=controls.filter(control=>control.kind==='a'&&!control.href);
const hiddenRouteTargets=[...app.matchAll(/(?:href=|link:)['"]#\/([a-z][a-z0-9_-]*)/g)]
  .map(match=>({route:match[1],line:app.slice(0,match.index).split('\n').length}))
  .filter(target=>hiddenModules.includes(target.route));
const nonSemanticClickTargets=[...app.matchAll(/<(tr|div|span)\b([^>]*)\bonclick\s*=/gi)]
  .map(match=>({element:match[1].toLowerCase(),line:app.slice(0,match.index).split('\n').length,attrs:match[2].replace(/\s+/g,' ').trim().slice(0,180)}));

const result={
  baselineCommit:process.env.V123_BASELINE_COMMIT||'',
  business:{expected:expectedBusinessRoutes.length,mapped:mappedBusinessRoutes.size,missing:missingBusinessRoutes},
  platform:{expected:platformRoutes.length,missing:missingPlatformRoutes},
  controls:{total:controls.length,buttons:controls.filter(control=>control.kind==='button').length,links:controls.filter(control=>control.kind==='a').length,unlabeled,unwired,invalidAnchors,hiddenRouteTargets,nonSemanticClickTargets}
};

console.log(JSON.stringify(result,null,2));
if(process.argv.includes('--strict')&&(missingBusinessRoutes.length||missingPlatformRoutes.length||unlabeled.length||unwired.length||invalidAnchors.length||hiddenRouteTargets.length||nonSemanticClickTargets.length))process.exitCode=1;

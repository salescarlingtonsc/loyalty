import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

/* v293/v294: the customer wallet follows the member's stored preferred
   language for all four SG-first mandate languages — en / zh-CN / ms / ta.
   This suite guards the parity that makes the switch honest: every English
   key resolves in every other locale, the plumbing honors the stored choice,
   and no locale table carries strings that look like code or unfilled
   prompts. */

const js=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');

function copyBlock(locale){
  const anchor=locale==='en'?'  en:Object.freeze({':locale==='zh-CN'?"  'zh-CN':Object.freeze({":locale==='ta'?'  ta:Object.freeze({':'  ms:Object.freeze({';
  const start=js.indexOf('const CUSTOMER_COPY=Object.freeze({');
  assert.ok(start>=0,'CUSTOMER_COPY missing');
  const blockStart=js.indexOf(anchor,start);
  assert.ok(blockStart>start,`${locale} block missing`);
  let depth=0,i=js.indexOf('{',blockStart+anchor.length-1),from=i,quote=null,escaped=false;
  for(;i<js.length;i++){
    const ch=js[i];
    if(quote){
      if(escaped)escaped=false;
      else if(ch==='\\')escaped=true;
      else if(ch===quote)quote=null;
      continue;
    }
    if(ch==='\''||ch==='"'||ch==='`'){quote=ch;continue}
    if(ch==='{')depth++;
    else if(ch==='}'){depth--;if(depth===0)return js.slice(from,i+1)}
  }
  assert.fail(`${locale} block never closed`);
}

function keysOf(block){
  const keys=[];
  let depth=0,quote=null,escaped=false,token='',tokenStart=-1;
  for(let i=0;i<block.length;i++){
    const ch=block[i];
    if(quote){
      if(escaped){escaped=false;token+=ch;continue}
      if(ch==='\\'){escaped=true;token+=ch;continue}
      if(ch===quote){
        quote=null;
        let j=i+1;
        while(j<block.length&&/\s/.test(block[j]))j++;
        if(depth===1&&block[j]===':')keys.push(token);
        token='';continue;
      }
      token+=ch;continue;
    }
    if(ch==='\''||ch==='"'){quote=ch;token='';tokenStart=i;continue}
    if(ch==='{')depth++;
    else if(ch==='}')depth--;
    else if(depth===1&&/[A-Za-z_$]/.test(ch)){
      // bare identifier key
      let j=i,ident='';
      while(j<block.length&&/[A-Za-z0-9_$]/.test(block[j])){ident+=block[j];j++}
      let k=j;while(k<block.length&&/\s/.test(block[k]))k++;
      if(block[k]===':'){keys.push(ident);i=k}else i=j-1;
    }
  }
  return keys;
}

const en=keysOf(copyBlock('en'));
const zh=keysOf(copyBlock('zh-CN'));
const ms=keysOf(copyBlock('ms'));
const ta=keysOf(copyBlock('ta'));

test('the wallet ships four locales and zh-CN/ms/ta cover every English key',()=>{
  assert.match(js,/const CUSTOMER_LOCALES=Object\.freeze\(\['en','zh-CN','ms','ta'\]\)/);
  assert.ok(en.length>=40,`en table unexpectedly small: ${en.length}`);
  for(const [name,keys] of [['zh-CN',zh],['ms',ms],['ta',ta]]){
    const set=new Set(keys);
    const missing=en.filter(k=>!set.has(k));
    assert.deepEqual(missing,[],`${name} is missing: ${missing.join(', ')}`);
  }
});

test('zh-CN, ms and ta sentence keys cover the ct()-routed wallet and scanner strings',()=>{
  const sets=[['zh-CN',new Set(zh)],['ms',new Set(ms)],['ta',new Set(ta)]];
  for(const key of [
    'Rewards could not be loaded.',
    'Membership is not available for this account.',
    'No appointments are available yet.',
    'Scan the business QR',
    'The scanner could not load. Check your connection and try again.',
    'Point the camera at the business QR.'
  ]){
    for(const [name,set] of sets)assert.ok(set.has(key),`${name} missing sentence key: ${key}`);
  }
});

test('the stored preferred language drives the wallet and legacy zh folds to zh-CN',()=>{
  assert.match(js,/const normalizeCustomerLocale=value=>\{const v=String\(value\|\|''\)\.trim\(\);if\(v==='zh'\)return 'zh-CN';return CUSTOMER_LOCALES\.includes\(v\)\?v:'en'\}/);
  assert.match(js,/customerLocale=normalizeCustomerLocale\(profile\?\.preferred_language\)/);
  assert.match(js,/setAttribute\('lang',customerLocale\)/);
  // sign-out still resets the surface to English
  assert.match(js,/customerLocale='en';\n  workspaceLocaleLoadedFor=''/);
});

test('a saved language change applies immediately and re-renders the profile',()=>{
  assert.match(js,/const nextLocale=normalizeCustomerLocale\(language\);/);
  assert.match(js,/if\(nextLocale!==customerLocale\)\{[\s\S]{0,300}?renderCustomerProfile\(\);/);
  assert.match(js,/CUI\.announce\(ct\('profileSaved'\)\)/);
});

test('no locale table carries code-like or unfilled translations',()=>{
  for(const [locale,block] of [['zh-CN',copyBlock('zh-CN')],['ms',copyBlock('ms')],['ta',copyBlock('ta')]]){
    assert.doesNotMatch(block,/```|<script|TODO|FIXME|\btranslate this\b/i,`${locale} has a code-like translation`);
  }
});

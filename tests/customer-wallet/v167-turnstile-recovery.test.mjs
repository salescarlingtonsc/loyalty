import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');

function turnstileSource(){
  const start=source.indexOf('let turnstileLoader;');
  const end=source.indexOf('/* Supabase Auth has CAPTCHA protection enabled');
  assert.ok(start>=0&&end>start,'Turnstile helper block is present');
  return source.slice(start,end);
}

function createHarness(){
  const elements=new Map();
  const makeElement=(id)=>{
    const el={
      id,
      hidden:false,
      textContent:'',
      onclick:null,
      style:{},
      children:[],
      focusCount:0,
      isConnected:true,
      remove(){this.removed=true;this.isConnected=false},
      replaceChildren(){this.children=[]},
      focus(){this.focusCount+=1}
    };
    elements.set(id,el);
    return el;
  };
  ['challenge','status','retry','reload'].forEach(makeElement);
  const timers=new Map();
  let nextTimer=1;
  const widgets=[];
  const activeWidgets=new Set();
  const api={
    render(selector,options){
      const widget={id:widgets.length+1,selector,options};
      widgets.push(widget);
      activeWidgets.add(widget.id);
      return widget.id;
    },
    remove(id){activeWidgets.delete(id)},
    reset(id){widgets.push({id:`reset:${id}`})}
  };
  const context={
    console:{warn(){}},
    location:{reload(){context.reloaded=true}},
    window:{turnstile:api},
    document:{
      getElementById:id=>elements.get(id)||null,
      createElement(){return {remove(){}}},
      head:{appendChild(){}}
    },
    setTimeout(fn,ms){
      const id=nextTimer++;
      timers.set(id,{fn,ms});
      return id;
    },
    clearTimeout(id){timers.delete(id)},
    $:id=>elements.get(id),
    authSecurityCopy(locale,key){
      return {
        loading:'Loading security check…',
        retry:'Retry security check',
        complete:'Security check complete.',
        expired:'Security check expired. Please try again.',
        timeout:'Security check timed out. Please try again.',
        connectShort:'Security check could not connect.',
        load:'Security check could not load. Turn off content blockers, VPN or Private Relay, or try another network.',
        continue:'Complete the security check to continue.',
        reload:'Reload page'
      }[key]||key;
    },
    onTokenCalls:[],
    reloaded:false
  };
  vm.createContext(context);
  vm.runInContext(turnstileSource(),context);
  const flush=()=>new Promise(resolve=>setImmediate(resolve));
  const mount=()=>context.mountTurnstile('site-key',{
    container:'challenge',
    status:'status',
    retry:'retry',
    reload:'reload',
    action:'frenly_customer_password',
    onToken:(token,detail)=>context.onTokenCalls.push({token,detail})
  });
  const runTimers=()=>{
    const pending=[...timers.entries()];
    timers.clear();
    for(const [,timer] of pending)timer.fn();
  };
  return {context,elements,widgets,activeWidgets,timers,mount,flush,runTimers};
}

test('successful Turnstile token enables the current attempt and clears retry UI',async()=>{
  const h=createHarness();
  await h.mount();
  assert.equal(h.widgets.length,1);
  h.widgets[0].options.callback('token-1');
  assert.equal(h.context.onTokenCalls.at(-1).token,'token-1');
  assert.equal(h.context.onTokenCalls.at(-1).detail.state,'ready');
  assert.equal(h.elements.get('status').textContent,'Security check complete.');
  assert.equal(h.elements.get('retry').hidden,true);
  assert.equal(h.timers.size,0);
});

test('missing callback trips the watchdog and reveals retry',async()=>{
  const h=createHarness();
  await h.mount();
  h.runTimers();
  assert.equal(h.context.onTokenCalls.at(-1).token,'');
  assert.equal(h.context.onTokenCalls.at(-1).detail.state,'retryable_error');
  assert.equal(h.elements.get('status').textContent,'Security check could not connect.');
  assert.equal(h.elements.get('retry').hidden,false);
});

test('Turnstile error callback reveals retry and clears token',async()=>{
  const h=createHarness();
  await h.mount();
  h.widgets[0].options['error-callback']('network');
  assert.equal(h.context.onTokenCalls.at(-1).token,'');
  assert.equal(h.context.onTokenCalls.at(-1).detail.state,'retryable_error');
  assert.equal(h.elements.get('retry').hidden,false);
  assert.equal(h.timers.size,0);
});

test('expired token disables the current attempt and clears watchdog',async()=>{
  const h=createHarness();
  await h.mount();
  h.widgets[0].options.callback('token-1');
  h.widgets[0].options['expired-callback']();
  assert.equal(h.context.onTokenCalls.at(-1).token,'');
  assert.equal(h.context.onTokenCalls.at(-1).detail.state,'expired');
  assert.equal(h.elements.get('retry').hidden,false);
  assert.equal(h.timers.size,0);
});

test('retry removes the old widget and creates only one active replacement',async()=>{
  const h=createHarness();
  await h.mount();
  h.runTimers();
  h.elements.get('retry').onclick();
  await h.flush();
  assert.equal(h.widgets.length,2);
  assert.deepEqual([...h.activeWidgets],[2]);
  assert.equal(h.elements.get('retry').hidden,true);
});

test('stale callback from an older widget is ignored after retry',async()=>{
  const h=createHarness();
  await h.mount();
  const first=h.widgets[0];
  h.elements.get('retry').onclick();
  await h.flush();
  first.options.callback('stale-token');
  assert.notEqual(h.context.onTokenCalls.at(-1).token,'stale-token');
});

test('destroy clears the watchdog timer and prevents later state changes',async()=>{
  const h=createHarness();
  const control=await h.mount();
  control.destroy();
  assert.equal(h.timers.size,0);
  h.runTimers();
  assert.notEqual(h.context.onTokenCalls.at(-1)?.detail?.state,'retryable_error');
});

test('customer password sign-in keeps credentials behind a current captcha token',()=>{
  const login=source.slice(
    source.indexOf('function renderCustomerPasswordSignIn'),
    source.indexOf('async function renderCustomerOtpStart')
  );
  assert.match(login,/if\(!captchaToken\)\{\s*errorHost\.innerHTML='<div class="err">Complete the security check to continue\.<\/div>';return;\s*\}/);
  assert.match(login,/const challenge=captchaToken;captchaToken='';\s*captchaControl\?\.beginSubmit\?\.\(\);/);
  assert.match(login,/sb\.auth\.signInWithPassword\(\{phone,password,options:\{captchaToken:challenge\}\}\)/);
  assert.match(login,/captchaControl\?\.recoverAfterServerReject\?\.\(\);/);
});

test('Cloudflare script loading has a finite timeout and admin auth uses reload-capable recovery',()=>{
  const turnstile=turnstileSource();
  assert.match(turnstile,/const scriptTimer=setTimeout\(fail,AUTH_TURNSTILE_WATCHDOG_MS\)/);
  assert.match(turnstile,/script\.onload=\(\)=>\{clearTimeout\(scriptTimer\);window\.turnstile\?resolve\(window\.turnstile\):fail\(\)\}/);
  assert.match(turnstile,/script\.onerror=\(\)=>\{clearTimeout\(scriptTimer\);fail\(\)\}/);
  assert.match(turnstile,/transition\('retryable_error',\{textKey:'load',isError:true,showRetry:true,showReload:true\}\)/);
  const auth=source.slice(
    source.indexOf('function renderAuth'),
    source.indexOf('function validNewPassword')
  );
  assert.match(auth,/retry:'authTurnstileRetry',reload:'authTurnstileReload',action:'frenly_auth'/);
});

import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const [app,ui]=await Promise.all([
  readFile(new URL('app/index.html',root),'utf8'),
  readFile(new URL('app/customer-ui.js',root),'utf8')
]);

test('toast timeout is generation-protected and removes historical text from the DOM',()=>{
  assert.match(app,/let toastGeneration=0,toastTimer=null;/);
  assert.match(app,/generation=\+\+toastGeneration/);
  assert.match(app,/if\(toastTimer\)clearTimeout\(toastTimer\)/);
  assert.match(app,/if\(generation!==toastGeneration\)return;[\s\S]*t\.classList\.remove\('show'\);t\.textContent=''/);
});

test('live-region lifecycle clears the latest announcement and ignores an obsolete timer',()=>{
  const polite={textContent:''};
  const assertive={textContent:''};
  const timers=[];
  const cleared=[];
  const window={};
  vm.runInNewContext(ui,{
    window,
    document:{getElementById:id=>id==='appAlert'?assertive:polite},
    requestAnimationFrame:callback=>callback(),
    setTimeout:callback=>{timers.push(callback);return timers.length;},
    clearTimeout:id=>cleared.push(id),
    MutationObserver:class {},
    Object,
    String,
    WeakMap
  });

  window.FrenlyCustomerUI.announce('historical database error',{assertive:true});
  assert.equal(assertive.textContent,'historical database error');
  const obsolete=timers[0];

  window.FrenlyCustomerUI.announce('Settings loaded',{assertive:true});
  assert.deepEqual(cleared,[1]);
  assert.equal(assertive.textContent,'Settings loaded');

  obsolete();
  assert.equal(assertive.textContent,'Settings loaded','obsolete timer must not clear a newer announcement');
  timers[1]();
  assert.equal(assertive.textContent,'','latest live-region text must clear after its bounded timeout');
});

import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('v91 preserves consent-aware visit-triggered inbox facts with truthful urgent windows',async()=>{
  const sql=await read('supabase/migrations/20260727163752_nestly_v91_customer_game_notifications.sql');
  assert.match(sql,/create or replace function app\.c46_customer_safe_inbox_candidates/);
  assert.match(sql,/interval '3 days'/);
  assert.match(sql,/interval '1 day'/);
  assert.match(sql,/Points expire tomorrow/);
  assert.match(sql,/Points expire within 3 days/);
  assert.match(sql,/'window'.*'one_day'.*'three_days'/s);
  assert.match(sql,/business_get_customer_join_qr_status_v91/);
  assert.doesNotMatch(sql,/push_token|service_worker|vapid|firebase/i,
    'v91 must not pretend an external push provider exists before owner configuration');
});

test('reward feedback is driven only by a new confirmed earn event and uses its actual unit',async()=>{
  const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(app,/function customerConfirmedEarnFeedback/);
  assert.match(app,/item\?\.event_type==='earn'&&Number\(item\?\.points_delta\|\|0\)>0/);
  assert.match(app,/safeUnit=unit==='stamps'\?'stamps':'points'/);
  assert.match(app,/toast\('\+'\+increase\+' '\+safeUnit\+' earned!'\)/);
  assert.doesNotMatch(app,/points added — quest progress updated/);
  assert.match(app,/prefers-reduced-motion: reduce/);
  assert.match(app,/AudioContext/);
  assert.match(app,/navigator\?\.vibrate/);
  assert.match(app,/function customerSuccessCue/);
  assert.match(app,/customer-redemption-complete/);
  assert.match(app,/customer-game-card/);
});

test('owner QR first-use creation is one atomic locked ensure operation',async()=>{
  const [app,sql]=await Promise.all([
    Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),
    read('supabase/migrations/20260727163752_nestly_v91_customer_game_notifications.sql')
  ]);
  assert.match(app,/business_ensure_customer_join_qr_v91/);
  assert.doesNotMatch(app,/active_count\|\|0\)===0[\s\S]{0,220}generateJoinQr/,
    'the browser must never status-check then rotate as two operations');
  const ensure=sql.match(/create or replace function public\.business_ensure_customer_join_qr_v91[\s\S]*?revoke all on function public\.business_ensure_customer_join_qr_v91/)?.[0]||'';
  assert.match(ensure,/app\.is_salon_owner\(p_business\) or app\.is_super_admin\(\)/);
  assert.match(ensure,/pg_advisory_xact_lock[\s\S]*status='active'[\s\S]*if found then[\s\S]*'created',false[\s\S]*business_create_customer_join_qr_v89/,
    'the shared lock and active check must precede creation');
  assert.doesNotMatch(ensure,/business_revoke_customer_join_qrs_v90/,
    'ensuring an active QR must never revoke a concurrent or printed QR');
});

test('scanner releases its dialog trap and restores focus unless route navigation owns focus',async()=>{
  const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(app,/dialogCleanup=CUI\.activateDialog/);
  assert.match(app,/dialogCleanup\(\{restoreFocus\}\)/);
  assert.match(app,/close\(\{restoreFocus:false\}\);nav\('#\/join'\)/);
  assert.match(app,/activeCustomerJoinScannerCleanup\(\{restoreFocus:false\}\)/);
});

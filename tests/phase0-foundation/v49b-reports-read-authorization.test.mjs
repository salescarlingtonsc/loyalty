import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const [source,deploy,fixture,app]=await Promise.all([
  readFile(new URL('db/migrations/20260722_frenly_v49b_reports_read_authorization.sql',root),'utf8'),
  readFile(new URL('supabase/migrations/20260722141000_frenly_v49b_reports_read_authorization.sql',root),'utf8'),
  readFile(new URL('db/tests/v49b_reports_read_authorization.sql',root),'utf8'),
  readFile(new URL('app/index.html',root),'utf8')
]);

test('v49b is a byte-identical atomic forward migration after v49a',()=>{
  assert.equal(deploy,source);
  assert.equal((source.match(/^begin;$/gim)||[]).length,1);
  assert.equal((source.match(/^commit;$/gim)||[]).length,1);
  assert.match(source,/pg_get_functiondef\([\s\S]*public\.get_reports_summary\(uuid,date,date,uuid\)/);
  assert.match(source,/v_legacy_occurrences <> 1 or v_read_occurrences <> 0[\s\S]*v_gift_card_legacy_occurrences <> 1 or v_gift_card_helper_occurrences <> 0/);
  assert.match(source,/unexpected get_reports_summary predecessor authorization definition/);
  assert.match(source,/v_definition := replace\(v_definition, v_legacy, v_read\)/);
  assert.match(source,/execute replace\(v_definition, v_gift_card_legacy, v_gift_card_helper\)/);
});

test('v49b keeps the report invoker and delegates only the protected aggregate',()=>{
  assert.match(source,/v_legacy text := '     or not app\.can_module\(p_business, ''reports''\) then'/);
  assert.match(source,/v_read text := '     or not app\.can_module_read\(p_business, ''reports''\) then'/);
  assert.doesNotMatch(source,/create or replace function public\.get_reports_summary/i);
  assert.match(source,/v_gift_card_legacy text := E'  select coalesce\(sum\(gc\.balance_cents\)/);
  assert.match(source,/v_gift_card_helper text := '  v_gift_card_liability := app\.reports_gift_card_liability_v49b\(p_business, p_branch\);'/);
  assert.match(source,/revoke all privileges on function public\.get_reports_summary\(uuid,date,date,uuid\)[\s\S]*from public, anon, authenticated/i);
  assert.match(source,/grant execute on function public\.get_reports_summary\(uuid,date,date,uuid\)[\s\S]*to authenticated/i);
});

test('v49b private scalar helper is independently authorized and exposes no raw table grant',()=>{
  const helper=source.slice(
    source.indexOf('create or replace function app.reports_gift_card_liability_v49b'),
    source.indexOf('do $migration$'),
  );
  assert.match(helper,/returns bigint[\s\S]*stable[\s\S]*security definer[\s\S]*set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(helper,/auth\.uid\(\) is null[\s\S]*app\.has_perm\(p_business, 'view_sales'\)[\s\S]*app\.can_module_read\(p_business, 'reports'\)/);
  assert.match(helper,/from public\.branches branch[\s\S]*app\.can_see_branch\(p_business, p_branch\)/);
  assert.match(helper,/sum\(card\.balance_cents\) filter \(where card\.status = 'active'\)[\s\S]*from public\.gift_cards card[\s\S]*where card\.business_id = p_business/);
  assert.doesNotMatch(helper,/\bexecute\b/i);
  assert.match(source,/revoke all privileges on function app\.reports_gift_card_liability_v49b\(uuid,uuid\)[\s\S]*from public, anon, authenticated/i);
  assert.match(source,/grant execute on function app\.reports_gift_card_liability_v49b\(uuid,uuid\)[\s\S]*to authenticated/i);
  assert.doesNotMatch(source,/grant\s+select[\s\S]*gift_cards/i);
});

test('v49b rollback fixture proves catalog invariants and full authorization matrix',()=>{
  assert.equal((fixture.match(/^begin;$/gim)||[]).length,1);
  assert.equal((fixture.match(/^rollback;$/gim)||[]).length,1);
  assert.match(fixture,/v_report\.provolatile<>'s' or v_report\.prosecdef/);
  assert.match(fixture,/v_helper\.provolatile<>'s' or not v_helper\.prosecdef/);
  assert.match(fixture,/v_helper_path<>'search_path=pg_catalog, public, app, pg_temp'/);
  assert.match(fixture,/has_table_privilege\('authenticated','public\.gift_cards','select'\)/);
  assert.match(fixture,/gift_card_liability_cents'\)::bigint<>1500/g);
  assert.match(fixture,/gift_card_liability_cents'\)::bigint<>0/);
  assert.match(fixture,/direct raw gift-card SELECT/);
  assert.match(fixture,/v_key_count<>6[\s\S]*code\|recipient\|email\|purchaser\|client_id/);
  for(const scenario of [
    'read-only unassigned branch Reports read','missing Reports module read','giftcards-only module read',
    'inactive Reports read','unaffiliated Reports read','foreign tenant Reports read',
    'anonymous Reports read','anonymous gift-card aggregate helper',
  ])assert.match(fixture,new RegExp(scenario));
  assert.match(fixture,/revenue_by_kind,quick_sale[\s\S]*<>1234/);
});

test('Reports explains that gift-card liability remains business-wide under a branch filter',()=>{
  assert.match(app,/Gift-card liability is business-wide, even when a branch filter is selected, because gift cards are not assigned to branches\./);
});

test('Reports uses zero-minimum tracks and one column at 390px without shrinking controls',()=>{
  const mobile=app.slice(app.indexOf('@media(max-width:767px){'),app.indexOf('@media(max-width:375px){'));
  assert.match(app,/<div class="grid reports-grid" id="rbody">/);
  assert.doesNotMatch(app,/id="rbody"[^>]*grid-template-columns/);
  assert.match(app,/\.reports-grid\{[^}]*grid-template-columns:repeat\(2,minmax\(0,1fr\)\)[^}]*width:100%[^}]*min-width:0[^}]*max-width:100%/s);
  assert.match(app,/\.reports-grid>\.card\{[^}]*min-width:0[^}]*max-width:100%/s);
  assert.match(app,/\.reports-grid table\{[^}]*table-layout:fixed/);
  assert.match(mobile,/\.reports-grid\{[^}]*grid-template-columns:minmax\(0,1fr\)[^}]*width:100%[^}]*min-width:0[^}]*max-width:100%/s);
  assert.match(app,/\.btn\{[^}]*min-height:44px/s);
  assert.match(app,/input,select,textarea\{[^}]*min-height:44px/s);
});

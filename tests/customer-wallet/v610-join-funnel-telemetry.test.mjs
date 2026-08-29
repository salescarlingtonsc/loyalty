/* nestly_v610 — scan-journey funnel telemetry (diagnosis instrumentation, owner-directed).
 *
 * The production trace for the real customer's phone ends at "business lookup 200 → UNKNOWN".
 * These pins hold the instrumentation that names UNKNOWN: every boundary of one scan journey
 * emits one event, correlated by a per-scan id, to the log-only join-funnel edge function.
 * The pins protect two properties above all: the raw token is never emitted, and the app-side
 * emitter is inert (zero traffic) unless a journey id exists.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const join=readFileSync(new URL('../../app/join.html',import.meta.url),'utf8');
const fn=readFileSync(new URL('../../supabase/functions/join-funnel/index.ts',import.meta.url),'utf8');
const config=readFileSync(new URL('../../supabase/config.toml',import.meta.url),'utf8');

const PAGE_EVENTS=['join_page_loaded','join_token_received','join_business_lookup_started',
  'join_business_lookup_succeeded','join_business_lookup_failed','join_confirmation_render_attempted',
  'join_confirmation_visible','join_yes_pointerdown','join_yes_click','join_pending_scan_saved',
  'join_navigation_started'];
const APP_EVENTS=['join_app_loaded','join_pending_scan_found','join_auth_screen_shown',
  'join_auth_completed','join_rpc_started','join_rpc_succeeded','join_rpc_failed','join_business_visible',
  /* the owner's real-device trace showed the IN-APP scanner is the failing surface — it starts
     its own journey and reports its own decode/camera outcomes and sheet visibility */
  'join_inapp_scan_opened','join_inapp_scan_result'];

test('the /join page emits every page-side stage',()=>{
  for(const event of PAGE_EVENTS)assert.ok(join.includes(`'${event}'`),`join.html emits ${event}`);
  assert.match(join,/sessionStorage\.setItem\('nestly\.join\.funnelCid',cid\)/,
    'the id is written for the app to continue the SAME journey');
});

test('the visibility probe measures what a finger would meet, not what code appended',()=>{
  assert.match(join,/elementFromPoint\(cx,cy\)/,'the element actually on top at the Yes centre');
  assert.match(join,/getBoundingClientRect\(\)/);
  assert.match(join,/pointerEvents:style\.pointerEvents/);
  assert.match(join,/topIsYes:onTop===yes/);
});

test('the in-app scanner starts its own journey with the build sha',()=>{
  const scanner=app.slice(app.indexOf('function openCustomerJoinScanner'),app.indexOf('function sortStaffWorkspaces'));
  assert.match(scanner,/joinFunnelStartV610\(\);/,'a fresh correlation id per scan-panel open');
  assert.match(scanner,/join_inapp_scan_opened',\{build:joinFunnelBuildV610\(\)/,
    'the build sha settles instantly whether the installed app is stale');
  assert.match(scanner,/reason:'unrecognised',shape:shapeV610/,'a rejected decode reports shape, never the raw value');
  const sheet=app.slice(app.indexOf('async function confirmCustomerJoinV571'),app.indexOf('function customerReferralReasonTextV571'));
  assert.match(sheet,/surface:'app-sheet',present:true,via/,'the in-app sheet has the same finger-level visibility probe');
  assert.match(sheet,/confirm sheet refused: pending token or hash moved/,'a guard refusal is loud, not silent');
});

test('the app continues the journey and emits every app-side stage',()=>{
  for(const event of APP_EVENTS)assert.ok(app.includes(`'${event}'`),`app.js emits ${event}`);
  const emitter=app.slice(app.indexOf('function joinFunnelEmitV610'),app.indexOf('function joinFunnelEndV610'));
  assert.match(emitter,/if\(!cid\)return;/,'inert for every ordinary visit — no journey id, no traffic');
});

test('no raw token, no PII, and the sink is log-only',()=>{
  /* The token may be REFERENCED for presence/length, never carried as a value. */
  assert.doesNotMatch(join,/joinFunnel\([^)]*token:\s*joinToken/,
    'the page never passes the token value to the funnel');
  assert.match(join,/joinFunnel\('join_token_received',\{present:!!joinToken,len:joinToken\?joinToken\.length:0\}\)/,
    'presence and length are the only things emitted about the token');
  assert.doesNotMatch(fn,/adminClient|createClient|from\(|rpc\(/,'the edge function touches no database');
  assert.match(fn,/console\.log\(`JOIN_FUNNEL cid=/,'one console line per event is the whole sink');
  assert.match(fn,/^\s*'join_business_visible',$/m,'the acceptance stage is an accepted event');
  assert.match(config,/\[functions\.join-funnel\]\nverify_jwt = false/,'registered as a public function');
});

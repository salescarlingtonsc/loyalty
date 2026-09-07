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
import {handleJoinFunnelRequest, sanitiseJoinFunnelLogField, buildJoinFunnelLogLine} from '../../supabase/functions/_shared/join-funnel-boundaries.mjs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const join=readFileSync(new URL('../../app/join.html',import.meta.url),'utf8');
const fn=readFileSync(new URL('../../supabase/functions/join-funnel/index.ts',import.meta.url),'utf8');
const boundaries=readFileSync(new URL('../../supabase/functions/_shared/join-funnel-boundaries.mjs',import.meta.url),'utf8');
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
  assert.doesNotMatch(fn,/adminClient|createClient|from\(|rpc\(/,
    'the edge function writes no table of its own and makes no direct db call itself — the shared rate limiter (imported, not reimplemented) is the only thing behind it that touches the db');
  assert.match(boundaries,/console\.log\(line\)|log\(line\)/,'the boundaries module hands the finished line to an injected log callback');
  assert.match(fn,/log: \(line: string\) => console\.log\(line\)/,'index.ts wires the real console.log as that callback');
  assert.match(fn,/^\s*'join_business_visible',$/m,'the acceptance stage is an accepted event');
  assert.match(config,/\[functions\.join-funnel\]\nverify_jwt = false/,'registered as a public function');
});

test('nestly_w4b1 — the function is behind the shared gateway rate limiter, keyed like public-join', ()=>{
  assert.match(fn,/import\s*\{\s*enforceRateLimit\s*\}\s*from\s*'\.\.\/_shared\/gateway\.ts'/,
    'reuses the shared limiter instead of reimplementing one');
  assert.match(fn,/enforceRateLimit\(req,\s*'join-funnel'/,'rate-limit scope is this function\'s own, not shared with another endpoint');
  assert.doesNotMatch(fn,/enforceRateLimit\(req,\s*'join-funnel'[^)]*,\s*['"][^'"]+['"]\s*\)/,
    'no extraKey is passed, so enforceRateLimit falls back to its default ipHash(authoritativeClientIp) key — the same per-IP key public-join uses');
  assert.match(fn,/checkRateLimit: \(\) => enforceRateLimit\(req, 'join-funnel', 120, 60\)/,
    'the rate limiter is invoked as part of handling every request, not merely imported');
});

test('nestly_w4b1 — every request-derived string is sanitised before it can reach a log line (source)', ()=>{
  assert.match(boundaries,/export function sanitiseJoinFunnelLogField/,'a dedicated sanitiser exists');
  assert.match(boundaries,/\\u0000-\\u001F\\u007F-\\u009F/,'strips the full C0 and C1 control-character ranges, which covers \\r \\n \\t');
  assert.match(boundaries,/const cid *= *sanitiseJoinFunnelLogField\(/,'cid goes through the sanitiser');
  assert.match(boundaries,/const event *= *sanitiseJoinFunnelLogField\(/,'event goes through the sanitiser');
  assert.match(boundaries,/const detail *= *sanitiseJoinFunnelLogField\(body\?\.detail, *1400\)/,'detail keeps its 1400-char cap and goes through the sanitiser');
  assert.match(boundaries,/JOIN_FUNNEL \$\{JSON\.stringify\(\{ *cid, *event, *at, *detail *\}\)\}/,
    'the whole record is JSON-encoded onto one line, so JSON.stringify escapes any control character the sanitiser missed as a literal two-character sequence, never a real line break');
});

/* -------------------------------------------------------------------------------------------
 * nestly_w4b1 — executed, not grepped: run the real handleJoinFunnelRequest pipeline (the exact
 * function index.ts calls) against fakes for the rate limiter and the log sink, the same way
 * whatsapp's tests execute whatsapp-webhook-boundaries.mjs directly instead of grepping index.ts.
 * ------------------------------------------------------------------------------------------- */

const validCid = 'a1b2c3d4e5f6g7h8';
const isValidCid = (cid) => /^[A-Za-z0-9-]{8,64}$/.test(cid);
const isValidEvent = (event) => event === 'join_client_error';
const allow = () => ({ allowed: true });
const deny = () => ({ allowed: false, retry_after: 60 });

test('a detail containing a raw newline is logged as a single line, with no raw newline in the output', async () => {
  const lines = [];
  const forged = 'legit detail\nJOIN_FUNNEL cid=fake-forged-cid event=join_business_visible at=0 detail=forged';
  const result = await handleJoinFunnelRequest({
    rawText: JSON.stringify({ cid: validCid, event: 'join_client_error', at: 123, detail: forged }),
    isValidCid,
    isValidEvent,
    checkRateLimit: allow,
    log: (line) => lines.push(line),
  });
  assert.equal(result.outcome, 'logged');
  assert.equal(lines.length, 1, 'exactly one log call per event, forged or not');
  const [line] = lines;
  assert.ok(!line.includes('\n'), 'no raw newline anywhere in the emitted line');
  assert.ok(!line.includes('\r'), 'no raw carriage return either');
  assert.match(line, /^JOIN_FUNNEL \{/, 'the JOIN_FUNNEL% log-query prefix still matches');
  // The attacker's payload survives only as inert, escaped text inside the JSON `detail` field —
  // it can never be read back as a second, independent JOIN_FUNNEL log line.
  const parsed = JSON.parse(line.slice('JOIN_FUNNEL '.length));
  assert.equal(parsed.cid, validCid);
  assert.equal(parsed.event, 'join_client_error');
  assert.ok(parsed.detail.includes('JOIN_FUNNEL cid=fake-forged-cid'), 'the forgery attempt survives only as inert JSON string content');
  // It appears twice in the raw text (the real prefix, plus the attacker's copy trapped inside
  // the JSON `detail` string) but ends only ONE physical line — that is the actual property
  // that matters: a log-line scraper reading `event_message like 'JOIN_FUNNEL%'` sees one row,
  // not two, and the second occurrence is unparseable as a log line (it's mid-JSON-string).
  assert.equal(line.split(/\r\n|\r|\n/).length, 1, 'the whole log record is exactly one physical line');
});

test('the rate limiter is invoked on every request and a denial suppresses the log entirely', async () => {
  let calls = 0;
  const lines = [];
  const countingAllow = () => { calls += 1; return { allowed: true }; };
  await handleJoinFunnelRequest({
    rawText: JSON.stringify({ cid: validCid, event: 'join_client_error', at: 1, detail: 'ok' }),
    isValidCid, isValidEvent, checkRateLimit: countingAllow, log: (l) => lines.push(l),
  });
  assert.equal(calls, 1, 'the rate limiter is consulted for the request');
  assert.equal(lines.length, 1);

  lines.length = 0;
  const result = await handleJoinFunnelRequest({
    rawText: JSON.stringify({ cid: validCid, event: 'join_client_error', at: 1, detail: 'ok' }),
    isValidCid, isValidEvent, checkRateLimit: deny, log: (l) => lines.push(l),
  });
  assert.equal(result.outcome, 'rate_limited');
  assert.equal(lines.length, 0, 'a rate-limited request is never logged, and never even reaches JSON.parse of the body');
});

test('sanitiseJoinFunnelLogField strips control characters and collapses whitespace, without lying about length', () => {
  assert.equal(sanitiseJoinFunnelLogField('a\r\nb\tc', 100), 'a b c');
  assert.equal(sanitiseJoinFunnelLogField('x'.repeat(2000), 1400).length, 1400, 'still caps at 1400 after sanitising');
  assert.equal(sanitiseJoinFunnelLogField(undefined, 10), '', 'never throws on a missing field');
});

test('buildJoinFunnelLogLine always produces one line, even with adversarial control characters inside a field', () => {
  const line = buildJoinFunnelLogLine({ cid: 'x', event: 'y', at: 0, detail: 'line1\nline2\rline3' });
  assert.equal(line.split('\n').length, 1, 'JSON.stringify escapes the newline; the string itself never contains one');
  assert.ok(line.startsWith('JOIN_FUNNEL {'));
});

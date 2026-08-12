import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const appJs = await read('app/app.js');

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

const loadTurnstile = section(appJs, 'function loadTurnstile(', 'const authSecurityCopy=');
const mountTurnstile = section(appJs, 'async function mountTurnstile(', 'const AUTH_TURNSTILE_SITE_KEY=');

/* V206: Turnstile must never be able to strand the sign-in form on "Loading security check…"
   with the Retry button hidden. These tests pin the structural invariants that guarantee that,
   independent of the exact prose in any failure message. */

/* --------------------------------------------------------------------- timeout constants */

test('the script-load and solve-watchdog timeouts are declared with sane bounds', () => {
  assert.match(appJs, /const TURNSTILE_SCRIPT_TIMEOUT_MS=(\d+);/);
  assert.match(appJs, /const TURNSTILE_SOLVE_TIMEOUT_MS=(\d+);/);
  const scriptMs = Number(appJs.match(/const TURNSTILE_SCRIPT_TIMEOUT_MS=(\d+);/)[1]);
  const solveMs = Number(appJs.match(/const TURNSTILE_SOLVE_TIMEOUT_MS=(\d+);/)[1]);
  assert.ok(scriptMs >= 5000 && scriptMs <= 30000, `script timeout ${scriptMs}ms out of sane bounds`);
  assert.ok(solveMs >= 5000 && solveMs <= 30000, `solve timeout ${solveMs}ms out of sane bounds`);
  // the solve watchdog should give a genuinely rendered widget more room than the raw script
  // fetch — collapsing them to the same value would starve a slow-but-alive Cloudflare flow.
  assert.ok(solveMs >= scriptMs, 'solve timeout should be at least as generous as the script load timeout');
});

/* --------------------------------------------------------------- loadTurnstile() failure paths */

test('every loadTurnstile() failure path clears the cached loader promise so Retry re-requests', () => {
  // the single `fail()` closure is the only place turnstileLoader is written back to null; every
  // caller of fail() (onerror, the timeout deadline, onload-without-api) inherits the reset.
  assert.match(loadTurnstile, /const fail=\(message,\{remove=true\}=\{\}\)=>\{\n\s*if\(settled\)return;\n\s*settled=true;clearTimeout\(deadline\);turnstileLoader=null;/);
  assert.match(loadTurnstile, /script\.onerror=\(\)=>fail\('Security check unavailable\.'\);/);
  assert.match(loadTurnstile, /setTimeout\(\(\)=>fail\('Security check timed out\.',\{remove:false\}\),TURNSTILE_SCRIPT_TIMEOUT_MS\);/);
  // onload firing without the global defined (captive portal / interception proxy) must also
  // route through fail(), not resolve — a truthy onload alone is not proof of a working widget.
  assert.match(loadTurnstile, /const succeed=\(\)=>\{[\s\S]*if\(!api\)return fail\('Security check unavailable\.'\);/);
});

test('the timeout branch leaves the script element in place while onerror removes it', () => {
  // remove:false on timeout: a slow-but-alive request may still define window.turnstile, and the
  // next Retry then resolves instantly off the global instead of re-injecting a second script tag.
  assert.match(loadTurnstile, /fail\('Security check timed out\.',\{remove:false\}\)/);
  // onerror uses fail()'s default {remove=true} — a genuinely failed request's script tag is
  // torn down so a Retry starts clean.
  assert.match(loadTurnstile, /script\.onerror=\(\)=>fail\('Security check unavailable\.'\);/);
  assert.doesNotMatch(loadTurnstile, /script\.onerror=\(\)=>fail\('Security check unavailable\.',\{remove:false\}\)/);
  assert.match(loadTurnstile, /if\(remove\)script\.remove\(\);/);
});

/* --------------------------------------------------------------------- mountTurnstile() wiring */

test('every mountTurnstile() failure/expiry/timeout callback un-hides the Retry control', () => {
  for (const cb of [
    "'expired-callback':()=>{if(!live())return;stopStall();clear(security('expired'),true);retryEl.hidden=false}",
    "'timeout-callback':()=>{if(!live())return;stopStall();clear(security('timeout'),true);retryEl.hidden=false}",
    "'error-callback':(errorCode)=>{if(!live())return true;stopStall();logTurnstileError(errorCode);clear(security('connect'),true);retryEl.hidden=false;return true}",
  ]) {
    assert.ok(mountTurnstile.includes(cb), `missing or changed callback: ${cb}`);
  }
  // the render()-level catch is the backstop for a rejected loadTurnstile() (script load timeout,
  // network failure, etc) — it must also surface Retry, not just the widget-level callbacks.
  assert.match(mountTurnstile, /\}catch\{\n\s*stopStall\(\);\n[\s\S]*?if\(live\(\)\)\{clear\(security\('load'\),true\);retryEl\.hidden=false\}/);
  // and the stall watchdog itself (silent wedge, no callback of any kind) has the same duty.
  assert.match(mountTurnstile, /const armStall=\(mine\)=>\{\n\s*stopStall\(\);\n\s*stall=setTimeout\(\(\)=>\{\n\s*if\(destroyed\|\|mine!==generation\)return;\n\s*clear\(security\('timeout'\),true\);retryEl\.hidden=false;/);
});

test('the success callback checks the generation guard before writing the token', () => {
  assert.match(mountTurnstile, /const live=\(\)=>!destroyed&&mine===generation;/);
  /* V286: the same callback now also records that a token arrived and clears the 12s
     "Taking long? Reload to retry." line. The guard order this test is about is unchanged:
     live() first, then stopStall(), and onToken() still only ever receives a real token. */
  assert.match(mountTurnstile, /callback:\(token\)=>\{if\(!live\(\)\)return;stopStall\(\);tokenSeenV286=true;stopSlowNoteV286\(\);onToken\(token\);retryEl\.hidden=true;setPassed\(true\)\}/);
  // every widget callback opens on the same live() guard — a stale generation's token, error, or
  // expiry must never reach the CURRENT render's DOM or the current onToken().
  const callbackGuardCount = (mountTurnstile.match(/if\(!live\(\)\)return/g) || []).length;
  assert.ok(callbackGuardCount >= 5, `expected the live() guard on every widget callback, saw ${callbackGuardCount} uses`);
});

test('destroy() bumps the generation and stops the stall watchdog', () => {
  /* V286: destroy() also cancels the slow-fallback timer, so a torn-down widget cannot paint
     its "Taking long?" line onto whatever screen replaced it. */
  assert.match(mountTurnstile, /const destroy=\(\)=>\{\n\s*if\(destroyed\)return;\n\s*destroyed=true;generation\+=1;stopStall\(\);stopSlowNoteV286\(\);\n\s*retryEl\.onclick=null;removeWidget\(\);mountedTurnstileControls\.delete\(control\);\n\s*\};/);
});

test('armStall() is keyed to TURNSTILE_SOLVE_TIMEOUT_MS, not a re-declared literal', () => {
  assert.match(mountTurnstile, /const armStall=\(mine\)=>\{\n\s*stopStall\(\);\n\s*stall=setTimeout\(\(\)=>\{[\s\S]*?\},TURNSTILE_SOLVE_TIMEOUT_MS\);\n\s*\};/);
});

test('the interactive handoff disarms the stall watchdog and re-arms it once collapsed', () => {
  // Cloudflare's own interactive flow (tapping the checkbox) can legitimately take longer than
  // the silent-wedge watchdog allows — so the watchdog must step aside while the checkbox is
  // visible, then resume the instant the widget goes back to unattended waiting.
  assert.match(mountTurnstile, /'before-interactive-callback':\(\)=>\{if\(!live\(\)\)return;stopStall\(\);message\(security\('interactive'\)\)\}/);
  assert.match(mountTurnstile, /'after-interactive-callback':\(\)=>\{if\(!live\(\)\)return;armStall\(mine\);message\(security\('loading'\)\)\}/);
});

test('render() arms the stall watchdog for its own generation before awaiting the loader', () => {
  assert.match(mountTurnstile, /const render=async\(\)=>\{\n\s*if\(destroyed\)return;\n\s*generation\+=1;\n\s*const mine=generation;\n\s*const live=\(\)=>!destroyed&&mine===generation;\n\s*message\(security\('loading'\)\);retryEl\.hidden=true;\n\s*armStall\(mine\);/);
});

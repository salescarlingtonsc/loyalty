import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

test('publishing an offer cannot hang forever', () => {
  // Owner: "why publishing forever?" — sb.rpc had no timeout, so a stalled request never settled
  // and the status sat at "Publishing…" with no error path at all.
  assert.match(app, /const PROMOTION_RPC_TIMEOUT_MS_V186=\d+/);
  const i = app.indexOf('promotionReceiptRpcV104=Object.freeze');
  const src = app.slice(i, i + 500);
  assert.ok((src.match(/abortSignal\(customerRpcSignal\(PROMOTION_RPC_TIMEOUT_MS_V186\)\)/g) || []).length === 2,
    'both the draft and finalize receipt calls need the timeout');
});

test('a timed-out publish is ambiguous, never a clean failure', () => {
  // The server may already have committed, so the receipt key must be replayed rather than the
  // just-uploaded photo being deleted.
  const i = app.indexOf('function promotionRpcErrorIsAmbiguousV104');
  const src = app.slice(i, i + 800);
  assert.match(src, /error\.name==='AbortError'/);
  assert.ok(src.indexOf("error.name==='AbortError'") < src.indexOf('if(error.code)return false'),
    'the abort check must run before the code check that would classify it as a clean failure');
});

test('a save that cannot be confirmed hands the editor back instead of locking it', () => {
  // pendingFinalize is written to session storage BEFORE the call, so a stalled save hijacked
  // every later press AND every reload into "Confirming the previous save…" — the owner could
  // never edit or publish that offer again.
  const i = app.indexOf("status.textContent='Confirming the previous save…'");
  const src = app.slice(i, i + 1400);
  // The pending receipt is deliberately NOT cleared on an ambiguous error — the server may have
  // committed, and the same idempotent key must replay. What was broken is that the controls
  // stayed disabled, locking the owner out of the editor.
  assert.match(src, /\.filter\(Boolean\)\.forEach\(button=>\{button\.disabled=false\}\)/);
  assert.match(src, /Your edits are safe|Your edits are still here/);
  // `buttons` is declared further down save(); referencing it here would throw.
  assert.ok(!/\n\s*buttons\.forEach/.test(src),
    'the resume branch must not reference the later `buttons` binding');
  assert.match(src, /field\('promotionSave'\),field\('promotionPublish'\)/);
});

test('an offer that has not started yet is never labelled as simply Published', () => {
  // Owner: "i dont see the published marketing content". It WAS published — and scheduled to
  // start two days later — but every label said only "Published", so an offer no customer could
  // see looked live.
  assert.match(app, /function promotionLifecycleV186\(item,now=new Date\(\)\)/);
  const i = app.indexOf('function promotionLifecycleV186');
  const src = app.slice(i, i + 900);
  assert.ok(src.includes("state:'scheduled'") && src.includes("state:'ended'") && src.includes("state:'live'"),
    'draft / scheduled / live / ended must be distinguished');
  assert.match(src, /starts&&starts>now/);
  assert.match(app, /promotionLifecycleV186\(item\)\.label/);
  assert.match(app, /customers cannot see it yet — it starts/);
  assert.ok(!app.includes("item.active?'Published':'Draft'"),
    'the two-state label that hid scheduled offers must be gone');
});

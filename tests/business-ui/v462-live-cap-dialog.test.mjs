/* V462 — owner ruling R2c: "publishing when 10 are live prompts the owner to move one to draft
 * first (honest dialog, no silent failure)."
 *
 * Three shipped pieces are executed here, not described:
 *   promotionPublishLimitRefusalV462  — recognises the refusal from the server's own `reason`
 *   promotionDemoteDialogV462         — the dialog: which offers are live, which one to demote
 *   demoteLiveOfferV462               — performs the demotion through the EXISTING finalize writer
 *
 * The DOM is a shim rather than jsdom (this repo has none) and the Supabase client is a recording
 * stub; both are small enough to read, and every stub returns a distinctive value so no assertion
 * can pass on an empty render or a call that never happened.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

const between = (start, end) => {
  const from = app.indexOf(start);
  assert.notEqual(from, -1, `missing start ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end ${end}`);
  return app.slice(from, to + end.length);
};

const esc = value => String(value ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const REFUSAL_SRC = between('function promotionPublishLimitRefusalV462(error){', '\n}');
const LIFECYCLE_SRC = between('function promotionLifecycleV186(item,now=new Date()){', '\n}');
const DATE_TEXT_SRC = between('function promotionDateTextV104(value){', '\n}');
const DIALOG_SRC = between('function promotionDemoteDialogV462({live=[],max=0}={}){', '\n}');
const DEMOTE_SRC = between('  const demoteLiveOfferV462=async promotionId=>{', '\n  };');

// ---------------------------------------------------------------- the refusal predicate

const isLiveCapRefusal = new Function(`${REFUSAL_SRC}\nreturn promotionPublishLimitRefusalV462;`)();

test('V462 the cap refusal is recognised from the server\'s own reason, never from prose', () => {
  /* Exactly the shape business_finalize_promotion_v155 returns (v378) once runPendingFinalize has
     converted its structured 200 into an error object. */
  assert.equal(isLiveCapRefusal({
    code: 'promotion_finalize_rejected',
    reason: 'promotion_publish_limit_reached',
    message: 'This promotion was not saved (promotion_publish_limit_reached). Reopen it…',
  }), true);
  /* NEGATIVE CONTROLS: every other definitive refusal, and the retryable conflict, must stay out
     of this branch — routing a version conflict into the demote dialog would ask the owner to
     retire an offer for no reason. */
  assert.equal(isLiveCapRefusal({ code: 'promotion_finalize_rejected', reason: 'promotion_image_required' }), false);
  assert.equal(isLiveCapRefusal({ code: '40001', reason: 'promotion_version_conflict' }), false);
  assert.equal(isLiveCapRefusal({ code: 'owner_required', message: 'owner required' }), false);
  assert.equal(isLiveCapRefusal(null), false);
  assert.equal(isLiveCapRefusal(undefined), false);
  assert.equal(isLiveCapRefusal({}), false);
});

test('V462 runPendingFinalize carries the server reason through instead of flattening it', () => {
  /* Without this line the reason survives only inside an English sentence, and recognising a
     refusal by parsing prose is how the cap became invisible in the first place. */
  assert.match(app, /result=\{data:null,error:\{code:'promotion_finalize_rejected',reason:result\.data\.reason\|\|'',/);
});

// ---------------------------------------------------------------- the dialog

/* A DOM shim, not a browser. It records innerHTML, resolves the two buttons and the radio group,
   and lets a test "click". Anything the dialog touches that is not modelled here would throw. */
function domShim() {
  const appended = [];
  const makeNode = () => {
    const node = {
      className: '', tabIndex: 0, innerHTML: '', removed: false,
      attributes: new Map(),
      setAttribute(name, value) { this.attributes.set(name, String(value)); },
      remove() { this.removed = true; },
      querySelector(selector) {
        if (selector === 'input[name="promotionDemotePickV462"]:checked') {
          const checked = [...node.innerHTML.matchAll(
            /<input type="radio" name="promotionDemotePickV462" value="([^"]+)"( checked)?>/g)]
            .filter(match => match[2]);
          assert.ok(checked.length <= 1, 'at most one radio may be pre-checked');
          return checked.length ? { value: checked[0][1] } : null;
        }
        const id = selector.replace('#', '');
        assert.ok(node.innerHTML.includes(`id="${id}"`), `dialog must contain #${id}`);
        const handle = { onclick: null };
        buttons.set(id, handle);
        return handle;
      },
    };
    return node;
  };
  const buttons = new Map();
  const document = { createElement: () => makeNode(), body: { append: node => appended.push(node) } };
  return { document, appended, buttons };
}

function buildDialog() {
  const { document, appended, buttons } = domShim();
  const activations = [];
  const CUI = {
    activateDialog: (dialog, options) => {
      activations.push({ dialog, options });
      return ({ restoreFocus } = {}) => { dialog.removed = true; dialog.restoreFocus = restoreFocus; };
    },
  };
  const open = new Function('esc', 'document', 'CUI',
    `${DATE_TEXT_SRC}\n${LIFECYCLE_SRC}\n${DIALOG_SRC}\nreturn promotionDemoteDialogV462;`)(esc, document, CUI);
  return { open, appended, buttons, activations };
}

const LIVE = [
  { id: 'p1', name: '20% off spa', active: true, ends_at: '2099-01-01T00:00:00+08:00' },
  { id: 'p2', name: 'Kopi hour', active: true, ends_at: '2099-01-02T00:00:00+08:00' },
  { id: 'p3', name: 'Toast set', active: true, ends_at: '2099-01-03T00:00:00+08:00' },
];

test('V462 the dialog names the real limit and LISTS the live offers rather than sending the owner away', () => {
  const { open, appended } = buildDialog();
  open({ live: LIVE, max: 10 });
  assert.equal(appended.length, 1, 'exactly one dialog is mounted');
  const html = appended[0].innerHTML;
  assert.match(html, /You already have 3 offers live/);
  assert.match(html, /10 live offers is the limit for this business/,
    'the sentence must name the entitlement it was handed, not a constant');
  for (const offer of LIVE) {
    assert.ok(html.includes(offer.name), `${offer.name} must be offered as a choice`);
    assert.ok(html.includes(`value="${offer.id}"`));
  }
  assert.match(html, /Customers stop seeing the one you choose; nothing about it is deleted/,
    'the dialog must be honest about what "move to draft" costs');
  assert.match(html, /Move to draft and publish/);
  assert.match(html, /Keep them all — do not publish/);
});

test('V462 confirming resolves the chosen offer; the first is pre-selected so a blind Enter is safe', async () => {
  const { open, buttons } = buildDialog();
  const promise = open({ live: LIVE, max: 10 });
  buttons.get('promotionDemoteOkV462').onclick();
  assert.equal(await promise, 'p1');
});

test('V462 cancelling resolves null, which the caller reads as "publish nothing"', async () => {
  const { open, buttons } = buildDialog();
  const promise = open({ live: LIVE, max: 10 });
  buttons.get('promotionDemoteCancelV462').onclick();
  assert.equal(await promise, null);
});

test('V462 Escape (the dialog\'s own onClose) also resolves null, and closing restores focus', async () => {
  const { open, activations, appended } = buildDialog();
  const promise = open({ live: LIVE, max: 10 });
  assert.equal(activations.length, 1);
  assert.equal(activations[0].options.initialFocus, '#promotionDemoteCancelV462',
    'the safe option takes focus — this dialog opens mid-publish');
  activations[0].options.onClose();
  assert.equal(await promise, null);
  assert.equal(appended[0].removed, true);
});

test('V462 R5 NEGATIVE CONTROL: there is no backdrop-click dismissal on this dialog', () => {
  /* Owner ruling R5, 2026-08-23: backdrop-click dismissal stays OFF. It matters more here than
     anywhere else — this dialog is opened in the middle of a publish the owner asked for, and a
     stray click behind it must not silently abandon the save. */
  assert.doesNotMatch(DIALOG_SRC, /dialog\.onclick\s*=/);
  assert.doesNotMatch(DIALOG_SRC, /event\.target===dialog/);
  const { open, appended } = buildDialog();
  open({ live: LIVE, max: 10 });
  assert.equal(appended[0].onclick, undefined, 'no click handler is installed on the backdrop');
});

test('V462 the dialog is a real dialog for assistive technology', () => {
  const { open, appended } = buildDialog();
  open({ live: LIVE, max: 10 });
  assert.equal(appended[0].attributes.get('role'), 'dialog');
  assert.equal(appended[0].attributes.get('aria-modal'), 'true');
  assert.equal(appended[0].attributes.get('aria-labelledby'), 'promotionDemoteTitleV462');
  assert.match(appended[0].innerHTML, /role="radiogroup" aria-label="Offer to move back to draft"/);
});

// ---------------------------------------------------------------- the demotion write

function buildDemoter(items, reply) {
  const calls = [];
  /* A recording stub shaped like safeRpc: it never throws and always answers {data,error}. */
  const safeRpc = async (name, args) => { calls.push({ name, args }); return reply; };
  const run = new Function('items', 'safeRpc', 'businessId', 'operationalPromotionBranch',
    'exactTargetMediaVersion', 'crypto',
    `${DEMOTE_SRC}\nreturn demoteLiveOfferV462;`)(
    items, safeRpc, 'biz-1', 'branch-1', () => 4,
    { randomUUID: () => '11111111-2222-3333-4444-555555555555' });
  return { run, calls };
}

const TARGET = {
  id: 'p2', name: 'Kopi hour', description: 'A ten percent offer for the acceptance run.',
  terms: 'One per visit.', offerFacts: '10% off any kopi', occasion: null,
  ctaKind: 'counter', ctaLabel: 'Show at counter',
  starts_at: '2026-08-01T00:00:00+08:00', ends_at: '2099-01-02T00:00:00+08:00',
  display_order: 0, contentVersion: 7, copyVersion: 3,
  branchScope: { mode: 'all_branches', branch_ids: [] },
};

test('V462 demoting goes through the EXISTING finalize writer, changing exactly one property', async () => {
  const { run, calls } = buildDemoter([TARGET], { data: { promotion_id: 'p2' }, error: null });
  const result = await run('p2');
  assert.equal(result.error, null);
  assert.equal(calls.length, 1, 'one write, not two');
  const { name, args } = calls[0];
  assert.equal(name, 'business_finalize_promotion_v155',
    'the same writer the editor\'s own Unpublish uses — never business_delete_promotion_v183, ' +
    'which RETIRES an offer (ends_at pulled to now) instead of drafting it');
  assert.equal(args.p_publish, false);
  assert.equal(args.p_business, 'biz-1');
  assert.equal(args.p_promotion_id, 'p2');
  /* Every other field is echoed back, so nothing else about the offer moves. */
  assert.equal(args.p_name, TARGET.name);
  assert.equal(args.p_description, TARGET.description);
  assert.equal(args.p_terms, TARGET.terms);
  assert.equal(args.p_offer_facts, TARGET.offerFacts);
  assert.equal(args.p_cta_kind, TARGET.ctaKind);
  assert.equal(args.p_cta_label, TARGET.ctaLabel);
  assert.equal(args.p_starts_at, TARGET.starts_at);
  assert.equal(args.p_ends_at, TARGET.ends_at);
  /* display_order 0 is a real value, not a missing one (the v104 ??100 rule). */
  assert.equal(args.p_display_order, 0);
  assert.equal(args.p_expected_content_version, 7);
  assert.equal(args.p_expected_copy_version, 3);
  assert.equal(args.p_expected_target_media_version, 4);
  /* Its photo is left exactly where it is. */
  assert.equal(args.p_object_path, null);
  assert.equal(args.p_mime_type, null);
  assert.equal(args.p_alt_en, null);
  assert.ok(args.p_attempt_key, 'a fresh idempotency key, because these are new arguments');
});

test('V462 a branch-scoped offer keeps its branch scope when it is demoted', async () => {
  const scoped = { ...TARGET, branchScope: { mode: 'selected_branches', branch_ids: ['br-a', 'br-b'] } };
  const { run, calls } = buildDemoter([scoped], { data: {}, error: null });
  await run('p2');
  assert.equal(calls[0].args.p_scope_mode, 'selected');
  assert.deepEqual(calls[0].args.p_branch_ids, ['br-a', 'br-b']);
});

test('V462 NEGATIVE CONTROL: a structured 200 refusal is treated as the failure it is', async () => {
  /* v378 returns definitive refusals as {ok:false,blocked:true,...} with NO transport error. A
     caller that only checks `error` would report "moved to draft" and then publish over the cap. */
  const { run } = buildDemoter([TARGET], {
    data: { ok: false, blocked: true, code: 'promotion_finalize_rejected', reason: 'promotion_version_conflict' },
    error: null,
  });
  const result = await run('p2');
  assert.ok(result.error, 'a blocked reply must not read as success');
  assert.equal(result.error.reason, 'promotion_version_conflict');
  assert.match(result.error.message, /was not moved to draft/);
});

test('V462 NEGATIVE CONTROL: an unknown offer id writes nothing at all', async () => {
  const { run, calls } = buildDemoter([TARGET], { data: {}, error: null });
  const result = await run('does-not-exist');
  assert.ok(result.error);
  assert.equal(calls.length, 0, 'no write may be attempted against an offer this page never read');
});

test('V462 NEGATIVE CONTROL: a transport error is surfaced, not swallowed', async () => {
  const { run } = buildDemoter([TARGET], { data: null, error: { message: 'network down' } });
  const result = await run('p2');
  assert.equal(result.error.message, 'network down');
});

test('V462 the publish the owner asked for continues by itself after the demotion', () => {
  const runSave = between('  const runSave=async(publish,{unpublish=false}={})=>{',
    '\n  /* V280: the busy state is released on EVERY path');
  /* Only a PUBLISH opens the dialog: an unpublish or a draft save can never hit a live cap. */
  assert.match(runSave, /if\(finalized\.error&&publish&&!unpublish&&promotionPublishLimitRefusalV462\(finalized\.error\)\)\{/);
  /* The offer being published is excluded from its own demote list. */
  assert.match(runSave, /live:liveOffersV462\.filter\(item=>String\(item\.id\)!==String\(workingPromotionId\)\)/);
  /* Declining leaves the draft and its work intact rather than discarding either. */
  assert.match(runSave, /workspaceTemplateTextV97\('offerLiveCapReached',\{max\}\)/);
  /* Accepting demotes, then re-sends the SAME save under a NEW attempt key — replaying the old
     one could only raise promotion_attempt_key_reused, because the first attempt rolled back. */
  assert.match(runSave, /const demoted=await demoteLiveOfferV462\(demoteId\);/);
  assert.match(runSave, /pendingFinalize=buildPendingFinalizeV280\(workingPromotion,crypto\.randomUUID\(\)\);\s*\n\s*writeSessionValue\(pendingStorageKey,pendingFinalize\);\s*\n\s*status\.textContent='Publishing…';\s*\n\s*finalized=await runPendingFinalize\(pendingFinalize\);/);
  /* And a failed demotion publishes nothing. */
  assert.match(runSave, /That offer could not be moved back to draft, so nothing was published\./);
});

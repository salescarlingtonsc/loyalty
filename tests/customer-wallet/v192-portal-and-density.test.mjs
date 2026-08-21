import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const indexHtml = await read('app/index.html');
const appJs = await read('app/app.js');
const app = `${indexHtml}\n${appJs}`;

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}
const portal = section(appJs, 'async function renderPortal(slug){', 'async function boot(){');
const prefill = section(appJs, 'function prefillEmptyPortalDetails', 'function customerBookingIdentitySummaryV167');

/* ------------------------------------------------------------------ 1 · the offer list fits */

test('a promotion in the list no longer fills the screen', () => {
  assert.match(indexHtml, /\.customer-promotion-card\{[^}]*border-radius:18px/);
  assert.doesNotMatch(indexHtml, /\.customer-promotion-card\{[^}]*min-height:360px/,
    'the fixed 360px floor is what made a two-offer list three screens long');
  /* nestly_v417: the max-height that capped the card is now a fixed 16:9 frame — a stricter
     bound, and the one that also makes two offers the same shape (owner, photo 4). */
  assert.match(indexHtml, /\.customer-promotion-card-media\{[^}]*aspect-ratio:16\/9/);
  assert.match(indexHtml, /\.customer-promotion-card-copy\{[^}]*padding:15px 16px 16px\}/);
});

test('shrinking it did not start cropping the business’s artwork', () => {
  // the owner's earlier ruling: an uploaded EDM has its words baked in
  /* nestly_v417 — THE NEVER-CROP RULE WAS REVERSED BY THE OWNER, deliberately.
     Photos 1, 3 and 4, 2026-08-21: "picture not max out ... i want uploaded photo full to
     picture", "why here have big empty space", and "even when two offers photo are different
     size, pls simplify to one fixed size/format so it appears uniform in customer app".
     Contain in a fixed frame letterboxes a 4:5 poster and makes two offers two different shapes;
     that is what the owner photographed. Cards crop now.
     WHAT SURVIVES, and is asserted below: opening an offer still shows the photo WHOLE. The
     detail dialog and the full-page offer view keep object-fit:contain, so nothing a firm
     designed is lost — it is only framed consistently in the list. */
  assert.match(indexHtml, /\.customer-promotion-card-media img\{[^}]*object-fit:cover/);
  assert.doesNotMatch(indexHtml, /customer-promotion-card-media::after/);
  /* v192's real point — the card must not grow to swallow the screen — is now enforced by a
     fixed 16:9 frame rather than by a max-height, which is stricter, not looser. */
  assert.match(indexHtml, /\.customer-promotion-card-media\{[^}]*aspect-ratio:16\/9/);
  // full size is still one tap away in the sheet
  assert.match(indexHtml, /\.customer-offer-detail-media--fallback\{[^}]*aspect-ratio:16\/9/);
});

/* ------------------------------------------------------------- 2 · a way back off the portal */

test('a customer who came from their wallet can get back', () => {
  assert.match(portal, /let portalBackHrefV192=signedInUser\?'#\/wallet':''/,
    'a stranger who opened the QR has nothing to go back to, so they get no control');
  assert.match(portal, /portalBackHrefV192\?`<a class="btn ghost sm portal-back" href="\$\{esc\(portalBackHrefV192\)\}"/);
  assert.match(portal, /portalBackHrefV192=`#\/wallet\/\$\{encodeURIComponent\(slug\)\}`/,
    'once the link resolves, Back points at that business’s own programme');
  assert.match(portal, /const back=root\.querySelector\('\.portal-back'\);\s*\n\s*if\(back\)back\.setAttribute\('href',portalBackHrefV192\)/);
});

/* --------------------------------------------------------- 3 · Edit booking details actually works */

test('"Edit booking details" is wired to a stepper it can actually see', () => {
  assert.match(portal, /let portalShowStepV192=null;/);
  assert.match(portal, /const showStep=portalShowStepV192=\(idx\)=>\{/,
    'draw() must publish its stepper for handlers attached after it returns');
  assert.match(portal, /\$\('portalBookingEditIdentity'\)\?\.addEventListener\('click',\(\)=>portalShowStepV192\?\.\(steps\.indexOf\('details'\)\)\)/);
  assert.doesNotMatch(portal, /addEventListener\('click',\(\)=>showStep\(steps\.indexOf\('details'\)\)\)/,
    'the old handler referenced a const scoped inside draw() and threw ReferenceError');
});

/* ------------------------------------------- 4 · "Just a reservation" belongs to table businesses */

test('a spa is not offered a table reservation', () => {
  assert.match(portal, /\$\{usesTables\?`<button class="svc\$\{\(serviceChosen&&selSvc===null\)\?' sel':''\}"[^`]*Just a reservation/,
    'the general-visit choice is only for a business that takes table reservations');
  // a business with no services at all still gets the general-visit path
  assert.match(portal, /:`<p class="muted small">We'll note this as a general visit/);
});

/* ----------------------------------------------------- 5 · the phone is split from its country code */

test('a verified phone fills the local field, not the whole E.164 number', () => {
  const build = new Function(`
    const COUNTRY_CODES=[['+65','SG'],['+60','MY'],['+852','HK'],['+1','US']];
    const fields={};
    const $=id=>fields[id];
    ${prefill}
    return (phone)=>{
      fields.pn={value:''};fields.pe={value:''};
      fields.pp={value:''};fields.ppcc={value:'+65'};
      prefillEmptyPortalDetails({user:{phone}});
      return {cc:fields.ppcc.value,local:fields.pp.value};
    };`)();
  // Supabase stores E.164 without the plus — this is the number in the owner's screenshot
  assert.deepEqual(build('6581863833'), { cc: '+65', local: '81863833' });
  assert.deepEqual(build('+6581863833'), { cc: '+65', local: '81863833' });
  assert.deepEqual(build('65 8186 3833'), { cc: '+65', local: '81863833' });
  assert.deepEqual(build('60123456789'), { cc: '+60', local: '123456789' });
  assert.deepEqual(build('85212345678'), { cc: '+852', local: '12345678' },
    'the longest matching code wins, so +852 is not read as +85');
  assert.deepEqual(build(''), { cc: '+65', local: '' });
});

test('the country-code split is documented where it bit', () => {
  assert.match(prefill, /Supabase stores\s*\n?\s*the verified phone in E\.164 WITHOUT the leading plus/);
});

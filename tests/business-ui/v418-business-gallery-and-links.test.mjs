/* nestly_v418 — photo 10: a gallery and social links on the business profile.
   "1. i want to add another segment in customer app, which is editable here — i want to be able to
       upload menu or other gallery photos to business profile
    2. add biz social media links"
   The one item in that batch that is a FEATURE rather than a correction. Built on what exists:
   the same storage bucket and path grammar as every other business image, the same owner gate as
   the logo, and the customer sees it through the read that already carries name, logo, bio. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260821_nestly_v418_business_gallery_and_links.sql'), 'utf8');

const statement = (start, end, source = appJs) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing statement ${start} … ${end}`);
  return source.slice(from, to + end.length);
};
const esc = v => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* The customer-facing segment, evaluated as it ships. */
const segment = business => new Function('esc', 'CUI', 'customerMediaUrlV95', `
  ${statement('const CUSTOMER_SOCIAL_LABELS_V418=', '\n});')}
  ${statement('function customerLinkIsOwnAppV561(', '\n}')}
  ${statement('function customerBusinessGalleryMarkupV418(', '\n}')}
  return customerBusinessGalleryMarkupV418;`)(
  esc, { icon: () => '<svg></svg>' },
  ref => (/^https:\/\/ok\//.test(String(ref || '')) ? String(ref) : ''))(business);

const PHOTO = 'https://ok/storage/v1/object/public/business-public/b/gallery/a.jpg';

test('v418 a business with neither photos nor links renders no segment at all', () => {
  assert.equal(segment({ name: 'Cubbly' }), '', 'an empty heading promises a section that is not there');
  assert.equal(segment({ name: 'Cubbly', gallery: [], social_links: [] }), '');
});

test('v418 photos render, captioned, and open full size', () => {
  const out = segment({ name: 'Cubbly', gallery: [
    { image_ref: PHOTO, caption: 'Our menu' }, { image_ref: PHOTO }] });
  assert.match(out, /data-customer-gallery-v418="0"/);
  assert.match(out, /data-customer-gallery-v418="1"/);
  assert.match(out, /Our menu/);
  assert.match(out, /aria-label="Our menu\. Open full size\."/);
  /* A stored ref that customerMediaUrlV95 refuses is dropped, not rendered as a broken image. */
  const bad = segment({ name: 'Cubbly', gallery: [{ image_ref: 'https://elsewhere/evil.jpg' }] });
  assert.equal(bad, '', 'an unrenderable ref leaves nothing behind');
});

test('v418 only https links the app can name are drawn', () => {
  const out = segment({ name: 'Cubbly', social_links: [
    { platform: 'instagram', url: 'https://instagram.com/cubbly' },
    { platform: 'myspace', url: 'https://myspace.example' },
    { platform: 'facebook', url: 'http://insecure.example' }] });
  assert.match(out, /Instagram/);
  assert.doesNotMatch(out, /myspace/i, 'a platform with no icon renders as nothing');
  assert.doesNotMatch(out, /insecure\.example/, 'http is not made tappable on a phone');
  assert.match(out, /rel="noopener noreferrer"/);
  assert.match(out, /target="_blank"/);
});

/* ------------------------------------------------ the editor ------------------------------- */

test('v418 the editor is on the Business Profile, and the branch card sits under the preview', () => {
  /* nestly_v493 (owner, photos 6 + 7: "move here", pointing at the empty space under the Live
     preview). The two cards were adjacent in the form column; the branch card is now the
     preview column's second child. Both are still on this page and still loaded by their own
     loaders — only the column changed. */
  assert.match(appJs, /\$\{businessProfileExtrasCardHtmlV418\(\)\}`,businessProfileBranchCardHtmlV325\(\)\)\)\}/);
  assert.match(appJs, /\$\{customerInterfacePreviewSideCardHtmlV325\(\)\}\$\{belowPreviewHtml\}/,
    'the branch card renders below the preview, not beside the form');
  assert.match(appJs, /loadBusinessProfileExtrasV418\(\);/);
  assert.match(appJs, /loadBranchContactCardV325\(\);/,
    'and its loader still runs — moving the column must not strand the fetch');
});

test('v418 a gallery upload writes to this business\'s own gallery folder', () => {
  const upload = statement('async function uploadGalleryPhotoV418(', '\n}');
  assert.match(upload, /\$\{S\.biz\.id\}\/gallery\/\$\{crypto\.randomUUID\(\)\}/,
    'the folder name is what makes the storage policy allow the write');
  assert.match(upload, /from\('business-public'\)/, 'the same bucket as every other business image');
  assert.match(upload, /'image\/png':'png','image\/jpeg':'jpg','image\/webp':'webp'/);
  assert.match(upload, /10\*1024\*1024/);
  /* And the guard that policy calls must know the folder. */
  assert.match(migration, /benefit\|offer\|gallery/);
  /* The renderer's whitelist has to agree, or a saved photo would never draw. */
  assert.match(appJs, /\(\?:logo\|hero\|programme\|reward\|product\|service\|benefit\|offer\|gallery\)/);
});

test('v418 both writers are replace-set and owner-gated', () => {
  assert.match(migration, /if not app\.is_salon_owner\(p_business\) then/);
  assert.match(migration, /delete from public\.business_gallery_v418 where business_id = p_business;/);
  assert.match(migration, /delete from public\.business_social_links_v418 where business_id = p_business;/);
  /* The check that stops a firm pointing at another firm's storage object. */
  assert.match(migration, /a gallery photo must be an image uploaded to this business/);
  assert.match(migration, /a profile gallery holds up to 12 photos/);
});

/* nestly_v471 reversed the premise of the v418 test that stood here. The owner's ruling
   (photo 2, 2026-08-23) is "all link don't need to start with https://" — typing "Instagram.com"
   used to refuse the whole form. The https RULE is unchanged, because the table CHECK and the
   customer render both still demand it; what changed is who has to type it.
   This replaces a source-regex pin ("does the save handler mention linkNeedsHttps") with a test
   that EXECUTES the shipped normaliser, which is the only way to tell a rule that works from a
   string that is merely present. */
const normaliseV471 = new Function(
  `${statement('function businessLinkNormaliseV471(', '\n}')}\nreturn businessLinkNormaliseV471;`,
)();

test('v471 a bare domain is given the scheme it obviously meant', () => {
  assert.equal(normaliseV471('Instagram.com'), 'https://instagram.com/', 'the exact value the owner typed');
  assert.equal(normaliseV471('www.cubbly.sg'), 'https://www.cubbly.sg/');
  assert.equal(normaliseV471('  peekaa.asia/app  '), 'https://peekaa.asia/app', 'and it is trimmed');
});

test('v471 http is upgraded, never refused and never stored as plaintext', () => {
  assert.equal(normaliseV471('http://cubbly.sg'), 'https://cubbly.sg/');
  assert.ok(normaliseV471('https://cubbly.sg/x').startsWith('https://'));
});

test('v471 a scheme we will not publish is still refused, not rewritten', () => {
  /* Rewriting these into https would invent a destination the owner never typed, and they must
     never reach an anchor on a customer's phone. */
  assert.equal(normaliseV471('javascript:alert(1)'), null);
  assert.equal(normaliseV471('data:text/html,<script>'), null);
  assert.equal(normaliseV471('mailto:hi@cubbly.sg'), null);
});

test('v471 a word or a handle is not a link, and says so', () => {
  assert.equal(normaliseV471('our shop'), null, 'a hostname with no dot is a word');
  assert.equal(normaliseV471('@cubbly'), null);
  assert.equal(normaliseV471('localhost'), null, 'a customer phone cannot reach the owner machine');
  assert.equal(normaliseV471(''), '', 'blank clears the field — that is how a link is removed');
});

test('v471 the save handler reports the value it cannot use, and writes the normalised one', () => {
  const save = statement("const save=$('ciExtrasSaveV418');", '\n  };');
  assert.match(save, /linkNotAWebAddressV471/, 'reviewed, localised copy — not a raw string');
  assert.doesNotMatch(save, /linkNeedsHttps/, 'the owner no longer has to type the scheme');
  assert.match(save, /business_set_gallery_v418/);
  assert.match(save, /p_links:linksToSaveV471/, 'the NORMALISED url is what reaches the table');
  assert.match(save, /Promise\.all\(\[/, 'two independent tables, one round trip');
});

test('v418 the two whitelists cannot drift: browser, table CHECK and customer labels agree', () => {
  const browser = [...statement('const BUSINESS_SOCIAL_PLATFORMS_V418=', '\n]);')
    .matchAll(/\['([a-z]+)',/g)].map(m => m[1]).sort();
  const table = [...migration.match(/'website','instagram','facebook','tiktok','whatsapp','youtube','telegram','xiaohongshu'/)[0]
    .matchAll(/'([a-z]+)'/g)].map(m => m[1]).sort();
  const labels = [...statement('const CUSTOMER_SOCIAL_LABELS_V418=', '\n});')
    .matchAll(/([a-z]+):'/g)].map(m => m[1]).sort();
  assert.deepEqual(browser, table, 'the editor offers exactly what the table accepts');
  assert.deepEqual(labels, table, 'and the customer app can name every one of them');
});

test('v418 the customer read carries both, and no new endpoint was added', () => {
  assert.match(migration, /'gallery', coalesce\(\(select jsonb_agg/);
  assert.match(migration, /'social_links', coalesce\(\(select jsonb_agg/);
  /* pg_get_functiondef emits CREATE OR REPLACE in caps; the body was extracted from production
     rather than retyped, so the assertion matches what Postgres actually wrote. */
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.customer_get_business_summary/,
    'they ride the read that already carries the name, logo, industry and bio');
  assert.doesNotMatch(migration, /create (or replace )?function public\.customer_get_gallery/i,
    'no new customer endpoint was added');
});

test('v418 the tables keep the browser out of writing them', () => {
  for (const table of ['business_gallery_v418', 'business_social_links_v418']) {
    assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`));
    assert.match(migration, new RegExp(`revoke all on table public\\.${table} from public, anon, authenticated;`));
    assert.match(migration, new RegExp(`grant select on table public\\.${table} to authenticated;`));
  }
  /* No insert/update/delete grant anywhere: writes go through the owner-gated RPCs. */
  assert.doesNotMatch(migration, /grant (insert|update|delete)[^;]*on table public\.business_(gallery|social_links)_v418/i);
});

test('v418 photos use the one card shape v417 unified everything else to', () => {
  const cell = html.slice(html.indexOf('.customer-business-gallery-cell-v418 img{'));
  assert.match(cell.slice(0, 200), /aspect-ratio:16\/9/);
  assert.match(cell.slice(0, 200), /object-fit:cover/);
  /* ...and opening one shows it whole, the same bargain v417 struck. */
  const viewer = statement('function openCustomerGalleryPhotoV418(', '\n}');
  assert.match(viewer, /object-fit:contain/);
});

/* nestly_v561 (owner, two photos: Cubbly's captioned one-row block vs a new tenant listing all
   eight platforms, every URL the brand editor's own address). Same backend, different rows —
   browser autofill had filled every field with the page's own URL and Save stored them. Two
   rules close it: the customer renderer never draws a link that points back at Peekaa itself,
   and a photo-less section's heading wears the caption's small-caps-plus-heart look the owner
   ruled correct, instead of the plain full-size H2. */
test('v561 a link pointing back at Peekaa itself is never drawn', () => {
  const out = segment({ name: 'KKY', social_links: [
    { platform: 'website', url: 'https://www.peekaa.asia/business#/customer-interface/brand' },
    { platform: 'instagram', url: 'https://instagram.com/kky' }] });
  assert.match(out, /Instagram/);
  assert.doesNotMatch(out, /Website/);
  /* All-junk rows leave nothing behind at all — the section only exists for real content. */
  assert.equal(segment({ name: 'KKY', social_links: [
    { platform: 'website', url: 'https://peekaa.asia/x' },
    { platform: 'tiktok', url: 'https://loyalty-pi-seven.vercel.app/y' }] }), '');
});

test('v561 a photo-less section heads itself like the caption, heart included', () => {
  const out = segment({ name: 'KKY', social_links: [
    { platform: 'instagram', url: 'https://instagram.com/kky' }] });
  assert.match(out, /customer-business-links-head-v561/);
  assert.match(out, /Follow us here <span aria-hidden="true">\u2764\uFE0F<\/span>/u);
  /* With photos the heading stays Gallery and the v468 caption keeps the heart — unchanged. */
  const withPhotos = segment({ name: 'Cubbly', gallery: [{ image_ref: PHOTO }],
    social_links: [{ platform: 'website', url: 'https://cubbly.sg/' }] });
  assert.match(withPhotos, />Gallery</);
  assert.match(withPhotos, /customer-business-links-head-v468/);
  assert.doesNotMatch(withPhotos, /customer-business-links-head-v561/);
});

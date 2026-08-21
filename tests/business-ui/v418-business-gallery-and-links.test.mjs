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

test('v418 the editor is on the Business Profile, above branch contact details', () => {
  assert.match(appJs, /\$\{businessProfileExtrasCardHtmlV418\(\)\}\s*\n\s*\$\{businessProfileBranchCardHtmlV325\(\)\}/);
  assert.match(appJs, /loadBusinessProfileExtrasV418\(\);/);
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

test('v418 an https-less link is refused before the round trip, naming the field', () => {
  const save = statement("const save=$('ciExtrasSaveV418');", '\n  };');
  assert.match(save, /linkNeedsHttps/, 'and the message is reviewed, localised copy');
  assert.match(save, /business_set_gallery_v418/);
  assert.match(save, /business_set_social_links_v418/);
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

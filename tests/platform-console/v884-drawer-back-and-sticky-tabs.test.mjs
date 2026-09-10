/* nestly_v884 — the prospect/firm drawer had no way back, only close entirely.

   Owner, 2026-09-10: "there is no back button, only close entire page." The Pipeline drawer opens
   the prospect drawer on top of itself via its "Open full record" button, so closing the prospect
   drawer should reveal the drawer underneath rather than reading as a dead end next to the X.

   Two changes: (A) the tab strip (and now the head — title, Back, X) stay visible while scrolling
   the drawer instead of scrolling out of reach; (B) a Back button appears in the drawer head, but
   only when this drawer was opened on top of another one, and it closes just this drawer.

   Source pins only — this is markup/CSS wiring, not calculation, so there is nothing here worth
   executing through the vm-loaded console. */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('the prospect drawer head sticks alongside the tab strip, scoped to just this drawer',async()=>{
  const css=await read('app/platform-console.css');
  // Scoped to .platform-prospect-drawer so the dozen other drawers that reuse
  // .platform-drawer-head are never affected.
  assert.match(css,/\.platform-prospect-drawer \.platform-drawer-head\{\s*position:sticky;top:-24px;z-index:6;background:var\(--bg\);padding-bottom:6px;margin-bottom:12px\s*\}/);
  // The tab strip was already sticky; it still is, with a bottom hairline, an opaque background,
  // and a z-index below the head (6) so the head always paints on top of it.
  assert.match(css,/\.platform-detail-nav\{\s*position:sticky;top:-24px;z-index:4;display:flex;gap:4px;overflow-x:auto;/);
  assert.match(css,/border-bottom:1px solid var\(--hair\);\s*background:rgba\(244,242,238,\.96\);backdrop-filter:blur\(12px\)\s*\}/);
  // Mobile keeps the tab strip scrolling horizontally (unchanged) and gives the now-sticky head
  // the same reduced offset the panel's smaller mobile padding needs.
  assert.match(css,/@media\(max-width:760px\)\{[\s\S]*\.platform-detail-nav\{top:-20px\}\s*\.platform-prospect-drawer \.platform-drawer-head\{top:-20px\}/);
});

test('positionStickyProspectHead measures the real head height instead of guessing it',async()=>{
  const source=await read('app/platform-console.js');
  const fn=source.slice(source.indexOf('function positionStickyProspectHead('),source.indexOf('function positionStickyProspectHead(')+600);
  assert.match(fn,/const panelTop=parseFloat\(globalObject\.getComputedStyle\?\.\(panel\)\?\.paddingTop\)\|\|0;/);
  assert.match(fn,/head\.style\.top=`-\$\{panelTop\}px`;/);
  assert.match(fn,/nav\.style\.top=`\$\{Math\.max\(0,head\.offsetHeight-panelTop\)\}px`;/);
  assert.match(source,/wireProspectDetail\(detail,context\);\s*\/\/ nestly_v884:[\s\S]*?positionStickyProspectHead\(overlay\);/);
});

test('a Back button appears only when the prospect drawer opens on top of another drawer, and closes just this one',async()=>{
  const source=await read('app/platform-console.js');
  const open=source.slice(source.indexOf('async function openProspectDetail('),source.indexOf('async function loadProspectDetail('));
  // Computed before this overlay is appended, so document.querySelectorAll never counts itself.
  assert.match(open,/const stackedOnAnotherDrawer=document\.querySelectorAll\('\.platform-drawer'\)\.length>0;/);
  assert.match(open,/const overlay=document\.createElement\('div'\);overlay\.className='platform-drawer platform-prospect-drawer';/);
  assert.match(open,/stackedOnAnotherDrawer\?`<button type="button" class="btn ghost sm" data-prospect-back>\$\{CUI\.icon\('back',\{size:16\}\)\}<span>\$\{escapeHtml\(pt\('Back'\)\)\}<\/span><\/button>`:''/);
  // Placed before the close button inside the head's .platform-actions group, and
  // .platform-drawer-close stays intact for activateDialog's initial focus.
  assert.match(open,/data-prospect-back>[\s\S]*?<\/button>`:''\}<button type="button" class="btn ghost sm platform-drawer-close"/);
  // Wired right where .platform-drawer-close is wired, and it just calls close — the same
  // function the X calls — so the underlying drawer is revealed, not re-rendered or re-fetched.
  assert.match(open,/overlay\.querySelector\('\.platform-drawer-close'\)\.onclick=close;\s*[\s\S]{0,220}overlay\.querySelector\('\[data-prospect-back\]'\)\?\.addEventListener\('click',close\);/);
});

test('the console asset version is bumped to v884',async()=>{
  const html=await read('app/index.html');
  assert.match(html,/platform-console\.js\?v=20260910-v884/);
  assert.match(html,/platform-console\.css\?v=20260910-v884/);
  assert.doesNotMatch(html,/platform-console\.(?:js|css)\?v=20260910-v883/);
});

test('Back has real zh-CN and ms dictionary copy, not an identity mapping',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/'Back':'返回'/);
  assert.match(source,/'Back':'Kembali'/);
});

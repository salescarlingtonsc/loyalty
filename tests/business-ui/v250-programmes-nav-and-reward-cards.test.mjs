/* V250 — two owner-approved changes to the Programmes area.

   1. The nav. "Programmes" was a collapsible header over three sub-rows — Programmes list,
      Ongoing programmes, Pending setup — which is a menu of the page's own sections: the list
      opens with the V244 "Ongoing programmes" and "Pending setup" groups. The rail said three
      times what the page says once, so it is now ONE flat link onto the list. The two filtered
      hashes are deliberately still routed: deep links, browser history and the V245 heading
      logic all depend on them, and deleting a menu row must not delete a destination.

   2. The Points redemption topic page. The owner crossed out the "● Live: …" status-chip column,
      the "Add another reward" row and the "Start from a template" row, and drew reward boxes —
      "Free Facial / 5 points", "Free Moisturiser / 150 points", plus a "+". Rewards are now
      cards. The two things that could quietly go wrong are pinned here: a card must carry its
      own status pill (a paused reward drawn identically to a live one would tell the owner
      customers can claim something they cannot), and the cards must open the SAME editor the
      rows opened rather than a second, forking edit path. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');

const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
};
const nav = section('function navHtml(', 'function wireNav()');
const grow = section('async function growPage(', '/* ---------- Bring-back playbooks');

test('V250 (a) Programmes is one flat nav group and both sub-rows are gone', () => {
  /* V294 (owner markup 2026-08-12): the flat link became a GROUP whose children are the page's
     own Overview / List / History views. What V250 removed stays removed: no per-module peer
     rows, no resurrected sub-nav helper. giftcards moved to Serve & sell with its card. */
  assert.match(app, /\{key:'grow',icon:'star',label:'Rewards & Offer',items:\['loyalty','retention','referrals','memberships'\],\s*views:\[\['Overview','#\/grow\/overview','reports'\],\['Rewards Programme','#\/grow','menu'\],\s*\['Limited Offer','#\/grow\/offers','loyalty'\],\['History','#\/grow\/history','waitlist'\]\]\}/);
  assert.doesNotMatch(app, /flat:'Programmes'/);
  // The sub-nav helper rendered the three rows; it is gone, not left as an empty container.
  assert.doesNotMatch(app, /growNavItemHtml/);
  assert.doesNotMatch(app, /const links=\[/);
  assert.doesNotMatch(app, /'Programmes list'/);
  assert.doesNotMatch(app, /\['#\/grow\/ongoing','Ongoing programmes'\]/);
  assert.doesNotMatch(app, /\['#\/grow\/available','Pending setup'\]/);
  // No dead branch left behind in the collapsible renderer either.
  assert.doesNotMatch(nav, /restItems/);
  assert.match(nav, /g\.items\.filter\(m=>MODULES\[m\]\)/);
  /* V371: the view list and the deep-link guard are ONE constant now (GROW_PROGRAMME_VIEWS_V371).
     They were separate lists and drifted — V366 added 'bringback' to the resolver but not to the
     guard, so opening the Bring-back page also mounted a deep editor surface with a view name
     where a draft id belongs. Assert the constant and that both readers use it. */
  assert.match(app, /const GROW_PROGRAMME_VIEWS_V371=Object\.freeze\(\['overview','history','offers','points','tiers','bringback','ongoing','available','settings','setup'\]\);/);
  assert.match(app, /const programmeView=GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\)\?String\(hashParam\):'list'/);
  assert.match(app, /const hashParamIsProgrammeView=GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\);/);
});

test('V250 (b) the filtered hashes still resolve and the list keeps the programme-card landing', () => {
  // V271 added the owner's two new views (overview, history). The three V250-era hashes must
  // still resolve — deleting a destination was never part of adding one.
  /* V301 added a fourth ('setup', the one-page rewards wizard) on exactly those terms: it is an
     ADDITION to the same list, and the three V250-era hashes are still in it. V331 added a fifth
     ('tiers', the Tiered membership page) the same way. */
  // V245 heading logic still names each view.
  assert.match(app, /programmeView==='ongoing'\?'Ongoing programmes':programmeView==='available'\?'Pending setup':programmeView==='setup'\?'Set up rewards':'Rewards Programme'/);
  // ...and no view hash is mistaken for an engine deep link.
  // The owner mockup landing still opens from #/grow with the same topic click contracts.
  assert.match(app, /growDisplayTopicsV343=growTopicDefsV229\.filter\(topic=>topic\.key!=='recurring'\)/);
  assert.match(app, /grow-topic-card-grid-v343/);
  assert.match(app, /data-grow-topic-v229="\$\{topic\.key\}"/);
  assert.match(app, /if\(\['ongoing','available'\]\.includes\(programmeView\)\)\{/);
});

test('V250 (c) the flat link stays active across every route that resolves to Programmes', () => {
  // A flat group with its own href is judged by the GROUP, not by items[0] — that is what makes
  // #/grow, #/grow/ongoing, #/grow/available and the topic views all keep the link lit.
  assert.match(nav, /const href=g\.href\|\|`#\/\$\{target\}`/);
  assert.match(nav, /const isAct=g\.href\?activeGrp===g\.key:activeKey===target/);
  assert.match(app, /function activeGroupKey\(pageKey\)\{[\s\S]{0,240}?if\(k==='grow'\)return 'grow'/);
  // The topic surfaces map into the same group, so drilling into a topic cannot unlight it.
  assert.match(app, /\['studio','storedvalue','promotions'\]\.includes\(pageKey\)\?'loyalty'/);
});

test('V250 (d) the status-chip column is gone from the Points redemption view', () => {
  assert.match(app, /const growPointsModeChooserV229=\(\{showLiveModelsV250=true\}=\{\}\)=>\{/);
  // Points redemption asks for the chooser WITHOUT the chips; Tiered membership still shows them.
  assert.match(grow, /points-mode-row-v229">\$\{growPointsChooserRowV271\}/);
  assert.match(grow, /points-mode-row-v229">\$\{growPointsModeChooserV229\(\)\}/);
  // V271: the chips are now suppressed by an early return rather than an inline ternary, because
  // the same flag also decides whether the container renders at all.
  assert.match(app, /if\(!showLiveModelsV250\)return '';/);
  // V271 (owner struck "Change model" and wrote "delete"). It is gone. It was NOT the only way to
  // switch: it opened surface 'rewards' focus 'lm', which is the exact destination the Point
  // system row's own Edit opens, and the four-way toggle lives inside that editor.
  assert.doesNotMatch(app, /'Change model'/);
  assert.match(app, /data-loyalty-model-v235="\$\{key\}"/);
  assert.match(app, /focusTarget:kind==='earning'\?'lm'/);
});

test('V250 (e) rewards render as cards with a name, a point cost and their own status pill', () => {
  const cards = section('const rewardCardStatusV250=', 'const rewardCardGridV250=');
  // Status is preserved per reward — Ongoing / Scheduled / Ended / Paused, not a blanket "live".
  assert.match(cards, /milestone\.availability==='not_started'\?\['Scheduled','off'\]/);
  assert.match(cards, /milestone\.availability==='ended'\?\['Ended','off'\]/);
  assert.match(cards, /\$\{programmeStatus\(status,tone\)\}<b class="reward-card-name-v250"/);
  assert.match(cards, /<span class="reward-card-cost-v250" data-merchant-content>\$\{esc\(`\$\{cost\} \$\{unit\}`\)\}<\/span>/);
  // The SAME edit contract the rows carried — one edit path, reached from the card.
  assert.match(cards, /data-rewards-overview-edit="\$\{esc\(editKind\)\}"\$\{rewardId\?` data-reward-id="\$\{esc\(rewardId\)\}"`:''\}/);
  /* V375 (owner, photo 3): the classic points-for-store-credit model is retired. */
  assert.doesNotMatch(cards, /editKind:'classic'/);
  assert.match(cards, /editKind:'catalogue'/);
  assert.match(app, /document\.querySelectorAll\('\[data-rewards-overview-edit\]'\)\.forEach/);
  // A staff member without setup rights gets a card that is not a button.
  assert.match(cards, /:`<article class="reward-card-v250"/);
  // The Ongoing / Pending views judge a card exactly as they judged the row it replaced.
  assert.match(app, /category\.querySelectorAll\('\.grow-programme-row,\.reward-card-v250'\)/);
  // 390px-safe grid, reusing existing tokens.
  assert.match(html, /\.reward-card-grid-v250\{display:grid;grid-template-columns:repeat\(auto-fill,minmax\(150px,1fr\)\)/);
  assert.match(html, /\.reward-card-v250\[hidden\]\{display:none!important\}/);
});

test('V250 (f) the "+" card fires the old Add path and both struck rows are gone', () => {
  assert.match(app, /class="reward-card-v250 reward-card-add-v250" data-programme-kind="redeemable" data-rewards-overview-edit="add"/);
  assert.match(html, /\.reward-card-add-v250\{border-style:dashed/);
  // Matched as markup, not as prose: the V227/V250 comments still name the struck row.
  assert.doesNotMatch(app, /title:'Add another reward'/);
  assert.doesNotMatch(app, /Create another milestone in the editable draft\./);
  // The template ROW went; the flow it was the only door to did not.
  assert.doesNotMatch(app, /data-programme-kind="template"/);
  assert.doesNotMatch(app, /Ready-made rewards for your business/);
  assert.match(app, /<p class="reward-card-templates-v250"><button type="button" class="btn ghost sm" id="growTemplatesOpen" aria-expanded="false" aria-controls="growTemplatesPanel">/);
  assert.match(app, /<div id="growTemplatesPanel" hidden/);
  assert.match(app, /const templatesOpen=\$\('growTemplatesOpen'\),templatesPanel=\$\('growTemplatesPanel'\)/);
  assert.match(app, /rewardTemplatesForSectorV172\(S\.biz\.industry,prices\)/);
});

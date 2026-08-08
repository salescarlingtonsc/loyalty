/* V255 — owner-mandated copy sweep: "Remove internal/technical language. The merchant cares
   about the outcome, not the internal versioning architecture." Already applied to the Loyalty
   page; this extends the same sweep to retentionPage and the studioPage family
   (studioSetRuleActive, studioDraftEditor) plus one global hit in the compensation/reversal
   note. Version-speak ("configuration version", "Versioned"/"versioned", "Draft configuration")
   is replaced with outcome language, matching the phrasing the Loyalty page already uses
   ("Draft — not visible to customers"). */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const rawApp = readFileSync(join(root, 'app', 'app.js'), 'utf8');
/* The generated zh/ms/ta translation table still carries retired en source strings as lookup
   keys (translation data), and code comments still legitimately say "versioned" describing the
   underlying architecture. Strip both so doesNotMatch checks only judge the rendered template
   strings inside retentionPage / studioSetRuleActive / studioDraftEditor. */
const noTranslationTable = rawApp.replace(/const WORKSPACE_GENERATED_COPY_V97=Object\.freeze\([\s\S]*?\n\}\);/, ' ');

function fnSlice(source, startMarker, nextMarkerRegex) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `could not find ${startMarker}`);
  nextMarkerRegex.lastIndex = start + startMarker.length;
  const m = nextMarkerRegex.exec(source);
  assert.ok(m, `could not find end of ${startMarker}`);
  return source.slice(start, m.index);
}

const retentionPageSrc = fnSlice(
  noTranslationTable,
  'async function retentionPage(draftVersionId=null,editProgramId=null,stableRefresh=false){',
  /\nasync function growOverviewSnapshot\(/g
);
const studioSetRuleActiveSrc = fnSlice(
  noTranslationTable,
  'function studioSetRuleActive(item,active,onDone){',
  /\nfunction studioErrText\(/g
);
const studioDraftEditorSrc = fnSlice(
  noTranslationTable,
  'async function studioDraftEditor(routeMain,isCurrent,draftVersionId){',
  /\nfunction svAuthorityChip\(/g
);
// Strip block/line comments from each slice so internal-architecture comments (which are
// intentionally left alone — rule (b) in the sweep) don't false-positive the assertions below.
function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, ' ');
}
const retentionPageNoComments = stripComments(retentionPageSrc);
const studioSetRuleActiveNoComments = stripComments(studioSetRuleActiveSrc);
const studioDraftEditorNoComments = stripComments(studioDraftEditorSrc);

test('V255 new outcome-language copy exists in the rendered app', () => {
  assert.match(rawApp, /Draft — not visible to customers/,
    'the Loyalty page phrasing must still exist and now be reused by retentionPage/studioDraftEditor');
  assert.match(rawApp, /Publish your loyalty foundation first; retention rules are part of the same programme\./);
  assert.match(rawApp, /Return-visit rules customers actually experience, with reward behavior and grant history intact\./);
  assert.match(rawApp, /Publishing replaces what customers see and takes effect at the counter immediately\./);
  assert.match(rawApp, /every FEFO batch drain, the programme rules in effect at the time, and whether the/);
});

test('V255 retentionPage no longer speaks in version-architecture terms', () => {
  assert.doesNotMatch(retentionPageNoComments, /Versioned return-visit rules/);
  assert.doesNotMatch(retentionPageNoComments, /versioned configuration/);
  assert.doesNotMatch(retentionPageNoComments, /'Draft configuration'/);
  // "Published configuration" is left as-is (not in the owner's flagged phrase list) — confirm
  // the sweep did not accidentally remove the branch entirely.
  assert.match(retentionPageNoComments, /'Published configuration'/);
});

test('V255 studioSetRuleActive confirm dialog speaks in outcome language', () => {
  assert.doesNotMatch(studioSetRuleActiveNoComments, /publishes a NEW configuration version/);
  assert.match(studioSetRuleActiveNoComments, /Publishing replaces what customers see/);
});

test('V255 studioDraftEditor draft card no longer says "Draft configuration"', () => {
  assert.doesNotMatch(studioDraftEditorNoComments, /<b>Draft configuration<\/b>/);
  assert.match(studioDraftEditorNoComments, /<b>Draft — not visible to customers<\/b>/);
});

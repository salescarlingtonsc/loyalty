/* V291 — client-side UX debt closure.
   Seven previously-deferred items from the deep audit, each pinned here so it cannot be
   silently undone:
     1  PDPA erasure UI on Customer 360 (owner-only, typed-name confirm, honest refusals)
     2  Sales ledger paging + CSV export
     3  the last four native money confirm()s routed through the translatable dialog
     4  A2 leftovers: blocked-time edit + visibility, table-type edit, waitlist row edit,
        custom-field rename, sector-filtered module grants
     5  publish-gate coverage (reward fields, birthday, bring-back)
     6  bring-back published rows can be edited/paused without hunting for a draft button
     7  390px: day-timeline agenda fallback, bookings capacity table

   Read-site pattern is the repository standard: application code is the CONCATENATION of
   app/index.html and app/app.js, because the startup split moved the script out of the markup
   while tests still grep one body of code. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const indexHtml=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');
const appJs=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const app=`${indexHtml}\n${appJs}`;
/* The generated translation table is keyed by English source text, so an assertion that a
   sentence exists in RENDER code has to exclude it or it matches the catalogue instead. */
const code=appJs.replace(/const WORKSPACE_GENERATED_COPY_V97=Object\.freeze\([\s\S]*?\n\}\);/,' ');
const registry=JSON.parse(readFileSync(new URL('../../docs/design/ps0/writer-registry.json',import.meta.url),'utf8'));

function section(start,end,source=code){
  const from=source.indexOf(start);
  assert.ok(from>=0,`missing section start: ${start}`);
  const to=source.indexOf(end,from+start.length);
  assert.ok(to>from,`missing section end: ${end}`);
  return source.slice(from,to);
}

/* ---------------------------------------------------------------- 1. PDPA erasure ---- */

test('V291 erasure is owner-only, gated twice, and names exactly what it does',()=>{
  const dialog=section('function openEraseClientDialogV291(','const saleCorrectionAttempts=new Map();');
  // The single server writer, with the reason and idempotency key the contract requires.
  assert.match(dialog,/sb\.rpc\('erase_client_v290',\{/);
  assert.match(dialog,/p_business:S\.biz\.id,p_client:clientId,p_reason:text,p_idem:attempt\.key/);
  // Reason floor is the server's floor, enforced before the call as well as in the gate.
  assert.match(dialog,/reason\.value\.trim\(\)\.length>=8/);
  assert.match(dialog,/if\(text\.length<8\)return toast/);
  // The typed-name confirm: normalised so it is a deliberate act, not a typing test.
  assert.match(dialog,/normalise\(typed\.value\)===normalise\(label\)/);
  // A retry reuses the same key; a changed reason mints a new one.
  assert.match(dialog,/attempt\.fingerprint!==fingerprint/);
  // The card that opens it is owner-only and disappears once the record is erased.
  assert.match(code,/const eraseCardV291=S\.myRole==='owner'&&!erasedRecordV291/);
  assert.match(code,/id="c360EraseV291"/);
});

test('V291 erasure copy says what goes, what stays, and claims no compliance',()=>{
  const dialog=section('function openEraseClientDialogV291(','const saleCorrectionAttempts=new Map();');
  assert.match(dialog,/name, phone number, email address and date of birth/i);
  assert.match(dialog,/Sales, points, credit, appointments and every other ledger entry are kept/);
  assert.match(dialog,/This cannot be undone/);
  /* ⚖️ Peekaa never asserts that an action satisfies a law. */
  for(const claim of [/PDPA[- ]compliant/i,/complies with/i,/GDPR/i,/legally required/i,/right to be forgotten/i]){
    assert.doesNotMatch(dialog,claim,'erasure copy must not make a compliance claim');
  }
});

test('V291 a refused erasure prints the server sentence and changes nothing',()=>{
  const dialog=section('function openEraseClientDialogV291(','const saleCorrectionAttempts=new Map();');
  assert.match(dialog,/<b>Nothing was erased\.<\/b> \$\{esc\(error\.message\|\|'The server refused this request\.'\)\}/);
  // The register is only written on success, so a refusal cannot paint the erased state.
  const success=dialog.slice(dialog.indexOf('completed=true'));
  assert.match(success,/erasedClientsV291\.set\(String\(clientId\)/);
});

test('V291 an erased profile says so, above everything else on the page',()=>{
  assert.match(code,/const erasedRecordV291=erasedClientsV291\.get\(String\(id\)\)\|\|null;/);
  assert.match(code,/id="c360ErasedBannerV291"[\s\S]{0,80}<b>Personal details erased\.<\/b>/);
  assert.match(code,/\$\{erasedBannerV291\}\s*\n\s*\$\{editCustomerMarkup\}/);
});

test('V291 the erasure writer is curated in the PS0 registry as non-value',()=>{
  const entry=(registry.writers||[]).find(row=>row.id==='browser.rpc:app/app.js:erase_client_v290');
  assert.ok(entry,'erase_client_v290 must be curated as a browser.rpc writer');
  assert.equal(entry.surface,'browser_rpc_binding');
  assert.match(entry.kernel_migratability,/^non-value/);
  assert.match(entry.rows_written,/No ledger, sale, points, credit or stored-value row is written/);
});

/* ------------------------------------------------------- 2. Sales paging and export ---- */

test('V291 the sales ledger paints a bounded window of the full filtered answer',()=>{
  assert.match(code,/const SALES_PAGE_SIZE_V291=50;/);
  assert.match(code,/let salesFilteredRowsV291=\[\],salesWorkflowV291=\{\},salesVisibleCountV291=SALES_PAGE_SIZE_V291,salesWorkflowMayHaveMoreV291=false;/); // audit F001: the reversal map is unbounded and reports may_have_more
  const render=section('function renderSalesRowsV291(','/* V291: the export mirrors');
  // Only the window is turned into markup...
  assert.match(render,/const shown=rows\.slice\(0,salesVisibleCountV291\);/);
  assert.match(render,/\$\{shown\.map\(s=>\{/);
  // ...and the summary still counts the whole filtered set.
  assert.match(render,/Showing \$\{shown\.length\} of \$\{rows\.length\}/);
  assert.match(render,/id="salesLoadMoreV291"/);
  assert.match(render,/salesVisibleCountV291=Math\.min\(rows\.length,salesVisibleCountV291\+SALES_PAGE_SIZE_V291\)/);
  // The full fetch is untouched: counts, payment-state filtering and export need it.
  assert.match(code,/const \{data:sl,error\}=await fetchAllRowsResult\(\(\)=>query\.order\('occurred_at'/);
});

test('V291 Sales exports the filtered set with the shared CSV helpers',()=>{
  const block=section('/* V291: the export mirrors',"  ['salesStaff','salesType','salesPayment']");
  assert.match(block,/const salesExportV291=\$\('salesExportV291'\);/);
  assert.match(block,/csvRows\(table\)/);
  assert.match(block,/\$\{BRAND\.downloadPrefix\}-sales\.csv/);
  // The export reads the filtered rows, never the painted window.
  assert.match(block,/const rows=salesFilteredRowsV291/);
  assert.doesNotMatch(block,/salesVisibleCountV291/);
  // The button is only rendered on the paint that has a ledger and a handler behind it.
  assert.match(code,/const salesHeadHtmlV291=\(withExport=false\)=>/);
  assert.match(code,/salesHeadHtmlV291\(true\)/);
});

/* --------------------------------------------------------- 3. Money confirm i18n ---- */

test('V291 every money confirmation is the translatable dialog, not native confirm()',()=>{
  for(const [name,title,ack] of [
    ['use package session',"title:'Use one session?'","acknowledgement:'I understand one session will be taken off.'"],
    ['welcome offer',"title:'Give the welcome gift?'","acknowledgement:'I understand this can only be given once.'"],
    ['reversal',"title:'Confirm this reversal?'","acknowledgement:'I understand compensating records will be added.'"],
    ['sale correction',"title:'Replace this amount?'","acknowledgement:'I have checked the corrected amount.'"]
  ]){
    assert.ok(code.includes(title),`${name} must use the deliberate dialog`);
    assert.ok(code.includes(ack),`${name} must carry a translatable acknowledgement`);
  }
  // The four English confirm() sentences these replaced are gone from render code.
  for(const gone of [
    /confirm\(`Use 1 session from/,
    /confirm\(`Give \$\{label\} free to/,
    /!confirm\(`Confirm \$\{kind==='sale'/,
    /confirm\(`Final check: replace/
  ]) assert.doesNotMatch(code,gone,'a native money confirm() survived');
});

test('V291 the new dialog sentences are registered in both workspace locales',()=>{
  const curated=section('const WORKSPACE_COPY_V97=','const WORKSPACE_GENERATED_COPY_V97=',app);
  for(const source of [
    'Use one session?','What this does','I understand one session will be taken off.','Use one session',
    'Give the welcome gift?','This can only be done once','I understand this can only be given once.','Give the free item',
    'Confirm this reversal?','Nothing is deleted','I understand compensating records will be added.','Confirm reversal',
    'Replace this amount?','The original stays in history','I have checked the corrected amount.','Replace the amount'
  ]){
    const escaped=source.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
    const hits=[...curated.matchAll(new RegExp(`'${escaped}':'([^']+)'`,'g'))];
    assert.equal(hits.length,2,`${source} must carry a zh-CN and an ms value`);
    for(const hit of hits) assert.notEqual(hit[1],source,`${source} must not be inert English`);
  }
});

/* ------------------------------------------------------------- 4. A2 leftovers ---- */

test('V291 blocked time can be edited, and a refused edit restores the original',()=>{
  assert.match(code,/function openBlockedTimeDialog\(\{date=addDays\(todaySg,dayOffset\),block=null\}=\{\}\)/);
  assert.match(code,/const editingBlockV291=block&&block\.id\?block:null;/);
  const form=section("$('blockTimeForm').onsubmit=async event=>{",'function renderCustomerOptions(');
  // Remove first (the server refuses a new block that overlaps the one being edited)...
  assert.match(form,/if\(editingBlockV291\)\{[\s\S]{0,400}delete_staff_blocked_time_v120/);
  // ...then write the corrected block, and put the original back if that is refused.
  assert.match(form,/create_staff_blocked_time_v120/);
  assert.match(form,/restoredV291/);
  assert.match(form,/The original blocked time was put back\./);
  assert.match(form,/could NOT be put back/);
  // Delete is untouched.
  assert.match(code,/data-delete-block="\$\{block\.id\}"/);
});

test('V291 blocked time is visible in the List view and the mobile week agenda',()=>{
  // List view reads it over the same window the filters name, and never takes the list down.
  assert.match(code,/const blockedFromV291=\$\('appointmentListFrom'\)\?\.value\|\|todaySg;/);
  assert.match(code,/const blockedToV291=\$\('appointmentListTo'\)\?\.value\|\|addDays\(blockedFromV291,90\);/);
  assert.match(code,/blockedResultV291\.error\s*\n?\s*\?`<section class="card"[\s\S]{0,160}Blocked time could not be read/);
  /* V375 (owner, photo 13: "move there inside"): blocked time is its own Block tab now rather
     than a section appended under the appointment list, so the guarantee is that the tab renders
     it and wires its controls — the same markup, one tab across. */
  assert.match(code,/if\(view==='block'\)\{\s*\n?\s*\$\('alist'\)\.innerHTML=blockedListHtmlV291;/);
  assert.match(code,/id="appointmentBlockSeg"/);
  // Week agenda (the 390px week view) carries the rows plus their controls.
  assert.match(code,/const blockedAgendaV291=canWrite\?calendarBlocks\.map\(block=>\{/);
  /* V468 widened this guard: the week agenda now also carries pending booking-request rows, so
     the "No appointments this week" empty state is suppressed when EITHER kind of row exists. The
     V291 guarantee — blocked rows are never hidden behind that empty state — is unchanged. */
  assert.match(code,/<div class="calendar-agenda">\$\{agenda\|\|\(blockedAgendaV291\|\|pendingAgendaV468\?''/);
  assert.match(code,/\}\)\.join\(''\);\s*\n\s*const blockedAgendaV291=/);
});

test('nestly_v584 the table-capacity surface is deleted, not left half-wired',()=>{
  /* V291 gave a table type an in-place rename and re-count, because deleting and re-adding a row
     detaches it from the bookings that name it. Owner photo 13 deletes the whole Bookings settings
     tab AND its contents, so there is no capacity surface left to edit. What that ruling must not
     do is leave dead handlers pointing at booking_tables from a page nobody can reach — the rows
     themselves stay in the database untouched. */
  assert.ok(!app.includes('async function loadCapacity(){'));
  assert.ok(!app.includes('data-table-save-v291'));
  assert.ok(!app.includes("id=\"tblAdd\""));
  assert.ok(!app.includes('window.rmTable'));
  assert.ok(!app.includes('window.toggleTable'));
});

test('V291 a waiting walk-in can be corrected without losing their place in the queue',()=>{
  const save=section('async function saveWaitlistEditV291(','function actionsHtml(w){');
  /* nestly_v575 (owner: the waitlist should carry a real date & time so Book can push straight
     into an appointment). The free-text window became `preferred_at`, a timestamp. What V291
     protects — that an edit corrects the row IN PLACE and never rewrites created_at, so the
     walk-in keeps their place in the queue — is unchanged. */
  assert.match(save,/const patch=\{preferred_at:sgIso\(preferredAt\)\|\|null,notes:notes\|\|null\};/);
  assert.match(save,/patch\.table_type_id=\$\('wlEditTableV291'\)\?\.value\|\|null;/);
  assert.match(save,/sb\.from\('waitlist'\)\s*\n?\s*\.update\(patch\)/);
  // created_at orders the queue and is never rewritten.
  assert.doesNotMatch(save,/created_at/);
  /* nestly_v571 (owner, Waitlist photo): "Seat now" became "Book" and absorbed the separate
     "Start booking", so the row composes three actions plus remove. Edit — the control this test
     exists for — is still one of them. */
  assert.match(code,/return book\+edit\+called\+remove;/);
});

test('V375 the custom customer-field editor is gone, and no stored answer was touched',()=>{
  /* V375 (owner, photo 16: the Customer fields card struck through, "delete these wordings").
     The editor and all three of its handlers left with the card. What V291 protected — that a
     stored answer can never be re-typed or re-classified — is now guaranteed by there being no
     writer at all: nothing in the browser bundle updates client_field_definitions. */
  assert.doesNotMatch(code,/cfRenameV291/);
  assert.doesNotMatch(code,/\$\('cfAdd'\)/);
  assert.doesNotMatch(code,/create_client_field_definition/);
  assert.doesNotMatch(code,/client_field_definitions'\)\.update\(/);
  /* The customer profile still READS the definitions a business already has, so existing fields
     and every answer recorded against them keep appearing where they always did. */
  assert.match(code,/sb\.from\('client_field_definitions'\)\.select\(/);
});

test('V291 a module the sector does not run cannot be granted to a teammate',()=>{
  const grid=section('const sectorAssignableModulesV291=','const defaultInheritedPerms=');
  assert.match(grid,/INDUSTRIES\[String\(S\.biz\?\.industry\|\|''\)\.toLowerCase\(\)\]/);
  assert.match(grid,/\(!sectorModules\|\|sectorModules\.includes\(module\)\)/);
  // An unknown industry stays permissive rather than stripping a live permission.
  assert.match(grid,/Array\.isArray\(sector\?\.mods\)\?sector\.mods:null/);
  // The concrete case the audit named: 'bottles' belongs to the bar bundle only.
  assert.match(app,/bar:\{em:'🍸'[^}]*'bottles'/);
  for(const sector of ['fnb','salon','retail']){
    const bundle=section(`${sector}:{em:`,'},',app);
    assert.doesNotMatch(bundle,/'bottles'/,`${sector} must not be able to grant bottles`);
  }
});

/* ------------------------------------------------------- 5. Publish-gate coverage ---- */

test('V291 the reward comparison covers every field a draft can change',()=>{
  const fields=section('function growRewardDiffFieldsV291(','function growRewardDiffOptionsFromSnapshotV291(');
  /* V375: 'Store credit' left the comparison with the column it compared — a reward can no
     longer pay out credit at all (owner, photo 3).
     nestly_v754: 'Expires after' (a day count read from entitlement_expiry_days) became
     'Expires on' (a date read from claim_available_until) — the points editor's day box now
     writes the redeem-by deadline, and the publish diff states the same field. */
  for(const label of ['Name','Cost','Offered','Expires on','Uses per customer',
    'Who can redeem','Branches','Services']){
    assert.match(fields,new RegExp(`label:'${label}'`),`${label} must be compared`);
  }
  // The published read has to carry those columns or the comparison is blind.
  assert.match(code,/sb\.from\('loyalty_rewards'\)\.select\('id,active,customer_name,name,cost_points,credit_cents,entitlement_expiry_days,usage_limit,min_tier_id,min_tier_threshold/);
  // Eligibility that could not be READ is never printed as "All branches".
  assert.match(code,/branchName:Array\.isArray\(eligibility\.branches\)\?lookup\(names\.branches\)\|\|\(\(\)=>null\):null/);
});

test('V291 birthday and bring-back rows carry their own pending markers',()=>{
  assert.match(code,/const growPendingBirthdayV291=growDraftDetailV268&&snapshot\.draftBirthday/);
  assert.match(code,/const growRetentionDiffV291=Array\.isArray\(snapshot\.draftRetention\)/);
  // programmeRow renders the same block the reward cards use.
  assert.match(code,/\$\{growPendingBlockV268\(pending\)\}<\/div><span class="grow-programme-meta">/);
  /* V229/V358 moved birthday and bring-back off the overview's ROW list and onto their own peer
     tiles, so neither renders a pending marker any more — growRetentionDiffV291 and
     growPendingBirthdayV291 are both computed and unread (recorded as dead in the V371 evidence).
     The marker MECHANISM is unchanged and still carries the surfaces that do have rows, which is
     what this test now holds; if either programme regains a row it must use the same block. */
  assert.match(code,/\$\{growPendingBlockV268\(pending\)\}<\/div><span class="grow-programme-meta">/);
  assert.ok(code.split('growPendingBlockV268(').length - 1 >= 3,
    'the shared pending block must still be the one way a row says it has an edit waiting');
  // The welcome offer is not versioned, so it says that rather than faking a pending state.
  assert.match(code,/Not part of your draft \\u2014 changes here go live as soon as you save them\.|Not part of your draft — changes here go live as soon as you save them\./);
  // The draft readers that feed all three.
  assert.match(code,/sb\.rpc\('get_retention_config_draft',\{p_config_version:draftHeaderV268\.id\}\)/);
  assert.match(code,/sb\.rpc\('get_birthday_program_draft',\{p_config_version:draftHeaderV268\.id\}\)/);
});

test('V291 the publish gate renders the same diff it publishes, above its checkbox',()=>{
  const gate=section('async function studioPublishReviewPage(','async function studioPage(');
  assert.match(gate,/growRewardPendingChangesV291\(/);
  assert.match(gate,/growRetentionPendingChangesV291\(/);
  assert.match(gate,/growBirthdayPendingChangesV291\(/);
  /* V295 retarget (owner: "i do not know what changed - just be straight forward"). The three
     grouping headings became ONE flat list of concrete before/after lines. Completeness is what
     V291 was defending, so the pins move to the three renderers that feed that list — every
     reward, birthday and bring-back change still reaches it. */
  assert.match(gate,/studio-change-list-v295/);
  assert.match(gate,/rewardDiffV291\.rewards\.changed\.forEach\(\(changes,rewardId\)=>/);
  assert.match(gate,/rewardDiffV291\.rewards\.added\.forEach\(reward=>/);
  assert.match(gate,/rewardDiffV291\.rewards\.removed\.forEach\(reward=>/);
  assert.match(gate,/rewardDiffV291\?\.birthday\?\.length\)\s*\n?\s*rewardDiffV291\.birthday\.forEach/);
  assert.match(gate,/rewardDiffV291\.retention\.changed\.forEach\(changes=>/);
  assert.match(gate,/rewardDiffV291\.retention\.added\.forEach\(rule=>/);
  // The old disclaimer is gone from both the page and the dialog.
  assert.doesNotMatch(gate,/does not summarise reward, birthday or bring-back field values/);
  assert.doesNotMatch(gate,/This check does not display ordinary reward/);
  // A read that failed is admitted, never reported as "no change".
  assert.match(gate,/could not be read, so they are not listed here/);
  // The dialog mirrors the rendered block, so the checkbox is never ticked blind.
  assert.match(gate,/const publishDiffHtml=String\(\$\('growPublishDiffBody'\)\?\.innerHTML\|\|''\)/);
});

/* --------------------------------------------- 6. Bring-back published-row actions ---- */

test('V291 a published bring-back rule can be edited or paused in one tap',()=>{
  const block=section('const ensureRetentionDraftV291=async()=>{',"if($('beginRetentionDraft'))");
  // Resume an existing draft rather than opening a second one.
  assert.match(block,/if\(resumableDraft\?\.id\)return resumableDraft\.id;/);
  assert.match(block,/sb\.rpc\('create_loyalty_config_draft',\s*\n?\s*\{p_business:S\.biz\.id,p_based_on:currentVersion,p_source:'owner_retention_editor'\}\)/);
  // Pause writes into the draft, with the draft's own hash read back rather than guessed.
  assert.match(block,/get_retention_config_draft/);
  assert.match(block,/p_expected_snapshot_hash:draftDetail\?\.snapshot_hash\|\|null/);
  // Nothing publishes from here.
  assert.doesNotMatch(block,/publish_loyalty_config/);
  assert.match(block,/nothing is live until you publish/);
  // Deliberately still no delete on a published rule.
  assert.doesNotMatch(code,/retentionDeleteLiveV291/);
});

/* ---------------------------------------------------------------- 7. 390px ---- */

test('V291 the Day view has a linear agenda fallback like the Week view',()=>{
  assert.match(code,/const dayAgendaRowsV291=columns\.flatMap\(column=>\[/);
  assert.match(code,/const dayAgendaV291=dayAgendaRowsV291\.length/);
  assert.match(code,/<div class="calendar-agenda">\$\{dayAgendaV291\}<\/div>/);
  // Built from the same columns as the grid, so the two cannot disagree.
  assert.match(code,/\.\.\.column\.items\.map\(item=>\(\{sort:eventParts\(item\.starts_at\)\.minutes/);
  assert.match(code,/\.\.\.column\.blocks\.map\(block=>\{/);
  // The timeline is hidden at the same breakpoint the week grid is, and the instruction that
  // points at its green slots goes with it.
  assert.match(indexHtml,/\.calendar-week-scroll,\.day-timeline-scroll\{display:none\}\.calendar-agenda\{display:block\}/);
  assert.match(indexHtml,/\.day-timeline-slot-hint-v291\{display:none\}/);
  assert.match(code,/<p class="small day-timeline-slot-hint-v291">/);
});

/* nestly_v584: "the bookings capacity controls wrap at 390px" retired with the controls — see the
   deletion test above. The 390px wrapping rule it was one instance of is still asserted for the
   surfaces that still exist. */

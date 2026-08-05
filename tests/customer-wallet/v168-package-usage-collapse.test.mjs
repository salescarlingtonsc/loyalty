import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const helperStart=app.indexOf('function collapsePackageUsageRuns');
const helperEnd=app.indexOf('const loadPackages=async',helperStart);
assert.ok(helperStart>=0&&helperEnd>helperStart,'v168 package usage collapse helper must exist');
const {collapsePackageUsageRuns}=new Function(
  `const walletDate=(v,withTime)=>String(v)+(withTime?' t':'');${app.slice(helperStart,helperEnd)};return {collapsePackageUsageRuns};`
)();

test('a run of identical timestamp and status collapses to one entry carrying the lowest remaining',()=>{
  const rows=collapsePackageUsageRuns([
    {used_at:'2026-07-22T17:37:00Z',status:'used',remaining_after:5},
    {used_at:'2026-07-22T17:37:00Z',status:'used',remaining_after:4},
    {used_at:'2026-07-22T17:37:00Z',status:'used',remaining_after:3}
  ]);
  assert.equal(rows.length,1);
  assert.equal(rows[0].count,3);
  assert.equal(rows[0].status,'used');
  assert.equal(rows[0].remaining_after,3);
  assert.equal(rows[0].used_at,'2026-07-22T17:37:00Z');
});

test('singletons pass through unchanged and out-of-order remaining still yields the run minimum',()=>{
  const single=collapsePackageUsageRuns([{used_at:'2026-07-22T17:37:00Z',status:'used',remaining_after:2}]);
  assert.equal(single.length,1);
  assert.equal(single[0].count,1);
  assert.equal(single[0].remaining_after,2);
  const run=collapsePackageUsageRuns([
    {used_at:'2026-07-22T17:37:00Z',status:'used',remaining_after:1},
    {used_at:'2026-07-22T17:37:00Z',status:'used',remaining_after:6}
  ]);
  assert.equal(run.length,1);
  assert.equal(run[0].count,2);
  assert.equal(run[0].remaining_after,1);
  assert.deepEqual(collapsePackageUsageRuns(null),[]);
});

test('different timestamps or statuses are never merged and order is preserved',()=>{
  const rows=collapsePackageUsageRuns([
    {used_at:'2026-07-22T17:37:00Z',status:'used',remaining_after:5},
    {used_at:'2026-07-23T09:00:00Z',status:'used',remaining_after:4},
    {used_at:'2026-07-23T09:00:00Z',status:'refunded',remaining_after:5},
    {used_at:'2026-07-22T17:37:00Z',status:'used',remaining_after:3}
  ]);
  assert.equal(rows.length,4);
  assert.deepEqual(rows.map(r=>r.count),[1,1,1,1]);
  assert.deepEqual(rows.map(r=>r.status),['used','used','refunded','used']);
  assert.deepEqual(rows.map(r=>r.remaining_after),[5,4,5,3]);
});

test('the packages section renders from the collapsed runs and pluralises only real runs',()=>{
  assert.match(app,/collapsePackageUsageRuns\(item\.usage_history\)\.map\(use=>/);
  assert.match(app,/use\.count>1\?`\$\{use\.count\} sessions \$\{esc\(use\.status\)\}`:esc\(use\.status\)/);
  assert.match(app,/<div class="wallet-history">/);
  assert.doesNotMatch(app,/item\.usage_history\.map\(use=>/);
});

test('the feedback status sentence never doubles punctuation and the pill keeps the bare word',()=>{
  const sentenceStart=app.indexOf('const feedbackStatusWord=');
  const sentenceEnd=app.indexOf('const feedbackStatusTone=',sentenceStart);
  assert.ok(sentenceStart>=0&&sentenceEnd>sentenceStart,'v168 feedback status helpers must exist');
  const {feedbackStatusWord,feedbackStatusSentence}=new Function(
    `${app.slice(sentenceStart,sentenceEnd)};return {feedbackStatusWord,feedbackStatusSentence};`
  )();
  assert.equal(feedbackStatusSentence({recovery_status:'closed'}),'Thanks!');
  assert.equal(feedbackStatusSentence({recovery_status:'resolved'}),'Sorted out.');
  assert.equal(feedbackStatusSentence({recovery_status:'open'}),'The team is looking into this.');
  assert.equal(feedbackStatusWord({recovery_status:'resolved'}),'Sorted out');
  assert.match(app,/out of 5<\/span>\. \$\{esc\(feedbackStatusSentence\(general\)\)\}<\/p>/);
  assert.match(app,/<span class="pill \$\{feedbackStatusTone\(f\)\}">\$\{esc\(feedbackStatusWord\(f\)\)\}<\/span>/);
});

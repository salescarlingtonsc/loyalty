import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const from=app.indexOf('const PROMOTION_COPY_POLICY_V104');
const to=app.indexOf('function promotionEditorItemV104',from);
assert.ok(from>=0&&to>from,'v104 copy assistant source must exist');
const source=app.slice(from,to);
const {policy,assist,boundary,dateText}=new Function(`${source};return {
  policy:PROMOTION_COPY_POLICY_V104,
  assist:promotionCopyAssistV104,
  boundary:promotionBoundaryV104,
  dateText:promotionDateTextV104
};`)();

test('valid Singapore offer dates produce exact start and inclusive end boundaries',()=>{
  assert.equal(boundary('2026-08-30'),'2026-08-29T16:00:00.000Z');
  assert.equal(boundary('2026-08-30',{end:true}),'2026-08-30T15:59:59.999Z');
  assert.equal(dateText('2026-08-30'),'30 August 2026');
  assert.equal(boundary('30 August 2026'),null);
  assert.equal(boundary(''),null);
});

test('free copy assistant preserves the exact merchant offer, occasion, date, and CTA',()=>{
  const result=assist({
    offerFacts:'30% off Spa Ritual 60',
    occasion:'National Day',
    endDate:'2026-08-30',
    businessName:'Glow Atelier',
    ctaKind:'book'
  });
  assert.deepEqual(result,{
    headline:'National Day: 30% off Spa Ritual 60',
    message:'Celebrate National Day with 30% off Spa Ritual 60 at Glow Atelier. Available until 30 August 2026. Book now to enjoy this offer.',
    ctaLabel:'Book now'
  });
  assert.match(result.headline,/30% off Spa Ritual 60/);
  assert.match(result.message,/30 August 2026/);
  assert.match(result.message,/Book now to enjoy this offer\.$/);
  assert.doesNotMatch(result.message,/#|limited spots|best|guarantee/i);
});

test('assistant refuses incomplete facts and has an anti-invention provider-ready policy',()=>{
  assert.equal(assist({offerFacts:'',endDate:'2026-08-30'}),null);
  assert.equal(assist({offerFacts:'30% off',endDate:''}),null);
  assert.match(policy.system,/Preserve every number, percentage, date/);
  assert.match(policy.system,/Never invent scarcity, prices, availability, outcomes/);
  assert.deepEqual(Object.keys(policy.ctas),['book','programme','counter']);
});

test('maximum accepted inputs always produce a server-saveable headline and complete message',()=>{
  const facts=`30% off ${'signature treatment '.repeat(7)}`.slice(0,140),
    occasion=`National celebration ${'week '.repeat(20)}`.slice(0,80),
    result=assist({
      offerFacts:facts,
      occasion,
      endDate:'2026-08-30',
      businessName:'A'.repeat(500),
      ctaKind:'counter'
    });
  assert.ok(result.headline.length<=70,'headline must satisfy the database maximum');
  assert.ok(result.message.length<=600,'message must satisfy the database maximum');
  assert.match(result.message,new RegExp(facts.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')));
  assert.match(result.message,new RegExp(occasion.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')));
  assert.match(result.message,/30 August 2026/);
  assert.match(result.message,/Show this offer at the counter when you visit\.$/);
});

test('v104 launch copy assistance consumes no browser API key or model credits',()=>{
  assert.doesNotMatch(source,/fetch\(|openai|api[_-]?key|authorization/i);
  const page=app.slice(app.indexOf('async function promotionsPage'),app.indexOf('async function growPage'));
  assert.match(page,/Polish wording — free/);
  assert.match(page,/Uses verified templates; no API credits/);
  assert.match(page,/id="promotionMessage" maxlength="600"/);
});

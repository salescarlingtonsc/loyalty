import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');

/* nestly_v970 (production sweep II). The Programmes overview promises, in its own banner, that
   "Unavailable rows are not assumed to be off. Retry before making a decision." Seven reads keep
   that promise by handing their error to snapshot.overviewErrors, which raises the banner and turns
   each tile's pill to Unavailable. The welcome offer was the eighth, and it kept none of it:

     sb.rpc('business_get_welcome_offer_v215',...).then(r=>r.error?null:r.data).catch(()=>null)

   collapses "the read failed" and "no welcome offer is configured" into the same null. Downstream,
   the overview row is pushed only `if(welcomeOfferStatusV215?.configured)`, so the row vanished with
   no banner and nothing in the console, and the Grow tile — which borrowed the UNRELATED 'rewards'
   error key — positively asserted "Not set up". An owner reading that card after a dropped request
   would conclude they had never set their welcome gift up.

   Proven against production by failing that one RPC at the transport layer: the row disappeared and
   the banner stayed down, while failing bringback_campaigns_v361 instead raised it correctly. */

test('a failed welcome-offer read is reported as unavailable, never as "not set up"',()=>{
  /* 1. The read must carry its failure forward. A bare `.catch(()=>null)` is what threw the
        distinction away, so the shape that replaces it has to be visible here. */
  assert.doesNotMatch(app,/business_get_welcome_offer_v215',\{p_business:S\.biz\.id\}\)\.then\(r=>r\.error\?null:r\.data\)\.catch\(\(\)=>null\)/,
    'the welcome read still collapses a failure into the same null it uses for "not configured"');
  assert.match(app,/welcomeOfferRequestV215=canRewards[\s\S]{0,400}?failed:Boolean\(r\.error\)/,
    'the welcome read should report whether it failed alongside its data');
  assert.match(app,/welcomeOfferRequestV215=canRewards[\s\S]{0,400}?catch\(\(\)=>\(\{data:null,failed:true\}\)\)/,
    'a transport failure must be reported as failed, not swallowed');

  /* 2. That failure has to reach the map the banner and every tile already read. */
  assert.match(app,/snapshot\.overviewErrors\.welcome=/,
    'a welcome-read failure must join the overviewErrors map that raises the "could not be loaded" banner');

  /* 3. The tile must key off its OWN read. Keying off 'rewards' made it answer for a different
        request: the welcome RPC could fail while the tile still claimed "Not set up". */
  assert.doesNotMatch(app,/growTileStatusV371\('rewards',!canRewards\?\['Not included','off'\]:welcomeOfferStatusV215/,
    "the welcome tile still borrows the 'rewards' error key instead of its own");
  assert.match(app,/growTileStatusV371\('welcome',!canRewards\?\['Not included','off'\]:welcomeOfferStatusV215/,
    "the welcome tile should report unavailable when the welcome read is the one that failed");
});

test('the banner the overview promises is still driven by the whole error map',()=>{
  /* A positive control: if this ever stops reading every key, adding a key above would be inert. */
  assert.match(app,/const rewardsOverviewIncomplete=Object\.values\(snapshot\.overviewErrors\|\|\{\}\)\.some\(Boolean\)/);
  assert.match(app,/Some programme details could not be loaded\./);
  assert.match(app,/Unavailable rows are not assumed to be off/);
});

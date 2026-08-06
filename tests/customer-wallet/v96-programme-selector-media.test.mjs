import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const source=readFileSync(
  new URL('../../db/migrations/20260729_nestly_v96_customer_programme_selector_media.sql',import.meta.url),
  'utf8'
);
const canonical=readFileSync(
  new URL('../../supabase/migrations/20260729110000_nestly_v96_customer_programme_selector_media.sql',import.meta.url),
  'utf8'
);
const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const rollback=readFileSync(
  new URL('../../db/tests/v96_customer_programme_selector_media.sql',import.meta.url),
  'utf8'
);

function functionBlock(sql,name){
  const start=sql.indexOf(`function public.${name}(`);
  assert.ok(start>=0,`missing ${name}`);
  const end=sql.indexOf('\n$$;',start);
  assert.ok(end>start,`unterminated ${name}`);
  return sql.slice(start,end+4);
}

test('v96 source and deploy mirror are exact forward-only changes',()=>{
  assert.equal(source,canonical);
  assert.match(source,/^-- NESTLY v96[\s\S]*\bbegin;[\s\S]*\bcommit;\s*$/);
  assert.doesNotMatch(source,/\bdrop\s+(?:table|function|column)\b/i);
});

test('one actionable wallet call joins only verified-context customer-visible logos',()=>{
  const rpc=functionBlock(source,'customer_get_actionable_wallet');
  assert.match(rpc,/from app\.v32_customer_wallet_context\(null\) context/i);
  assert.match(rpc,/left join public\.business_brand_presentation_v95 brand[\s\S]*brand\.business_id\s*=\s*context\.business_id/i);
  assert.match(rpc,/left join public\.business_media_assets_v95 logo[\s\S]*logo\.business_id\s*=\s*context\.business_id/i);
  assert.match(rpc,/logo\.asset_kind\s*=\s*'logo'[\s\S]*logo\.customer_visible/i);
  assert.match(rpc,/app\.v95_public_media_url\(logo\.object_path\)/i);
  assert.match(rpc,/jsonb_build_object\(\s*'logo_url'/i);
  assert.doesNotMatch(rpc,/p_business|p_business_slug/);
  assert.equal((rpc.match(/app\.v32_customer_wallet_context/g)||[]).length,1);
});

test('legacy selector uses one independent bounded verified-link media batch',()=>{
  const rpc=functionBlock(source,'customer_get_programme_selector_media_v96');
  assert.match(rpc,/from app\.v32_customer_wallet_context\(null\) context/i);
  assert.match(rpc,/row_number\(\) over\(order by context\.business_slug\) item_rank/i);
  assert.match(rpc,/filter\(where ranked\.item_rank<=100\)/i);
  assert.match(rpc,/where ranked\.item_rank<=101/i);
  assert.match(rpc,/'business_slug',\s*ranked\.business_slug/i);
  assert.match(rpc,/'logo_url',\s*app\.v95_public_media_url\(ranked\.object_path\)/i);
  assert.doesNotMatch(rpc,/customer_actionable_wallet/i);
  assert.doesNotMatch(rpc,/p_business|p_business_slug/i);
});

test('both selector media contracts have authenticated-only finite grants',()=>{
  assert.match(source,/revoke all on function public\.customer_get_actionable_wallet\(\)\s*from public,\s*anon,\s*authenticated;/i);
  assert.match(source,/grant execute on function public\.customer_get_actionable_wallet\(\)\s*to authenticated;/i);
  assert.match(source,/revoke all on function public\.customer_get_programme_selector_media_v96\(\)\s*from public,\s*anon,\s*authenticated;/i);
  assert.match(source,/grant execute on function public\.customer_get_programme_selector_media_v96\(\)\s*to authenticated;/i);
  assert.doesNotMatch(source,/grant execute[\s\S]*\bto\s+(?:public|anon)\b/i);
});

test('selector tiles consume server-projected logos and legacy paths use one batch call',()=>{
  const selector=app.slice(
    app.indexOf('function customerProgrammeTileLogoV96'),
    app.indexOf('async function renderCustomerWallet')
  );
  assert.match(selector,/business\?\.logo_url/);
  assert.match(selector,/customerMediaUrlV95/);
  assert.match(selector,/customerProgrammeTileLogoV96\(business\)/);
  assert.equal((selector.match(/sb\.rpc\(/g)||[]).length,0);
  assert.match(app,/function mergeCustomerProgrammeSelectorMediaV96/);
  assert.match(app,/Promise\.all\(\[\s*sb\.rpc\('customer_get_wallet'\),\s*sb\.rpc\('customer_get_programme_selector_media_v96'\)/);
  assert.match(app,/mergeCustomerProgrammeSelectorMediaV96\(\s*Array\.isArray\(data\)\?data:\[\],selectorMediaResult\.error\?null:selectorMediaResult\.data/s);
  assert.doesNotMatch(app,/cards\.map\([\s\S]{0,300}customer_get_programme_selector_media_v96/);
});

test('rollback SQL proves linked visibility, hidden-media fallback, isolation and ACLs',()=>{
  for(const phrase of[
    'verified-link scoped','customer-visible logo','foreign tenant media',
    'hidden logo','anonymous caller','unlinked active customer','ACL is not finite'
  ])assert.match(rollback,new RegExp(phrase,'i'));
  assert.match(rollback,/v_result#>>'\{cards,0,business,logo_url\}'/i);
  assert.match(rollback,/set enabled=false[\s\S]*customer_actionable_wallet[\s\S]*customer_get_programme_selector_media_v96\(\)/i);
  assert.match(rollback,/set customer_visible=false/i);
  assert.match(rollback,/rollback;\s*$/i);
});

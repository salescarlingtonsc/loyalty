import assert from 'node:assert/strict';
import test from 'node:test';

import {setupStripeCatalog} from '../../scripts/stripe/setup-v124-catalog.mjs';

const definitions=[
  ['nestly_v124_monthly_base_sgd','price_monthly_base',14800,'month','Peekaa monthly base — 1,000 customers','base','monthly'],
  ['nestly_v124_monthly_capacity_1000_sgd','price_monthly_capacity',1000,'month','Peekaa monthly — additional 1,000 customers','capacity','monthly'],
  ['nestly_v124_annual_base_sgd','price_annual_base',118800,'year','Peekaa annual base — 1,000 customers','base','annual'],
  ['nestly_v124_annual_capacity_1000_sgd','price_annual_capacity',12000,'year','Peekaa annual — additional 1,000 customers','capacity','annual'],
];

function stripeResponse(body,status=200){
  return {ok:status>=200&&status<300,status,json:async()=>body};
}

function legacyCatalogue({conflicting=false}={}){
  let product={
    id:'prod_v124',name:'Nestly Business Subscription',description:'Legacy workspace',
    metadata:{nestly_pricing_model:'v124_customer_capacity'},
  };
  const prices=new Map(definitions.map(([lookup,id,amount,interval])=>[lookup,{
    id,product:'prod_v124',currency:'sgd',unit_amount:conflicting&&lookup==='nestly_v124_monthly_base_sgd'?14901:amount,
    type:'recurring',recurring:{interval,interval_count:1,usage_type:'licensed'},tax_behavior:'exclusive',
    nickname:`Nestly ${lookup}`,metadata:{nestly_pricing_model:'v124_customer_capacity'},
  }]));
  const calls=[];
  const fetchImpl=async(rawUrl,init={})=>{
    const url=new URL(rawUrl),method=init.method||'GET',fields=new URLSearchParams(init.body||'');
    calls.push({method,path:url.pathname,fields:Object.fromEntries(fields)});
    if(method==='GET'&&url.pathname==='/v1/products')return stripeResponse({data:[product]});
    if(method==='POST'&&url.pathname==='/v1/products/prod_v124'){
      product={...product,name:fields.get('name'),description:fields.get('description'),metadata:{
        nestly_pricing_model:fields.get('metadata[nestly_pricing_model]'),
        included_customer_capacity:fields.get('metadata[included_customer_capacity]'),
        capacity_block_size:fields.get('metadata[capacity_block_size]'),
      }};
      return stripeResponse(product);
    }
    if(method==='GET'&&url.pathname==='/v1/prices'){
      return stripeResponse({data:[prices.get(url.searchParams.get('lookup_keys[]'))].filter(Boolean)});
    }
    if(method==='POST'&&url.pathname.startsWith('/v1/prices/')){
      const price=[...prices.values()].find(candidate=>`/v1/prices/${candidate.id}`===url.pathname);
      assert.ok(price,`unexpected Price update ${url.pathname}`);
      price.nickname=fields.get('nickname');
      price.metadata={
        nestly_pricing_model:fields.get('metadata[nestly_pricing_model]'),
        item_role:fields.get('metadata[item_role]'),cadence:fields.get('metadata[cadence]'),
        capacity_block_size:fields.get('metadata[capacity_block_size]'),
      };
      return stripeResponse(price);
    }
    throw new Error(`unexpected Stripe request ${method} ${url.pathname}`);
  };
  return {fetchImpl,calls,getProduct:()=>product,prices};
}

test('existing reviewed Stripe objects converge to Peekaa presentation and rerun idempotently',async()=>{
  const mock=legacyCatalogue();
  const first=await setupStripeCatalog({secret:'sk_test_v134catalog',apply:true,fetchImpl:mock.fetchImpl});
  assert.equal(mock.getProduct().name,'Peekaa Business Subscription');
  assert.equal(mock.getProduct().description,'Peekaa business workspace with customer-capacity billing; staff access included.');
  assert.equal(mock.calls.filter(call=>call.method==='POST'&&call.path.startsWith('/v1/products/')).length,1);
  assert.equal(mock.calls.filter(call=>call.method==='POST'&&call.path.startsWith('/v1/prices/')).length,4);
  for(const [lookup,,amount,interval,nickname,role,cadence] of definitions){
    const price=mock.prices.get(lookup);
    assert.equal(price.unit_amount,amount);
    assert.equal(price.recurring.interval,interval);
    assert.equal(price.tax_behavior,'exclusive');
    assert.equal(price.nickname,nickname);
    assert.deepEqual(price.metadata,{
      nestly_pricing_model:'v124_customer_capacity',item_role:role,cadence,capacity_block_size:'1000',
    });
  }
  assert.deepEqual(first.prices,{
    monthly_base:'price_monthly_base',monthly_capacity:'price_monthly_capacity',
    annual_base:'price_annual_base',annual_capacity:'price_annual_capacity',
  });
  const postsAfterFirst=mock.calls.filter(call=>call.method==='POST').length;
  await setupStripeCatalog({secret:'sk_test_v134catalog',apply:true,fetchImpl:mock.fetchImpl});
  assert.equal(mock.calls.filter(call=>call.method==='POST').length,postsAfterFirst,'an exact rerun must not mutate Stripe');
});

test('existing lookup-key economic conflict fails closed before provider mutation',async()=>{
  const mock=legacyCatalogue({conflicting:true});
  await assert.rejects(
    setupStripeCatalog({secret:'sk_test_v134catalog',apply:true,fetchImpl:mock.fetchImpl}),
    /conflicts with reviewed V125 no-GST pricing/,
  );
  assert.equal(mock.getProduct().name,'Nestly Business Subscription','failed preflight must not partially rename Product');
  assert.equal(mock.calls.some(call=>call.method==='POST'),false);
});

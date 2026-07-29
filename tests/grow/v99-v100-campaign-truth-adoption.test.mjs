import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
import test from 'node:test';

const root=new URL('../..',import.meta.url).pathname;
const read=path=>readFile(join(root,path),'utf8');
const v99Path='supabase/migrations/20260729130000_nestly_v99_campaign_truth.sql';
const v100Path='supabase/migrations/20260729140000_nestly_v100_product_adoption_events.sql';
const functionBlock=(sql,schema,name)=>
  sql.match(new RegExp(
    `create or replace function ${schema}\\.${name}[\\s\\S]+?\\n\\$\\$;`,
    'i'
  ))?.[0]||'';

test('v99 and v100 sort after v97 and are transactional forward migrations',async()=>{
  const [v99,v100]=await Promise.all([read(v99Path),read(v100Path)]);
  assert.match(v99,/^-- NESTLY v99/m);
  assert.match(v100,/^-- NESTLY v100/m);
  assert.ok(v99Path.includes('20260729130000'));
  assert.ok(v100Path.includes('20260729140000'));
  for(const sql of [v99,v100]){
    assert.match(sql,/\bbegin;\s/i);
    assert.match(sql,/\bcommit;\s*$/i);
  }
});

test('v99 exposure is immutable, treatment-only and structurally tied to the same customer entitlement',async()=>{
  const sql=await read(v99Path);
  assert.match(sql,/create table public\.retention_campaign_exposures_v99/i);
  assert.match(sql,/assignment text not null default 'treatment'[\s\S]+check \(assignment='treatment'\)/i);
  assert.match(sql,/foreign key \(campaign_grant_id,business_id,campaign_id,client_id\)[\s\S]+references public\.retention_campaign_grants/i);
  assert.match(sql,/foreign key \(reward_grant_id,business_id,client_id,campaign_id\)[\s\S]+references public\.reward_grants\(id,business_id,client_id,campaign_id\)/i);
  assert.match(sql,/reward\.client_id=v_grant\.client_id/i);
  assert.match(sql,/reward\.campaign_id=p_campaign/i);
  assert.match(sql,/reward\.status in \('granted','redeemed'\)/i);
  assert.match(sql,/reward\.granted_at<=p_exposed_at/i);
  assert.match(sql,/before update or delete on public\.retention_campaign_exposures_v99/i);
  assert.match(sql,/evidence_kind text not null[\s\S]+check \(evidence_kind='manual_confirmation'\)/i);
  assert.match(sql,/delivery_provider_status','not_configured'/i);
});

test('v99 exposure and measurement writes are replay-safe and changed envelopes conflict',async()=>{
  const [sql,acceptance]=await Promise.all([
    read(v99Path),
    read('db/tests/v99_v100_campaign_truth_adoption.sql')
  ]);
  const exposure=functionBlock(sql,'public','record_campaign_exposure_v99');
  const attest=functionBlock(sql,'public','attest_campaign_exposure_v99');
  const seal=functionBlock(sql,'public','seal_campaign_measurement_v99');
  assert.match(sql,/unique \(business_id,idempotency_key\)/i);
  assert.match(exposure,/pg_advisory_xact_lock/i);
  assert.match(exposure,/request_hash<>v_hash[\s\S]+idempotency key conflicts with another exposure envelope/i);
  assert.match(exposure,/'replayed',true/i);
  assert.match(attest,/p_confirmed is distinct from true/i);
  assert.match(attest,/manual exposure must be explicitly confirmed/i);
  assert.match(
    attest,
    /v_existing\.evidence_context[\s\S]+is distinct from coalesce\(p_evidence_context,'\{\}'::jsonb\)/i
  );
  assert.match(attest,/public\.record_campaign_exposure_v99\(/i);
  assert.match(attest,/'attestation_kind','merchant_manual_confirmation'/i);
  assert.match(acceptance,/campaign exposure exact replay was not idempotent/i);
  assert.match(
    acceptance,
    /same-key changed exposure context unexpectedly replayed/i
  );
  assert.match(seal,/pg_advisory_xact_lock/i);
  assert.match(seal,/request_hash<>v_hash[\s\S]+sealed with different terms/i);
  assert.match(seal,/'replayed',true/i);
});

test('v99 offer issuance creates and links the exact published treatment entitlement server-side',async()=>{
  const sql=await read(v99Path);
  const issue=functionBlock(sql,'public','issue_campaign_offer');
  assert.match(sql,/alter table public\.reward_grants[\s\S]+add column campaign_id uuid/i);
  assert.match(sql,/foreign key \(campaign_id,client_id,campaign_assignment\)[\s\S]+retention_campaign_members/i);
  assert.match(sql,/create unique index reward_grants_v99_campaign_member_uk[\s\S]+campaign_id,client_id/i);
  assert.match(issue,/p_reward_grant_id is not null[\s\S]+server-issued/i);
  assert.match(issue,/member\.assignment='treatment'/i);
  assert.match(issue,/business\.active_config_version_id=config\.id/i);
  assert.match(issue,/insert into public\.reward_grants\(/i);
  assert.match(issue,/insert into public\.retention_campaign_grants\(/i);
  assert.match(issue,/'campaign_grant_id',v_campaign_grant/i);
  assert.match(issue,/'reward_grant_id',v_entitlement/i);
  assert.match(issue,/'exposure_status','awaiting_manual_attestation'/i);
  assert.match(issue,/where exposure\.campaign_grant_id=v_existing\.id/i);
  assert.match(issue,/when v_existing_exposure\.id is null[\s\S]+awaiting_manual_attestation[\s\S]+else 'verified'/i);
  assert.match(issue,/'exposure_id',v_existing_exposure\.id/i);
  assert.match(issue,/'delivery_provider_status','not_configured'/i);
  assert.match(issue,/'customer_history_visible',true/i);
  assert.match(issue,/'economic_value_posted',false/i);
  assert.match(issue,/'redemption_mode','merchant_fulfilment_pending'/i);
});

test('v99 customer and staff projections never present pending campaign value as earned or spendable',async()=>{
  const sql=await read(v99Path);
  const customer=functionBlock(sql,'public','customer_get_loyalty_details');
  const staff=functionBlock(sql,'public','staff_get_reward_entitlements_v99');
  for(const projection of [customer,staff]){
    assert.match(projection,/'is_campaign_entitlement'/i);
    assert.match(projection,/'entitlement_status'/i);
    assert.match(projection,/'fulfillment_status'/i);
    assert.match(projection,/'redemption_mode'/i);
    assert.match(projection,/'economic_value_posted'/i);
    assert.match(projection,/'reward_value_hidden'/i);
    assert.match(projection,/Offer awaiting merchant fulfilment/i);
    assert.match(projection,/merchant_fulfilment_pending/i);
    assert.match(projection,/campaign_id is not null[\s\S]+then false/i);
  }
  assert.match(
    customer,
    /No wallet value has been posted\. Ask the business to fulfil this offer\./i
  );
  assert.match(
    staff,
    /when reward\.campaign_id is null[\s\S]+reward\.fulfillment_kind='credit'[\s\S]+then reward\.reward_value::bigint/i
  );
  assert.match(
    sql,
    /grant execute on function public\.staff_get_reward_entitlements_v99\(uuid,uuid\)[\s\S]+to authenticated/i
  );
});

test('v99 common-arm measurement cannot begin before complete verified treatment exposure',async()=>{
  const sql=await read(v99Path);
  const seal=functionBlock(sql,'public','seal_campaign_measurement_v99');
  const record=functionBlock(sql,'public','record_campaign_returns');
  assert.match(seal,/v_exposures<>v_treatment/i);
  assert.match(seal,/every treatment member has verified exposure/i);
  assert.match(seal,/reward\.client_id=member\.client_id/i);
  assert.match(seal,/v_started:=greatest\(v_campaign\.activated_at,v_last_exposure\)/i);
  assert.match(seal,/measurement_ends_at/i);
  assert.match(record,/verified exposure measurement is not sealed/i);
  assert.match(record,/sale\.occurred_at>=v_window\.measurement_started_at/i);
  assert.match(record,/public\.retention_campaign_attributions_v99/i);
  assert.doesNotMatch(record,/public\.retention_campaign_returns\b/i);
});

test('v99 results withdraw legacy causal claims and separate minimum sample from evidence',async()=>{
  const sql=await read(v99Path);
  const results=functionBlock(sql,'public','get_campaign_results');
  assert.match(results,/'measurement_status','awaiting_verified_exposure'/i);
  assert.match(results,/'claimability','no_lift_or_roi_claim'/i);
  assert.match(results,/'minimum_sample_met',v_threshold_met/i);
  assert.match(results,/'inconclusive_minimum_sample'/i);
  assert.match(results,/'inconclusive_statistical_test_not_implemented'/i);
  assert.match(results,/'net_lift_bps',null/i);
  assert.match(results,/'incremental_returns',null/i);
  assert.match(results,/'incremental_revenue_cents',null/i);
  assert.match(results,/'legacy_v50_return_evidence_used',false/i);
  assert.doesNotMatch(results,/statistically_significant['",:]?\s*(?:,|=>)?\s*true/i);
  assert.doesNotMatch(results,/statistical_evidence_verified['",:]?\s*(?:,|=>)?\s*true/i);
});

test('v99 exposed tables use RLS and definer RPCs use the canonical hardened path and explicit ACLs',async()=>{
  const sql=await read(v99Path);
  for(const table of [
    'retention_campaign_exposures_v99',
    'retention_campaign_measurement_windows_v99',
    'retention_campaign_attributions_v99'
  ]){
    assert.match(sql,new RegExp(`alter table public\\.${table}[\\s\\n]+enable row level security`,'i'));
    assert.match(sql,new RegExp(`revoke all privileges on table[\\s\\n]+public\\.${table}[\\s\\S]+?from public,anon,authenticated,service_role`,'i'));
  }
  for(const fn of [
    'record_campaign_exposure_v99',
    'attest_campaign_exposure_v99',
    'seal_campaign_measurement_v99',
    'record_campaign_returns',
    'get_campaign_results'
  ]){
    assert.match(
      functionBlock(sql,'public',fn),
      /security definer[\s\S]+set search_path = pg_catalog, public, app, pg_temp/i
    );
  }
  assert.doesNotMatch(sql,/grant execute on function public\.record_campaign_exposure_v99[\s\S]+to authenticated/i);
  assert.match(sql,/grant execute on function public\.attest_campaign_exposure_v99[\s\S]+to authenticated/i);
  assert.match(sql,/grant execute on function public\.seal_campaign_measurement_v99[\s\S]+to authenticated/i);
});

test('v100 client RPC allowlist is exact, high-value and contains no outcome-completion event',async()=>{
  const sql=await read(v100Path);
  const clientNames=[...sql.matchAll(/\('([a-z0-9_.]+)','client','(?:customer|merchant)'/g)]
    .map(match=>match[1]).sort();
  assert.deepEqual(clientNames,[
    'customer.programme_viewed',
    'merchant.counter_action_opened',
    'merchant.counter_action_started',
    'merchant.grow_draft_started',
    'merchant.grow_opened',
    'merchant.redemption_scan_started',
    'merchant.workspace_viewed'
  ]);
  assert.match(sql,/create or replace function public\.record_product_interaction_v100/i);
  assert.match(sql,/'recording_status','accepted_interaction_only'/i);
  assert.match(sql,/'business_outcome_asserted',false/i);
  assert.doesNotMatch(clientNames.join(','),/(completed|paid|redeemed|joined)/i);
});

test('v100 context is privacy-minimized and economic truth is database-authored',async()=>{
  const sql=await read(v100Path);
  const client=functionBlock(sql,'public','record_product_interaction_v100');
  for(const forbidden of ['email','phone','name','address','token','search','query','raw_route']){
    assert.doesNotMatch(
      client,
      new RegExp(`'${forbidden}'\\s*(?:,|\\))`,'i'),
      `${forbidden} must not be an allowed context key`
    );
  }
  assert.match(client,/octet_length\(v_context::text\)>2048/i);
  assert.match(client,/jsonb_typeof\(context_item\.value\)[\s\S]+not in \('string','number','boolean','null'\)/i);
  for(const event of [
    'sale.recorded','sale.reversed','loyalty.redemption_completed',
    'billing.invoice_paid','customer.qr_join_completed',
    'customer.booking_submitted','campaign.exposure_verified',
    'campaign.return_attributed'
  ]) assert.match(sql,new RegExp(`'${event.replace('.','\\.')}','server'`,'i'));
  for(const trigger of [
    'after insert on public.sales',
    'after insert on public.loyalty_redemptions',
    'on public.billing_provider_invoices',
    'after insert on public.customer_link_audit_events',
    'after insert on public.booking_requests'
  ]) assert.match(sql,new RegExp(trigger.replaceAll('.','\\.'),'i'));
});

test('v100 event store is fail-closed, immutable, replay-safe and aggregate-only to browsers',async()=>{
  const sql=await read(v100Path);
  const client=functionBlock(sql,'public','record_product_interaction_v100');
  const server=functionBlock(sql,'app','append_server_adoption_event_v100');
  assert.match(sql,/alter table public\.product_adoption_events_v100[\s\n]+enable row level security/i);
  assert.match(sql,/revoke all privileges on table public\.product_adoption_events_v100[\s\S]+?from public,anon,authenticated,service_role/i);
  assert.doesNotMatch(sql,/grant select on (?:table )?public\.product_adoption_events_v100/i);
  assert.match(sql,/before update or delete on public\.product_adoption_events_v100/i);
  assert.match(client,/pg_advisory_xact_lock/i);
  assert.match(client,/request_hash<>v_hash[\s\S]+idempotency key conflicts/i);
  assert.match(client,/'replayed',true/i);
  assert.match(server,/on conflict \(source_table,source_id,event_name\) do nothing/i);
  assert.match(sql,/grant execute on function public\.get_product_adoption_summary_v100[\s\S]+to authenticated/i);
  assert.match(sql,/grant execute on function public\.purge_product_adoption_events_v100\(integer\)[\s\S]+to service_role/i);
  assert.doesNotMatch(sql,/grant execute on function public\.purge_product_adoption_events_v100\(integer\)[\s\S]+to authenticated/i);
  assert.match(sql,/nestly-v100-adoption-retention-daily/i);
  assert.match(sql,/cron\.schedule\([\s\S]+public\.purge_product_adoption_events_v100\(5000\)/i);
  assert.match(sql,/if to_regnamespace\('cron'\) is not null/i);
  for(const [,schema,name] of sql.matchAll(
    /create or replace function (public|app)\.([a-z0-9_]+)[\s\S]+?\n\$\$;/gi
  )){
    const block=functionBlock(sql,schema,name);
    if(/security definer/i.test(block)){
      assert.match(
        block,
        /set search_path = pg_catalog, public, app, pg_temp/i,
        `${schema}.${name} must use the canonical hardened path`
      );
    }
  }
});

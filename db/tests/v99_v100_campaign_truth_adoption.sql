-- Rollback-only v99/v100 campaign-truth and adoption-event acceptance suite.
-- Run after the complete canonical chain through v100 in a disposable database.
begin;

-- v95 deliberately retires the legacy create_business() bootstrap used by the
-- shared pristine-chain fixture. Seed two post-v95 firms directly, then make
-- their v94 approval state explicit. This keeps the suite self-contained and
-- exercises the final trigger chain instead of reopening a retired RPC.
do $v99_v100_fixture$
declare
  v_owner_a uuid:=gen_random_uuid();
  v_owner_b uuid:=gen_random_uuid();
  v_business_a uuid:=gen_random_uuid();
  v_business_b uuid:=gen_random_uuid();
  v_config_a uuid:=gen_random_uuid();
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    (
      '00000000-0000-0000-0000-000000000000',v_owner_a,
      'authenticated','authenticated',
      'v100-owner-a-'||substr(v_owner_a::text,1,8)||'@example.test',
      '',now(),now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',v_owner_b,
      'authenticated','authenticated',
      'v100-owner-b-'||substr(v_owner_b::text,1,8)||'@example.test',
      '',now(),now(),now()
    );

  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values
    (
      v_business_a,'V100 campaign truth fixture A',
      'v100-truth-a-'||substr(v_business_a::text,1,8),'test',true,
      array[
        'dashboard','clients','sales','till','appointments','bookings',
        'loyalty','retention','reports'
      ]
    ),
    (
      v_business_b,'V100 campaign truth fixture B',
      'v100-truth-b-'||substr(v_business_b::text,1,8),'test',true,
      array['dashboard','clients','sales','loyalty','retention','reports']
    );
  insert into public.staff(
    business_id,user_id,role,full_name,active
  ) values
    (v_business_a,v_owner_a,'owner','V100 Owner A',true),
    (v_business_b,v_owner_b,'owner','V100 Owner B',true);
  insert into public.branches(
    business_id,name,is_default,active
  ) values
    (v_business_a,'Primary',true,true),
    (v_business_b,'Primary',true,true);

  update public.business_workspace_controls_v94
     set approval_status='approved',
         version=version+1,
         decided_at=clock_timestamp(),
         decision_reason='rollback-only v100 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id in(v_business_a,v_business_b);

  -- The final draft API clones an existing published typed configuration.
  -- Seed that minimal baseline through the same typed tables used by the
  -- canonical final-chain fixtures.
  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,snapshot_hash,created_by
  ) values(
    v_config_a,v_business_a,1,'draft','manual',
    md5('v100-campaign-truth-baseline'),v_owner_a
  );
  perform set_config('request.jwt.claim.sub',v_owner_a::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_a,'role','authenticated')::text,
    true
  );
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,
    tier_basis,expiry_mode
  ) values(
    v_config_a,v_business_a,'points','classic',true,
    1,50,500,'points_earned','none'
  );
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  update public.firm_config_versions
     set status='published',published_at=clock_timestamp()
   where id=v_config_a;
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    current_config_version_id
  ) values(
    v_business_a,'points',true,'classic','published',v_config_a
  );
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses
     set active_config_version_id=v_config_a
   where id=v_business_a;
  perform set_config('app.v79_system_transition','',true);
end
$v99_v100_fixture$;

create or replace function pg_temp.as_v100_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v100_user(uuid,text)
  to authenticated,anon;

do $v99_v100$
declare
  v_owner uuid;
  v_other_owner uuid;
  v_outsider uuid:=gen_random_uuid();
  v_business uuid;
  v_other_business uuid;
  v_owner_staff uuid;
  v_branch uuid;
  v_base uuid;
  v_draft uuid;
  v_snapshot_hash text;
  v_taxonomy uuid;
  v_program uuid:=gen_random_uuid();
  v_program_version uuid;
  v_campaign uuid;
  v_clients uuid[]:=array[]::uuid[];
  v_treatment uuid[];
  v_wrong_client uuid;
  v_customer_user uuid:=gen_random_uuid();
  v_customer_identity uuid:=gen_random_uuid();
  v_customer_link uuid:=gen_random_uuid();
  v_business_slug text;
  v_client uuid;
  v_reward uuid;
  v_wrong_reward uuid;
  v_grant uuid;
  v_first_grant uuid;
  v_first_exposure uuid;
  v_exposed_at timestamptz;
  v_result jsonb;
  v_replay jsonb;
  v_projection jsonb;
  v_sale uuid:=gen_random_uuid();
  v_interaction_at timestamptz:=clock_timestamp();
  v_interaction_key text:='v100-workspace-view-replay';
  v_session uuid:=gen_random_uuid();
  v_event_id uuid;
  v_index integer:=0;
begin
  reset role;
  if has_table_privilege(
       'authenticated','public.product_adoption_events_v100','SELECT'
     )
     or has_table_privilege(
       'authenticated',
       'public.product_adoption_event_taxonomy_v100','SELECT'
     ) then
    raise exception 'v100 event tables are directly browser-readable';
  end if;
  if has_function_privilege(
       'anon',
       'public.record_product_interaction_v100(text,uuid,uuid,uuid,text,timestamptz,jsonb)',
       'EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.record_product_interaction_v100(text,uuid,uuid,uuid,text,timestamptz,jsonb)',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.purge_product_adoption_events_v100(integer)',
       'EXECUTE'
     ) then
    raise exception 'v100 RPC ACLs are not fail-closed';
  end if;
  if has_function_privilege(
       'authenticated',
       'public.record_campaign_exposure_v99(uuid,uuid,uuid,text,text,timestamptz,text,jsonb)',
       'EXECUTE'
     )
     or has_function_privilege(
       'anon',
       'public.attest_campaign_exposure_v99(uuid,uuid,uuid,text,boolean,text,timestamptz,jsonb)',
       'EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.attest_campaign_exposure_v99(uuid,uuid,uuid,text,boolean,text,timestamptz,jsonb)',
       'EXECUTE'
     ) then
    raise exception 'v99 manual exposure attestation ACLs are not fail-closed';
  end if;

  select business.id,staff.user_id,staff.id
  into v_business,v_owner,v_owner_staff
  from public.businesses business
  join public.staff staff
    on staff.business_id=business.id
   and staff.role='owner'
   and staff.active
   and staff.user_id is not null
  where business.name='V100 campaign truth fixture A';
  select business.id,staff.user_id
  into v_other_business,v_other_owner
  from public.businesses business
  join public.staff staff
    on staff.business_id=business.id
   and staff.role='owner'
   and staff.active
   and staff.user_id is not null
  where business.name='V100 campaign truth fixture B';
  select branch.id into v_branch
  from public.branches branch
  where branch.business_id=v_business and branch.active
  order by branch.is_default desc,branch.created_at,branch.id
  limit 1;
  if v_business is null or v_other_business is null or v_branch is null then
    raise exception 'v99/v100 suite requires pristine tenants and branch';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',
    v_outsider,'authenticated','authenticated',
    'v100-outsider-'||substr(v_outsider::text,1,8)||'@example.test',
    '',now(),now(),now()
  );

  -- Client events say only that an interaction was accepted. Exact replay
  -- returns the same row; a changed envelope under the same key conflicts.
  perform pg_temp.as_v100_user(v_owner);
  v_result:=public.record_product_interaction_v100(
    'merchant.workspace_viewed',v_business,null,v_session,
    v_interaction_key,v_interaction_at,
    jsonb_build_object('entry_point','signed_in')
  );
  v_event_id:=(v_result->>'event_id')::uuid;
  if (v_result->>'replayed')::boolean
     or (v_result->>'business_outcome_asserted')::boolean
     or v_result->>'recording_status'<>'accepted_interaction_only' then
    raise exception 'first client interaction response overclaims: %',v_result;
  end if;
  v_replay:=public.record_product_interaction_v100(
    'merchant.workspace_viewed',v_business,null,v_session,
    v_interaction_key,v_interaction_at,
    jsonb_build_object('entry_point','signed_in')
  );
  if not (v_replay->>'replayed')::boolean
     or (v_replay->>'event_id')::uuid<>v_event_id then
    raise exception 'client interaction exact replay was not idempotent';
  end if;
  begin
    perform public.record_product_interaction_v100(
      'merchant.grow_opened',v_business,null,v_session,
      v_interaction_key,v_interaction_at,
      jsonb_build_object('entry_point','signed_in')
    );
    raise exception 'changed client event envelope unexpectedly replayed';
  exception when unique_violation then null;
  end;
  perform pg_temp.as_v100_user(v_outsider);
  begin
    perform public.record_product_interaction_v100(
      'merchant.workspace_viewed',v_business,null,gen_random_uuid(),
      'v100-outsider-workspace',clock_timestamp(),'{}'::jsonb
    );
    raise exception 'outsider recorded a merchant interaction';
  exception when insufficient_privilege then null;
  end;

  -- Publish a small versioned retention rule, then freeze a deterministic
  -- audience. All test writes remain inside this rollback-only transaction.
  reset role;
  select active_config_version_id into v_base
  from public.businesses where id=v_business;
  select taxonomy.id into v_taxonomy
  from public.firm_reward_taxonomy taxonomy
  where taxonomy.business_id=v_business
    and taxonomy.fulfillment_kind='credit'
    and taxonomy.active
  order by taxonomy.sort,taxonomy.id
  limit 1;
  perform pg_temp.as_v100_user(v_owner);
  v_draft:=(
    public.create_loyalty_config_draft(
      v_business,v_base,'v99-campaign-truth-test'
    )::jsonb->>'version_id'
  )::uuid;
  reset role;
  select snapshot_hash into v_snapshot_hash
  from public.firm_config_versions where id=v_draft;
  perform pg_temp.as_v100_user(v_owner);
  perform public.save_retention_program_draft(
    v_draft,v_program,
    jsonb_build_object(
      'name','V99 truth rule','active',true,'goal_visits',1,
      'period_days',30,'starts_on',current_date,
      'reward_taxonomy_id',v_taxonomy,'credit_cents',500,'sort',10
    ),
    v_snapshot_hash
  );
  perform public.publish_loyalty_config(v_draft);
  reset role;
  select version_row.id into v_program_version
  from public.retention_program_versions version_row
  where version_row.program_id=v_program
    and version_row.config_version_id=v_draft
    and version_row.business_id=v_business;

  for i in 1..24 loop
    insert into public.clients(business_id,full_name)
    values(v_business,'V99 audience '||i)
    returning id into v_client;
    v_clients:=v_clients||v_client;
  end loop;
  perform pg_temp.as_v100_user(v_owner);
  v_campaign:=(
    public.create_retention_campaign(
      v_business,v_program_version,'V99 exposure truth',
      jsonb_build_object('segment','rollback_fixture'),
      50,0,30,null,null,'Rollback-only campaign truth fixture.'
    )::jsonb->>'campaign_id'
  )::uuid;
  perform public.activate_retention_campaign(
    v_business,v_campaign,v_clients,'v99-activate-fixture'
  );
  reset role;
  select array_agg(member.client_id order by member.client_id)
  into v_treatment
  from public.retention_campaign_members member
  where member.campaign_id=v_campaign
    and member.assignment='treatment';
  v_wrong_client:=v_treatment[2];
  if v_wrong_client is null then
    raise exception 'v99 suite requires at least two treatment members';
  end if;
  reset role;
  select business.slug into v_business_slug
  from public.businesses business
  where business.id=v_business;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',
    v_customer_user,'authenticated','authenticated',
    'v99-customer-'||substr(v_customer_user::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.customer_identities(id,auth_user_id)
  values(v_customer_identity,v_customer_user);
  perform set_config(
    'app.customer_link_insert_id',v_customer_link::text,true
  );
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_customer_link,v_business,v_customer_identity,v_customer_user,
    v_wrong_client,'verified','firm_invitation',clock_timestamp()
  );
  perform set_config('app.customer_link_insert_id','',true);
  update app.platform_feature_flags
  set enabled=true
  where feature_key='customer_wallet';

  -- A qualifying sale before the final verified exposure is intentionally
  -- outside the sealed common-arm measurement window.
  perform pg_temp.as_v100_user(v_owner);
  perform public.record_quick_sale(
    v_business,1200,'cash',v_treatment[1],v_owner_staff,v_branch,
    'pre-exposure return','v99-pre-exposure-sale',true
  );

  -- The server creates the published treatment entitlement; the browser never
  -- supplies a reward identity. Create another member's entitlement so the
  -- structural cross-customer exposure FK can be exercised below.
  perform pg_temp.as_v100_user(v_owner);
  v_result:=public.issue_campaign_offer(
    v_business,v_campaign,v_wrong_client,'v99-cross-customer-offer'
  )::jsonb;
  v_wrong_reward:=(v_result->>'reward_grant_id')::uuid;
  if v_wrong_reward is null
     or not (v_result->>'customer_history_visible')::boolean
     or (v_result->>'economic_value_posted')::boolean
     or v_result->>'redemption_mode'<>'merchant_fulfilment_pending'
     or v_result->>'exposure_status'<>'awaiting_manual_attestation' then
    raise exception 'server-issued entitlement truth contract is incomplete: %',
      v_result;
  end if;
  v_projection:=(
    select item
    from pg_catalog.jsonb_array_elements(
      public.staff_get_reward_entitlements_v99(
        v_business,v_wrong_client
      )
    ) item
    where item->>'id'=v_wrong_reward::text
    limit 1
  );
  if v_projection is null
     or not (v_projection->>'is_campaign_entitlement')::boolean
     or v_projection->>'entitlement_status'<>'granted'
     or v_projection->>'fulfillment_status'
          <>'merchant_fulfilment_pending'
     or v_projection->>'redemption_mode'
          <>'merchant_fulfilment_pending'
     or (v_projection->>'economic_value_posted')::boolean
     or not (v_projection->>'reward_value_hidden')::boolean
     or v_projection->>'display_label'
          <>'Offer awaiting merchant fulfilment'
     or v_projection->'display_amount_cents'<>'null'::jsonb then
    raise exception
      'staff campaign entitlement projection overclaimed wallet value: %',
      v_projection;
  end if;
  perform pg_temp.as_v100_user(v_customer_user);
  v_projection:=(
    select item
    from pg_catalog.jsonb_array_elements(
      public.customer_get_loyalty_details(
        v_business_slug,pg_catalog.jsonb_build_object('limit',50)
      )->'items'
    ) item
    where item->>'event_type'='campaign_offer_entitlement'
      and item->>'entitlement_status'='granted'
    limit 1
  );
  if v_projection is null
     or not (v_projection->>'is_campaign_entitlement')::boolean
     or v_projection->>'title'<>'Offer awaiting merchant fulfilment'
     or v_projection->>'status'<>'merchant_fulfilment_pending'
     or v_projection->>'fulfillment_status'
          <>'merchant_fulfilment_pending'
     or (v_projection->>'economic_value_posted')::boolean
     or not (v_projection->>'reward_value_hidden')::boolean
     or v_projection->'display_amount_cents'<>'null'::jsonb then
    raise exception
      'customer campaign entitlement projection overclaimed wallet value: %',
      v_projection;
  end if;
  perform pg_temp.as_v100_user(v_owner);

  foreach v_client in array v_treatment loop
    v_index:=v_index+1;
    perform pg_temp.as_v100_user(v_owner);
    v_result:=public.issue_campaign_offer(
      v_business,v_campaign,v_client,'v99-offer-'||v_index
    )::jsonb;
    v_grant:=(v_result->>'campaign_grant_id')::uuid;
    v_reward:=(v_result->>'reward_grant_id')::uuid;
    if v_grant is null or v_reward is null
       or v_result->>'delivery_provider_status'<>'not_configured'
       or (v_result->>'economic_value_posted')::boolean then
      raise exception 'campaign offer issuance overclaimed or lost linkage: %',
        v_result;
    end if;
    if v_index=1 then
      v_first_grant:=v_grant;
      reset role;
      begin
        insert into public.retention_campaign_exposures_v99(
          business_id,campaign_id,client_id,campaign_grant_id,
          reward_grant_id,assignment,channel,evidence_kind,
          evidence_context,exposed_at,recorded_by,idempotency_key,
          request_hash
        ) values(
          v_business,v_campaign,v_client,v_grant,v_wrong_reward,
          'treatment','in_app','manual_confirmation','{}'::jsonb,
          clock_timestamp(),v_owner,'v99-cross-client-proof',
          repeat('a',64)
        );
        raise exception 'another customer entitlement proved exposure';
      exception when foreign_key_violation then null;
      end;
      perform pg_temp.as_v100_user(v_owner);
      begin
        perform public.attest_campaign_exposure_v99(
          v_business,v_campaign,v_grant,'in_app',false,
          'v99-unconfirmed-exposure'
        );
        raise exception 'unconfirmed exposure was accepted';
      exception when invalid_parameter_value then null;
      end;
    end if;
    v_exposed_at:=clock_timestamp();
    v_result:=public.attest_campaign_exposure_v99(
      v_business,v_campaign,v_grant,'in_app',true,
      'v99-exposure-'||v_index,v_exposed_at,
      jsonb_build_object('entry_point','owner_confirmation')
    );
    if not (v_result->>'attested')::boolean
       or v_result->>'attestation_kind'
          <>'merchant_manual_confirmation'
       or v_result->>'exposure_status'<>'verified' then
      raise exception 'manual exposure attestation truth contract failed: %',
        v_result;
    end if;
    if v_index=1 then
      v_first_exposure:=(v_result->>'exposure_id')::uuid;
      v_replay:=public.attest_campaign_exposure_v99(
        v_business,v_campaign,v_grant,'in_app',true,
        'v99-exposure-'||v_index,null,
        jsonb_build_object('entry_point','owner_confirmation')
      );
      if not (v_replay->>'replayed')::boolean
         or (v_replay->>'exposure_id')::uuid<>v_first_exposure then
        raise exception 'campaign exposure exact replay was not idempotent';
      end if;
      begin
        perform public.attest_campaign_exposure_v99(
          v_business,v_campaign,v_grant,'in_app',true,
          'v99-exposure-'||v_index,null,
          jsonb_build_object('entry_point','changed_after_first_write')
        );
        raise exception
          'same-key changed exposure context unexpectedly replayed';
      exception when unique_violation then null;
      end;
      v_replay:=public.attest_campaign_exposure_v99(
        v_business,v_campaign,v_grant,'in_app',true,
        'v99-exposure-recovered-after-reload',null,
        jsonb_build_object('entry_point','owner_confirmation')
      );
      if not (v_replay->>'replayed')::boolean
         or (v_replay->>'exposure_id')::uuid<>v_first_exposure then
        raise exception
          'campaign-grant exposure recovery was not replay-safe';
      end if;
      v_replay:=public.issue_campaign_offer(
        v_business,v_campaign,v_client,'v99-offer-reload-recovery'
      )::jsonb;
      if v_replay->>'exposure_status'<>'verified'
         or (v_replay->>'exposure_id')::uuid<>v_first_exposure then
        raise exception
          'offer replay did not report the existing verified exposure: %',
          v_replay;
      end if;
      begin
        perform public.attest_campaign_exposure_v99(
          v_business,v_campaign,v_grant,'sms',true,
          'v99-exposure-'||v_index,null,
          jsonb_build_object('entry_point','owner_confirmation')
        );
        raise exception 'changed exposure envelope unexpectedly replayed';
      exception when unique_violation then null;
      end;
    end if;
  end loop;

  v_result:=public.seal_campaign_measurement_v99(
    v_business,v_campaign,'v99-seal-fixture',10
  );
  v_replay:=public.seal_campaign_measurement_v99(
    v_business,v_campaign,'v99-seal-fixture',10
  );
  if (v_result->>'replayed')::boolean
     or not (v_replay->>'replayed')::boolean
     or v_result->>'measurement_started_at'
        <>v_replay->>'measurement_started_at' then
    raise exception 'campaign measurement seal replay is not stable';
  end if;
  v_result:=public.record_campaign_returns(v_business,v_campaign)::jsonb;
  if (v_result->>'newly_recorded')::integer<>0
     or (v_result->>'legacy_v50_return_evidence_used')::boolean then
    raise exception 'pre-exposure return leaked into v99 attribution: %',v_result;
  end if;
  v_result:=public.get_campaign_results(v_campaign)::jsonb;
  if v_result->>'measurement_status'<>'collecting'
     or v_result->>'claimability'
        <>'descriptive_observation_not_causal_proof'
     or v_result->'minimum_sample_met' is null
     or v_result->'net_lift_bps'<>'null'::jsonb
     or v_result->'incremental_returns'<>'null'::jsonb
     or (v_result->>'legacy_v50_return_evidence_used')::boolean then
    raise exception 'v99 results made an unsupported causal claim: %',v_result;
  end if;

  -- Server event capture is canonical-row based and replay-safe.
  reset role;
  insert into public.sales(
    id,business_id,client_id,branch_id,staff_id,kind,amount_cents,
    occurred_at,note
  ) values(
    v_sale,v_business,v_treatment[1],v_branch,v_owner_staff,
    'quick_sale',1300,clock_timestamp(),'v100 server event fixture'
  );
  if (
    select count(*)
    from public.product_adoption_events_v100 event_row
    where event_row.event_name='sale.recorded'
      and event_row.source_table='sales'
      and event_row.source_id=v_sale
  )<>1 then
    raise exception 'canonical sale did not produce one server adoption event';
  end if;
  perform app.append_server_adoption_event_v100(
    'sale.recorded',v_business,v_branch,null,'sales',v_sale,'INSERT',
    clock_timestamp()
  );
  if (
    select count(*)
    from public.product_adoption_events_v100 event_row
    where event_row.event_name='sale.recorded'
      and event_row.source_table='sales'
      and event_row.source_id=v_sale
  )<>1 then
    raise exception 'server source replay duplicated adoption evidence';
  end if;

  perform pg_temp.as_v100_user(v_owner);
  v_result:=public.get_product_adoption_summary_v100(
    v_business,clock_timestamp()-interval '1 day',
    clock_timestamp()+interval '1 minute'
  );
  if v_result->>'provider_status'<>'not_configured'
     or (v_result#>>'{privacy_contract,contact_fields_collected}')::boolean
     or jsonb_array_length(v_result->'totals')=0 then
    raise exception 'adoption summary is incomplete or overclaims: %',v_result;
  end if;
  perform pg_temp.as_v100_user(v_other_owner);
  begin
    perform public.get_product_adoption_summary_v100(
      v_business,clock_timestamp()-interval '1 day',clock_timestamp()
    );
    raise exception 'cross-tenant adoption summary unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;

  reset role;
  if to_regnamespace('cron') is not null then
    if not exists(
      select 1 from cron.job
      where jobname='nestly-v100-adoption-retention-daily'
        and schedule='40 19 * * *'
    ) then
      raise exception 'v100 bounded retention cron is missing';
    end if;
  end if;
  raise notice 'v99/v100 campaign truth and adoption suite: ALL PASS';
end
$v99_v100$;

reset role;
rollback;

-- Rollback-only C44 synthetic acceptance suite. It uses disposable identities
-- and rolls all fixtures back. Coverage: self, cross-user, cross-firm, exact
-- delta/zero, no-expiry, ordering bands, provable versus unprovable visits,
-- sensitive/internal/savings omissions, ACL/RLS, bounded cards, and legacy
-- reader preservation.
begin;

create or replace function pg_temp.as_c44_user(p_uid uuid) returns void
language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', 'authenticated'
  )::text, true);
end;
$$;
grant execute on function pg_temp.as_c44_user(uuid) to public;

do $c44_test$
declare
  v_business uuid;
  v_other_business uuid;
  v_slug text;
  v_other_slug text;
  v_owner uuid := gen_random_uuid();
  v_owner_staff uuid;
  v_branch uuid;
  v_customer uuid := gen_random_uuid();
  v_customer_b uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_identity_b uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_client_b uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_link_b uuid := gen_random_uuid();
  v_draft uuid;
  v_taxonomy uuid;
  v_retention_draft uuid;
  v_retention_hash text;
  v_retention_program uuid := gen_random_uuid();
  v_retention_program_tie uuid := gen_random_uuid();
  v_expected_visit_description text;
  v_unprovable_sale uuid;
  v_provable_sale uuid;
  v_sale_result jsonb;
  v_wallet jsonb;
  v_legacy jsonb;
  v_card jsonb;
  v_card_b jsonb;
  v_unexpired integer;
  v_proc regprocedure;
  v_definition text;
  v_visible integer;
  v_name text;
begin
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'c44-owner-'||v_owner::text||'@example.test','',now(),now(),now());
  perform pg_temp.as_c44_user(v_owner);
  v_business := (public.create_business(
    'C44 wallet fixture '||substr(v_owner::text,1,8),
    'c44-wallet-'||substr(v_owner::text,1,8),'test',
    array['dashboard','clients','sales','loyalty','packages','retention']
  )::jsonb->>'id')::uuid;
  v_other_business := (public.create_business(
    'C44 wallet other fixture '||substr(v_owner::text,1,8),
    'c44-wallet-other-'||substr(v_owner::text,1,8),'test',
    array['dashboard','clients','sales','loyalty','packages','retention']
  )::jsonb->>'id')::uuid;
  reset role;
  select b.id, b.slug, s.user_id, s.id
    into v_business, v_slug, v_owner, v_owner_staff
    from public.businesses b
    join public.staff s on s.business_id = b.id
   where b.id = v_business and s.role = 'owner' and s.active and s.user_id = v_owner
   order by s.created_at
   limit 1;
  select b.id, b.slug into v_other_business, v_other_slug
    from public.businesses b where b.id = v_other_business;
  select br.id into v_branch from public.branches br
   where br.business_id=v_business and br.active order by br.is_default desc,br.created_at limit 1;
  if v_business is null or v_other_business is null or v_owner is null or v_owner_staff is null or v_branch is null then
    raise exception 'C44 self-created business fixture is incomplete';
  end if;

  update public.businesses set enabled_modules = array['loyalty','packages'] where id = v_business;
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key in ('customer_wallet','customer_actionable_wallet');

  -- A published fixture makes the exact reward delta observable through the
  -- normal owner APIs; no live customer data or production data is used.
  perform pg_temp.as_c44_user(v_owner);
  v_draft := (public.create_loyalty_config_draft(v_business, null, 'c44-wallet-suite')::jsonb->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft, jsonb_build_object(
    'active', true,
    'kind', 'points',
    'loyalty_model', 'points_tiers',
    'expiry_mode', 'fixed',
    'expiry_days', 10,
    'reward', jsonb_build_object(
      'internal_name', 'C44 internal fixture only',
      'customer_name', 'C44 reward',
      'fulfillment_kind', 'manual_item',
      'cost_points', 50,
      'credit_cents', 0,
      'estimated_cost_cents', 999,
      'active', true
    ),
    'reward_branch_ids', '[]'::jsonb,
    'reward_service_ids', '[]'::jsonb,
    'reward_product_ids', '[]'::jsonb
  ), null);
  perform public.publish_loyalty_config(v_draft);
  reset role;

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
      'c44-a-'||v_customer::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer_b,'authenticated','authenticated',
      'c44-b-'||v_customer_b::text||'@example.test','',now(),now(),now());
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values (v_identity,v_customer,'active','wallet_start'),
         (v_identity_b,v_customer_b,'active','wallet_start');
  insert into public.clients(id,business_id,full_name,email)
  values (v_client,v_business,'C44 customer A','c44-a@example.test'),
         (v_client_b,v_business,'C44 customer B','c44-b@example.test');
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id',v_link_b::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_b,v_business,v_identity_b,v_customer_b,v_client_b,'verified','firm_invitation',now());

  -- 30 points with a batch inside seven days: exact delta is 20, and the
  -- customer-facing balance must never exceed the unexpired batch balance.
  perform pg_temp.as_c44_user(v_owner);
  perform public.adjust_points(v_business,v_client,30,'C44 exact delta fixture');
  reset role;
  -- This is the established v20 rollback-fixture expiry route: it modifies
  -- only synthetic batches inside this transaction and does not disable a
  -- trigger or use session_replication_role.
  update public.points_batches
     set expires_at = statement_timestamp() + interval '2 days'
   where business_id=v_business and client_id=v_client and remaining>0;
  select coalesce(sum(remaining),0)::integer into v_unexpired
    from public.points_batches
   where business_id=v_business and client_id=v_client and remaining>0 and expires_at>statement_timestamp();
  perform pg_temp.as_c44_user(v_customer);
  v_wallet := public.customer_get_actionable_wallet();
  v_card := v_wallet->'cards'->0;
  if (v_card#>>'{loyalty,balance}')::integer <> 30
     or (v_card#>>'{loyalty,balance}')::integer > v_unexpired
     or (v_card#>>'{expiry,expiring_within_7_days}')::integer <> 30
     or (v_card#>>'{next_eligible_reward,cost_units}')::integer <> 50
     or (v_card#>>'{next_eligible_reward,remaining_units}')::integer <> 20
     or coalesce((v_card#>>'{next_eligible_reward,available_now}')::boolean,true)
     or v_card#>>'{action,reason}' <> 'expiring_within_7_days' then
    raise exception 'C44 self exact delta/expiry ordering fixture failed: %', v_card;
  end if;
  v_legacy := public.customer_get_wallet();
  if jsonb_array_length(v_legacy) <> 1
     or (v_legacy#>>'{0,loyalty,balance}')::integer <> 30 then
    raise exception 'C44 changed the legacy customer_get_wallet reader: %',v_legacy;
  end if;

  -- A transient ledger/batch mismatch must never advertise raw batch expiry
  -- that cannot be spent. The projection caps expiry by the FEFO allocation
  -- of the proven balance, then emits no expiry date after that allocation is
  -- zero. These direct batch edits are synthetic rollback-only fault fixtures.
  reset role;
  update public.points_batches set remaining=10
   where business_id=v_business and client_id=v_client and remaining>0;
  perform pg_temp.as_c44_user(v_customer);
  v_card := public.customer_get_actionable_business(v_slug)->'card';
  if (v_card#>>'{loyalty,balance}')::integer <> 10
     or (v_card#>>'{expiry,expiring_within_7_days}')::integer <> 10
     or (v_card#>>'{expiry,expiring_units}')::integer <> 10
     or (v_card->'expiry'->'next_expiry_at') = 'null'::jsonb then
    raise exception 'C44 ledger/batch mismatch did not cap expiry by actionable balance: %', v_card;
  end if;
  reset role;
  update public.points_batches set remaining=0
   where business_id=v_business and client_id=v_client and remaining>0;
  perform pg_temp.as_c44_user(v_customer);
  v_card := public.customer_get_actionable_business(v_slug)->'card';
  if (v_card#>>'{loyalty,balance}')::integer <> 0
     or (v_card#>>'{expiry,expiring_within_7_days}')::integer <> 0
     or (v_card#>>'{expiry,expiring_units}')::integer <> 0
     or (v_card->'expiry'->'next_expiry_at') <> 'null'::jsonb then
    raise exception 'C44 zero-balance expiry fixture returned units or a date: %', v_card;
  end if;
  reset role;
  update public.points_batches set remaining=earned
   where business_id=v_business and client_id=v_client;

  -- A 14-day synthetic batch is the behavioural 30-day ordering band: it
  -- cannot be represented as a seven-day warning.
  reset role;
  update public.points_batches
     set expires_at = statement_timestamp() + interval '14 days'
   where business_id=v_business and client_id=v_client and remaining>0;
  perform pg_temp.as_c44_user(v_customer);
  v_card := public.customer_get_actionable_business(v_slug)->'card';
  if v_card#>>'{action,reason}' <> 'expiring_within_30_days'
     or (v_card#>>'{expiry,expiring_within_7_days}')::integer <> 0
     or (v_card#>>'{expiry,expiring_units}')::integer <> 30 then
    raise exception 'C44 30-day ordering band fixture failed: %', v_card;
  end if;

  -- Build one active current-window rule. Before a true snapshot visit, an
  -- unprovable sale (counts_as_visit=false) must leave the exact remaining
  -- visit count unchanged. Then a true snapshot visit reduces it by one.
  reset role;
  perform pg_temp.as_c44_user(v_owner);
  select id into v_taxonomy from public.firm_reward_taxonomy
   where business_id=v_business and fulfillment_kind='free_item' and active
   order by sort,id limit 1;
  if v_taxonomy is null then
    v_taxonomy := (public.save_reward_taxonomy(v_business,null,jsonb_build_object(
      'label','C44 fixture return type','fulfillment_kind','free_item','active',true,'sort',9000))->>'id')::uuid;
  end if;
  v_retention_draft := (public.create_loyalty_config_draft(v_business,null,'c44-retention-fixture')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_retention_hash from public.firm_config_versions where id=v_retention_draft;
  v_retention_hash := (public.save_retention_program_draft(v_retention_draft,v_retention_program,jsonb_build_object(
    'name','C44 return visit','active',true,'goal_visits',2,'period_days',30,
    'starts_on',current_date,'reward_taxonomy_id',v_taxonomy,'manual_item','C44 visit reward',
    'sort',0,'customer_description','Return once more for your C44 reward'
  ),v_retention_hash)::jsonb->>'snapshot_hash');
  perform public.save_retention_program_draft(v_retention_draft,v_retention_program_tie,jsonb_build_object(
    'name','C44 return visit','active',true,'goal_visits',2,'period_days',30,
    'starts_on',current_date,'reward_taxonomy_id',v_taxonomy,'manual_item','C44 visit reward',
    'sort',0,'customer_description','C44 deterministic tie B'
  ),v_retention_hash);
  reset role;
  -- Published retention versions are intentionally immutable. Narrow the
  -- cloned rules while this configuration is still a draft, then publish it.
  update public.retention_program_versions set active=false
   where business_id=v_business and config_version_id=v_retention_draft
     and program_id not in (v_retention_program,v_retention_program_tie);
  v_expected_visit_description := case when v_retention_program < v_retention_program_tie
    then 'Return once more for your C44 reward' else 'C44 deterministic tie B' end;
  perform pg_temp.as_c44_user(v_owner);
  perform public.publish_loyalty_config(v_retention_draft);
  perform pg_temp.as_c44_user(v_owner);
  perform public.set_sale_policy(v_business,'quick_sale',true,false,false,
    'C44 synthetic unprovable visit snapshot');
  v_sale_result := public.record_quick_sale(v_business,100,'cash',v_client,v_owner_staff,v_branch,
    'C44 unprovable sale','c44-unprovable-sale',true)::jsonb;
  v_unprovable_sale := (v_sale_result#>>'{sale,id}')::uuid;
  reset role;
  if v_unprovable_sale is null
     or coalesce((select counts_as_visit from public.sales where id=v_unprovable_sale),true) then
    raise exception 'C44 unprovable fixture did not persist counts_as_visit=false; policy=%, sale=%',
      (select row_to_json(p) from app.sale_policy(v_business,'quick_sale') p),
      (select row_to_json(s) from public.sales s where s.id=v_unprovable_sale);
  end if;
  perform pg_temp.as_c44_user(v_customer);
  v_card := public.customer_get_actionable_business(v_slug)->'card';
  if (v_card->'visit_progress'->>'remaining')::integer <> 2
     or v_card#>>'{visit_progress,customer_description}' <> v_expected_visit_description then
    raise exception 'C44 unprovable sale was incorrectly counted as a visit: %',v_card;
  end if;
  perform pg_temp.as_c44_user(v_owner);
  perform public.set_sale_policy(v_business,'quick_sale',true,true,false,
    'C44 synthetic provable visit snapshot');
  v_sale_result := public.record_quick_sale(v_business,100,'cash',v_client,v_owner_staff,v_branch,
    'C44 provable visit','c44-provable-sale',true)::jsonb;
  v_provable_sale := (v_sale_result#>>'{sale,id}')::uuid;
  reset role;
  if v_provable_sale is null
     or not coalesce((select counts_as_visit from public.sales where id=v_provable_sale),false) then
    raise exception 'C44 provable fixture did not persist counts_as_visit=true';
  end if;
  reset role;
  update public.loyalty_programs set expiry_mode='none' where business_id=v_business;
  perform pg_temp.as_c44_user(v_customer);
  v_card := public.customer_get_actionable_business(v_slug)->'card';
  if (v_card->'visit_progress'->>'remaining')::integer <> 1
     or v_card#>>'{visit_progress,customer_description}' <> v_expected_visit_description
     or v_card#>>'{action,reason}' <> 'one_qualifying_visit_remaining' then
    raise exception 'C44 provable visit/current-window action fixture failed: %',v_card;
  end if;

  -- The same business, second customer is the cross-user control: the shared
  -- published catalogue remains visible, but it cannot inherit A's balance,
  -- expiry batch, redemption state, or visit progress. B's exact delta is 50.
  perform pg_temp.as_c44_user(v_customer_b);
  v_card_b := public.customer_get_actionable_business(v_slug)->'card';
  if (v_card_b#>>'{loyalty,balance}')::integer <> 0
     or (v_card_b#>>'{next_eligible_reward,cost_units}')::integer <> 50
     or (v_card_b#>>'{next_eligible_reward,remaining_units}')::integer <> 50
     or coalesce((v_card_b#>>'{next_eligible_reward,available_now}')::boolean,true)
     or (v_card_b#>>'{expiry,expiring_units}')::integer <> 0
     or (v_card_b->'expiry'->'next_expiry_at') <> 'null'::jsonb then
    raise exception 'C44 cross-user wallet data leaked: %', v_card_b;
  end if;

  perform pg_temp.as_c44_user(v_customer);
  begin
    perform public.customer_get_actionable_business(v_other_slug);
    raise exception 'C44 cross-firm reader accepted an unlinked business';
  exception when insufficient_privilege then null;
  end;

  -- Zero means available now exactly, rather than a guessed monetary benefit.
  reset role;
  perform pg_temp.as_c44_user(v_owner);
  perform public.adjust_points(v_business,v_client,20,'C44 exact zero fixture');
  perform pg_temp.as_c44_user(v_customer);
  v_card := public.customer_get_actionable_business(v_slug)->'card';
  if (v_card#>>'{next_eligible_reward,remaining_units}')::integer <> 0
     or coalesce((v_card#>>'{next_eligible_reward,available_now}')::boolean,false) is not true then
    raise exception 'C44 zero/available-now fixture failed: %', v_card;
  end if;

  -- No-expiry must have no date or expiring units even if an old batch still
  -- carries a timestamp. This is presentation truth, not a batch rewrite.
  reset role;
  update public.loyalty_programs set expiry_mode='none' where business_id=v_business;
  perform pg_temp.as_c44_user(v_customer);
  v_card := public.customer_get_actionable_business(v_slug)->'card';
  if v_card#>>'{expiry,mode}' <> 'none'
     or (v_card#>>'{expiry,expiring_units}')::integer <> 0
     or (v_card->'expiry'->'next_expiry_at') <> 'null'::jsonb then
    raise exception 'C44 no-expiry contract returned a date or units: %', v_card;
  end if;

  -- A visit is provable only from an active, version-locked current-window
  -- sales snapshot with counts_as_visit. Points, stamps, spending and an
  -- unprovable legacy transaction must not fabricate a visit promise.
  reset role;
  -- C45 decorates the C44 projection and retains the reviewed C44 body under
  -- this private base name. Inspect whichever implementation is authoritative
  -- for the installed chain.
  v_proc := coalesce(
    to_regprocedure('app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamp with time zone)'),
    to_regprocedure('app.c44_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamp with time zone)')
  );
  v_definition := pg_get_functiondef(v_proc);
  if v_definition !~* 'retention_program_versions'
     or v_definition !~* 'config_version_id = b.active_config_version_id'
     or v_definition !~* 's\.counts_as_visit'
     or v_definition ~* 's\.earns_points|earn_points_per_dollar|stamp_per_cents' then
    raise exception 'C44 provable/unprovable visit contract drifted';
  end if;

  -- The reviewed response is a customer-safe allowlist; sensitive identity,
  -- internal/economic fields and savings claims never escape the RPC.
  perform pg_temp.as_c44_user(v_customer);
  v_wallet := public.customer_get_actionable_wallet();
  if v_wallet::text ~* '"(business_id|client_id|identity_id|auth_user_id|email|phone|birth_date|dob|internal_name|estimated_cost_cents|credit_cents|discount_percent|savings|cash_value|retail_value)"' then
    raise exception 'C44 sensitive/internal/savings output leaked: %', v_wallet;
  end if;

  -- Direct table access remains denied by ACL or returns no rows under RLS;
  -- the authenticated browser may use only the narrow self-scoped RPCs.
  foreach v_name in array array['points_ledger','points_batches','credit_ledger','client_packages','loyalty_reward_versions','retention_program_versions'] loop
    v_visible := 0;
    begin
      execute format('select count(*) from public.%I where business_id=$1',v_name)
        into v_visible using v_business;
      if v_visible <> 0 then raise exception 'C44 RLS exposed % raw rows from %',v_visible,v_name; end if;
    exception when insufficient_privilege then null;
    end;
  end loop;
  reset role;
  foreach v_name in array array['customer_get_actionable_wallet()','customer_get_actionable_business(text)'] loop
    v_proc := to_regprocedure('public.'||v_name);
    if v_proc is null
       or has_function_privilege('anon',v_proc,'execute')
       or not has_function_privilege('authenticated',v_proc,'execute') then
      raise exception 'C44 ACL mismatch for %',v_name;
    end if;
  end loop;
  v_definition := pg_get_functiondef('public.customer_get_actionable_wallet()'::regprocedure);
  if v_definition !~* 'action_rank <= 101'
     or v_definition !~* 'action_rank <= 100'
     or v_definition ~* 'source_rank|context[^;]{0,240}limit 101'
     or v_definition !~* 'truncated' then
    raise exception 'C44 value-first bounded card response contract drifted';
  end if;
  if to_regprocedure('public.customer_get_wallet()') is null
     or to_regprocedure('public.customer_get_business_summary(text)') is null then
    raise exception 'C44 must preserve legacy wallet readers';
  end if;

  raise notice 'C44 actionable customer wallet suite: ALL PASS';
end $c44_test$;

rollback;

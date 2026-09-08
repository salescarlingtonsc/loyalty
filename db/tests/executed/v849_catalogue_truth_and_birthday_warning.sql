-- EXECUTED acceptance fixture for nestly_v849
-- (db/migrations/20261008_nestly_v849_catalogue_truth_and_birthday_warning.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v849
--
-- WHY THIS EXISTS — two surfaces that reported success while the machinery behind them refused.
--
-- (A) THE CATALOGUE ADVERTISED A GIFT NO PATH CAN CLAIM. A reward restricted to a branch, a
--     service or a product came back from public.customer_get_reward_catalog as
--     availability='available_at_counter', claim_method='counter', quantity=1. Measured on
--     production 2026-09-08 in a rolled-back probe, for a service-scoped gift:
--        available_at_counter | claim_method=counter | services {"count":1,"scope":"restricted"}
--     while, for the very same gift and the very same customer, in the same probe:
--        staff_manual_redeem_reward_v404       -> P0001 reward not eligible for service
--        customer_create_redemption_intent_v89 -> 22023 context-restricted rewards require
--                                                 staff-assisted redemption
--        app.customer_ready_reward_count_v465  -> {"count": 1, "choose_one": false} -- that 1 is
--            the OTHER, unrestricted gift the same probe published; the scoped gift is not
--            counted, while the catalogue advertised both as available
--        staff_get_customer_actionable_loyalty_v145 -> listed the unrestricted gift only; the
--            scoped gift was absent, so no staff member could have redeemed it either
--     T1-T2 below are that measurement, inverted: they FAIL against the pre-v849 catalogue.
--
-- (B) A BUSINESS COULD PUBLISH A BIRTHDAY GIFT THE PLATFORM WILL NEVER DELIVER.
--     app.platform_feature_enabled('customer_birthday_benefits') has been false since
--     2026-07-22 and every customer- and staff-facing birthday RPC refuses on it, but the
--     business-side pair said nothing. Measured on production 2026-09-08, same probe style:
--        business_save_birthday_program_v424 ->
--          {"status":"published","replayed":false,"program_id":"...","version_id":"..."}
--        get_active_birthday_program        -> top-level keys: as_of, programs, status
--        the published programme's `active`  -> true
--        the string 'birthday_benefits' anywhere in either payload -> NO
--     Four tenants are live on exactly that state. T10-T14 are that measurement, inverted.
--     The advisory has to be a fact about TODAY on every path, replays included, which is what
--     T19 pins: birthday_program_versions rows are cloned forward on every publish, so the
--     config version frozen in a save receipt is a historical snapshot. Counted on production
--     2026-09-08: four of the seven rows in birthday_program_save_operations_v424 already sit on
--     a stale version, and one of them is frozen at active=false while that firm's live row says
--     active=true.
--
-- ASSERTIONS (rows, with a fatal gate at the end):
--   T1   a service-scoped gift is no longer called 'available_at_counter'   <- the (A) before-probe
--   T2   ...it is 'context_restricted', claim_method 'unavailable', quantity 0
--   T3   ...and the eligibility block the customer reads is untouched (restricted, count 1)
--   T4   the counter really would refuse it: staff_manual_redeem_reward_v404 raises
--        'reward not eligible for service'
--   T5   ...and so does customer_create_redemption_intent_v89
--   T6   ...and the staff redeem list (staff_get_customer_actionable_loyalty_v145) never
--        offered it, which is why there was no staff-assisted path to fall back on
--   T7   an UNRESTRICTED gift is untouched: 'available_at_counter', 'counter', quantity 1
--   T8   the catalogue and app.customer_ready_reward_count_v465 now agree on what is claimable
--   T9   a BRANCH-scoped gift is marked too -- app.redeem_reward_core would accept a matching
--        branch, but no surface ever lists such a gift for a staff member to redeem
--   T10  birthday, delivery OFF: the save reports platform_delivery.platform_enabled = false
--        and exactly one warning coded 'birthday_delivery_disabled'
--   T11  ...and that advisory is NOT frozen into birthday_program_save_operations_v424.result
--   T12  ...and an IMMEDIATE replay of the same idempotency key still replays AND still advises
--   T13  get_active_birthday_program's published path reports the same platform state and
--        carries the save's advisory worded identically (the sentence is a separate literal in
--        each function; this equality is what stops the two copies drifting)
--   T14  ...and so does its 'unavailable' path (a firm with no active config version), with an
--        empty warnings array rather than an absent one
--   T15  delivery ON: the same save reports platform_enabled = true and warns about nothing
--   T16  ...and the platform switch is the ONLY thing that stood in the way: the staff birthday
--        reader raised 0A000 'birthday benefit unavailable' before the flip and answers after it,
--        while the stored programme row is byte-identical across the flip. It does NOT claim a
--        customer is handed a gift: with no entitlement row for this fixture's client the reader
--        answers {"status":"unavailable"} -- a per-customer state, not the platform gate.
--   T17  an INACTIVE birthday programme published while delivery is off is NOT warned about:
--        the warning is about a promise being made, not about the switch in general
--   T18  the publish contract itself is unchanged: status 'published', and the row is live on
--        the firm's active config version
--   T19  a DELAYED replay -- the original key, replayed after two further publishes, the second
--        of which switched the programme off -- answers about the programme as it stands NOW and
--        does not warn about a gift the firm has already withdrawn. T12 cannot catch this: it
--        replays immediately, with nothing in between, so the frozen version and the live one
--        are the same row and the two readings cannot disagree.
--
-- MUTATION CHECK (measured 2026-09-08, not assumed -- each reversion was applied to a scratch
-- cluster that already had v849 and this file was re-run against it):
--   * revert the availability splice in public.customer_get_reward_catalog (back to
--     `'availability', core.availability,`)                -> T1, T2, T8, T9 FAIL (4 assertions)
--   * revert both advisory payloads in business_save_birthday_program_v424
--                                          -> T10, T12, T13, T15, T17, T19 FAIL (6). T13 appears
--     here as well as in the next group because it compares the READER's sentence against the
--     SAVE's; with no advisory on either side there is nothing left to compare.
--   * revert both additions to get_active_birthday_program -> T13, T14 FAIL (2)
--   * revert ONLY the replay path's resolution of the programme, so that it reads the config
--     version frozen in the receipt again -- the defect T19 exists for
--                                                          -> T19 FAILS, and nothing else (1).
--     T12 still passes, which is precisely why T19 had to be written: replaying immediately
--     cannot tell a frozen snapshot from the live one.
--   * restore everything                                   -> 19/19 PASS
--   * and the whole-file case, which is the one the harness actually reproduces: build the
--     migrated cluster with db/migrations/20261008_nestly_v849_*.sql withheld and this suite
--     fails with exactly 11 assertions -- T1, T2, T8, T9, T10, T12, T13, T14, T15, T17, T19 --
--     the union of the groups above, and nothing else.
-- No assertion here can pass on a no-op.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table v849_out(seq integer, step text, outcome text, detail text) on commit drop;

create or replace function pg_temp.v849_note(
  p_seq integer, p_step text, p_ok boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into v849_out values (p_seq, p_step, case when p_ok then 'PASS' else 'FAIL' end, p_detail);
end
$$;
grant execute on function pg_temp.v849_note(integer,text,boolean,text) to public;

create or replace function pg_temp.v849_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.v849_as(uuid) to public;

do $v849_test$
declare
  v_business uuid; v_slug text; v_branch uuid := gen_random_uuid();
  v_owner_u uuid := gen_random_uuid(); v_owner_s uuid;
  v_customer uuid := gen_random_uuid(); v_identity uuid; v_client uuid;
  v_link uuid := gen_random_uuid();
  v_prog uuid; v_ver uuid; v_service uuid;
  v_free uuid; v_scoped uuid; v_branch_scoped uuid; v_rv uuid;
  v_seed uuid := gen_random_uuid();
  v_out jsonb; v_cat jsonb; v_row_free jsonb; v_row_scoped jsonb; v_row_branch jsonb;
  v_saved jsonb; v_replay jsonb; v_replay_late jsonb; v_read jsonb; v_stored jsonb; v_v145 jsonb;
  v_err text; v_after text; v_claimable integer; v_ready integer;
  v_row_before jsonb; v_row_after jsonb;
  v_empty_biz uuid; v_key text;
begin
  reset role;

  -- ==========================================================================================
  -- FIXTURE: one firm, an owner, a verified customer with 500 points, one published points
  -- programme, and three gifts -- unrestricted, service-scoped, branch-scoped.
  -- ==========================================================================================
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key in ('customer_wallet','customer_identity','customer_claims');
  insert into app.platform_feature_flags(feature_key, enabled, changed_at)
  select k, true, now() from unnest(array['customer_wallet','customer_identity','customer_claims']) k
   where not exists (select 1 from app.platform_feature_flags f where f.feature_key = k);
  -- The switch under test in (B) starts OFF, exactly as production has had it since 2026-07-22.
  insert into app.platform_feature_flags(feature_key, enabled, changed_at)
  values ('customer_birthday_benefits', false, now())
  on conflict (feature_key) do update set enabled = false, changed_at = now();

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(name,slug,industry,is_synthetic,enabled_modules)
  values('v849 acceptance','v849-'||substr(gen_random_uuid()::text,1,8),'test',true,
         array['dashboard','clients','sales','loyalty'])
  returning id, slug into v_business, v_slug;
  insert into public.businesses(name,slug,industry,is_synthetic,enabled_modules)
  values('v849 unconfigured','v849-empty-'||substr(gen_random_uuid()::text,1,8),'test',true,
         array['dashboard','clients','sales','loyalty'])
  returning id into v_empty_biz;
  perform set_config('app.v79_system_transition','',true);

  insert into public.branches(id,business_id,name,is_default,active)
  values(v_branch,v_business,'v849 branch',true,true);
  /* decision_reason is restated in the ON CONFLICT branch: on production public.businesses has an
     AFTER INSERT trigger that seeds this row as 'pending', so the DO UPDATE runs and an approved
     row without a reason violates business_workspace_controls_v94_decision_shape (23514, observed
     2026-09-08). The scratch cluster has no such trigger and takes the INSERT path. */
  insert into public.business_workspace_controls_v94(business_id,approval_status,decided_at,decision_reason)
  values(v_business,'approved',now(),'v849')
  on conflict (business_id) do update set approval_status='approved', decided_at=now(), decision_reason='v849 fixture';
  insert into public.business_subscription_lifecycle_v94(business_id,state,workspace_paused)
  values(v_business,'current',false)
  on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values(v_business,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update set status='active', payment_status='paid';

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_owner_u,'authenticated','authenticated',
    'v849-owner-'||substr(v_owner_u::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  values(v_business,v_owner_u,'owner',true,'approved','v849 owner') returning id into v_owner_s;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_owner_s,v_branch) on conflict do nothing;
  -- The same owner on the second firm, so T14 can read it back as an authorised principal.
  -- The workspace gates matter as much as the staff row: app.can_module_read refuses with 42501
  -- 'loyalty read access required' for a firm with no approval / lifecycle / subscription rows --
  -- observed on production while building the before-probe for this file.
  insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  values(v_empty_biz,v_owner_u,'owner',true,'approved','v849 owner');
  insert into public.branches(business_id,name,is_default,active)
  values(v_empty_biz,'v849 empty branch',true,true);
  /* decision_reason is restated in the ON CONFLICT branch: on production public.businesses has an
     AFTER INSERT trigger that seeds this row as 'pending', so the DO UPDATE runs and an approved
     row without a reason violates business_workspace_controls_v94_decision_shape (23514, observed
     2026-09-08). The scratch cluster has no such trigger and takes the INSERT path. */
  insert into public.business_workspace_controls_v94(business_id,approval_status,decided_at,decision_reason)
  values(v_empty_biz,'approved',now(),'v849')
  on conflict (business_id) do update set approval_status='approved', decided_at=now(), decision_reason='v849 fixture';
  insert into public.business_subscription_lifecycle_v94(business_id,state,workspace_paused)
  values(v_empty_biz,'current',false)
  on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values(v_empty_biz,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update set status='active', payment_status='paid';

  insert into public.loyalty_programs(business_id,kind,active,loyalty_model,
    configuration_status,earn_points_per_dollar)
  values(v_business,'points',true,'classic','published',1);
  select id into v_ver from public.firm_config_versions
   where business_id=v_business and status='published' order by version_no desc limit 1;
  update public.businesses set active_config_version_id=v_ver
   where id=v_business and active_config_version_id is null;
  insert into public.business_programmes(business_id,kind,active,sort,activated_at)
  values(v_business,'points',true,1,now())
  on conflict (business_id,kind) do update set active=true returning id into v_prog;
  insert into public.services(business_id,name,price_cents,duration_min,active)
  values(v_business,'v849 service',1000,30,true) returning id into v_service;

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
    'v849-cust-'||substr(v_customer::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.customer_identities(auth_user_id,status,created_via)
  values(v_customer,'active','phone_registration') returning id into v_identity;
  insert into public.clients(business_id,full_name)
  values(v_business,'v849 customer') returning id into v_client;
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at)
  values(v_link,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id','',true);

  /* The EXCLUSIVE fence, not the shared one a till write takes: this file publishes a birthday
     programme below, and public.publish_loyalty_config calls app.acquire_loyalty_exclusive_v480,
     which refuses to upgrade a fence already held shared (40P01 'unsafe loyalty fence upgrade
     from shared to exclusive'). Same idiom, same reason, as
     db/tests/executed/v814_stamp_gift_pause_version_forward.sql. */
  perform app.acquire_loyalty_exclusive_v480(v_business);
  perform set_config('app.points_ledger_insert_id',v_seed::text,true);
  perform set_config('app.points_ledger_write_scope','adjust_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,
    programme_id,actor)
  values(v_seed,v_business,v_client,'adjust',500,'v849 seed',v_prog,null);
  insert into public.points_batches(business_id,client_id,programme_id,remaining,earned,
    expires_at,earned_at)
  values(v_business,v_client,v_prog,500,500,null,now());
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);

  perform pg_temp.v849_as(v_owner_u); set local role authenticated;
  v_out := public.business_create_reward_v326(v_business, v_prog, 'v849 free gift'::text,
    10, 0, 'v849'::text, null::text, null::timestamptz, null::text, null::integer, null::integer);
  v_free := (v_out->>'reward_id')::uuid;
  v_out := public.business_create_reward_v326(v_business, v_prog, 'v849 service gift'::text,
    10, 0, 'v849'::text, null::text, null::timestamptz, null::text, null::integer, null::integer);
  v_scoped := (v_out->>'reward_id')::uuid;
  v_out := public.business_create_reward_v326(v_business, v_prog, 'v849 branch gift'::text,
    10, 0, 'v849'::text, null::text, null::timestamptz, null::text, null::integer, null::integer);
  v_branch_scoped := (v_out->>'reward_id')::uuid;
  reset role;

  /* The scope rows must sit on the version the catalogue reads, so the firm's ACTIVE config
     version is re-read rather than assumed after three publishing calls. */
  select active_config_version_id into v_ver from public.businesses where id=v_business;
  select id into v_rv from public.loyalty_reward_versions
   where reward_id=v_scoped and business_id=v_business and config_version_id=v_ver;
  insert into public.loyalty_reward_services(reward_version_id,reward_id,business_id,service_id)
  values(v_rv,v_scoped,v_business,v_service);
  select id into v_rv from public.loyalty_reward_versions
   where reward_id=v_branch_scoped and business_id=v_business and config_version_id=v_ver;
  insert into public.loyalty_reward_branches(reward_version_id,reward_id,business_id,branch_id)
  values(v_rv,v_branch_scoped,v_business,v_branch);

  -- ==========================================================================================
  -- (A) THE CATALOGUE
  -- ==========================================================================================
  perform pg_temp.v849_as(v_customer); set local role authenticated;
  v_cat := public.customer_get_reward_catalog(v_slug);
  reset role;
  select value into v_row_free from jsonb_array_elements(v_cat->'rewards') value
   where value->>'customer_name'='v849 free gift' limit 1;
  select value into v_row_scoped from jsonb_array_elements(v_cat->'rewards') value
   where value->>'customer_name'='v849 service gift' limit 1;
  select value into v_row_branch from jsonb_array_elements(v_cat->'rewards') value
   where value->>'customer_name'='v849 branch gift' limit 1;

  perform pg_temp.v849_note(1,
    'T1 a service-scoped gift is not advertised as available at the counter',
    v_row_scoped is not null and v_row_scoped->>'availability' <> 'available_at_counter',
    'availability=' || coalesce(v_row_scoped->>'availability','(row absent)'));

  perform pg_temp.v849_note(2,
    'T2 ...it is context_restricted, claim_method unavailable, quantity 0',
    v_row_scoped->>'availability' = 'context_restricted'
      and v_row_scoped->>'claim_method' = 'unavailable'
      and (v_row_scoped->>'quantity')::integer = 0,
    coalesce(v_row_scoped->>'availability','-') || ' / '
      || coalesce(v_row_scoped->>'claim_method','-') || ' / q='
      || coalesce(v_row_scoped->>'quantity','-'));

  perform pg_temp.v849_note(3,
    'T3 ...and the eligibility block the customer reads is untouched',
    v_row_scoped->'eligibility'->'services'->>'scope' = 'restricted'
      and (v_row_scoped->'eligibility'->'services'->>'count')::integer = 1
      and v_row_scoped->'eligibility'->'branches'->>'scope' = 'all',
    coalesce((v_row_scoped->'eligibility')::text,'-'));

  perform pg_temp.v849_as(v_owner_u); set local role authenticated;
  begin
    perform public.staff_manual_redeem_reward_v404(v_business, v_client, v_scoped, 1, v_branch,
      'customer_unable_to_show_qr', null, 'v849-manual-'||substr(v_business::text,1,8));
    v_err := '(no refusal)';
  exception when others then v_err := sqlstate || ' ' || sqlerrm; end;
  reset role;
  perform pg_temp.v849_note(4,
    'T4 the counter would refuse it: staff_manual_redeem_reward_v404 raises',
    v_err like '%reward not eligible for service%', v_err);

  perform pg_temp.v849_as(v_customer); set local role authenticated;
  begin
    perform public.customer_create_redemption_intent_v89(
      v_business, v_scoped, gen_random_uuid(), 'catalog_reward');
    v_err := '(no refusal)';
  exception when others then v_err := sqlstate || ' ' || sqlerrm; end;
  reset role;
  perform pg_temp.v849_note(5,
    'T5 ...and so does customer_create_redemption_intent_v89',
    v_err like '%context-restricted rewards require staff-assisted redemption%', v_err);

  perform pg_temp.v849_as(v_owner_u); set local role authenticated;
  v_v145 := public.staff_get_customer_actionable_loyalty_v145(v_business, v_client, v_branch);
  reset role;
  perform pg_temp.v849_note(6,
    'T6 ...and the staff redeem list never offered it, so there was no fallback path',
    not exists (select 1 from jsonb_array_elements(coalesce(v_v145->'rewards','[]'::jsonb)) r
                 where r.value->>'reward_id' in (v_scoped::text, v_branch_scoped::text)),
    'staff rewards=' || coalesce(jsonb_array_length(v_v145->'rewards'),-1)::text);

  perform pg_temp.v849_note(7,
    'T7 an unrestricted gift is untouched: available_at_counter, counter, quantity 1',
    v_row_free->>'availability' = 'available_at_counter'
      and v_row_free->>'claim_method' = 'counter'
      and (v_row_free->>'quantity')::integer = 1,
    coalesce(v_row_free->>'availability','-') || ' / '
      || coalesce(v_row_free->>'claim_method','-') || ' / q='
      || coalesce(v_row_free->>'quantity','-'));

  select count(*)::integer into v_claimable
    from jsonb_array_elements(v_cat->'rewards') value
   where value->>'availability' = 'available_at_counter';
  v_ready := (app.customer_ready_reward_count_v465(v_business, v_client, now())->>'count')::integer;
  perform pg_temp.v849_note(8,
    'T8 the catalogue and app.customer_ready_reward_count_v465 agree on what is claimable',
    v_claimable = 1 and v_ready = 1,
    'catalogue claimable=' || v_claimable || ', ready count=' || v_ready);

  perform pg_temp.v849_note(9,
    'T9 a branch-scoped gift is marked too -- no surface ever lists one for a staff member',
    v_row_branch is not null
      and v_row_branch->>'availability' = 'context_restricted'
      and v_row_branch->'eligibility'->'branches'->>'scope' = 'restricted',
    coalesce(v_row_branch->>'availability','(row absent)'));

  -- ==========================================================================================
  -- (B) THE BIRTHDAY PROGRAMME, WITH PLATFORM DELIVERY OFF
  -- ==========================================================================================
  v_key := 'v849-bday-' || substr(v_business::text,1,8);
  perform pg_temp.v849_as(v_owner_u); set local role authenticated;
  v_saved := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
    'active',true,'customer_label','v849 birthday','customer_description','A free slice.',
    'customer_terms','One a year.','fulfillment_kind','free_item','manual_item','Free slice',
    'window_mode','month','window_days_before',0,'window_days_after',0,'sort',0), v_key);
  v_replay := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
    'active',true,'customer_label','v849 birthday','customer_description','A free slice.',
    'customer_terms','One a year.','fulfillment_kind','free_item','manual_item','Free slice',
    'window_mode','month','window_days_before',0,'window_days_after',0,'sort',0), v_key);
  v_read := public.get_active_birthday_program(v_business);
  reset role;

  perform pg_temp.v849_note(10,
    'T10 delivery OFF: the save reports the platform state and warns, exactly once',
    (v_saved->'platform_delivery'->>'platform_enabled')::boolean = false
      and v_saved->'platform_delivery'->>'feature_key' = 'customer_birthday_benefits'
      and jsonb_array_length(coalesce(v_saved->'warnings','[]'::jsonb)) = 1
      and v_saved->'warnings'->0->>'code' = 'birthday_delivery_disabled',
    coalesce((v_saved - 'version_id' - 'program_id')::text,'(null)'));

  select result into v_stored from public.birthday_program_save_operations_v424
   where business_id = v_business and idempotency_key = v_key;
  perform pg_temp.v849_note(11,
    'T11 ...and the live advisory is not frozen into the stored receipt',
    v_stored is not null and not (v_stored ? 'warnings') and not (v_stored ? 'platform_delivery'),
    coalesce(v_stored::text,'(no receipt)'));

  perform pg_temp.v849_note(12,
    'T12 ...and a replay still replays AND still advises',
    (v_replay->>'replayed')::boolean
      and v_replay->>'version_id' = v_saved->>'version_id'
      and (v_replay->'platform_delivery'->>'platform_enabled')::boolean = false
      and v_replay->'warnings'->0->>'code' = 'birthday_delivery_disabled',
    coalesce((v_replay - 'version_id' - 'program_id')::text,'(null)'));

  /* The reader carries the SAME advisory as the save, worded identically. The sentence is a
     separate string literal in each of the two functions -- there is no shared database object
     holding it -- so the equality below is what stops the two copies drifting apart, and it is
     also the promise the client contract makes ("branch on `code`, render `message`; do not
     re-derive the condition in the browser"). */
  perform pg_temp.v849_note(13,
    'T13 get_active_birthday_program''s published path reports the same platform state and '
    'carries the save''s advisory, word for word',
    v_read->>'status' = 'published'
      and (v_read->'platform_delivery'->>'platform_enabled')::boolean = false
      and v_read->'programs'->0->>'active' = 'true'
      and jsonb_array_length(coalesce(v_read->'warnings','[]'::jsonb)) = 1
      and v_read->'warnings'->0->>'code' = 'birthday_delivery_disabled'
      and v_read->'warnings'->0->>'message' is not null
      and v_read->'warnings'->0->>'message' = v_saved->'warnings'->0->>'message',
    'status=' || coalesce(v_read->>'status','-') || ' delivery='
      || coalesce((v_read->'platform_delivery')::text,'(absent)') || ' warnings='
      || coalesce((v_read->'warnings')::text,'(absent)'));

  perform pg_temp.v849_as(v_owner_u); set local role authenticated;
  v_out := public.get_active_birthday_program(v_empty_biz);
  reset role;
  perform pg_temp.v849_note(14,
    'T14 ...and so does its unavailable path (a firm with no active config version), with an '
    'empty warnings array rather than an absent one',
    v_out->>'status' = 'unavailable'
      and (v_out->'platform_delivery'->>'platform_enabled')::boolean = false
      and v_out ? 'warnings'
      and jsonb_array_length(v_out->'warnings') = 0,
    coalesce(v_out::text,'(null)'));

  perform pg_temp.v849_note(18,
    'T18 the publish contract is unchanged: published, active, on the live config version',
    v_saved->>'status' = 'published'
      and exists (select 1 from public.birthday_program_versions bpv
                   join public.businesses b on b.id = bpv.business_id
                    and b.active_config_version_id = bpv.config_version_id
                  where bpv.business_id = v_business and bpv.active),
    'status=' || coalesce(v_saved->>'status','-'));

  -- The staff birthday reader, with delivery OFF: this is the refusal the business was never
  -- told about.
  perform pg_temp.v849_as(v_owner_u); set local role authenticated;
  begin
    perform public.staff_get_customer_birthday_benefit(v_business, v_client);
    v_err := '(no refusal)';
  exception when others then v_err := sqlstate || ' ' || sqlerrm; end;
  reset role;

  /* The stored programme exactly as it stands with delivery OFF. Captured so T16 can prove the
     claim this migration rests on for the four live tenants: switching the platform on changes
     NOTHING about the row they already hold -- only the gate in front of it. */
  select to_jsonb(bpv.*) into v_row_before
    from public.birthday_program_versions bpv
    join public.businesses b on b.id = bpv.business_id
     and b.active_config_version_id = bpv.config_version_id
   where bpv.business_id = v_business and bpv.active;

  -- ==========================================================================================
  -- (B) THE SAME ROWS, WITH PLATFORM DELIVERY SWITCHED ON. Nothing about the published
  -- programme changes -- only the platform switch does.
  -- ==========================================================================================
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key = 'customer_birthday_benefits';

  select to_jsonb(bpv.*) into v_row_after
    from public.birthday_program_versions bpv
    join public.businesses b on b.id = bpv.business_id
     and b.active_config_version_id = bpv.config_version_id
   where bpv.business_id = v_business and bpv.active;

  perform pg_temp.v849_as(v_owner_u); set local role authenticated;
  v_out := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
    'program_id',(v_saved->>'program_id')::uuid,
    'active',true,'customer_label','v849 birthday','customer_description','A free slice.',
    'customer_terms','One a year.','fulfillment_kind','free_item','manual_item','Free slice',
    'window_mode','month','window_days_before',0,'window_days_after',0,'sort',0),
    v_key || '-on');
  reset role;
  perform pg_temp.v849_note(15,
    'T15 delivery ON: the same save reports platform_enabled true and warns about nothing',
    (v_out->'platform_delivery'->>'platform_enabled')::boolean = true
      and jsonb_array_length(coalesce(v_out->'warnings','[]'::jsonb)) = 0,
    coalesce((v_out - 'version_id' - 'program_id')::text,'(null)'));

  /* The outcome is captured under the authenticated role and RECORDED after `reset role`:
     pg_temp.v849_note is not SECURITY DEFINER, so calling it while the role is still
     `authenticated` fails with 'permission denied for table v849_out' -- observed here before
     this was split. */
  perform pg_temp.v849_as(v_owner_u); set local role authenticated;
  begin
    v_stored := coalesce(public.staff_get_customer_birthday_benefit(v_business, v_client),'{}'::jsonb);
    v_after := 'answered ' || v_stored::text;
  exception when others then
    v_after := 'still refuses: ' || sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  /* What this proves, stated exactly: the PLATFORM refusal is what stood in the way. The staff
     reader raised 0A000 'birthday benefit unavailable' before the switch and stops raising after
     it, while the stored programme row is byte-identical across the flip. It does NOT prove a
     customer is handed a gift -- with no entitlement row for this fixture's client the reader
     answers {"status":"unavailable"}, which is a per-customer state, not the platform gate. */
  perform pg_temp.v849_note(16,
    'T16 ...the platform switch was the only thing in the way: the staff reader raised 0A000 '
    'before it, answers after it, and the stored programme row is unchanged across the flip',
    v_err like '0A000%' and v_after like 'answered %'
      and v_row_before is not null
      and v_row_after is not distinct from v_row_before,
    'before: ' || v_err || ' | after: ' || v_after || ' | stored row unchanged: '
      || (v_row_before is not null and v_row_after is not distinct from v_row_before)::text);

  -- ==========================================================================================
  -- T17 · an INACTIVE programme published while delivery is off is not warned about.
  -- ==========================================================================================
  update app.platform_feature_flags set enabled = false, changed_at = now()
   where feature_key = 'customer_birthday_benefits';
  perform pg_temp.v849_as(v_owner_u); set local role authenticated;
  v_out := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
    'program_id',(v_saved->>'program_id')::uuid,
    'active',false,'customer_label','v849 birthday','customer_description','A free slice.',
    'customer_terms','One a year.','fulfillment_kind','free_item','manual_item','Free slice',
    'window_mode','month','window_days_before',0,'window_days_after',0,'sort',0),
    v_key || '-off');
  reset role;
  perform pg_temp.v849_note(17,
    'T17 a paused birthday programme published while delivery is off is not warned about',
    (v_out->'platform_delivery'->>'platform_enabled')::boolean = false
      and jsonb_array_length(coalesce(v_out->'warnings','[]'::jsonb)) = 0,
    coalesce((v_out - 'version_id' - 'program_id')::text,'(null)'));

  -- ==========================================================================================
  -- T19 · A DELAYED REPLAY ANSWERS ABOUT TODAY, NOT ABOUT THE VERSION FROZEN IN THE RECEIPT.
  --
  -- DO NOT DELETE THIS AS A DUPLICATE OF T12. T12 replays the key immediately, with nothing in
  -- between, so the receipt's config version IS still the firm's live one and a reader that
  -- quotes the frozen snapshot and a reader that resolves the live version cannot disagree.
  -- This one replays the ORIGINAL key of the very first save AFTER two further publishes -- the
  -- '-on' save and the '-off' save above -- and the second of those switched the programme off.
  -- Because public.birthday_program_versions rows are cloned forward on EVERY publish, the
  -- receipt now points at a historical row that still says active=true while the firm's live row
  -- says active=false. A replay judged by the frozen row would warn that an undeliverable gift
  -- is published, about a gift the firm has already withdrawn.
  --
  -- This is not hypothetical. Counted on production 2026-09-08: kopi-tiam-tyeh holds 20 birthday
  -- rows across 20 distinct config versions with exactly one on its live version; four of the
  -- seven rows in birthday_program_save_operations_v424 already sit on a stale version, and one
  -- of them (key 5ff4f850..., saved 2026-08-25) is frozen at active=false while that firm's live
  -- row says active=true -- the same divergence in the other direction, which would have kept a
  -- replay SILENT about a live, undeliverable gift.
  -- ==========================================================================================
  perform pg_temp.v849_as(v_owner_u); set local role authenticated;
  /* Byte-identical payload and key to the very first save, or the 40001 key-reuse refusal fires
     instead of a replay. */
  v_replay_late := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
    'active',true,'customer_label','v849 birthday','customer_description','A free slice.',
    'customer_terms','One a year.','fulfillment_kind','free_item','manual_item','Free slice',
    'window_mode','month','window_days_before',0,'window_days_after',0,'sort',0), v_key);
  reset role;
  perform pg_temp.v849_note(19,
    'T19 a replay after an intervening publish answers about the programme as it stands NOW: '
    'still a replay, still reports the platform state, and does not warn about a gift the firm '
    'has since switched off',
    (v_replay_late->>'replayed')::boolean
      and v_replay_late->>'version_id' = v_saved->>'version_id'
      and v_replay_late->>'program_id' = v_saved->>'program_id'
      and (v_replay_late->'platform_delivery'->>'platform_enabled')::boolean = false
      and jsonb_array_length(coalesce(v_replay_late->'warnings','[]'::jsonb)) = 0
      and not exists (select 1 from public.birthday_program_versions bpv
                       join public.businesses b on b.id = bpv.business_id
                        and b.active_config_version_id = bpv.config_version_id
                      where bpv.business_id = v_business and bpv.active)
      and exists (select 1 from public.birthday_program_versions bpv
                   where bpv.business_id = v_business
                     and bpv.config_version_id = (v_saved->>'version_id')::uuid
                     and bpv.active),
    coalesce((v_replay_late - 'version_id' - 'program_id')::text,'(null)')
      || ' | frozen version still says active, live version does not');
end
$v849_test$;

select seq, step, outcome, detail from v849_out order by seq;

do $gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v849_out where outcome <> 'PASS';
  if v_failed > 0 then
    raise exception 'nestly_v849 acceptance: % assertion(s) FAILED', v_failed;
  end if;
end
$gate$;

rollback;

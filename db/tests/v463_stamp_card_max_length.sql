-- Rollback-only acceptance for nestly_v463 — a stamp card may be at most 15 stamps long.
--   supabase db query --linked -f db/tests/v463_stamp_card_max_length.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Owner ruling R3(a), 2026-08-23: the business editor's maximum is 15 stamps, enforced in the
-- input, in both steppers and in the server's own write guard for NEW writes. Existing
-- stamp_target values are NOT mutated.
--
-- Every behavioural check below CALLS public.business_set_stamp_card_length_v414. None of them
-- asserts on source text for its own sake — the two that read pg_get_functiondef (02, 09) are
-- checking that the migration's patch landed and that it left the rest of the body alone, which
-- is a claim about the patch and not a substitute for exercising it. db/tests/v414_stamp_card_
-- length.sql is the suite that ran against whatever tenant the caller owned; this one builds its
-- own firm inside the transaction, so it can also cover the cases no live tenant is in.
--
--   00  deployed, exactly one candidate, anon cannot execute
--   01  the fixture really is a stamps firm with a published config version
--   02  the deployed body carries the 15 bound and no longer carries the 100 one
--   03  NEGATIVE CONTROL: with the pre-v463 bound put back inside this transaction, 16 is
--       ACCEPTED — so checks 04-06 can actually see the difference. The patched body is
--       reinstalled immediately afterwards and check 03z proves it took.
--   04  15 is accepted and reaches loyalty_programs AND the config version the RPC targeted
--   05  16 is refused, with the new sentence and errcode 22023
--   06  100, 0 and null are refused
--   07  the stranded-gift refusal is untouched: shortening past a live gift still raises 23514
--       and still names the gift
--   08  a card ALREADY stored longer than 15 is not mutated — the guard bounds writes, not rows —
--       and a request to keep it at its current length is refused rather than silently accepted
--   09  the owner gate and the version begin/commit calls survived the patch
--   10  tenant isolation: a firm this session does not own is refused

begin;

create temp table _r(k text, v text) on commit drop;

-- Impersonate a browser session: the RPC is SECURITY DEFINER but gates on auth.uid().
create or replace function pg_temp.as_v463_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v463_user(uuid) to public;

-- Move the deployed bound between two values without leaving this transaction. Used by the
-- negative control to put the pre-v463 body back and then take it out again.
create or replace function pg_temp.v463_set_bound(p_from text, p_to text) returns void
language plpgsql as $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_set_stamp_card_length_v414';
  if v_src is null then
    raise exception 'v463 harness: business_set_stamp_card_length_v414 is missing';
  end if;
  if position('p_stamps > ' || p_from in v_src) = 0 then
    raise exception 'v463 harness: the deployed body does not carry the % bound', p_from;
  end if;
  v_new := replace(replace(v_src,
    'p_stamps > ' || p_from, 'p_stamps > ' || p_to),
    'between 1 and ' || p_from || ' stamps long', 'between 1 and ' || p_to || ' stamps long');
  execute v_new;
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_set_stamp_card_length_v414';
  if position('p_stamps > ' || p_to in v_src) = 0 then
    raise exception 'v463 harness: the bound did not move to %', p_to;
  end if;
end
$$;
grant execute on function pg_temp.v463_set_bound(text, text) to public;

-- Call the RPC and report either the returned stamp_target or the sqlstate + message.
create or replace function pg_temp.v463_try(p_business uuid, p_stamps integer)
returns text language plpgsql as $$
declare v_res jsonb;
begin
  v_res := public.business_set_stamp_card_length_v414(p_business, p_stamps);
  return 'OK ' || coalesce(v_res->>'stamp_target', '(no stamp_target)');
exception when others then
  return sqlstate || ' ' || sqlerrm;
end
$$;
grant execute on function pg_temp.v463_try(uuid, integer) to public;

-- The same call, returning the whole payload. Check 04 needs target_version_id: nestly_v433 does
-- not write the length into the ACTIVE version — it opens a draft, writes there, and leaves
-- publish_status 'pending' until the change is complete. That lifecycle is protected and is not
-- what this suite is testing; it just has to be read correctly.
create or replace function pg_temp.v463_call(p_business uuid, p_stamps integer)
returns jsonb language plpgsql as $$
begin
  return public.business_set_stamp_card_length_v414(p_business, p_stamps);
end
$$;
grant execute on function pg_temp.v463_call(uuid, integer) to public;

-- ------------------------------------------------------------------ 0 - shape of the RPC
do $$
declare v_n int;
begin
  if to_regprocedure('public.business_set_stamp_card_length_v414(uuid,integer)') is null then
    insert into _r values('00_deployed', 'FAIL business_set_stamp_card_length_v414 is not deployed');
    return;
  end if;
  insert into _r values('00_deployed', 'PASS business_set_stamp_card_length_v414 is deployed');

  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_set_stamp_card_length_v414';
  insert into _r values('00_no_overload_twin',
    case when v_n = 1 then 'PASS exactly one candidate'
         else 'FAIL ' || v_n || ' candidates — an overload twin exists' end);

  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_set_stamp_card_length_v414'
     and has_function_privilege('anon', p.oid, 'execute');
  insert into _r values('00_not_anon_callable',
    case when v_n = 0 then 'PASS anon cannot execute it'
         else 'FAIL anon holds execute on a configuration writer' end);
end
$$;

-- ------------------------------------------------- 2 - the patch landed, and only the patch
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_set_stamp_card_length_v414';
  insert into _r values('02_bound_is_fifteen',
    case when position('p_stamps > 15' in v_src) > 0
          and position('between 1 and 15 stamps long' in v_src) > 0
      then 'PASS the deployed body caps at 15'
      else 'FAIL the deployed body does not carry the 15 bound' end);
  insert into _r values('02_old_bound_is_gone',
    case when position('p_stamps > 100' in v_src) = 0
          and position('between 1 and 100 stamps long' in v_src) = 0
      then 'PASS the 100 bound is gone'
      else 'FAIL the 100 bound survived' end);
  insert into _r values('09_guards_survived_the_patch',
    case when position('app.c45_owner_loyalty_write(p_business)' in v_src) > 0
          and position('app.stamp_config_edit_begin_v433(p_business)' in v_src) > 0
          and position('app.stamp_config_edit_commit_v433(p_business, v_target)' in v_src) > 0
          and position('Move or remove that gift first.' in v_src) > 0
      then 'PASS the owner gate, the version split and the stranded-gift refusal are intact'
      else 'FAIL the patch removed something it must have kept' end);
end
$$;

-- ------------------------------------------- 1, 3-8, 10 - a stamps firm, built and exercised
do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_legacy_biz uuid := gen_random_uuid();
  v_gift_biz uuid := gen_random_uuid();
  v_config uuid := gen_random_uuid();
  v_legacy_config uuid := gen_random_uuid();
  v_gift_config uuid := gen_random_uuid();
  v_spine uuid := gen_random_uuid();
  v_legacy_spine uuid := gen_random_uuid();
  v_gift_spine uuid := gen_random_uuid();
  v_reward uuid := gen_random_uuid();
  v_txt text;
  v_res jsonb;
  v_n int;
begin
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'v463-owner@example.test', '', now(), now(), now());

  insert into public.businesses(id, name, slug, enabled_modules) values
    (v_biz, 'V463 Firm', 'v463-' || substr(v_biz::text, 1, 8), array['loyalty']),
    (v_legacy_biz, 'V463 Legacy Firm', 'v463l-' || substr(v_legacy_biz::text, 1, 8), array['loyalty']),
    (v_gift_biz, 'V463 Gift Firm', 'v463g-' || substr(v_gift_biz::text, 1, 8), array['loyalty']);
  insert into public.staff(business_id, user_id, role, full_name, active) values
    (v_biz, v_owner, 'owner', 'V463 Owner', true),
    (v_legacy_biz, v_owner, 'owner', 'V463 Owner', true),
    (v_gift_biz, v_owner, 'owner', 'V463 Owner', true);
  insert into public.business_workspace_controls_v94(
    business_id, approval_status, decided_by, decided_at, decision_reason) values
    (v_biz, 'approved', v_owner, now(), 'v463 fixture'),
    (v_legacy_biz, 'approved', v_owner, now(), 'v463 fixture'),
    (v_gift_biz, 'approved', v_owner, now(), 'v463 fixture')
  -- inserting a business auto-creates an undecided controls row, so this always takes the
  -- conflict branch; the decision columns must move with the status or the shape check fires.
  on conflict (business_id) do update
    set approval_status = 'approved', decided_by = excluded.decided_by,
        decided_at = excluded.decided_at, decision_reason = excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused) values
    (v_biz, false), (v_legacy_biz, false), (v_gift_biz, false)
  on conflict (business_id) do update set workspace_paused = false;

  -- Inserting a business auto-creates its four programme spine rows (points/tiers/stamps/
  -- referral), so this reads the stamps spine rather than creating a second one, and switches it
  -- on the way business_switch_programme would.
  update public.business_programmes set active = (kind = 'stamps'),
         activated_at = case when kind = 'stamps' then now() else activated_at end
   where business_id in (v_biz, v_legacy_biz, v_gift_biz);
  select id into v_spine from public.business_programmes
   where business_id = v_biz and kind = 'stamps';
  select id into v_legacy_spine from public.business_programmes
   where business_id = v_legacy_biz and kind = 'stamps';
  select id into v_gift_spine from public.business_programmes
   where business_id = v_gift_biz and kind = 'stamps';
  if v_spine is null or v_legacy_spine is null or v_gift_spine is null then
    raise exception 'v463 fixture: a business was created without a stamps programme spine';
  end if;

  insert into public.firm_config_versions(
    id, business_id, version_no, status, source, snapshot_hash, created_by) values
    (v_config, v_biz, 1, 'draft', 'manual', md5('v463-firm'), v_owner),
    (v_legacy_config, v_legacy_biz, 1, 'draft', 'manual', md5('v463-legacy-firm'), v_owner),
    (v_gift_config, v_gift_biz, 1, 'draft', 'manual', md5('v463-gift-firm'), v_owner);

  -- The gift firm carries a live gift on stamp 12 of a 15-stamp card, so check 07 can prove the
  -- stranded-gift refusal is untouched. It is a SEPARATE firm because that gift would otherwise
  -- block the negative control in check 03 from putting the main firm's length back.
  insert into public.loyalty_rewards(id, business_id, programme_id, name, internal_name,
                                     customer_name, fulfillment_kind, cost_points, credit_cents,
                                     estimated_cost_cents, active, paused)
  values (v_reward, v_gift_biz, v_gift_spine, 'V463 Gift', 'V463 Gift', 'V463 Gift',
          'manual_item', 12, 0, 0, true, false);

  -- The version tables carry an immutability guard that reads auth.uid(); the claims are set
  -- without switching role, because `authenticated` holds no INSERT grant on them — only the
  -- SECURITY DEFINER publish path writes them in production, and this fixture stands in for it.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.loyalty_program_versions(
    config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents,
    tier_basis, expiry_mode, stamp_target, stamp_per_cents) values
    (v_config, v_biz, 'points', 'stamps', true, 1, 800, 2000, 'visits', 'none', 10, 500),
    -- The legacy firm is seeded at 40: a length no owner may set any more, and one the pre-v463
    -- server would have accepted. Nothing in this migration migrates it, which is the point.
    (v_legacy_config, v_legacy_biz, 'points', 'stamps', true, 1, 800, 2000, 'visits', 'none', 40, 500),
    (v_gift_config, v_gift_biz, 'points', 'stamps', true, 1, 800, 2000, 'visits', 'none', 15, 500);
  insert into public.loyalty_reward_versions(
    config_version_id, business_id, programme_id, reward_id, internal_name, customer_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active)
  values (v_gift_config, v_gift_biz, v_gift_spine, v_reward, 'V463 Gift', 'V463 Gift',
          'manual_item', 12, 0, 0, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);

  update public.firm_config_versions set status = 'published', published_at = now()
   where id in (v_config, v_legacy_config, v_gift_config);

  insert into public.loyalty_programs(
    business_id, kind, active, loyalty_model, configuration_status,
    current_config_version_id, earn_points_per_dollar, redeem_points,
    reward_credit_cents, tier_basis, expiry_mode, stamp_target, stamp_per_cents) values
    (v_biz, 'points', true, 'stamps', 'published', v_config, 1, 800, 2000, 'visits', 'none', 10, 500),
    (v_legacy_biz, 'points', true, 'stamps', 'published', v_legacy_config, 1, 800, 2000,
     'visits', 'none', 40, 500),
    (v_gift_biz, 'points', true, 'stamps', 'published', v_gift_config, 1, 800, 2000,
     'visits', 'none', 15, 500);

  perform set_config('app.v79_system_transition', 'on', true);
  update public.businesses set active_config_version_id = v_config where id = v_biz;
  update public.businesses set active_config_version_id = v_legacy_config where id = v_legacy_biz;
  update public.businesses set active_config_version_id = v_gift_config where id = v_gift_biz;
  perform set_config('app.v79_system_transition', '', true);

  ------------------------------------------------------------------ 1 - the fixture is real
  select stamp_target into v_n from public.loyalty_programs where business_id = v_biz;
  insert into _r values('01_fixture_is_a_stamps_firm',
    case when v_n = 10 and exists(select 1 from public.business_programmes
                                   where business_id = v_biz and kind = 'stamps' and active)
                       and exists(select 1 from public.businesses
                                   where id = v_biz and active_config_version_id = v_config)
      then 'PASS a published 10-stamp card'
      else 'FAIL the fixture is not a published stamps firm (stamp_target=' ||
           coalesce(v_n::text, 'null') || ')' end);

  ------------------------------------------------- 3 - NEGATIVE CONTROL: put the old bound back
  perform pg_temp.v463_set_bound('15', '100');
  perform pg_temp.as_v463_user(v_owner);
  v_txt := pg_temp.v463_try(v_biz, 16);
  reset role;
  insert into _r values('03_negative_control_pre_v463_accepts_16',
    case when v_txt = 'OK 16'
      then 'PASS with the 100 bound restored, 16 is accepted — the checks below can see the change'
      else 'FAIL the negative control did not reproduce the old behaviour; got ' || v_txt end);
  -- put the card back where the rest of the suite expects it, then restore the patched bound
  perform pg_temp.as_v463_user(v_owner);
  perform pg_temp.v463_try(v_biz, 10);
  reset role;
  perform pg_temp.v463_set_bound('100', '15');
  insert into _r values('03z_patched_bound_reinstalled',
    case when position('p_stamps > 15' in
           (select pg_get_functiondef(p.oid) from pg_proc p
              join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public'
               and p.proname = 'business_set_stamp_card_length_v414')) > 0
      then 'PASS the 15 bound is back in place for the checks below'
      else 'FAIL the harness left the wrong body installed' end);

  ------------------------------------------------------------------ 4 - 15 is accepted
  perform pg_temp.as_v463_user(v_owner);
  v_res := pg_temp.v463_call(v_biz, 15);
  reset role;
  insert into _r values('04_fifteen_accepted',
    case when v_res->>'status' = 'ok' and v_res->>'stamp_target' = '15'
      then 'PASS the maximum itself is settable (publish_status='
           || coalesce(v_res->>'publish_status', 'null') || ')'
      else 'FAIL 15 must be accepted; got ' || v_res::text end);

  select stamp_target into v_n from public.loyalty_programs where business_id = v_biz;
  insert into _r values('04_spine_row_updated',
    case when v_n = 15 then 'PASS loyalty_programs.stamp_target is 15'
         else 'FAIL the spine row reads ' || coalesce(v_n::text, 'null') end);

  -- The length is written to the version the RPC says it targeted, NOT necessarily the active
  -- one: nestly_v433 opens a draft for an edit and holds publish_status 'pending' until the
  -- change is complete (here, until a gift sits on the new final stamp). That lifecycle is
  -- protected and untouched by v463; this check reads it as it is rather than asserting the
  -- active version moved, which it deliberately does not.
  select v.stamp_target into v_n
    from public.loyalty_program_versions v
   where v.business_id = v_biz
     and v.config_version_id = (v_res->>'target_version_id')::uuid;
  insert into _r values('04_target_version_updated',
    case when v_n = 15 then 'PASS the targeted config version carries 15'
         else 'FAIL the targeted version reads ' || coalesce(v_n::text, 'null')
              || ' — the engine reads a version row, not the spine' end);

  ------------------------------------------------------------------ 5 - 16 is refused
  perform pg_temp.as_v463_user(v_owner);
  v_txt := pg_temp.v463_try(v_biz, 16);
  reset role;
  insert into _r values('05_sixteen_refused',
    case when v_txt like '22023 %' and v_txt like '%between 1 and 15 stamps long%'
      then 'PASS ' || v_txt
      else 'FAIL one past the maximum must be refused with the 15 sentence; got ' || v_txt end);

  select stamp_target into v_n from public.loyalty_programs where business_id = v_biz;
  insert into _r values('05_refusal_wrote_nothing',
    case when v_n = 15 then 'PASS the card is still 15 after the refusal'
         else 'FAIL a refused write changed the card to ' || coalesce(v_n::text, 'null') end);

  ------------------------------------------------------------ 6 - the rest of the range
  perform pg_temp.as_v463_user(v_owner);
  v_txt := pg_temp.v463_try(v_biz, 100);
  reset role;
  insert into _r values('06_hundred_refused',
    case when v_txt like '22023 %' and v_txt like '%between 1 and 15 stamps long%'
      then 'PASS the old maximum is no longer settable'
      else 'FAIL 100 must now be refused; got ' || v_txt end);

  perform pg_temp.as_v463_user(v_owner);
  v_txt := pg_temp.v463_try(v_biz, 0);
  reset role;
  insert into _r values('06_zero_refused',
    case when v_txt like '22023 %' then 'PASS ' || v_txt
         else 'FAIL a zero-length card must be refused; got ' || v_txt end);

  perform pg_temp.as_v463_user(v_owner);
  v_txt := pg_temp.v463_try(v_biz, null);
  reset role;
  insert into _r values('06_null_refused',
    case when v_txt like '22023 %' then 'PASS ' || v_txt
         else 'FAIL a null length must be refused; got ' || v_txt end);

  ------------------------------------------- 7 - the stranded-gift refusal is untouched
  perform pg_temp.as_v463_user(v_owner);
  v_txt := pg_temp.v463_try(v_gift_biz, 5);
  reset role;
  insert into _r values('07_stranded_gift_still_refuses',
    case when v_txt like '23514 %' and v_txt like '%V463 Gift%' and v_txt like '%out of reach%'
      then 'PASS ' || v_txt
      else 'FAIL shortening past a live gift must still be refused by name; got ' || v_txt end);

  ------------------------------------ 8 - a card already longer than 15 is not mutated
  select stamp_target into v_n from public.loyalty_programs where business_id = v_legacy_biz;
  insert into _r values('08_legacy_row_untouched',
    case when v_n = 40
      then 'PASS a 40-stamp card stored before v463 still reads 40 — the guard bounds writes, '
           || 'not rows, and this migration contains no UPDATE'
      else 'FAIL the legacy card now reads ' || coalesce(v_n::text, 'null') end);

  perform pg_temp.as_v463_user(v_owner);
  v_txt := pg_temp.v463_try(v_legacy_biz, 40);
  reset role;
  insert into _r values('08_legacy_length_not_resettable',
    case when v_txt like '22023 %' and v_txt like '%between 1 and 15 stamps long%'
      then 'PASS re-saving the stored length is refused like any other write above 15'
      else 'FAIL got ' || v_txt end);

  perform pg_temp.as_v463_user(v_owner);
  v_txt := pg_temp.v463_try(v_legacy_biz, 15);
  reset role;
  select stamp_target into v_n from public.loyalty_programs where business_id = v_legacy_biz;
  insert into _r values('08_legacy_can_come_down_to_fifteen',
    case when v_txt = 'OK 15' and v_n = 15
      then 'PASS the one way out is open: a legacy card can be brought to 15'
      else 'FAIL got ' || v_txt || ', row now ' || coalesce(v_n::text, 'null') end);

  ------------------------------------------------------------------ 10 - tenant isolation
  perform pg_temp.as_v463_user(v_owner);
  v_txt := pg_temp.v463_try('00000000-0000-0000-0000-000000000000', 10);
  reset role;
  insert into _r values('10_other_tenant_refused',
    case when v_txt like '42501 %' and v_txt like '%access required%' then 'PASS ' || v_txt
         else 'FAIL a firm this session does not own was written; got ' || v_txt end);
end
$$;

select k as check, v as result from _r order by k;

rollback;

-- Rollback-only acceptance for v423 — an edit to a live gift reaches the customer.
--   supabase db query --linked -f db/tests/v423_reward_edit_reaches_customers.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Until v423, public.business_update_reward_v326 wrote only public.loyalty_rewards. Both readers
-- that matter — public.customer_get_reward_catalog and app.redeem_reward_core — read
-- public.loyalty_reward_versions at businesses.active_config_version_id, so a rename, a reprice,
-- a new description or a new photo changed the owner's screen and nothing the customer saw or
-- paid. v343's header asserted the opposite ("Only public.loyalty_rewards is the current-state
-- source of truth this page (and customer_get_reward_catalog) reads") and that sentence is the
-- whole defect.
--
-- This runs on Cubbly SPA, the only production tenant that has BOTH an active loyalty_programs
-- row and live published gifts — the two things customer_get_reward_catalog requires before it
-- will return anything. It is also the tenant carrying eleven open drafts, which is what makes
-- check 08 a real test rather than a vacuous one.
--
-- Checks 09-11 run the immutability probes as the connected role rather than through the RPC:
-- app.reward_version_immutable_guard must still refuse everything it refused yesterday.

begin;

create temp table _r(k text, v text) on commit drop;

do $$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';   -- Cubbly SPA
  v_slug text := 'kopi-tiam-tyeh';
  v_owner uuid := 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7';
  v_cust uuid := '8144949d-346c-4726-88c5-ceafce5442a6';
  v_active uuid; v_reward uuid; v_version uuid;
  v_was_name text; v_was_cost integer; v_was_desc text; v_was_photo text;
  v_pinned_before uuid; v_pinned_after uuid;
  v_probe_name text := 'V423 PROBE GIFT';
  v_probe_desc text := 'V423 probe description';
  v_probe_photo text := 'https://example.invalid/v423/probe.png';
  v_stale_draft uuid; v_diverged_draft uuid;
  v_cat jsonb; v_gift jsonb; v_price integer; v_n integer; v_msg text; v_ret jsonb;
begin
  select active_config_version_id into v_active from public.businesses where id = v_biz;

  -- The gift under test: a live, unpaused, published gift whose programme is switched ON — the
  -- only shape V372 lets into the customer catalogue at all. Resolved rather than hardcoded so a
  -- later rename in the tenant cannot quietly turn this file into a no-op.
  select lr.id, rv.id, lr.customer_name, lr.cost_points, lr.description, lr.image_ref
    into v_reward, v_version, v_was_name, v_was_cost, v_was_desc, v_was_photo
    from public.loyalty_rewards lr
    join public.business_programmes spine on spine.id = lr.programme_id and spine.active
    join public.loyalty_reward_versions rv
      on rv.reward_id = lr.id and rv.business_id = lr.business_id and rv.config_version_id = v_active and rv.active
   where lr.business_id = v_biz and lr.active and not lr.paused
   order by lr.sort, lr.id
   limit 1;
  if v_reward is null then
    raise exception 'no live published gift on an active programme in this tenant — pick another';
  end if;
  insert into _r values('00_subject', 'gift ' || v_reward || ' version ' || v_version ||
    ' was ' || coalesce(v_was_name,'<null>') || ' @ ' || v_was_cost);

  -- Where the customer's stamp card is pinned BEFORE the edit (v416). Recorded so check 07b can
  -- prove the edit did not move a part-filled card onto a different configuration.
  select app.stamp_cycle_version_v416(v_biz, l.client_id, lr.programme_id)
    into v_pinned_before
    from public.customer_links l
    join public.loyalty_rewards lr on lr.id = v_reward
   where l.auth_user_id = v_cust and l.business_id = v_biz and l.state = 'verified'
   limit 1;

  -- One draft still holding the pre-edit values, one the owner has staged something else into.
  select d.config_version_id into v_stale_draft
    from public.loyalty_reward_versions d
    join public.firm_config_versions f on f.id = d.config_version_id and f.status = 'draft'
   where d.reward_id = v_reward and d.business_id = v_biz
     and d.customer_name is not distinct from v_was_name
     and d.cost_points is not distinct from v_was_cost
   limit 1;
  select d.config_version_id into v_diverged_draft
    from public.loyalty_reward_versions d
    join public.firm_config_versions f on f.id = d.config_version_id and f.status = 'draft'
   where d.reward_id = v_reward and d.business_id = v_biz
     and d.config_version_id is distinct from v_stale_draft
   limit 1;
  if v_diverged_draft is not null then
    -- a draft is mutable, so this is a legitimate write inside the rolled-back transaction
    update public.loyalty_reward_versions
       set customer_name = 'V423 STAGED', cost_points = 97
     where reward_id = v_reward and config_version_id = v_diverged_draft;
  end if;

  -- ==========================================================================================
  -- 01  WHAT THE CUSTOMER IS SERVED BEFORE THE EDIT
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
  v_cat := public.customer_get_reward_catalog(v_slug);
  select value into v_gift from jsonb_array_elements(v_cat -> 'rewards')
   where value ->> 'customer_name' = v_was_name limit 1;
  insert into _r values('01_customer_is_served_the_gift',
    case when v_gift is not null then 'PASS ' || coalesce(v_gift ->> 'customer_name','?') || ' @ ' || coalesce(v_gift ->> 'cost_points','?')
         else 'FAIL the gift is not in the catalogue at all, so nothing below means anything' end);

  -- ==========================================================================================
  -- 02  THE OWNER EDITS IT
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_ret := public.business_update_reward_v326(v_biz, v_reward, v_probe_name, 1, v_probe_desc, 0, v_probe_photo, false);
  insert into _r values('02_rpc_reports_the_sync',
    case when coalesce((v_ret ->> 'published_version_synced')::boolean, false)
      then 'PASS the RPC says it wrote the published snapshot'
      else 'FAIL ' || v_ret::text end);

  -- 03  the owner's own screen — v343 behaviour, unregressed
  insert into _r select '03_live_row_changed',
    case when customer_name = v_probe_name and cost_points = 1 and description = v_probe_desc
          and image_ref = v_probe_photo and name = v_probe_name and internal_name = v_probe_name
      then 'PASS' else 'FAIL ' || customer_name || ' @ ' || cost_points end
  from public.loyalty_rewards where id = v_reward;

  -- ==========================================================================================
  -- 04  THE FIX — the published snapshot follows
  -- ==========================================================================================
  insert into _r select '04_published_snapshot_changed',
    case when customer_name = v_probe_name and internal_name = v_probe_name and cost_points = 1
          and description = v_probe_desc and image_ref = v_probe_photo
      then 'PASS THE FIX: the row the customer is served now carries the edit'
      else 'FAIL still ' || customer_name || ' @ ' || cost_points end
  from public.loyalty_reward_versions where id = v_version;

  -- 05  and nothing else on that row moved
  insert into _r select '05_snapshot_identity_intact',
    case when id = v_version and reward_id = v_reward and business_id = v_biz
          and config_version_id = v_active and active
      then 'PASS identity, tenancy, config version and active are untouched'
      else 'FAIL the snapshot row was re-pointed' end
  from public.loyalty_reward_versions where id = v_version;

  -- ==========================================================================================
  -- 06  THE CUSTOMER SEES IT
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
  v_cat := public.customer_get_reward_catalog(v_slug);
  select value into v_gift from jsonb_array_elements(v_cat -> 'rewards')
   where value ->> 'customer_name' = v_probe_name limit 1;
  insert into _r values('06_customer_sees_the_edit',
    case when v_gift is null then 'FAIL the customer is still being offered the old gift'
         when (v_gift ->> 'cost_points')::integer = 1
          and v_gift ->> 'description' = v_probe_desc
          and v_gift ->> 'image_ref' = v_probe_photo
           then 'PASS name, price, description and photo all followed'
         else 'FAIL ' || v_gift::text end);
  insert into _r values('06b_old_gift_is_gone',
    case when not exists (select 1 from jsonb_array_elements(v_cat -> 'rewards') e
                           where e.value ->> 'customer_name' = v_was_name)
      then 'PASS the pre-edit gift is no longer listed'
      else 'FAIL both versions are on the shelf at once' end);

  -- ==========================================================================================
  -- 07  REDEMPTION IS QUOTED AT THE NEW PRICE
  -- ==========================================================================================
  -- The exact lookup app.redeem_reward_core performs for a points gift.
  select rv.cost_points into v_price
    from public.loyalty_reward_versions rv
    join public.businesses b on b.id = rv.business_id and b.active_config_version_id = rv.config_version_id
   where rv.reward_id = v_reward and rv.business_id = v_biz;
  insert into _r values('07_redemption_price_follows',
    case when v_price = 1 then 'PASS the counter would charge the new price'
         else 'FAIL it would still charge ' || v_price end);

  -- 07b  and a part-filled stamp card is NOT dragged onto a different configuration (v416)
  select app.stamp_cycle_version_v416(v_biz, l.client_id, lr.programme_id)
    into v_pinned_after
    from public.customer_links l
    join public.loyalty_rewards lr on lr.id = v_reward
   where l.auth_user_id = v_cust and l.business_id = v_biz and l.state = 'verified'
   limit 1;
  insert into _r values('07b_stamp_pin_unmoved',
    case when v_pinned_after is not distinct from v_pinned_before
      then 'PASS the customer''s open card is pinned exactly where it was'
      else 'FAIL the edit moved the pin from ' || coalesce(v_pinned_before::text,'null')
           || ' to ' || coalesce(v_pinned_after::text,'null') end);

  -- ==========================================================================================
  -- 08  DRAFTS: stale clones follow, staged work does not
  -- ==========================================================================================
  if v_stale_draft is null then
    insert into _r values('08_stale_draft_follows','SKIP no draft was holding the pre-edit values');
  else
    insert into _r select '08_stale_draft_follows',
      case when customer_name = v_probe_name and cost_points = 1
        then 'PASS publishing that draft can no longer revert the edit'
        else 'FAIL it still holds ' || customer_name || ' @ ' || cost_points end
    from public.loyalty_reward_versions where reward_id = v_reward and config_version_id = v_stale_draft;
  end if;
  if v_diverged_draft is null then
    insert into _r values('08b_staged_draft_untouched','SKIP this gift has no second draft');
  else
    insert into _r select '08b_staged_draft_untouched',
      case when customer_name = 'V423 STAGED' and cost_points = 97
        then 'PASS deliberately staged draft values were left alone'
        else 'FAIL staged work was overwritten with ' || customer_name || ' @ ' || cost_points end
    from public.loyalty_reward_versions where reward_id = v_reward and config_version_id = v_diverged_draft;
  end if;

  -- ==========================================================================================
  -- 09-11  THE IMMUTABILITY GUARD STILL GUARDS
  -- ==========================================================================================
  begin
    update public.loyalty_reward_versions set customer_name = 'V423 SNEAKED IN' where id = v_version;
    insert into _r values('09_bare_update_still_refused','FAIL a published snapshot was edited with no token');
  exception when restrict_violation then
    insert into _r values('09_bare_update_still_refused','PASS still immutable to everything but the RPC');
  end;

  begin
    perform set_config('app.v423_reward_edit_version_id', v_version::text, true);
    delete from public.loyalty_reward_versions where id = v_version;
    perform set_config('app.v423_reward_edit_version_id', '', true);
    insert into _r values('10_delete_still_refused','FAIL the token allowed a DELETE');
  exception when restrict_violation then
    perform set_config('app.v423_reward_edit_version_id', '', true);
    insert into _r values('10_delete_still_refused','PASS the hatch is UPDATE-only');
  end;

  begin
    perform set_config('app.v423_reward_edit_version_id', v_version::text, true);
    update public.loyalty_reward_versions set active = false where id = v_version;
    perform set_config('app.v423_reward_edit_version_id', '', true);
    insert into _r values('11_token_is_column_scoped','FAIL the token let a non-editable column through');
  exception when restrict_violation then
    perform set_config('app.v423_reward_edit_version_id', '', true);
    insert into _r values('11_token_is_column_scoped','PASS only the seven owner columns may move');
  end;

  -- ==========================================================================================
  -- 12-13  THE REFUSALS v343 ALREADY OWNED
  -- ==========================================================================================
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
    perform public.business_update_reward_v326(v_biz, v_reward, 'V423 HIJACK', 5, null, 0, null, false);
    insert into _r values('12_non_owner_refused','FAIL a customer session edited the gift');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('12_non_owner_refused',
      case when v_msg like '%owner loyalty configuration access required%' then 'PASS ' || v_msg
           else 'FAIL ' || v_msg end);
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    perform public.business_update_reward_v326(v_biz, v_reward, v_probe_name, 0, null, 0, null, false);
    insert into _r values('13_zero_points_refused','FAIL a zero-point gift was accepted');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('13_zero_points_refused',
      case when v_msg like '%positive number%' then 'PASS ' || v_msg else 'FAIL ' || v_msg end);
  end;

  -- 14  clearing the photo clears BOTH rows
  perform public.business_update_reward_v326(v_biz, v_reward, v_probe_name, 1, v_probe_desc, 0, null, true);
  select count(*) into v_n
    from public.loyalty_reward_versions rv join public.loyalty_rewards lr on lr.id = rv.reward_id
   where rv.id = v_version and rv.image_ref is null and lr.image_ref is null;
  insert into _r values('14_clear_photo_clears_both',
    case when v_n = 1 then 'PASS' else 'FAIL the two rows disagree about the photo' end);

  -- 15  an unpublished gift is not published by an edit
  select count(*) into v_n
    from public.loyalty_rewards lr
   where lr.business_id = v_biz and lr.active
     and not exists (select 1 from public.loyalty_reward_versions rv
                      where rv.reward_id = lr.id and rv.config_version_id = v_active);
  insert into _r values('15_unpublished_gifts_unchanged',
    'INFO ' || v_n || ' live gift(s) in this tenant have no published snapshot; v423 leaves them live-only');
end $$;

-- ==============================================================================================
-- 16-17  GRANT POSTURE (section 3 of the migration)
-- ==============================================================================================
insert into _r
select '16_anon_cannot_execute_the_gift_rpcs',
  case when count(*) = 0 then 'PASS'
       else 'FAIL anon still holds EXECUTE on ' || string_agg(sig, ', ') end
from (
  select p.oid::regprocedure::text as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('business_create_reward_v326','business_update_reward_v326')
     and has_function_privilege('anon', p.oid, 'EXECUTE')
) leftover;

insert into _r
select '17_anon_surplus_dml_revoked',
  case when count(*) = 0 then 'PASS'
       else 'FAIL ' || string_agg(relname || ':' || priv, ', ') end
from (
  select c.relname, t.priv
    from pg_class c
    cross join unnest(array['INSERT','UPDATE','DELETE','TRUNCATE']) as t(priv)
   where c.relnamespace = 'public'::regnamespace
     and c.relname in ('bringback_campaigns_v361','bringback_grants_v361',
                       'client_points_balance','points_batches','reward_grants')
     and has_table_privilege('anon', c.oid, t.priv)
) leftover;

insert into _r
select '17b_authenticated_untouched',
  case when has_function_privilege('authenticated',
         'public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean)'::regprocedure, 'EXECUTE')
        and has_table_privilege('authenticated', 'public.points_batches'::regclass, 'UPDATE')
    then 'PASS the grants the product needs are still there'
    else 'FAIL an authenticated grant was collateral damage' end;

select k, v from _r order by k;
rollback;

-- v744_merge_v685_semantics.sql — merge proof (2026-09-03): after EVERY pending migration has
-- applied, the three functions that main's nestly_v685 (Singapore-day authority) patched AND the
-- Customer Intelligence wave re-emits still carry v685's semantics — the newer authority wins.
--
--   app.customer_demographics_v1          (v685 D-11; CI v674 split it into core + wrapper)
--   app.issue_bringback_for_business_v361 (v685 D-06; CI v743 excludes synthetic clients)
--   public.refresh_growth_recommendation_v108 (v685 D-09; CI v744 excludes synthetic clients)
--
-- Each assertion checks BOTH directions: the v685 text is present, the pre-v685 UTC-day text is
-- gone, and the CI exclusion is present too — so a regression in either session's work fails here.
-- Executed by scripts/db-tests/run.mjs in the migrated phase (n/a in the v422 baseline).
begin;

do $proof$
declare
  v_demo text; v_core text; v_bring text; v_growth text; v_fail text := '';
begin
  select pg_get_functiondef(p.oid) into v_demo
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'customer_demographics_v1';
  select pg_get_functiondef(p.oid) into v_core
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'customer_demographics_core_v674';
  select pg_get_functiondef(p.oid) into v_bring
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'issue_bringback_for_business_v361';
  select pg_get_functiondef(p.oid) into v_growth
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'refresh_growth_recommendation_v108';

  if v_demo is null or v_core is null or v_bring is null or v_growth is null then
    raise exception 'v744_merge_v685: a function under proof is missing';
  end if;

  -- 1. demographics: the wrapper delegates to the core, and the core ages against the SG day
  if position('customer_demographics_core_v674' in v_demo) = 0 then
    v_fail := v_fail || ' [demographics wrapper no longer delegates to the v674 core]';
  end if;
  if position($a$age(app.sg_today(), v_birth)$a$ in v_core) = 0 then
    v_fail := v_fail || ' [demographics core lost v685: age(app.sg_today(), v_birth)]';
  end if;
  if position($a$age(current_date$a$ in v_core) > 0 or position($a$age(current_date$a$ in v_demo) > 0 then
    v_fail := v_fail || ' [demographics still ages against current_date (UTC day)]';
  end if;

  -- 2. bring-back writer: SG last-seen day (v685) AND synthetic clients excluded (v743)
  if position($a$app.sg_day(max(s.created_at)) as last_day$a$ in v_bring) = 0 then
    v_fail := v_fail || ' [bringback lost v685: app.sg_day(max(s.created_at))]';
  end if;
  if position($a$max(s.created_at)::date$a$ in v_bring) > 0 then
    v_fail := v_fail || ' [bringback still keys the cycle on the UTC day]';
  end if;
  if position($a$sc.is_synthetic$a$ in v_bring) = 0 then
    v_fail := v_fail || ' [bringback lost v743: synthetic-client exclusion]';
  end if;

  -- 3. growth recommendation writer: SG day key (v685) AND synthetic clients excluded (v744)
  if position($a$app.sg_day(v_now)::text$a$ in v_growth) = 0 then
    v_fail := v_fail || ' [refresh_growth lost v685: app.sg_day(v_now)::text]';
  end if;
  if position($a$date_trunc('day',v_now)::text$a$ in v_growth) > 0 then
    v_fail := v_fail || ' [refresh_growth still keys on the UTC day]';
  end if;
  if position($a$sale_client.is_synthetic$a$ in v_growth) = 0 then
    v_fail := v_fail || ' [refresh_growth lost v744: synthetic-client exclusion]';
  end if;

  -- 4. the authority itself is the one main shipped
  if to_regprocedure('app.sg_today()') is null or to_regprocedure('app.sg_day(timestamptz)') is null then
    v_fail := v_fail || ' [app.sg_today()/app.sg_day(timestamptz) missing]';
  end if;

  -- 5. main's nestly_v677 ("a reversed sale is not a visit") and the CI wave's visit-day authority
  --    (v709/v724/v729) rewrite the SAME line in four readers. After the full chain each reader
  --    must count distinct Singapore visit days (CI) over the NON-REVERSED qualifying set (v677):
  --    the v699 authority is present, the reversal netting is present, and neither the raw
  --    count(*) nor a bare v677 call (which would mean the CI patch never landed) remains.
  declare
    v_fn text; v_body text;
  begin
    foreach v_fn in array array[
      'app.tier_resolve_v426(uuid,uuid,timestamptz)',
      'app.v666_till_customer_card(uuid,uuid)',
      'public.lookup_client_by_phone(uuid,text)',
      'public.customer_get_business_presentation_v95(uuid,uuid,text)'
    ] loop
      v_body := pg_get_functiondef(to_regprocedure(v_fn));
      if v_body is null then
        v_fail := v_fail || ' [' || v_fn || ' missing]'; continue;
      end if;
      if position('app.ci_visit_day_v699(' in v_body) = 0 then
        v_fail := v_fail || ' [' || v_fn || ' lost the CI visit-day authority]';
      end if;
      if position('r.reversal_of = v.id' in v_body) = 0 or position('v.reversal_of is null' in v_body) = 0 then
        v_fail := v_fail || ' [' || v_fn || ' lost v677 reversal netting]';
      end if;
      if position('app.client_qualifying_visits_v677(' in v_body) > 0 then
        v_fail := v_fail || ' [' || v_fn || ' still calls the raw v677 count — the CI patch did not land]';
      end if;
    end loop;
  end;

  if v_fail <> '' then
    raise exception 'v744_merge_v685 FAILED:%', v_fail;
  end if;
  raise notice 'v744_merge_v685: all three functions carry main''s v685 Singapore-day semantics and the CI exclusions';
end
$proof$;

rollback;

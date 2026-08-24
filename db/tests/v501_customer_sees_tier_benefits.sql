-- Rolled-back proof for nestly_v501. One transaction, ROLLBACK at the end, nothing survives.
-- Run: supabase db query --linked -f db/tests/v501_customer_sees_tier_benefits.sql
-- Any value starting with FAIL is a failure.
--
-- THE CLAIM: the customer's own read of their tier perks says exactly what the counter says, and
-- a monthly perk carries the deadline the counter actually enforces.
--
-- Fixture is the owner's own photo: Cubbly SPA, whose Gold tier carries "20% off — 1 per month",
-- and customer Mumu, who holds Gold. The owner's complaint was that this perk was configured,
-- countable and issuable, and completely invisible to Mumu.
--
--   01  the customer sees the perk at all — the whole defect
--   02  customer and staff agree, perk for perk, on remaining and claimability (the v495 law:
--       never offer what the counter refuses)
--   03  a monthly perk's deadline is the END of the calendar month, in Singapore
--   04  spending the allowance withdraws it from the customer's list in the same breath as it
--       withdraws it from the counter's
--   05  a customer with no verified link cannot read another customer's perks
begin;

create temp table _r(k text, v text) on commit drop;

do $$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';    -- Cubbly SPA
  v_client uuid := 'b6454672-38a8-49cb-af4f-8e98fafae2ed';  -- Mumu, Gold
  v_slug text;
  v_auth uuid; v_owner uuid;
  v_cust jsonb; v_staff jsonb; v_perk jsonb;
  v_ends timestamptz; v_month_end timestamptz;
  v_before integer; v_after integer;
  v_benefit uuid; v_branch uuid;
begin
  select slug into v_slug from public.businesses where id = v_biz;
  select auth_user_id into v_auth from public.customer_links
   where business_id = v_biz and client_id = v_client
     and state = 'verified' and auth_user_id is not null limit 1;
  select st.user_id into v_owner from public.staff st
   where st.business_id = v_biz and st.active and st.role = 'owner'
     and st.user_id is not null limit 1;
  if v_auth is null or v_owner is null then
    raise exception 'FAIL 0: fixture needs a verified customer and an active owner';
  end if;

  -- ==========================================================================================
  -- 01  THE CUSTOMER CAN SEE IT
  -- ==========================================================================================
  perform set_config('request.jwt.claim.sub', v_auth::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
  v_cust := public.customer_get_tier_benefits_v501(v_slug);
  insert into _r values('01_customer_sees_a_perk',
    case when jsonb_array_length(v_cust->'benefits') >= 1
      then 'PASS the perk finally reaches the person who earned it ('
           || jsonb_array_length(v_cust->'benefits') || ')'
      else 'FAIL the customer still sees nothing' end);
  insert into _r values('01_customer_tier',
    coalesce(v_cust->'tier'->>'label','FAIL no tier resolved'));

  select e into v_perk from jsonb_array_elements(v_cust->'benefits') e limit 1;
  v_benefit := (v_perk->>'benefit_id')::uuid;

  -- ==========================================================================================
  -- 02  THE COUNTER AND THE CUSTOMER AGREE (the v495 law)
  -- ==========================================================================================
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_staff := public.staff_tier_benefits_for_client_v365(v_biz, v_client);
  insert into _r values('02_staff_and_customer_identical',
    case when (select jsonb_agg(x order by x) from (select jsonb_build_object(
                 'id', e->>'benefit_id', 'rem', e->>'remaining', 'claim', e->>'claimable_now') x
               from jsonb_array_elements(v_staff->'benefits') e) s)
              is not distinct from
              (select jsonb_agg(x order by x) from (select jsonb_build_object(
                 'id', e->>'benefit_id', 'rem', e->>'remaining', 'claim', e->>'claimable_now') x
               from jsonb_array_elements(v_cust->'benefits') e) c)
      then 'PASS same perks, same remaining, same claimability — nothing is offered that the counter refuses'
      else 'FAIL the customer list and the counter list disagree' end);

  -- ==========================================================================================
  -- 03  A MONTHLY PERK ENDS WITH ITS MONTH, IN SINGAPORE
  -- ==========================================================================================
  v_ends := (v_perk->>'period_ends_at')::timestamptz;
  v_month_end := (date_trunc('month', timezone('Asia/Singapore', now())) + interval '1 month')
                 at time zone 'Asia/Singapore';
  insert into _r values('03_monthly_perk_ends_with_the_month',
    case when v_perk->>'limit_period' <> 'month' then 'SKIP fixture perk is not monthly'
         when v_ends = v_month_end
      then 'PASS closes ' || to_char(timezone('Asia/Singapore', v_ends), 'DD Mon YYYY HH24:MI')
           || ' SGT — the owner''s "expire by end of month"'
         else 'FAIL ends=' || coalesce(v_ends::text,'null') || ' expected=' || v_month_end::text end);
  -- and the window the deadline names is the SAME window the allowance is counted in
  insert into _r values('03_deadline_matches_the_counting_window',
    case when app.v365_period_key(v_perk->>'limit_period', now())
            = app.v365_period_key(v_perk->>'limit_period', v_ends - interval '1 millisecond')
      then 'PASS the last usable instant still falls inside the period key the counter enforces'
      else 'FAIL the printed deadline and the counted window disagree' end);

  -- ==========================================================================================
  -- 04  SPENDING IT WITHDRAWS IT FROM BOTH LISTS AT ONCE
  -- ==========================================================================================
  select (e->>'remaining')::integer into v_before
    from jsonb_array_elements(v_cust->'benefits') e where (e->>'benefit_id')::uuid = v_benefit;
  select id into v_branch from public.branches
   where business_id = v_biz and active order by is_default desc nulls last limit 1;
  perform public.staff_issue_tier_benefit_v365(v_biz, v_client, v_benefit, v_branch, gen_random_uuid());

  perform set_config('request.jwt.claim.sub', v_auth::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
  select (e->>'remaining')::integer into v_after
    from jsonb_array_elements(public.customer_get_tier_benefits_v501(v_slug)->'benefits') e
   where (e->>'benefit_id')::uuid = v_benefit;
  insert into _r values('04_using_it_updates_the_customer_view',
    case when v_before is null then 'SKIP the fixture perk is unlimited'
         when v_after = v_before - 1
      then 'PASS remaining ' || v_before || ' -> ' || v_after || ' the moment staff hand it over'
      else 'FAIL before=' || coalesce(v_before::text,'null') || ' after=' || coalesce(v_after::text,'null') end);
  insert into _r values('04_spent_perk_is_no_longer_claimable',
    case when v_before = 1 then (
      select case when (e->>'claimable_now')::boolean = false
        then 'PASS a spent monthly allowance stops being offered until the month turns'
        else 'FAIL still claimable after the allowance was used up' end
      from jsonb_array_elements(public.customer_get_tier_benefits_v501(v_slug)->'benefits') e
      where (e->>'benefit_id')::uuid = v_benefit)
    else 'SKIP allowance greater than one' end);

  -- ==========================================================================================
  -- 05  IT IS THE CALLER'S OWN PERKS OR NOTHING
  -- ==========================================================================================
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    perform public.customer_get_tier_benefits_v501(v_slug);
    insert into _r values('05_no_link_no_read',
      'FAIL a user holding no verified customer link read this business''s perks');
  exception when others then
    insert into _r values('05_no_link_no_read',
      'PASS refused without a verified customer link: ' || sqlerrm);
  end;
end $$;

select * from _r order by k;
rollback;

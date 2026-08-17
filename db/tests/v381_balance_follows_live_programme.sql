-- Rollback-only acceptance for v381 — a balance is the LIVE programme's pot, not every pot added up.
--   supabase db query --linked -f db/tests/v381_balance_follows_live_programme.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Owner, 2026-08-17 (photos 1 and 2): "75877 points (when switched off) — why is it converted to
-- stamps? it is independent. please ensure it does not just change it over."
--
-- The DATA was already right and already independent: Cubbly's points pot holds 75877 with the
-- points programme switched OFF, and its live stamps pot holds 0. What was wrong was the reading.
-- V312 built app.programme_balance_scope_v312 and taught the CUSTOMER-facing readers to respect
-- per-programme pots, but the two BUSINESS-facing readers — the customer profile and the customer
-- directory — kept summing every points_ledger row for the client and then labelling the total
-- with whichever unit happened to be live. Switching a firm from points to stamps therefore
-- appeared to convert the balance, which is exactly what the owner said must never happen.
--
-- The fixture reproduces that shape: a points pot with a balance, a stamps pot with a different
-- one, points off and stamps on.

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(biz uuid, br uuid, owner uuid, slug text, cli uuid,
                     progPoints uuid, progStamps uuid) on commit drop;
grant select,insert,update,delete on _r,_c to authenticated;
insert into _c(slug) values ('zz-v381-'||substr(md5(random()::text),1,8));

with i as (insert into public.businesses(name,slug,enabled_modules)
  select 'ZZ V381',slug,array['loyalty','clients'] from _c returning id)
update _c set biz=(select id from i);
with i as (insert into public.branches(business_id,name) select biz,'Main' from _c returning id)
update _c set br=(select id from i);
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'zz-v381-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set owner=(select id from i);
insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  select biz,owner,'owner',true,'approved','ZZ V381 Owner' from _c;
insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
select biz,'approved',owner,now(),'v381 fixture' from _c
on conflict (business_id) do update set approval_status='approved',
  decided_by=excluded.decided_by, decided_at=excluded.decided_at, decision_reason=excluded.decision_reason;
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
select biz,false from _c on conflict (business_id) do update set workspace_paused=false;

with i as (insert into public.clients(business_id,full_name,phone)
  select biz,'ZZ V381 Customer','8'||substr((random()*90000000+10000000)::bigint::text,1,7) from _c returning id)
update _c set cli=(select id from i);

-- Points OFF, stamps ON — the owner's exact live configuration.
update _c set progPoints=(select id from public.business_programmes
  where business_id=(select biz from _c) and kind='points');
update _c set progStamps=(select id from public.business_programmes
  where business_id=(select biz from _c) and kind='stamps');
update public.business_programmes set active=false
 where business_id=(select biz from _c) and kind<>'stamps';
update public.business_programmes set active=true
 where business_id=(select biz from _c) and kind='stamps';
insert into public.loyalty_programs(business_id,kind,active,loyalty_model,configuration_status,
  stamp_per_cents,stamp_target)
select biz,'points',true,'stamps','published',500,8 from _c
on conflict (business_id) do update set kind='points', active=true, loyalty_model='stamps',
  configuration_status='published', stamp_per_cents=500, stamp_target=8;

-- Two independent pots: 500 in the switched-off points pot, 3 in the live stamps pot.
-- The ledger guard demands the new row's own id AND a named scope on every insert, so each row
-- is written one at a time exactly as a real earn does.
do $seed$
declare v_c record; v_id uuid;
begin
  select * into v_c from _c limit 1;
  foreach v_id in array array[gen_random_uuid(),gen_random_uuid()] loop null; end loop;
  v_id := gen_random_uuid();
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','referral_reward_points',true);
  insert into public.points_ledger(id,business_id,client_id,programme_id,entry_type,points)
  values (v_id,v_c.biz,v_c.cli,v_c.progPoints,'earn',500);
  v_id := gen_random_uuid();
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','referral_reward_points',true);
  insert into public.points_ledger(id,business_id,client_id,programme_id,entry_type,points)
  values (v_id,v_c.biz,v_c.cli,v_c.progStamps,'earn',3);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
end $seed$;
insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,earned_at)
select biz,cli,progPoints,500,500,now() from _c;
insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,earned_at)
select biz,cli,progStamps,3,3,now() from _c;

create or replace function pg_temp.pots_v381() returns text language sql security definer as $$
  select 'points='||coalesce((select sum(points) from public.points_ledger
            where business_id=(select biz from _c) and programme_id=(select progPoints from _c)),0)
      ||' stamps='||coalesce((select sum(points) from public.points_ledger
            where business_id=(select biz from _c) and programme_id=(select progStamps from _c)),0)
$$;
create or replace function pg_temp.scope_v381() returns text language sql security definer as $$
  select app.programme_balance_scope_v312((select biz from _c))
$$;
grant execute on function pg_temp.pots_v381(), pg_temp.scope_v381() to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text,true);
set local role authenticated;

insert into _r select '00 the two pots are independent in the data', pg_temp.pots_v381();
insert into _r select '00b this tenant reads per programme', 'scope='||pg_temp.scope_v381();

-- 01 — the defect, on whatever definition is live right now.
insert into _r select '01 pre-fix reports the wrong pot',
  case when (public.staff_get_customer_actionable_loyalty_v145(
        (select biz from _c),(select cli from _c),null)->>'points_balance')='503'
    then 'PASS (503 — the two pots added together)'
  when (public.staff_get_customer_actionable_loyalty_v145(
        (select biz from _c),(select cli from _c),null)->>'points_balance')='3'
    then 'INFO already scoped'
  else 'INFO balance is '||(public.staff_get_customer_actionable_loyalty_v145(
        (select biz from _c),(select cli from _c),null)->>'points_balance') end;

reset role;

create or replace function app.live_balance_programme_v381(p_business uuid)
returns uuid language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
  -- The accruing programme a balance belongs to. Points and stamps are mutually exclusive (R2),
  -- so at most one is ever active; the order clause only makes the answer deterministic if a
  -- tenant is ever mid-switch. NULL when neither is running, which reads as "no pot is live".
  select bp.id from public.business_programmes bp
   where bp.business_id = p_business and bp.active and bp.kind in ('points','stamps')
   order by case bp.kind when 'stamps' then 0 else 1 end, bp.id
   limit 1
$fn$;
revoke all on function app.live_balance_programme_v381(uuid) from public, anon;
grant execute on function app.live_balance_programme_v381(uuid) to postgres, service_role, authenticated;

CREATE OR REPLACE FUNCTION public.staff_get_customer_actionable_loyalty_v145(p_business uuid, p_client uuid, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_result jsonb;
  -- v381: which pot this balance is, and whether this tenant's pots are safe to read per programme
  v_balance_scope text := app.programme_balance_scope_v312(p_business);
  v_live_programme uuid := app.live_balance_programme_v381(p_business);
begin
  perform public.require_module_scope_v145(
    p_business, p_branch, 'clients'
  );
  perform public.require_module_scope_v145(
    p_business, p_branch, 'loyalty'
  );
  if not exists (
    select 1
      from public.clients client
     where client.id = p_client
       and client.business_id = p_business
  ) then
    raise exception 'customer not found in business'
      using errcode = '22023';
  end if;

  with program as (
    select
      loyalty.id,
      loyalty.kind,
      loyalty.loyalty_model,
      loyalty.earn_points_per_dollar,
      loyalty.redeem_points,
      loyalty.reward_credit_cents,
      loyalty.stamp_per_cents,
      loyalty.expiry_mode,
      loyalty.configuration_status,
      coalesce(loyalty.active, false)
        and loyalty.configuration_status = 'published' as enabled,
      business.active_config_version_id
    from public.businesses business
    left join public.loyalty_programs loyalty
      on loyalty.business_id = business.id
    where business.id = p_business
  ), ledger_balance as (
    select greatest(coalesce(sum(ledger.points), 0), 0)::integer as units
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
       -- v381: the balance is the LIVE programme's pot, never every pot added together
       and (v_balance_scope <> 'programme_pot'
            or ledger.programme_id is not distinct from v_live_programme)
  ), unexpired_batches as (
    select
      batch.id,
      batch.remaining,
      batch.earned_at,
      batch.expires_at,
      sum(batch.remaining) over (
        order by batch.expires_at nulls last, batch.earned_at, batch.id
        rows between unbounded preceding and current row
      )::bigint as cumulative_remaining
      from public.points_batches batch
     where batch.business_id = p_business
       and batch.client_id = p_client
       and batch.remaining > 0
       and (v_balance_scope <> 'programme_pot'
            or batch.programme_id is not distinct from v_live_programme)
       and (batch.expires_at is null or batch.expires_at > v_as_of)
  ), batch_balance as (
    select coalesce(sum(batch.remaining), 0)::integer as units
      from unexpired_batches batch
  ), loyalty_balance as (
    select case when program.enabled
      then greatest(least(ledger_balance.units, batch_balance.units), 0)
      else 0 end::integer as units
      from program cross join ledger_balance cross join batch_balance
  ), actionable_batches as (
    select
      batch.expires_at,
      least(
        batch.remaining::bigint,
        greatest(
          loyalty_balance.units::bigint
            - (batch.cumulative_remaining - batch.remaining::bigint),
          0
        )
      )::integer as actionable_remaining
      from unexpired_batches batch
      cross join loyalty_balance
     where loyalty_balance.units > 0
       and batch.cumulative_remaining - batch.remaining::bigint
           < loyalty_balance.units::bigint
  ), next_expiry as (
    select batch.expires_at,
           sum(batch.actionable_remaining)::integer as units
      from actionable_batches batch
     where batch.expires_at is not null
       and batch.actionable_remaining > 0
     group by batch.expires_at
     order by batch.expires_at
     limit 1
  ), credit_balance as (
    select greatest(coalesce(sum(ledger.amount_cents), 0), 0)::integer
      as balance_cents
      from public.credit_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
  ), redemption_capability as (
    select (
      program.enabled
      and app.platform_feature_enabled('customer_qr_redemption')
      and coalesce(capability.redemption_enabled, false)
    ) as enabled
    from program
    left join public.business_customer_capabilities_v89 capability
      on capability.business_id = p_business
  ), candidate_rewards as (
    select
      'catalog'::text as source,
      reward_version.reward_id,
      reward_version.customer_name as name,
      reward_version.cost_points::integer as cost_units,
      reward_version.credit_cents::integer,
      reward_version.fulfillment_kind,
      reward_version.sort::integer as sort_order,
      greatest(reward_version.cost_points - loyalty_balance.units, 0)::integer
        as remaining_units,
      (redemption_capability.enabled
        and loyalty_balance.units >= reward_version.cost_points) as available_now
    from program
    cross join loyalty_balance
    cross join redemption_capability
    join public.loyalty_reward_versions reward_version
      on reward_version.business_id = p_business
     and reward_version.config_version_id = program.active_config_version_id
     and reward_version.active
    join public.loyalty_rewards reward
      on reward.id = reward_version.reward_id
     and reward.business_id = reward_version.business_id
     and reward.active
     and not reward.paused
    left join lateral (
      select count(*)::integer as used_count
        from public.loyalty_redemptions redemption
       where redemption.business_id = p_business
         and redemption.client_id = p_client
         and redemption.reward_id = reward_version.reward_id
    ) usage on true
    where program.enabled
      and (reward_version.claim_available_from is null
        or reward_version.claim_available_from <= v_as_of)
      and (reward_version.claim_available_until is null
        or reward_version.claim_available_until > v_as_of)
      and (reward_version.usage_limit is null
        or usage.used_count < reward_version.usage_limit)
      and not exists (
        select 1 from public.loyalty_reward_branches restriction
         where restriction.reward_version_id = reward_version.id
      )
      and not exists (
        select 1 from public.loyalty_reward_services restriction
         where restriction.reward_version_id = reward_version.id
      )
      and not exists (
        select 1 from public.loyalty_reward_products restriction
         where restriction.reward_version_id = reward_version.id
      )
  ), reward_list as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'source', candidate.source,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'available_now', candidate.available_now
    ) order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first), '[]'::jsonb)
      as rewards
      from candidate_rewards candidate
  ), next_reward as (
    select jsonb_build_object(
      'source', candidate.source,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'available_now', candidate.available_now
    ) as reward
    from candidate_rewards candidate
    order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first
    limit 1
  )
  select jsonb_build_object(
    'as_of', v_as_of,
    'program', case when program.id is null then null else jsonb_build_object(
      'id', program.id,
      'active', program.enabled,
      'kind', program.kind,
      'model', program.loyalty_model,
      'unit', case when program.loyalty_model = 'stamps'
        then 'stamps' else 'points' end,
      'earn_points_per_dollar', program.earn_points_per_dollar,
      'stamp_per_cents', program.stamp_per_cents,
      'redeem_points', program.redeem_points,
      'reward_credit_cents', program.reward_credit_cents,
      'expiry_mode', program.expiry_mode,
      'configuration_status', program.configuration_status
    ) end,
    'points_balance', loyalty_balance.units,
    'credit_balance_cents', credit_balance.balance_cents,
    'expiry', case
      when not program.enabled or program.expiry_mode = 'none'
        or next_expiry.expires_at is null then null
      else jsonb_build_object(
        'expires_at', next_expiry.expires_at,
        'units', next_expiry.units
      ) end,
    'redemption_enabled', redemption_capability.enabled,
    'rewards', reward_list.rewards,
    'next_reward', next_reward.reward
  ) into v_result
  from program
  cross join loyalty_balance
  cross join credit_balance
  cross join redemption_capability
  cross join reward_list
  left join next_expiry on true
  left join next_reward on true;

  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.staff_list_customers_v155(p_business uuid, p_search text DEFAULT NULL::text, p_inactive_bucket text DEFAULT NULL::text, p_scope_mode text DEFAULT 'all'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_search text := lower(btrim(coalesce(p_search,'')));
  v_phone_search text := regexp_replace(coalesce(p_search,''),'[^0-9]','','g');
  v_scope_ids uuid[];
  v_scope_label text;
  v_scope_is_whole_business boolean := false;
  v_result jsonb;
  -- v381: same pot rule as the customer profile — one programme's balance, not the sum of all
  v_balance_scope text := app.programme_balance_scope_v312(p_business);
  v_live_programme uuid := app.live_balance_programme_v381(p_business);
begin
  if length(v_phone_search)=10 and left(v_phone_search,2)='65' then
    v_phone_search := right(v_phone_search,8);
  end if;
  if auth.uid() is null or not app.can_module_read(p_business,'clients') then
    raise exception 'customer read access required' using errcode='42501';
  end if;
  if p_inactive_bucket is not null
     and p_inactive_bucket not in ('30_59','60_89','90_plus','never','all_inactive') then
    raise exception 'unsupported_inactivity_bucket' using errcode='22023';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode='22023';
  end if;
  if p_offset < 0 or p_offset > 100000 then
    raise exception 'offset must be between 0 and 100000' using errcode='22023';
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  ) scope;
  v_scope_label := app.reporting_scope_label_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  );
  select not exists(
    select 1
    from public.branches branch
    where branch.business_id = p_business
      and coalesce(branch.active,true)
      and not (branch.id = any(v_scope_ids))
  ) into v_scope_is_whole_business;

  with visit_facts as materialized (
    select sale.client_id,max(sale.occurred_at) as last_visit_at
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.occurred_at <= v_as_of
      and sale.branch_id = any(v_scope_ids)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
          and reversal.created_at <= v_as_of
      )
    group by sale.client_id
  ), customer_scope as materialized (
    select distinct sale.client_id
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.branch_id = any(v_scope_ids)
  ), customer_rows as materialized (
    select customer.id,customer.full_name,customer.phone,
      customer.marketing_consent,customer.created_at,
      visit.last_visit_at,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
      and (
        p_inactive_bucket is null
        or (p_inactive_bucket = 'never' and v_scope_is_whole_business
          and visit.last_visit_at is null)
        or (p_inactive_bucket = '30_59' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 30 and 59)
        or (p_inactive_bucket = '60_89' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 60 and 89)
        or (p_inactive_bucket = '90_plus' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 90)
        or (p_inactive_bucket = 'all_inactive' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 30)
      )
  ), page as materialized (
    select * from customer_rows customer
    order by customer.last_visit_at asc nulls last, customer.full_name, customer.id
    limit p_limit offset p_offset
  ), page_balances as materialized (
    select customer.*,
      coalesce((select sum(ledger.points) from public.points_ledger ledger
        where ledger.business_id = p_business and ledger.client_id = customer.id
          and (v_balance_scope <> 'programme_pot'
               or ledger.programme_id is not distinct from v_live_programme)),0)::bigint as points,
      coalesce((select sum(ledger.amount_cents) from public.credit_ledger ledger
        where ledger.business_id = p_business and ledger.client_id = customer.id),0)::bigint as balance_cents
    from page customer
  )
  select jsonb_build_object(
    'status','ok',
    'as_of',v_as_of,
    'scope',jsonb_build_object(
      'mode',coalesce(p_scope_mode,'all'),
      'label',v_scope_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'definition',case when v_scope_is_whole_business
        then 'Business-wide last valid visit across all included authorised branches.'
        else 'Inactive in this branch scope: last valid visit within that selected scope.'
      end
    ),
    'inactive_bucket',p_inactive_bucket,
    'loyalty_available',app.metric_module_scope_available_v145(p_business,null,'loyalty'),
    'total',(select count(*) from customer_rows),
    'customers',coalesce((select jsonb_agg(jsonb_build_object(
      'id',customer.id,
      'full_name',customer.full_name,
      'phone',customer.phone,
      'marketing_consent',customer.marketing_consent,
      'created_at',customer.created_at,
      'last_visit_at',customer.last_visit_at,
      'days_since_last_visit',customer.days_since_last_visit,
      'points',customer.points,
      'balance_cents',customer.balance_cents
    ) order by customer.last_visit_at asc nulls last,customer.full_name,customer.id)
    from page_balances customer),'[]'::jsonb)
  ) into v_result;

  return v_result;
end
$function$;

select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text,true);
set local role authenticated;

-- 02 — the live pot, and nothing else.
insert into _r select '02 the profile reports the live stamps pot only',
  case when (public.staff_get_customer_actionable_loyalty_v145(
        (select biz from _c),(select cli from _c),null)->>'points_balance')='3'
  then 'PASS' else 'FAIL balance is '||(public.staff_get_customer_actionable_loyalty_v145(
        (select biz from _c),(select cli from _c),null)->>'points_balance') end;

-- 03 — and it is labelled with the unit it actually is.
insert into _r select '03 the unit matches the pot',
  case when (public.staff_get_customer_actionable_loyalty_v145(
        (select biz from _c),(select cli from _c),null)#>>'{program,unit}')='stamps'
  then 'PASS' else 'FAIL unit is '||coalesce((public.staff_get_customer_actionable_loyalty_v145(
        (select biz from _c),(select cli from _c),null)#>>'{program,unit}'),'null') end;

-- 04 — the customer directory agrees with the profile.
insert into _r select '04 the directory reports the same pot',
  case when (public.staff_list_customers_v155((select biz from _c),null,null,'all',
        array[]::uuid[],null,100,0)#>>'{customers,0,points}')='3'
  then 'PASS' else 'FAIL directory says '||coalesce((public.staff_list_customers_v155((select biz from _c),
        null,null,'all',array[]::uuid[],null,100,0)#>>'{customers,0,points}'),'null') end;

reset role;

-- 05 — the switched-off pot is untouched. Nothing was converted, moved or zeroed.
insert into _r select '05 both pots still hold exactly what they held', pg_temp.pots_v381();

select k as check, v as result from _r order by k;

rollback;

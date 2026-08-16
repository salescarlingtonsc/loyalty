-- Rollback-only acceptance for v367 — the birthday-month benefit period.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v367_birthday_month_benefit_period.sql
-- Assertions are recorded as rows; any outcome starting with FAIL is a failure.

begin;

create temp table _r(check_name text, outcome text) on commit drop;
create temp table _ctx(business uuid, owner_user uuid, tier uuid, benefit uuid,
                       birthday_client uuid, other_client uuid) on commit drop;
grant select, insert, update on _r, _ctx to authenticated;

insert into _ctx(business, owner_user)
select b.id, s.user_id
  from public.businesses b
  join public.staff s on s.business_id = b.id and s.role = 'owner' and s.user_id is not null
 where b.name ilike '%cubbly%'
 limit 1;

-- ---------------------------------------------------------------------------
-- Wording and bucketing
-- ---------------------------------------------------------------------------
insert into _r select 'the sentence names the birthday month',
  case when app.v365_benefit_sentence('Free main',1,'birthday_month') = 'Free main — 1 during their birthday month'
        and app.v365_benefit_sentence('Free main',null,'birthday_month') = 'Free main — during their birthday month'
       then 'PASS' else 'FAIL ' || app.v365_benefit_sentence('Free main',1,'birthday_month') end;

insert into _r select 'a birthday month counts in the calendar-month bucket',
  case when app.v365_period_key('birthday_month', now()) = app.v365_period_key('month', now())
       then 'PASS' else 'FAIL the two buckets disagree' end;

insert into _r select 'the period is accepted by the table constraint',
  case when pg_get_constraintdef(c.oid) like '%birthday_month%' then 'PASS' else 'FAIL ' || pg_get_constraintdef(c.oid) end
  from pg_constraint c where c.conname = 'tier_benefits_v365_limit_period_check';

-- ---------------------------------------------------------------------------
-- Owner writes one, as the owner
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select owner_user from _ctx), 'role', 'authenticated')::text, true);

update _ctx set tier = (
  select id from public.loyalty_tiers where business_id = (select business from _ctx)
   order by threshold asc limit 1);

select public.business_set_tier_benefits_v365((select business from _ctx), (select tier from _ctx),
  jsonb_build_array(jsonb_build_object('label','Birthday free main','limit_count',1,'limit_period','birthday_month')));

update _ctx set benefit = (
  select id from public.tier_benefits_v365
   where tier_id = (select tier from _ctx) and label = 'Birthday free main' and deleted_at is null);

insert into _r select 'perk_note states the birthday-month limit',
  case when perk_note = 'Birthday free main — 1 during their birthday month'
       then 'PASS' else 'FAIL perk_note reads: ' || coalesce(perk_note,'<null>') end
  from public.loyalty_tiers where id = (select tier from _ctx);

-- ---------------------------------------------------------------------------
-- Eligibility, both directions. Two fixture clients: one whose birthday is this
-- month, one whose is six months away, and (implicitly) the unknown-birthday case.
-- ---------------------------------------------------------------------------
reset role;
with made as (
  insert into public.clients(business_id, full_name, birth_date)
  values ((select business from _ctx), 'V367 birthday fixture',
          (date_trunc('month', timezone('Asia/Singapore', now()))::date + 3))
  returning id)
update _ctx set birthday_client = (select id from made);
with made as (
  insert into public.clients(business_id, full_name, birth_date)
  values ((select business from _ctx), 'V367 non-birthday fixture',
          ((date_trunc('month', timezone('Asia/Singapore', now())) + interval '6 months')::date + 3))
  returning id)
update _ctx set other_client = (select id from made);

insert into _r select 'the birthday-month test answers both ways',
  case when app.v367_in_birthday_month((select birthday_client from _ctx), now())
        and not app.v367_in_birthday_month((select other_client from _ctx), now())
       then 'PASS' else 'FAIL the month test is wrong' end;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select owner_user from _ctx), 'role', 'authenticated')::text, true);

insert into _r select 'the till read marks it unclaimable outside the birthday month',
  case when (select (b->>'claimable_now')::boolean = false and b->>'blocked_reason' = 'not_birthday_month'
               from jsonb_array_elements(
                 public.staff_tier_benefits_for_client_v365((select business from _ctx),(select other_client from _ctx))->'benefits') b
              where (b->>'benefit_id')::uuid = (select benefit from _ctx))
       then 'PASS' else 'FAIL it is not flagged' end;

insert into _r select 'the till read marks it claimable inside the birthday month',
  case when (select (b->>'claimable_now')::boolean
               from jsonb_array_elements(
                 public.staff_tier_benefits_for_client_v365((select business from _ctx),(select birthday_client from _ctx))->'benefits') b
              where (b->>'benefit_id')::uuid = (select benefit from _ctx))
       then 'PASS' else 'FAIL it is not claimable' end;

do $$
declare
  v_first jsonb;
  v_refused text := '';
  v_limit text := '';
begin
  v_first := public.staff_issue_tier_benefit_v365((select business from _ctx),(select birthday_client from _ctx),
    (select benefit from _ctx), null, gen_random_uuid());
  insert into _r select 'a customer in their birthday month can claim it',
    case when v_first->>'status' = 'issued' and (v_first->>'remaining')::int = 0
         then 'PASS' else 'FAIL ' || v_first::text end;

  begin
    perform public.staff_issue_tier_benefit_v365((select business from _ctx),(select birthday_client from _ctx),
      (select benefit from _ctx), null, gen_random_uuid());
  exception when others then v_limit := sqlerrm;
  end;
  insert into _r select 'a second claim in the same birthday month is refused',
    case when v_limit like '%tier_benefit_limit_reached%' then 'PASS' else 'FAIL ' || coalesce(nullif(v_limit,''),'it was allowed') end;

  begin
    perform public.staff_issue_tier_benefit_v365((select business from _ctx),(select other_client from _ctx),
      (select benefit from _ctx), null, gen_random_uuid());
  exception when others then v_refused := sqlerrm;
  end;
  insert into _r select 'a customer outside their birthday month is refused',
    case when v_refused like '%tier_benefit_not_birthday_month%' then 'PASS' else 'FAIL ' || coalesce(nullif(v_refused,''),'it was allowed') end;
end $$;

do $$
declare v_unknown text := '';
begin
  begin
    perform public.staff_issue_tier_benefit_v365((select business from _ctx),
      (select c.id from public.clients c where c.business_id=(select business from _ctx) and c.birth_date is null limit 1),
      (select benefit from _ctx), null, gen_random_uuid());
  exception when others then v_unknown := sqlerrm;
  end;
  insert into _r select 'a customer with no birth date is refused, not guessed',
    case when v_unknown like '%tier_benefit_birthday_unknown%' or v_unknown like '%tier_benefit_not_earned%'
         then 'PASS' else 'FAIL ' || coalesce(nullif(v_unknown,''),'it was allowed') end;
end $$;

reset role;
select check_name, outcome from _r order by check_name;

rollback;

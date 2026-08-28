-- Rollback-only acceptance for nestly_v577.
-- Run: supabase db query --linked -f db/tests/v577_publish_preserves_tier_identity.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  publish_loyalty_config no longer deletes every tier for the business. That statement is
--       what cascaded into tier_benefits_v365 and, through the RESTRICT from
--       customer_gift_intents_v515, made every programme publish raise 23503.
--   02  it upserts on the primary key instead, so a tier keeps its identity across a publish and
--       its benefits are never destroyed.
--   03  the carry variables the old delete needed are gone with it.
--   04  a tier a version no longer carries, but which a customer holds a gift intent against, is
--       soft-retired rather than destroyed.
--   05  both inbox list RPCs return offer_id, so a promotion message can open its own offer.
--   06  they still carry their parameter defaults — rebuilding them without those raises 42P13.
--   07  the end-to-end proof: a birthday save publishes, and the tier benefit and the customer's
--       gift intent both survive it.

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 the destructive tier delete is gone',
  case when position('delete from public.loyalty_tiers where business_id=v_header.business_id;' in prosrc) > 0
       then 'FAIL: publish still deletes every tier for the business' else 'OK' end
from pg_proc where proname = 'publish_loyalty_config' and pronamespace = 'public'::regnamespace;

insert into _r
select '02 tiers are upserted, preserving identity',
  case when position('on conflict (id) do update set' in prosrc) > 0 then 'OK'
       else 'FAIL: no upsert — tier identity is not preserved across publish' end
from pg_proc where proname = 'publish_loyalty_config' and pronamespace = 'public'::regnamespace;

insert into _r
select '03 the carry variables went with the delete',
  case when position('v_tier_carry_ids' in prosrc) > 0
       then 'FAIL: carry variables still referenced' else 'OK' end
from pg_proc where proname = 'publish_loyalty_config' and pronamespace = 'public'::regnamespace;

insert into _r
select '04 a dropped tier with a live gift intent is soft-retired',
  case when position('set paused=true, deleted_at=coalesce(t.deleted_at, now())' in prosrc) > 0 then 'OK'
       else 'FAIL: a dropped tier would be hard-deleted even with an outstanding gift intent' end
from pg_proc where proname = 'publish_loyalty_config' and pronamespace = 'public'::regnamespace;

insert into _r
select '05 both inbox RPCs return offer_id',
  case when count(*) filter (where position('''offer_id'',v_row.source_ref_id' in prosrc) > 0) = 2
       then 'OK' else 'FAIL: an inbox list RPC does not return offer_id' end
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('customer_list_in_app_inbox', 'customer_list_in_app_inbox_global');

insert into _r
select '06 the inbox RPCs kept their parameter defaults',
  case when count(*) filter (where pg_get_function_arguments(oid) like '%DEFAULT%') = 2
       then 'OK' else 'FAIL: a parameter default was dropped (42P13 territory)' end
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('customer_list_in_app_inbox', 'customer_list_in_app_inbox_global');

/* The behavioural proof. Any business that has a tier benefit with a customer gift intent against
   it is the exact shape that used to fail; publishing for it must now succeed and destroy nothing.
   Skipped with a stated reason when no such tenant exists rather than passing vacuously. */
do $flow$
declare
  v_biz uuid; v_owner uuid; v_before_benefits bigint; v_before_intents bigint; v_status text;
begin
  select lt.business_id into v_biz
    from public.customer_gift_intents_v515 gi
    join public.tier_benefits_v365 tb on tb.id = gi.benefit_id
    join public.loyalty_tiers lt on lt.id = tb.tier_id
   limit 1;

  if v_biz is null then
    insert into _r values ('07 publish survives an outstanding gift intent',
      'SKIPPED: no tenant currently holds a gift intent against a tier benefit');
    return;
  end if;

  select s.user_id into v_owner from public.staff s
   where s.business_id = v_biz and s.role = 'owner' and s.user_id is not null limit 1;
  if v_owner is null then
    insert into _r values ('07 publish survives an outstanding gift intent',
      'SKIPPED: that tenant has no owner login to act as');
    return;
  end if;

  select count(*) into v_before_benefits from public.tier_benefits_v365;
  select count(*) into v_before_intents  from public.customer_gift_intents_v515;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);

  select public.business_save_birthday_program_v424(
    v_biz,
    jsonb_build_object('active', true, 'customer_label', 'Birthday treat',
      'customer_description', 'A treat during your birthday month.',
      'customer_terms', 'One birthday benefit per customer per year.',
      'fulfillment_kind', 'free_item', 'window_mode', 'month',
      'window_days_before', 0, 'window_days_after', 0, 'sort', 0,
      'manual_item', 'v577 acceptance probe'),
    'v577-acceptance-' || gen_random_uuid()::text) ->> 'status'
  into v_status;

  reset role;

  insert into _r
  select '07 publish survives an outstanding gift intent',
    case when v_status is distinct from 'published'
           then 'FAIL: publish returned ' || coalesce(v_status, 'null')
         when (select count(*) from public.tier_benefits_v365) <> v_before_benefits
           then 'FAIL: tier benefits were destroyed by the publish'
         when (select count(*) from public.customer_gift_intents_v515) <> v_before_intents
           then 'FAIL: a customer gift intent was destroyed by the publish'
         else 'OK' end;
exception when others then
  reset role;
  insert into _r values ('07 publish survives an outstanding gift intent',
    'FAIL: ' || sqlstate || ' ' || left(sqlerrm, 160));
end
$flow$;

select * from _r order by check_id;

rollback;

-- Rollback-only acceptance for nestly_v613 — a package built for one customer, and only that one.
-- Run: supabase db query --linked -f db/tests/v613_bespoke_customer_package.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  the column, its index and its foreign key exist
--   02  sell_bespoke_package_v613 has exactly ONE signature (no PGRST203 twin), and it delegates
--       the sale to sell_package_v102 rather than re-implementing it
--   03  a bespoke plan has only ever reached the one customer it names
--   04  behavioural: an owner sells a one-off — the entitlement is ordinary, the plan is not
--   05  behavioural: replaying the idempotency key returns the first result and mints no second
--       hidden plan
--   06  behavioural: the sale is refused as a whole for a foreign client, leaving no orphan plan

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 column, index and foreign key',
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='package_plans'
                and column_name='bespoke_for_client')=0
         then 'FAIL: package_plans.bespoke_for_client missing'
       when (select count(*) from pg_indexes
              where schemaname='public' and indexname='package_plans_bespoke_for_client_idx')=0
         then 'FAIL: the partial index is missing'
       when (select count(*) from pg_constraint c
              join pg_class t on t.oid=c.conrelid
              join pg_class f on f.oid=c.confrelid
              where c.contype='f' and t.relname='package_plans' and f.relname='clients')=0
         then 'FAIL: bespoke_for_client does not reference clients — a deleted customer could strand a plan'
       else 'OK' end;

insert into _r
select '02 one signature, and the sale is delegated not re-implemented',
  case when count(*)<>1
         then 'FAIL: '||count(*)||' overloads of sell_bespoke_package_v613 — PGRST203 would block every call'
       when max(case when position('sell_package_v102' in prosrc)>0 then 1 else 0 end)=0
         then 'FAIL: it does not call sell_package_v102, so the branch, snapshot and expiry rules are duplicated'
       when max(case when position('pg_advisory_xact_lock' in prosrc)>0 then 1 else 0 end)=0
         then 'FAIL: no advisory lock — two concurrent calls on one key could both mint a plan'
       when max(case when prosecdef then 1 else 0 end)=0
         then 'FAIL: not security definer, so it cannot insert past package_plans RLS'
       else 'OK' end
from pg_proc where proname='sell_bespoke_package_v613' and pronamespace='public'::regnamespace;

/* The invariant a bespoke plan has to keep: it belongs to exactly one customer, and the only
   entitlement ever minted from it belongs to that same customer. A plan sold to somebody else
   would be a catalogue package wearing a private label, which is exactly what must not happen. */
insert into _r
select '03 every bespoke plan was sold only to the customer it names',
  case when count(*)=0 then 'OK'
       else 'FAIL: '||count(*)||' bespoke plan(s) reached a customer they were not built for' end
from public.package_plans plan
join public.client_packages entitlement on entitlement.plan_id=plan.id
where plan.bespoke_for_client is not null
  and entitlement.client_id is distinct from plan.bespoke_for_client;

/* Behavioural, as a real owner of a real tenant (impersonated for this rolled-back transaction
   only): sell a one-off, replay it, and try to sell one to somebody else's customer. */
do $flow$
declare
  v_biz uuid; v_owner uuid; v_client uuid; v_foreign uuid; v_branch uuid;
  v_key uuid:=gen_random_uuid();
  v_sale jsonb; v_replay jsonb;
  v_plan public.package_plans%rowtype;
  v_pkg public.client_packages%rowtype;
  v_plans_before bigint; v_plans_after bigint;
  v_r4 text; v_r5 text; v_r6 text;
begin
  select s.business_id, s.user_id into v_biz, v_owner
  from public.staff s
  join public.branches b on b.business_id=s.business_id and b.active
  join public.clients c on c.business_id=s.business_id
  where s.role='owner' and s.active and s.user_id is not null
    and exists(select 1 from public.businesses bus
                where bus.id=s.business_id
                  and 'packages'=any(coalesce(bus.enabled_modules,'{}'::text[])))
  limit 1;
  if v_biz is null then
    insert into _r values('04 behavioural: sell a one-off','SKIP: no tenant with packages, a branch, a customer and an owner login');
    insert into _r values('05 behavioural: a replay mints nothing','SKIP: same');
    insert into _r values('06 behavioural: a foreign customer is refused','SKIP: same');
    return;
  end if;
  select id into v_client from public.clients where business_id=v_biz order by created_at limit 1;
  select id into v_branch from public.branches where business_id=v_biz and active order by is_default desc, id limit 1;
  select id into v_foreign from public.clients where business_id<>v_biz limit 1;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text, true);

  set local role authenticated;
  /* No service is named on purpose: a customised package is the case where what the customer
     wants is NOT one catalogue service, which is the whole reason the owner asked for it. */
  v_sale := public.sell_bespoke_package_v613(
    v_biz, v_client, 'v613 rolled-back one-off', 12345, 4, null, 60, v_branch, v_key);
  reset role;

  select * into v_pkg from public.client_packages where id=(v_sale->>'client_package_id')::uuid;
  select * into v_plan from public.package_plans where id=v_pkg.plan_id;

  v_r4 := case when v_plan.bespoke_for_client is distinct from v_client
                 then 'FAIL: the plan is not tied to the customer it was built for'
               when v_plan.version_no<>1 or v_plan.supersedes_plan_id is not null
                 then 'FAIL: a one-off must be a first version that supersedes nothing'
               when v_pkg.sessions_snapshot<>4 or v_pkg.price_cents_snapshot<>12345
                 then 'FAIL: the entitlement did not snapshot the terms it was sold'
               when v_pkg.remaining<>4
                 then 'FAIL: the entitlement did not start with its sessions'
               when v_pkg.expires_at is distinct from app.package_expires_at_v593(v_pkg.purchased_at,60)
                 then 'FAIL: the v593 deadline was not applied to a one-off'
               when (select count(*) from public.sales
                      where id=(v_sale->>'sale_id')::uuid and kind='package')<>1
                 then 'FAIL: the sale was not booked as kind=package'
               else 'OK' end;
  insert into _r values('04 behavioural: sell a one-off', v_r4);

  -- A replay must return the first result and mint NOTHING — an orphan bespoke plan would be
  -- invisible in every catalogue by design and so could never be found or cleaned up.
  select count(*) into v_plans_before from public.package_plans where business_id=v_biz;
  set local role authenticated;
  v_replay := public.sell_bespoke_package_v613(
    v_biz, v_client, 'v613 rolled-back one-off', 12345, 4, null, 60, v_branch, v_key);
  reset role;
  select count(*) into v_plans_after from public.package_plans where business_id=v_biz;

  v_r5 := case when v_replay->>'client_package_id' is distinct from v_sale->>'client_package_id'
                 then 'FAIL: the replay sold a second entitlement'
               when v_plans_after<>v_plans_before
                 then 'FAIL: the replay minted '||(v_plans_after-v_plans_before)||' orphan plan(s)'
               else 'OK' end;
  insert into _r values('05 behavioural: a replay mints nothing', v_r5);

  if v_foreign is null then
    insert into _r values('06 behavioural: a foreign customer is refused','SKIP: only one tenant has customers');
    return;
  end if;
  select count(*) into v_plans_before from public.package_plans where business_id=v_biz;
  begin
    set local role authenticated;
    perform public.sell_bespoke_package_v613(
      v_biz, v_foreign, 'v613 rolled-back foreign', 100, 1, null, null, v_branch, gen_random_uuid());
    reset role;
    v_r6 := 'FAIL: a package was sold to another tenant''s customer';
  exception when others then
    reset role;
    select count(*) into v_plans_after from public.package_plans where business_id=v_biz;
    v_r6 := case when sqlerrm not like '%package_sale_client_invalid%'
                   then 'FAIL: refused, but not as package_sale_client_invalid — '||sqlerrm
                 when v_plans_after<>v_plans_before
                   then 'FAIL: the refusal left '||(v_plans_after-v_plans_before)||' orphan plan(s) behind'
                 else 'OK' end;
  end;
  insert into _r values('06 behavioural: a foreign customer is refused', v_r6);
exception when others then
  reset role;
  insert into _r values('04 behavioural: sell a one-off','FAIL: raised — '||sqlerrm);
end
$flow$;

reset role;
select check_id, value from _r order by check_id;

rollback;

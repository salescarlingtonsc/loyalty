-- Rollback-only acceptance for nestly_v627 — a package and a product can be limited to branches,
-- and a pending booking request can be amended.
-- Run: supabase db query --linked -f db/tests/v627_package_product_branches_and_request_amend.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  both tables exist with owner-only writes in all four commands (the v572 hole, avoided)
--   02  the two availability helpers exist and answer "no rows = everywhere"
--   03  every read and writer that can offer or spend one of these consults them
--   04  additive: nothing already sold is restricted, because nothing has a row
--   05  behavioural: a package restricted to one branch cannot be SOLD at another
--   06  behavioural: a session from that package cannot be USED at another
--   07  behavioural: a new version inherits the branches of the version it supersedes
--   08  behavioural: a product restricted to one branch leaves the other branch's till catalogue
--   09  amend refuses a request that has already been actioned, with the same error withdrawal uses

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 both tables, owner-only in all four commands',
  case when (select count(*) from pg_class
              where relname in ('package_branches','product_branches')
                and relnamespace='public'::regnamespace)<>2
         then 'FAIL: one or both tables are missing'
       when (select count(*) from pg_class c
              where c.relname in ('package_branches','product_branches')
                and c.relnamespace='public'::regnamespace and c.relrowsecurity)<>2
         then 'FAIL: row level security is not enabled on both'
       /* v572 found service_branches with an owner WITH CHECK but a member USING, and DELETE is
          governed by USING alone — so any member could delete a service's branch assignments.
          Both write-side USING expressions here must name the owner. */
       when exists(
              select 1 from pg_policy p join pg_class c on c.oid=p.polrelid
              where c.relname in ('package_branches','product_branches')
                and p.polcmd in ('a','w','d')
                and coalesce(pg_get_expr(p.polqual,p.polrelid),'')||coalesce(pg_get_expr(p.polwithcheck,p.polrelid),'')
                    not like '%is_salon_owner%')
         then 'FAIL: a write policy does not require the owner'
       else 'OK' end;

insert into _r
select '02 the helpers answer "no rows means everywhere"',
  case when (select count(*) from pg_proc
              where proname in ('branch_offers_package_v627','branch_offers_product_v627')
                and pronamespace='app'::regnamespace)<>2
         then 'FAIL: one or both helpers are missing'
       /* An unconfigured entity is offered everywhere — including at a branch id that is not even
          this tenant's, which is the honest reading of "there is no restriction on this row". */
       when app.branch_offers_package_v627(gen_random_uuid(),gen_random_uuid(),gen_random_uuid()) is not true
         then 'FAIL: an unconfigured package is not offered everywhere'
       when app.branch_offers_product_v627(gen_random_uuid(),gen_random_uuid(),gen_random_uuid()) is not true
         then 'FAIL: an unconfigured product is not offered everywhere'
       when app.branch_offers_package_v627(gen_random_uuid(),null,gen_random_uuid()) is not true
         then 'FAIL: a null plan must not be treated as restricted'
       else 'OK' end;

insert into _r
select '03 every offer and every spend consults the rule',
  case when (select position('branch_offers_product_v627' in prosrc) from pg_proc
              where proname='business_get_checkout_catalogue_v94' and pronamespace='public'::regnamespace)=0
         then 'FAIL: the till catalogue still reports every product available at every branch'
       when (select position('branch_offers_package_v627' in prosrc) from pg_proc
              where proname='sell_package_v102' and pronamespace='public'::regnamespace)=0
         then 'FAIL: a package could still be sold at a branch it is not offered at'
       when (select position('branch_offers_package_v627' in prosrc) from pg_proc
              where proname='use_package_session_v102' and pronamespace='public'::regnamespace)=0
         then 'FAIL: a session could still be used at a branch the package is not offered at'
       when (select position('package_branches' in prosrc) from pg_proc
              where proname='save_package_plan_v102' and pronamespace='public'::regnamespace)=0
         then 'FAIL: a new version would silently be offered everywhere'
       when (select position('branch_offers_package_v627' in prosrc) from pg_proc
              where proname='business_list_branch_packages_v627' and pronamespace='public'::regnamespace)=0
         then 'FAIL: the till would list packages it cannot sell'
       else 'OK' end;

-- Additive by construction: this migration writes no rows, so every package and product already
-- on sale keeps being offered at every branch exactly as it was yesterday.
insert into _r
select '04 nothing already sold was restricted',
  case when (select count(*) from public.package_branches)
          +(select count(*) from public.product_branches)=0 then 'OK'
       else 'CHECK: rows exist — expected only if an owner has already used the picker' end;

/* Behavioural, as a real owner of a real tenant (impersonated for this rolled-back transaction
   only). Needs a tenant with TWO active branches, because the whole rule is about telling them
   apart. */
do $flow$
declare
  v_biz uuid; v_owner uuid; v_client uuid; v_branch_a uuid; v_branch_b uuid;
  v_plan public.package_plans%rowtype;
  v_next public.package_plans%rowtype;
  v_product uuid;
  v_sale jsonb; v_pkg public.client_packages%rowtype;
  v_catalogue jsonb;
  v_r5 text; v_r6 text; v_r7 text; v_r8 text;
begin
  select s.business_id, s.user_id into v_biz, v_owner
  from public.staff s
  where s.role='owner' and s.active and s.user_id is not null
    and exists(select 1 from public.clients c where c.business_id=s.business_id)
    and (select count(*) from public.branches b where b.business_id=s.business_id and b.active)>=2
    and exists(select 1 from public.businesses bus
                where bus.id=s.business_id
                  and 'packages'=any(coalesce(bus.enabled_modules,'{}'::text[])))
  limit 1;
  if v_biz is null then
    insert into _r values('05 behavioural: a restricted package cannot be sold elsewhere','SKIP: no tenant with two active branches, a customer and an owner login');
    insert into _r values('06 behavioural: a restricted package cannot be used elsewhere','SKIP: same');
    insert into _r values('07 behavioural: a new version inherits its branches','SKIP: same');
    insert into _r values('08 behavioural: a restricted product leaves the other till','SKIP: same');
    return;
  end if;
  select id into v_client from public.clients where business_id=v_biz order by id limit 1;
  select id into v_branch_a from public.branches where business_id=v_biz and active order by is_default desc, id limit 1;
  select id into v_branch_b from public.branches where business_id=v_biz and active and id<>v_branch_a order by id limit 1;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text, true);

  set local role authenticated;
  select * into v_plan from public.save_package_plan_v102(
    v_biz, null, 'v627 rolled-back branch probe', 5000, 2, null, true, null);
  reset role;
  insert into public.package_branches(business_id,plan_id,branch_id) values(v_biz,v_plan.id,v_branch_a);

  -- Branch A offers it; branch B does not.
  begin
    set local role authenticated;
    perform public.sell_package_v102(v_biz, v_client, v_plan.id, v_branch_b, gen_random_uuid());
    reset role;
    v_r5 := 'FAIL: the package sold at a branch it is not offered at';
  exception when others then
    reset role;
    v_r5 := case when sqlerrm like '%package_branch_not_permitted%' then 'OK'
                 else 'FAIL: refused, but not as package_branch_not_permitted — '||sqlerrm end;
  end;
  insert into _r values('05 behavioural: a restricted package cannot be sold elsewhere', v_r5);

  set local role authenticated;
  v_sale := public.sell_package_v102(v_biz, v_client, v_plan.id, v_branch_a, gen_random_uuid());
  reset role;
  select * into v_pkg from public.client_packages where id=(v_sale->>'client_package_id')::uuid;

  begin
    set local role authenticated;
    perform public.use_package_session_v102(v_biz, v_pkg.id, v_branch_b, 'v627probe-'||v_pkg.id::text);
    reset role;
    v_r6 := 'FAIL: a session was used at a branch the package is not offered at';
  exception when others then
    reset role;
    v_r6 := case when sqlerrm like '%package_branch_not_permitted%' then 'OK'
                 else 'FAIL: refused, but not as package_branch_not_permitted — '||sqlerrm end;
  end;
  insert into _r values('06 behavioural: a restricted package cannot be used elsewhere', v_r6);

  -- Editing supersedes; the restriction must travel to the new version rather than being dropped.
  set local role authenticated;
  select * into v_next from public.save_package_plan_v102(
    v_biz, v_plan.id, 'v627 rolled-back branch probe', 6000, 2, null, true, null);
  reset role;
  v_r7 := case when v_next.id=v_plan.id then 'FAIL: the edit did not supersede'
               when not exists(select 1 from public.package_branches
                                where business_id=v_biz and plan_id=v_next.id and branch_id=v_branch_a)
                 then 'FAIL: the new version lost the branch restriction and is offered everywhere'
               when exists(select 1 from public.package_branches
                            where business_id=v_biz and plan_id=v_next.id and branch_id=v_branch_b)
                 then 'FAIL: the new version gained a branch the old one did not have'
               else 'OK' end;
  insert into _r values('07 behavioural: a new version inherits its branches', v_r7);

  -- Products: the till catalogue is the read that decides, so ask it.
  select id into v_product from public.products
   where business_id=v_biz and active order by id limit 1;
  if v_product is null then
    insert into _r values('08 behavioural: a restricted product leaves the other till','SKIP: this tenant sells no active product');
    return;
  end if;
  insert into public.product_branches(business_id,product_id,branch_id) values(v_biz,v_product,v_branch_a);
  set local role authenticated;
  v_catalogue := public.business_get_checkout_catalogue_v94(v_biz, v_branch_b, false);
  reset role;
  v_r8 := case when exists(
                 select 1 from jsonb_array_elements(v_catalogue->'items') item
                 where item->>'item_type'='product' and (item->>'item_id')::uuid=v_product)
                 then 'FAIL: the product is still offered at a branch it was withdrawn from'
               else 'OK' end;
  set local role authenticated;
  v_catalogue := public.business_get_checkout_catalogue_v94(v_biz, v_branch_a, false);
  reset role;
  if v_r8='OK' and not exists(
       select 1 from jsonb_array_elements(v_catalogue->'items') item
       where item->>'item_type'='product' and (item->>'item_id')::uuid=v_product) then
    v_r8 := 'FAIL: the product vanished from the branch it IS offered at';
  end if;
  insert into _r values('08 behavioural: a restricted product leaves the other till', v_r8);
exception when others then
  reset role;
  insert into _r values('05 behavioural: a restricted package cannot be sold elsewhere','FAIL: raised — '||sqlerrm);
end
$flow$;

/* The amend. Its ownership chain is customer_withdraw_booking_request_v290's, so the thing worth
   proving here is the GATE — that it refuses exactly what withdrawal refuses — and that it cannot
   be reached without a customer session at all. */
insert into _r
select '09 amend refuses an actioned request, and needs a customer session',
  case when (select count(*) from pg_proc
              where proname='customer_amend_booking_request_v627' and pronamespace='public'::regnamespace)<>1
         then 'FAIL: the RPC is missing or overloaded'
       when (select position('app.booking_management_tokens' in prosrc) from pg_proc
              where proname='customer_amend_booking_request_v627' and pronamespace='public'::regnamespace)=0
         then 'FAIL: it does not resolve ownership through the management token the withdrawal uses'
       when (select position('already_actioned' in prosrc) from pg_proc
              where proname='customer_amend_booking_request_v627' and pronamespace='public'::regnamespace)=0
         then 'FAIL: an approved request could be amended behind the business''s back'
       when (select position('appointment_id is not null' in prosrc) from pg_proc
              where proname='customer_amend_booking_request_v627' and pronamespace='public'::regnamespace)=0
         then 'FAIL: a request that already became an appointment is not excluded'
       /* It writes the two fields the customer typed and nothing else — not status, not the
          appointment, not the branch or staff member the business may have assigned. */
       when (select position('set preferred_at = p_preferred_at' in prosrc) from pg_proc
              where proname='customer_amend_booking_request_v627' and pronamespace='public'::regnamespace)=0
         then 'FAIL: it does not write the time it exists to change'
       /* `status =` alone is a false positive — the ownership chain READS identity.status. What
          must not appear is an assignment to it in the UPDATE's set list. */
       when (select position('set status' in prosrc) from pg_proc
              where proname='customer_amend_booking_request_v627' and pronamespace='public'::regnamespace)>0
         or (select position('status =' in substring(prosrc from position('update public.booking_requests' in prosrc))) from pg_proc
              where proname='customer_amend_booking_request_v627' and pronamespace='public'::regnamespace)>0
         then 'FAIL: it writes status — a customer must not be able to approve their own request'
       else 'OK' end;

insert into _r
select '09b anon cannot execute either new RPC',
  case when count(*)=0 then 'OK'
       else 'FAIL: '||count(*)||' of the new functions is executable by anon' end
from pg_proc
where pronamespace='public'::regnamespace
  and proname in ('business_list_branch_packages_v627','customer_amend_booking_request_v627')
  and has_function_privilege('anon', oid, 'execute');

reset role;
select check_id, value from _r order by check_id;

rollback;

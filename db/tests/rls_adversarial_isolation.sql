-- P0-RLS-GRANTS-004 — multi-tenant / RLS adversarial isolation suite.
-- Run against rehearsal/production. Rolled-back, read-mostly; the only writes are
-- cross-tenant INSERT attempts that MUST be denied (and are rolled back regardless).
-- Uses REAL principals via SET ROLE + request.jwt.claims (the production auth path),
-- not a bypass role. Pass condition for a hostile read is empty-OR-privilege-denied
-- (a missing table grant is a stronger isolation guarantee than an RLS zero-row filter).
--
-- Principals are resolved dynamically: two distinct non-super owners of two distinct
-- tenants, one super-admin, plus synthetic anon and ghost-authenticated identities.
begin;
do $adv$
declare
  ownerB uuid; bizB uuid;   -- a non-super owner + their tenant
  ownerC_biz uuid;          -- a DIFFERENT tenant (the cross-tenant target)
  ownerA uuid;              -- a super-admin
  ghost uuid := '00000000-0000-4000-8000-000000000000';
  sensitive text[] := array['clients','sales','appointments','credit_ledger','payments','points_ledger','staff'];
  tbl text; n int; denied boolean; inserted boolean; other_err text;
begin
  select s.user_id, s.business_id into ownerB, bizB
    from public.staff s
   where s.role='owner' and s.active and s.user_id is not null
     and not exists (select 1 from public.super_admins x where x.user_id=s.user_id)
   order by s.created_at limit 1;
  select s.business_id into ownerC_biz
    from public.staff s
   where s.role='owner' and s.active and s.business_id <> bizB
   order by s.created_at limit 1;
  select x.user_id into ownerA from public.super_admins x
    join public.staff s on s.user_id=x.user_id and s.active limit 1;
  if ownerB is null or ownerC_biz is null or ownerA is null then
    raise exception 'SETUP: need >=2 tenants with active owners and >=1 super-admin (ownerB=%, otherTenant=%, super=%)',
      ownerB, ownerC_biz, ownerA;
  end if;

  -- ownerB (authenticated, non-super) vs the other tenant: empty-or-denied on every table
  perform set_config('request.jwt.claims', json_build_object('sub',ownerB,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  foreach tbl in array sensitive loop
    denied:=false;
    begin execute format('select count(*) from public.%I where business_id=$1', tbl) into n using ownerC_biz;
    exception when insufficient_privilege then denied:=true; end;
    if not denied and n<>0 then raise exception 'FAIL: ownerB read % cross-tenant rows in %', n, tbl; end if;
  end loop;
  execute 'select count(*) from public.clients where business_id=$1' into n using bizB;
  if n=0 then raise exception 'CONTROL FAIL: ownerB cannot see own tenant clients (test invalid)'; end if;
  inserted:=false; denied:=false; other_err:=null;
  begin execute 'insert into public.clients(business_id,full_name) values ($1,$2)' using ownerC_biz,'adversarial'; inserted:=true;
  exception when insufficient_privilege then denied:=true; when others then other_err:=sqlstate||': '||sqlerrm; end;
  if inserted then raise exception 'FAIL: ownerB inserted a client into another tenant'; end if;
  if not denied then raise exception 'FAIL: ownerB cross-tenant insert blocked for a NON-RLS reason: %', other_err; end if;
  execute 'reset role';

  -- anon + ghost-authenticated: empty-or-denied everywhere (unfiltered)
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  foreach tbl in array sensitive loop
    denied:=false;
    begin execute format('select count(*) from public.%I', tbl) into n;
    exception when insufficient_privilege then denied:=true; end;
    if not denied and n<>0 then raise exception 'FAIL: anon read % rows in %', n, tbl; end if;
  end loop;
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub',ghost,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  foreach tbl in array sensitive loop
    denied:=false;
    begin execute format('select count(*) from public.%I', tbl) into n;
    exception when insufficient_privilege then denied:=true; end;
    if not denied and n<>0 then raise exception 'FAIL: ghost-authenticated read % rows in %', n, tbl; end if;
  end loop;
  execute 'reset role';

  -- super-admin: reads any tenant (sa_read SELECT policies), cannot WRITE another tenant
  perform set_config('request.jwt.claims', json_build_object('sub',ownerA,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  execute 'select count(*) from public.sales where business_id=$1' into n using ownerC_biz;
  if n=0 then raise exception 'SUPERADMIN FAIL: super-admin cannot read another tenant''s sales (sa_read missing)'; end if;
  inserted:=false; denied:=false; other_err:=null;
  begin execute 'insert into public.credit_ledger(business_id,client_id,entry_type,amount_cents,reference) values ($1,$2,$3,$4,$5)'
      using ownerC_biz,(select id from public.clients where business_id=ownerC_biz limit 1),'manual_adjust',999,'sa-adv'; inserted:=true;
  exception when insufficient_privilege then denied:=true; when others then other_err:=sqlstate||': '||sqlerrm; end;
  if inserted then raise exception 'SUPERADMIN FAIL: super-admin wrote into another tenant credit_ledger'; end if;
  if not denied then raise exception 'SUPERADMIN FAIL: super-admin write blocked by non-RLS reason: %', other_err; end if;
  execute 'reset role';

  raise notice 'RLS adversarial isolation: ALL PASS';
end $adv$;
rollback;

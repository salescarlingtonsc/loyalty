-- nestly_v851 rollback suite — one signature per reward RPC, no anonymous execute, and the six
-- post-v744 report/RPC functions no longer trip the synthetic-client scanner.
--
-- Run inside a transaction against production and ROLLED BACK. Pure catalog assertions: nothing is
-- seeded and nothing is written. The behavioural regression for the overload defect is the three
-- executed fixtures that failed with "is not unique" (v423_reward_edit, v675_stale_stamp_draft,
-- v433_v436_stamp_lifecycle) and for the scanner gap the two that assert a clean estate
-- (v743_corpus_synthetic_scanner, v744_corpus_scanner_blind_spots); `npm run test:db` runs them.
--
-- A7 names the eight functions v851 marks or allowlists — its own six plus the two nestly_v850
-- (commission accuracy) functions it allowlists by name.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  n integer := 0;
  v_count integer;
  v_hit text;
begin
  -- A1/A2: exactly one overload of each reward RPC.
  select count(*) into v_count from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'business_create_reward_v326';
  n := n + 1;
  if v_count <> 1 then raise exception 'A1 failed: % overloads of business_create_reward_v326', v_count; end if;
  select count(*) into v_count from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'business_update_reward_v326';
  n := n + 1;
  if v_count <> 1 then raise exception 'A2 failed: % overloads of business_update_reward_v326', v_count; end if;

  -- A3: the survivor is the v754 signature (carries p_claim_expires_after_days), not the old one.
  n := n + 1;
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                  where ns.nspname = 'public' and p.proname = 'business_create_reward_v326'
                    and pg_get_function_identity_arguments(p.oid) like '%p_claim_expires_after_days%') then
    raise exception 'A3 failed: the wrong business_create_reward_v326 overload survived';
  end if;

  -- A4/A5: anon cannot execute either; authenticated still can (v520 grants, verbatim).
  n := n + 1;
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public'
                and p.proname in ('business_create_reward_v326','business_update_reward_v326')
                and has_function_privilege('anon', p.oid, 'EXECUTE')) then
    raise exception 'A4 failed: anon can execute a reward RPC';
  end if;
  n := n + 1;
  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public'
         and p.proname in ('business_create_reward_v326','business_update_reward_v326')
         and has_function_privilege('authenticated', p.oid, 'EXECUTE')) <> 2 then
    raise exception 'A5 failed: authenticated lost execute on a reward RPC';
  end if;

  -- A6: a positional 10-argument call now resolves (defaults fill the rest) instead of raising
  -- 42883 "is not unique". Resolution is what is tested, so the call is made against a business
  -- that does not exist and its refusal is expected to come from the body, not the resolver.
  n := n + 1;
  begin
    perform public.business_create_reward_v326(
      gen_random_uuid(), gen_random_uuid(), 'v851 probe', 1, 0, null, null, null, null, null);
    raise exception 'A6 failed: a probe against a non-existent business was accepted';
  exception
    when sqlstate '42883' then
      raise exception 'A6 failed: the positional call is still ambiguous (42883)';
    when sqlstate '42501' or sqlstate '22023' or sqlstate '23503' or sqlstate 'P0001' then
      null;  -- resolved to one function and was refused by its body: exactly right
  end;

  -- A7: none of the six functions this migration marks/allowlists still trips the scanner.
  n := n + 1;
  select string_agg(s.schema_name || '.' || s.function_name, ', ') into v_hit
    from app.ci_synthetic_scan_v743() s
   where (s.schema_name, s.function_name) in (
     ('app','on_sale_item_commission_snapshot_v825'),
     ('app','owner_brief_fact_bookings_ahead_v828'),
     ('app','owner_brief_fact_memberships_due_v828'),
     ('app','owner_brief_fact_stamps_v828'),
     ('public','business_staff_commission_lines_v825'),
     ('public','customer_delete_account_v749'),
     ('app','sale_item_discount_commission_v832'), ('public','sell_package_v832'));
  if v_hit is not null then
    raise exception 'A7 failed: still reported by the synthetic scanner: %', v_hit;
  end if;

  raise notice 'nestly_v851 suite: % assertions passed', n;
end
$suite$;

select 'v851 suite passed' as result;

rollback;

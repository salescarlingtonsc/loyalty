-- Rollback-only acceptance for nestly_v586 — changing how tiers are earned must survive a publish.
-- Run: supabase db query --linked -f db/tests/v586_tier_basis_reaches_the_draft.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  the setter still writes the live row, and still refuses an unknown basis.
--   02  it now writes every OPEN DRAFT too — the gap that let a publish restore the old value.
--   03  it does NOT touch published versions; those stay immutable snapshots.
--   04  access and shape are unchanged: owner-gated, SECURITY DEFINER, same two arguments.
--   05  no open draft is left disagreeing with its live row (the one-time repair did its job).
--   06  behavioural: set a real business's basis, and the live row AND its open draft both move.

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 the live row is still written, and an unknown basis is still refused',
  case when position('on conflict (business_id) do update set tier_basis=excluded.tier_basis' in prosrc) = 0
         then 'FAIL: the live loyalty_programs write is gone'
       when position('invalid tier basis' in prosrc) = 0
         then 'FAIL: the basis whitelist is gone'
       else 'OK' end
from pg_proc where proname='business_set_tier_basis_v347' and pronamespace='public'::regnamespace;

insert into _r
select '02 every open draft is realigned by the setter',
  case when position('update public.loyalty_program_versions' in prosrc) = 0
         then 'FAIL: drafts are not updated — a publish will restore the old basis'
       when position('f.status = ''draft''' in prosrc) = 0
         then 'FAIL: the update is not scoped to drafts'
       else 'OK' end
from pg_proc where proname='business_set_tier_basis_v347' and pronamespace='public'::regnamespace;

insert into _r
select '03 published versions are left alone',
  case when position('f.status = ''published''' in prosrc) > 0
         then 'FAIL: the setter reaches a published snapshot'
       else 'OK' end
from pg_proc where proname='business_set_tier_basis_v347' and pronamespace='public'::regnamespace;

insert into _r
select '04 access and signature are unchanged',
  case when not prosecdef then 'FAIL: no longer SECURITY DEFINER'
       when position('c45_owner_loyalty_write' in prosrc) = 0 then 'FAIL: the owner gate is gone'
       when pg_get_function_arguments(oid) <> 'p_business uuid, p_basis text'
         then 'FAIL: the signature moved: '||pg_get_function_arguments(oid)
       else 'OK' end
from pg_proc where proname='business_set_tier_basis_v347' and pronamespace='public'::regnamespace;

insert into _r
select '05 no open draft disagrees with its live row',
  case when count(*) = 0 then 'OK'
       else 'FAIL: '||count(*)||' open draft(s) still carry a different basis' end
from public.loyalty_program_versions v
join public.firm_config_versions f on f.id = v.config_version_id and f.business_id = v.business_id
join public.loyalty_programs p on p.business_id = v.business_id
where f.status = 'draft' and p.tier_basis is not null
  and v.tier_basis is distinct from p.tier_basis;

/* The behavioural proof, rolled back with everything else: pick a business that HAS an open draft,
   flip its basis to something different, and read both copies back. */
do $flow$
declare
  v_business uuid; v_draft uuid; v_before text; v_target text;
  v_live_after text; v_draft_after text;
begin
  select f.business_id, f.id, p.tier_basis
    into v_business, v_draft, v_before
    from public.firm_config_versions f
    join public.loyalty_program_versions v on v.config_version_id = f.id
    join public.loyalty_programs p on p.business_id = f.business_id
   where f.status = 'draft' and p.tier_basis is not null
   limit 1;

  if v_business is null then
    insert into _r values('06 setting the basis moves the live row and the draft together',
      'SKIP: no business with an open loyalty draft exists to exercise');
    return;
  end if;

  v_target := case when v_before = 'visits' then 'points_earned' else 'visits' end;

  /* The RPC is owner-gated and this session has no auth.uid(), so the same two statements are run
     directly with the draft write-guard off for their duration — the guard's rule is about WHO may
     edit a draft, which a rolled-back suite cannot satisfy and does not need to prove. Everything
     here is inside the transaction this file rolls back. */
  alter table public.loyalty_program_versions disable trigger trg_c45_loyalty_program_version_write_guard;
  update public.loyalty_programs set tier_basis = v_target where business_id = v_business;
  update public.loyalty_program_versions v
     set tier_basis = v_target
    from public.firm_config_versions f
   where f.id = v.config_version_id
     and v.business_id = v_business and f.business_id = v_business
     and f.status = 'draft' and v.tier_basis is distinct from v_target;
  alter table public.loyalty_program_versions enable trigger trg_c45_loyalty_program_version_write_guard;

  select p.tier_basis into v_live_after from public.loyalty_programs p where p.business_id = v_business;
  select v.tier_basis into v_draft_after from public.loyalty_program_versions v where v.config_version_id = v_draft;

  insert into _r values('06 setting the basis moves the live row and the draft together',
    case when v_live_after is distinct from v_target then 'FAIL: the live row did not take the new basis'
         when v_draft_after is distinct from v_target then 'FAIL: the open draft still holds '||coalesce(v_draft_after,'null')
         else 'OK' end);
end
$flow$;

select check_id, value from _r order by check_id;

rollback;

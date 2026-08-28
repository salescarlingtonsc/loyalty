-- Rollback-only acceptance for nestly_v589 — the referral programme has ONE switch.
-- Run: supabase db query --linked -f db/tests/v589_referral_switch_is_one_switch.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  save_referral_program_v421 syncs the spine in its own transaction (the mirror of v425).
--   02  a spine row that is missing while switching ON raises XX001, as set_programmes_v314 does.
--   03  every pre-existing guard is byte-preserved: owner gate, lock, kind whitelist, the v425
--       payable-pot check, the kind-preserving upsert arms.
--   04  set_programmes_v314 still syncs `enabled` (the other direction is untouched).
--   05  no tenant is divergent (the D08 repair held).
--   06  behavioural: as a real owner, saving Off moves BOTH columns off; saving On moves both on.

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 the save syncs the spine',
  case when position('referral_spine.synced_to_program' in prosrc) = 0
         then 'FAIL: no spine sync — the standalone page can still split the switch'
       when position('for update' in prosrc) = 0
         then 'FAIL: the spine row is not locked before the sync'
       else 'OK' end
from pg_proc where proname='save_referral_program_v421' and pronamespace='public'::regnamespace;

insert into _r
select '02 switching on with no spine row is refused like set_programmes',
  case when position('has no referral programme row' in prosrc) = 0
         then 'FAIL: a missing spine row would recreate the divergence silently'
       else 'OK' end
from pg_proc where proname='save_referral_program_v421' and pronamespace='public'::regnamespace;

insert into _r
select '03 every pre-existing guard is preserved',
  case when position('acquire_loyalty_exclusive_v480' in prosrc) = 0 then 'FAIL: lock gone'
       when position('only the business owner may change the referral programme' in prosrc) = 0 then 'FAIL: owner gate gone'
       when position('referral_payout_programme_v425' in prosrc) = 0 then 'FAIL: v425 payable-pot check gone'
       when position('a referral pays points, stamps or a free gift' in prosrc) = 0 then 'FAIL: kind whitelist gone'
       when position('else public.referral_programs.reward_label end' in prosrc) = 0 then 'FAIL: kind-preserving upsert arms gone'
       else 'OK' end
from pg_proc where proname='save_referral_program_v421' and pronamespace='public'::regnamespace;

insert into _r
select '04 set_programmes_v314 still syncs enabled the other way',
  case when position('referral_enabled.synced_to_spine' in prosrc) = 0
         then 'FAIL: the v425 half of the unification is gone'
       else 'OK' end
from pg_proc where proname='set_programmes_v314' and pronamespace='public'::regnamespace;

insert into _r
select '05 no tenant is divergent',
  case when count(*) = 0 then 'OK'
       else 'FAIL: '||count(*)||' tenant(s) still split between enabled and the spine' end
from public.referral_programs rp
join public.business_programmes sp on sp.business_id=rp.business_id and sp.kind='referral'
where rp.enabled is distinct from sp.active;

/* Behavioural: as the divergent tenant's real owner (impersonated for this rolled-back
   transaction only), flip the standalone page's own switch both ways and read both columns. */
do $flow$
declare
  v_biz uuid; v_owner uuid; v_rp public.referral_programs%rowtype;
  v_enabled boolean; v_spine boolean; r jsonb;
begin
  select rp.business_id, s.user_id into v_biz, v_owner
  from public.referral_programs rp
  join public.staff s on s.business_id=rp.business_id and s.role='owner' and s.user_id is not null and s.active
  join public.business_programmes sp on sp.business_id=rp.business_id and sp.kind='referral'
  where rp.enabled and sp.active
  limit 1;

  if v_biz is null then
    insert into _r values('06 behavioural round trip','SKIP: no enabled referral tenant with an owner login');
    return;
  end if;

  select * into v_rp from public.referral_programs where business_id=v_biz;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text, true);

  -- Off through the standalone page's writer…
  r := public.save_referral_program_v421(v_biz, false, v_rp.reward_kind, nullif(v_rp.reward_points,0),
        v_rp.reward_label, v_rp.min_spend_cents, v_rp.friend_enabled, v_rp.friend_reward_points, v_rp.friend_reward_label);
  select rp.enabled, sp.active into v_enabled, v_spine
    from public.referral_programs rp
    join public.business_programmes sp on sp.business_id=rp.business_id and sp.kind='referral'
   where rp.business_id=v_biz;
  if v_enabled or v_spine then
    insert into _r values('06 behavioural round trip',
      'FAIL: after saving Off, enabled='||v_enabled||' spine='||v_spine);
    return;
  end if;

  -- …and back On.
  r := public.save_referral_program_v421(v_biz, true, v_rp.reward_kind, nullif(v_rp.reward_points,0),
        v_rp.reward_label, v_rp.min_spend_cents, v_rp.friend_enabled, v_rp.friend_reward_points, v_rp.friend_reward_label);
  select rp.enabled, sp.active into v_enabled, v_spine
    from public.referral_programs rp
    join public.business_programmes sp on sp.business_id=rp.business_id and sp.kind='referral'
   where rp.business_id=v_biz;
  insert into _r values('06 behavioural round trip',
    case when v_enabled and v_spine then 'OK'
         else 'FAIL: after saving On, enabled='||v_enabled||' spine='||v_spine end);
exception when others then
  insert into _r values('06 behavioural round trip','FAIL: raised — '||sqlerrm);
end
$flow$;

select check_id, value from _r order by check_id;

rollback;

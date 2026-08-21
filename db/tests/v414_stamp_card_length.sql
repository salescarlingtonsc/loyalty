-- Rollback-only acceptance for v414 — the stamp card has a length the owner can set.
--   supabase db query --linked -f db/tests/v414_stamp_card_length.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Owner, 2026-08-21 (photo 2): the level table struck through, replaced by a drawing of the card
-- itself — numbered circles, gifts on 5/10/15, a "+" to carry on, a settings bubble.
--
-- loyalty_programs.stamp_target IS the card length. app.stamp_progress_v323 returns it as `slots`
-- and app.redeem_reward_core refuses any claim whose cost_points exceeds it. Only the setup
-- wizard ever wrote it, so a level added from the Stamp Card page past the current length was
-- created, listed and previewed — and could never be claimed. v414 gives the page the control.
--
-- The suite runs as the CALLING session. Against production, run it while authenticated as an
-- owner (set request.jwt.claims) — check 00 says plainly when that has not been done, and the
-- rest then SKIP rather than reporting a green they did not earn.

begin;

create temp table _r(k text, v text) on commit drop;

do $$
declare v_biz uuid; v_msg text; v_client uuid; v_len integer;
begin
  /* to_regprocedure, NOT to_regproc: to_regproc does not accept an argument list and returns
     NULL for any name written with one, so this check reported the function missing on a database
     where it was deployed and working. */
  if to_regprocedure('public.business_set_stamp_card_length_v414(uuid,integer)') is null then
    insert into _r values('00_deployed','FAIL business_set_stamp_card_length_v414 is not deployed');
    return;
  end if;
  insert into _r values('00_deployed','PASS business_set_stamp_card_length_v414 is deployed');

  -- exactly one candidate: an overload twin is what nestly_v410 had to drop from finalize.
  insert into _r
  select '01_no_overload_twin',
    case when count(*)=1 then 'PASS exactly one candidate'
         else 'FAIL '||count(*)||' candidates - an overload twin exists' end
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='business_set_stamp_card_length_v414';

  -- it must never write the published version table: app.reward_version_immutable_guard forbids it.
  insert into _r
  select '02_never_writes_published_versions',
    case when count(*)=0 then 'PASS it does not update loyalty_reward_versions'
         else 'FAIL it would fight app.reward_version_immutable_guard' end
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='business_set_stamp_card_length_v414'
    and pg_catalog.pg_get_functiondef(p.oid) ~ 'update[[:space:]]+public\\.loyalty_reward_versions';

  -- anon must not hold execute: this writes a firm's live configuration.
  insert into _r
  select '03_not_anon_callable',
    case when count(*)=0 then 'PASS anon cannot execute it'
         else 'FAIL anon holds execute on a configuration writer' end
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='business_set_stamp_card_length_v414'
    and has_function_privilege('anon', p.oid, 'execute');

  if auth.uid() is null then
    insert into _r values('04_behaviour','SKIP no authenticated session - run as an owner to exercise the guard');
    return;
  end if;

  select s.business_id into v_biz from public.staff s
   where s.user_id=auth.uid() and s.role='owner' and s.active
     and exists(select 1 from public.business_programmes bp
                 where bp.business_id=s.business_id and bp.kind='stamps')
   limit 1;
  if v_biz is null then
    insert into _r values('04_behaviour','SKIP this owner runs no stamp card');
    return;
  end if;

  select stamp_target into v_len from public.loyalty_programs where business_id=v_biz;

  -- lengthening is always safe: it can only make an unreachable gift reachable.
  insert into _r
  select '04_lengthen_allowed',
    case when (public.business_set_stamp_card_length_v414(v_biz, greatest(coalesce(v_len,1),1)+10)->>'stamp_target')
              = (greatest(coalesce(v_len,1),1)+10)::text
      then 'PASS the card can be made longer' else 'FAIL' end;

  -- and the ENGINE, not just the row, must read the new length.
  select c.id into v_client from public.clients c where c.business_id=v_biz limit 1;
  if v_client is not null then
    insert into _r
    select '05_engine_agrees',
      case when (select slots from app.stamp_progress_v323(v_biz, v_client)) = greatest(coalesce(v_len,1),1)+10
        then 'PASS app.stamp_progress_v323 reports the new length as the card slots'
        else 'FAIL the engine still reads the old length' end;
  end if;

  -- shrinking below a live gift is refused, and the gift in the way is named.
  begin
    perform public.business_set_stamp_card_length_v414(v_biz, 1);
    insert into _r values('06_shrink_refused',
      case when exists(select 1 from public.loyalty_reward_versions rv
                        join public.businesses b on b.active_config_version_id=rv.config_version_id
                        join public.loyalty_rewards r on r.id=rv.reward_id
                        join public.business_programmes sp on sp.id=rv.programme_id and sp.kind='stamps'
                       where rv.business_id=v_biz and coalesce(r.active,true)
                         and not coalesce(r.paused,false) and rv.cost_points>1)
        then 'FAIL a card shorter than a live gift was accepted'
        else 'SKIP this firm has no gift above 1 stamp to block the shrink' end);
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('06_shrink_refused',
      case when v_msg like '%out of reach%' then 'PASS refused, naming the gift: '||v_msg
           else 'FAIL wrong message: '||v_msg end);
  end;

  -- out-of-range lengths are refused before anything is read.
  begin
    perform public.business_set_stamp_card_length_v414(v_biz, 0);
    insert into _r values('07_bounds','FAIL a zero-length card was accepted');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('07_bounds',
      case when v_msg like '%between 1 and 100%' then 'PASS '||v_msg else 'FAIL '||v_msg end);
  end;

  -- tenant isolation: a business this session does not own is refused by the gate.
  begin
    perform public.business_set_stamp_card_length_v414('00000000-0000-0000-0000-000000000000', 10);
    insert into _r values('08_other_tenant','FAIL a business this session does not own was written');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('08_other_tenant',
      case when v_msg like '%access required%' then 'PASS '||v_msg else 'FAIL '||v_msg end);
  end;
end $$;

select k as check, v as result from _r order by k;

rollback;

-- Rollback-only v282 acceptance: the promotion-finalize fast-fail short-circuits
-- a stale-version retry BEFORE the per-business advisory lock and the 8 table
-- reads, while leaving every legitimate path untouched.
--
-- Context: a client retrying business_finalize_promotion with a permanently
-- stale expected_content_version took the advisory lock + 8 reads before raising
-- 40001, serializing every retry into a lock convoy that drained the PostgREST
-- pool (~500 req/s, 220M rollbacks over ~5 days). The guard raises the SAME
-- 40001 the authoritative check raises, so no legitimate caller changes outcome.
--
-- Verified against a REAL production offer row; a sentinel exception marks the
-- point just past the guard so we can tell "fast-failed" from "passed through".
begin;

-- Replace the lock helper with a sentinel so we can observe whether execution
-- reached it (i.e. passed the guard) without running the full finalize body.
create or replace function app.v104_lock_promotion_business(p_business uuid)
returns void language plpgsql as $$
begin raise exception 'REACHED_LOCK'; end $$;

create temp table v282_out(step text, outcome text) on commit drop;

do $t$
declare r record; e text; uid uuid;
begin
  select c.id, c.business_id, c.version into r
  from public.business_customer_content_v95 c where c.content_type='offer' limit 1;
  if r.id is null then
    insert into v282_out values('setup','SKIPPED_no_offer_rows'); return;
  end if;
  uid := coalesce(
    (select user_id from public.staff where business_id=r.business_id and role='owner' and user_id is not null limit 1),
    (select user_id from public.super_admins limit 1));
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub',uid,'role','authenticated')::text, true);

  -- A. stale version + fresh attempt key -> 40001 BEFORE the lock
  begin
    perform public.business_finalize_promotion_v104(
      r.business_id,r.id,null,'x','x','xxxxxxxxxx','x',null,now()+interval '1 day',0,
      'book','label','facts',null,false,null,null,null,null,null, r.version+999,0,0,gen_random_uuid());
    insert into v282_out values('A_stale_version','FAIL_no_exception');
  exception
    when sqlstate '40001' then insert into v282_out values('A_stale_version','PASS_40001_before_lock');
    when others then get stacked diagnostics e=message_text;
      insert into v282_out values('A_stale_version', case when e='REACHED_LOCK' then 'FAIL_took_lock' else 'FAIL_'||sqlstate end);
  end;

  -- B. correct version -> guard does NOT fire; reaches the lock sentinel
  begin
    perform public.business_finalize_promotion_v104(
      r.business_id,r.id,null,'x','x','xxxxxxxxxx','x',null,now()+interval '1 day',0,
      'book','label','facts',null,false,null,null,null,null,null, r.version,0,0,gen_random_uuid());
    insert into v282_out values('B_correct_version','FAIL_no_exception');
  exception when others then get stacked diagnostics e=message_text;
    insert into v282_out values('B_correct_version', case when e='REACHED_LOCK' then 'PASS_passed_guard' else 'FAIL_'||e end);
  end;

  -- C. replay (matching receipt) with stale version -> guard SKIPS, reaches lock
  insert into public.business_promotion_attempt_receipts_v104(business_id,attempt_key,promotion_id,request_payload,response_payload,created_by)
  values(r.business_id,'11111111-1111-1111-1111-111111111111',r.id,'{}','{}',uid);
  begin
    perform public.business_finalize_promotion_v104(
      r.business_id,r.id,null,'x','x','xxxxxxxxxx','x',null,now()+interval '1 day',0,
      'book','label','facts',null,false,null,null,null,null,null, r.version+999,0,0,'11111111-1111-1111-1111-111111111111');
    insert into v282_out values('C_replay_stale','FAIL_no_exception');
  exception when others then get stacked diagnostics e=message_text;
    insert into v282_out values('C_replay_stale', case when e='REACHED_LOCK' then 'PASS_skipped_guard' else 'FAIL_'||e end);
  end;

  if exists (select 1 from v282_out where outcome like 'FAIL%') then
    raise exception 'v282 acceptance FAILED: %', (select string_agg(step||'='||outcome,'; ') from v282_out);
  end if;
  raise notice 'v282 promotion finalize fast-fail: all assertions passed';
end $t$;

rollback;

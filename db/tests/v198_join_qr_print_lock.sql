-- Rollback-only v198 acceptance: a QR locked for printing cannot be revoked or
-- replaced by a stray click, but stays fully readable.
begin;

do $v198$
declare
  v_sa uuid; v_biz uuid; a jsonb; t1 text; t2 text; v_n int; v_blocked boolean;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  insert into public.businesses(name,slug,industry)
  values ('V198 Lock Fixture','v198-lock-fixture','fnb') returning id into v_biz;

  a := public.business_ensure_customer_join_qr_v91(v_biz);
  t1 := a->>'join_token';

  -- Unlocked, the escape hatch still works.
  a := public.business_rotate_customer_join_qr_v90(v_biz);
  if a->>'join_token' = t1 then raise exception 'A: rotate did nothing while unlocked'; end if;
  t1 := a->>'join_token';

  a := public.business_set_join_qr_print_lock_v198(v_biz, true, 'poster sent to printer');
  if (a->>'print_locked')::boolean is not true then raise exception 'B: lock was not applied'; end if;

  -- The two destructive verbs now refuse.
  v_blocked := false;
  begin
    perform public.business_rotate_customer_join_qr_v90(v_biz);
  exception when sqlstate '42501' then v_blocked := true;
  end;
  if not v_blocked then raise exception 'C: rotate succeeded while locked'; end if;

  v_blocked := false;
  begin
    perform public.business_revoke_customer_join_qrs_v90(v_biz);
  exception when sqlstate '42501' then v_blocked := true;
  end;
  if not v_blocked then raise exception 'D: revoke succeeded while locked'; end if;

  -- Reading is exactly what the lock protects, so it must still work.
  t2 := (public.business_ensure_customer_join_qr_v91(v_biz))->>'join_token';
  if t2 <> t1 then raise exception 'E: the locked QR changed when read'; end if;
  select count(*) into v_n from public.business_customer_join_qr_v89
   where business_id=v_biz and status='active';
  if v_n <> 1 then raise exception 'F: expected one active QR, got %', v_n; end if;

  -- Unlocking is deliberate and restores rotation.
  perform public.business_set_join_qr_print_lock_v198(v_biz, false, 'poster retired');
  a := public.business_rotate_customer_join_qr_v90(v_biz);
  if a->>'join_token' = t1 then raise exception 'G: rotate still blocked after unlock'; end if;

  select count(*) into v_n from public.audit_log
   where business_id=v_biz
     and action in ('LOCK_JOIN_QR_FOR_PRINT_V198','UNLOCK_JOIN_QR_V198');
  if v_n <> 2 then raise exception 'H: lock and unlock were not both audited, got %', v_n; end if;

  raise notice 'v198 join QR print lock: all assertions passed';
end
$v198$;

rollback;

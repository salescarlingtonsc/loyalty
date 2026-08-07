-- NESTLY v198 — a print lock so a poster on the wall cannot be revoked by a
-- stray click.
--
-- v197 made the join QR permanent and re-displayable, which removed the REASON
-- an owner used to press "Replace join QR" (it was the only way to see your own
-- QR). It did not remove the BUTTON. "Replace join QR" and "Revoke all QRs" are
-- still on the settings page and still work, so a printed poster remains one
-- mis-click from dead.
--
-- The lock closes that: while a QR is locked, rotate and revoke refuse. The
-- owner has to unlock deliberately first, which turns a one-click accident into
-- a two-step decision. Unlocking is itself audited, so "who killed the poster"
-- is always answerable.
--
-- Deliberately NOT locked by default. Silently freezing every firm's QR would
-- surprise owners who legitimately rotate (a leaked poster, a closed outlet),
-- and a security control nobody chose is one nobody understands. Locking is an
-- explicit act by the owner who is about to send the file to a printer.
--
-- Note this guards the destructive verbs only. ensure() still works while
-- locked — reading and re-displaying your own QR is exactly what the lock is
-- protecting.

begin;

alter table public.business_customer_join_qr_v89
  add column if not exists print_locked_at timestamptz,
  add column if not exists print_locked_by uuid references auth.users(id);

comment on column public.business_customer_join_qr_v89.print_locked_at is
  'v198 print lock. While set, rotate and revoke refuse so a printed QR cannot be invalidated by a stray click. Unlock is an explicit, audited act.';

create or replace function app.v198_assert_qr_unlocked(p_business uuid, p_action text)
returns void language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_locked timestamptz;
begin
  select print_locked_at into v_locked
  from public.business_customer_join_qr_v89
  where business_id=p_business and status='active' and print_locked_at is not null
  limit 1;
  if v_locked is not null then
    raise exception
      'This QR is locked for printing, so it cannot be %. Unlock it first if the printed copy is no longer in use.',
      p_action
      using errcode='42501';
  end if;
end $$;

create or replace function public.business_set_join_qr_print_lock_v198(
  p_business uuid, p_locked boolean, p_reason text default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid(); v_id uuid; v_was timestamptz;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'business owner access is required' using errcode='42501';
  end if;
  if p_locked is null then
    raise exception 'lock state is required' using errcode='22023';
  end if;

  select id,print_locked_at into v_id,v_was
  from public.business_customer_join_qr_v89
  where business_id=p_business and status='active'
  order by expires_at desc,id desc limit 1;
  if v_id is null then
    raise exception 'there is no active QR to lock' using errcode='22023';
  end if;

  update public.business_customer_join_qr_v89
     set print_locked_at=case when p_locked then coalesce(print_locked_at,now()) end,
         print_locked_by=case when p_locked then coalesce(print_locked_by,v_actor) end
   where id=v_id;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,
    case when p_locked then 'LOCK_JOIN_QR_FOR_PRINT_V198' else 'UNLOCK_JOIN_QR_V198' end,
    'business_customer_join_qr_v89',v_id,
    jsonb_build_object('reason',nullif(btrim(coalesce(p_reason,'')),''),
      'was_locked',v_was is not null));
  return jsonb_build_object('business_id',p_business,'qr_id',v_id,
    'print_locked',p_locked,'changed',(v_was is not null)<>p_locked);
end $$;

revoke all on function app.v198_assert_qr_unlocked(uuid,text) from public, anon, authenticated;
revoke all on function public.business_set_join_qr_print_lock_v198(uuid,boolean,text)
  from public, anon, authenticated;
grant execute on function public.business_set_join_qr_print_lock_v198(uuid,boolean,text)
  to authenticated;

-- The two destructive verbs now respect the lock. Both are patched by asserting
-- their exact deployed body once, so a drifted definition fails loudly instead
-- of being silently rebuilt from a stale copy.
do $v198_guards$
declare v_def text; v_old text; v_hits integer;
begin
  v_def := pg_get_functiondef(to_regprocedure(
    'public.business_revoke_customer_join_qrs_v90(uuid)'));
  v_old := '  perform pg_advisory_xact_lock(hashtextextended(';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'v198: expected one advisory lock in revoke, found %', v_hits;
  end if;
  if position('v198_assert_qr_unlocked' in v_def) > 0 then
    raise exception 'v198: revoke already guarded';
  end if;
  execute replace(v_def, v_old,
    '  perform app.v198_assert_qr_unlocked(p_business,''revoked'');'||chr(10)||v_old);

  v_def := pg_get_functiondef(to_regprocedure(
    'public.business_rotate_customer_join_qr_v90(uuid,timestamptz)'));
  v_old := '  v_revoked:=public.business_revoke_customer_join_qrs_v90(p_business);';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'v198: expected one revoke call in rotate, found %', v_hits;
  end if;
  if position('v198_assert_qr_unlocked' in v_def) > 0 then
    raise exception 'v198: rotate already guarded';
  end if;
  execute replace(v_def, v_old,
    '  perform app.v198_assert_qr_unlocked(p_business,''replaced'');'||chr(10)||v_old);
end
$v198_guards$;

commit;

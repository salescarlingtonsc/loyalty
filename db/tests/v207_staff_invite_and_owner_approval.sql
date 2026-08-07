-- Rolled-back acceptance for v207 — invite code links an existing teammate; the owner approves.
begin;
do $$
declare
  v_biz uuid; v_owner uuid; v_joiner uuid; v_staff uuid; v_name text;
  v_code text; v_res jsonb; v_json json;
begin
  select s.business_id, s.user_id into v_biz, v_owner from public.staff s
   where s.role='owner' and s.user_id is not null and s.access_state='approved' limit 1;
  select id, full_name into v_staff, v_name from public.staff
   where business_id=v_biz and user_id is null and active limit 1;
  select u.id into v_joiner from auth.users u
   where not exists (select 1 from public.staff s2 where s2.business_id=v_biz and s2.user_id=u.id)
   limit 1;
  if v_biz is null or v_staff is null or v_joiner is null then
    raise notice 'no fixture; skipping'; return;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);
  v_code := public.create_staff_invite_v207(v_biz, v_staff, null)->>'code';
  assert v_code is not null, 'the owner must be able to issue a code for a roster teammate';

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_joiner,'role','authenticated','email','x@example.invalid')::text, true);
  v_json := public.accept_invite(v_code);
  assert (v_json::jsonb->>'status')='awaiting_approval', 'accepting must wait for the owner';
  assert (select count(*) from public.staff where business_id=v_biz and user_id=v_joiner)=1,
    'the code must link the EXISTING record, never create a duplicate';
  assert (select full_name from public.staff where id=v_staff)=v_name,
    'the existing teammate keeps their identity';
  assert app.is_salon_member(v_biz)=false, 'no access before the owner approves';
  assert jsonb_array_length(public.my_pending_access_v207())=1, 'they must be told they are waiting';

  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);
  v_res := public.decide_staff_access_v207(v_biz, v_staff, true);
  assert (v_res->>'access_state')='approved', 'the owner can approve';

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_joiner,'role','authenticated','email','x@example.invalid')::text, true);
  assert app.is_salon_member(v_biz)=true, 'access is granted only after approval';
  raise notice 'v207 approval path passed';
end$$;

-- Refusal keeps the person on the rota: refusing app access is not sacking someone.
do $$
declare v_biz uuid; v_owner uuid; v_joiner uuid; v_staff uuid; v_code text;
begin
  select s.business_id, s.user_id into v_biz, v_owner from public.staff s
   where s.role='owner' and s.user_id is not null and s.access_state='approved' limit 1;
  select id into v_staff from public.staff where business_id=v_biz and user_id is null and active limit 1;
  select u.id into v_joiner from auth.users u
   where not exists (select 1 from public.staff s2 where s2.business_id=v_biz and s2.user_id=u.id) limit 1;
  if v_staff is null or v_joiner is null then raise notice 'no fixture; skipping'; return; end if;

  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);
  v_code := public.create_staff_invite_v207(v_biz, v_staff, null)->>'code';
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_joiner,'role','authenticated','email','x@example.invalid')::text, true);
  perform public.accept_invite(v_code);

  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);
  perform public.decide_staff_access_v207(v_biz, v_staff, false);
  assert (select active and user_id is null from public.staff where id=v_staff),
    'a refused teammate stays on the rota with the login detached';

  -- and a non-owner cannot approve themselves in
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_joiner,'role','authenticated','email','x@example.invalid')::text, true);
  begin
    perform public.decide_staff_access_v207(v_biz, v_staff, true);
    raise exception 'a non-owner was allowed to approve access';
  exception when insufficient_privilege then null;
  end;
  raise notice 'v207 refusal path passed';
end$$;

-- Nobody who already had a login was locked out by the new gate.
do $$
begin
  assert not exists (select 1 from public.staff where user_id is not null and access_state<>'approved'
                      and id not in (select staff_id from public.staff_invites where staff_id is not null)),
    'existing logins must all remain approved';
end$$;
rollback;

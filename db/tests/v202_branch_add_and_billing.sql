-- Rolled-back acceptance for v202 / v202a / v202b — add a branch, bill it, enable it.
-- Every statement runs inside one transaction that is rolled back; nothing is left behind
-- and no charge is ever raised, because Stripe is never called from SQL.
begin;

do $$
declare
  v_biz uuid; v_owner uuid; v_src uuid; v_added jsonb; v_replay jsonb; v_branch uuid;
begin
  select s.business_id, s.user_id into v_biz, v_owner
    from public.staff s where s.role='owner' and s.user_id is not null
     and exists (select 1 from public.branches b where b.business_id=s.business_id and b.is_default)
   limit 1;
  if v_biz is null then raise notice 'no owner fixture; skipping'; return; end if;
  select id into v_src from public.branches where business_id=v_biz and is_default limit 1;

  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);

  -- 1. a new branch is created UNPAID and NOT operational
  v_added := public.business_add_branch_v202(v_biz,'ZZ Rollback Branch',null,null,null,v_src,
    gen_random_uuid());
  v_branch := (v_added->>'branch_id')::uuid;
  assert v_added->>'billing_state' = 'pending_payment',
    'a new branch must start unpaid';
  assert (select not active from public.branches where id=v_branch),
    'a new branch must start switched off';
  assert not app.branch_is_operational_v202(v_branch),
    'an unpaid branch must never be operational';
  assert v_added->>'command_id' is not null,
    'adding a branch must mint a billing command';

  -- 2. the settings the owner chose came across
  assert (v_added->'copied'->>'status') = 'ok', 'the copy must report its result';
  assert (v_added->'copied'->>'opening_hours')::int >= 0
     and (v_added->'copied'->>'staff_assignments')::int >= 0,
    'the copy must count what it actually inserted';

  -- 3. replaying the same idempotency key cannot mint a second branch or a second charge
  v_replay := public.business_add_branch_v202(v_biz,'ZZ Rollback Branch',null,null,null,v_src,
    (select idempotency_key from public.billing_commands
      where id=(v_added->>'command_id')::uuid));
  assert v_replay->>'status' = 'replayed', 'a repeat must replay, not create';
  assert (v_replay->>'branch_id')::uuid = v_branch, 'a replay must return the same branch';
  assert (v_replay->>'command_id')::uuid = (v_added->>'command_id')::uuid,
    'a replay must return the same charge';

  -- 4. the free path is checked in its own statement below, NOT here: a DO block runs as the
  --    session role, so a service-role session bypasses RLS and the check would pass whatever
  --    the policy says. Asserting it here would be a test that cannot fail.

  -- 5. payment confirmation switches it on, and only then
  perform set_config('request.jwt.claims', null, true);
  update public.billing_commands set status='completed' where id=(v_added->>'command_id')::uuid;
  assert (select active and billing_state='active' from public.branches where id=v_branch),
    'a confirmed payment must switch the branch on';
  assert app.branch_is_operational_v202(v_branch),
    'a paid branch must be operational';

  -- 6. branches that existed before v202 are never back-charged
  assert (select bool_and(billing_state='included')
            from public.branches where business_id=v_biz and id<>v_branch),
    'existing branches must stay grandfathered';

  raise notice 'v202 acceptance passed';
end$$;

-- 4. creating a branch is billable, so a plain insert must be refused for a real owner.
-- `set local role` is what makes RLS apply; without it this proves nothing.
do $bypass$
declare v_biz uuid; v_owner uuid;
begin
  select s.business_id, s.user_id into v_biz, v_owner
    from public.staff s where s.role='owner' and s.user_id is not null limit 1;
  if v_biz is null then return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);
  perform set_config('role','authenticated',true);
  begin
    insert into public.branches(business_id,name,active) values (v_biz,'ZZ Free Bypass',true);
    raise exception 'the free-branch bypass is still open';
  exception when insufficient_privilege then
    raise notice 'direct branch insert refused, as intended';
  end;
  perform set_config('role','none',true);
end$bypass$;

rollback;

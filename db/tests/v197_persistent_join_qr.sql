-- Rollback-only v197 acceptance: the printed customer join QR must never change.
-- The owner prints this and puts it on a counter, so the contract under test is
-- "the same token comes back, call after call, indefinitely".
begin;

do $v197$
declare
  v_sa uuid; v_biz uuid; a jsonb; b jsonb; c jsonb; v_n int; v_hash text;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  insert into public.businesses(name,slug,industry)
  values ('V197 QR Fixture','v197-qr-fixture','fnb') returning id into v_biz;

  a := public.business_ensure_customer_join_qr_v91(v_biz, now()+interval '365 days');
  if (a->>'created')::boolean is not true then raise exception 'A: first call did not issue a QR'; end if;
  if a->>'join_token' is null then raise exception 'B: no token returned on create'; end if;

  -- THE CONTRACT: reopening the page returns the same token, not a new QR.
  b := public.business_ensure_customer_join_qr_v91(v_biz, now()+interval '365 days');
  c := public.business_ensure_customer_join_qr_v91(v_biz, now()+interval '30 days');
  if (b->>'created')::boolean is not false then raise exception 'C: second call created a new QR'; end if;
  if b->>'join_token' <> a->>'join_token' then raise exception 'D: the token changed between calls'; end if;
  if c->>'join_token' <> a->>'join_token' then raise exception 'E: the token changed with a different requested expiry'; end if;
  if b->>'qr_id' <> a->>'qr_id' then raise exception 'F: a second QR row appeared'; end if;

  -- A printed poster must not age out.
  if (b->>'expires_at')::timestamptz < now()+interval '50 years' then
    raise exception 'G: the QR still expires within a working lifetime: %', b->>'expires_at';
  end if;

  -- The scan path is unchanged: resolution is still by sha256(token).
  select token_hash into v_hash from public.business_customer_join_qr_v89 where id=(a->>'qr_id')::uuid;
  if v_hash <> app.v89_sha256(a->>'join_token') then
    raise exception 'H: stored hash does not match the derived token';
  end if;
  select count(*) into v_n from public.business_customer_join_qr_v89
   where business_id=v_biz and status='active';
  if v_n <> 1 then raise exception 'I: expected exactly one active QR, got %', v_n; end if;

  -- Rotation stays possible and deliberate, and the new token is itself stable.
  a := public.business_rotate_customer_join_qr_v90(v_biz, now()+interval '365 days');
  if a->>'join_token' = b->>'join_token' then raise exception 'J: rotation did not change the token'; end if;
  if (a->>'token_version')::int <> (b->>'token_version')::int + 1 then
    raise exception 'K: rotation did not bump the version';
  end if;
  c := public.business_ensure_customer_join_qr_v91(v_biz, now()+interval '365 days');
  if c->>'join_token' <> a->>'join_token' then raise exception 'L: the rotated token is not stable'; end if;

  -- The derivation is a pure function of (business, version).
  if app.v197_join_token(v_biz,(c->>'token_version')::int) <> c->>'join_token' then
    raise exception 'M: token is not reproducible from business and version';
  end if;
  -- Browser roles can never derive a token themselves.
  if has_function_privilege('authenticated','app.v197_join_token(uuid,integer)','EXECUTE')
     or has_function_privilege('anon','app.v197_join_token(uuid,integer)','EXECUTE') then
    raise exception 'N: token derivation is callable by a browser role';
  end if;

  raise notice 'v197 persistent join QR: all assertions passed';
end
$v197$;

rollback;

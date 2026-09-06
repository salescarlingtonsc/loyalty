-- Rollback-only nestly_v808 acceptance: a customer with no registration-preferences row can save
-- the marketing choice, and every consent guarantee around that write still holds.
--
-- WHAT THE BUG WAS (audit F040). public.customer_get_platform_marketing_preference coalesces a
-- missing customer_registration_preferences row to {opted_in:false}, so the Profile page renders
-- a live checkbox and a Save button for every customer. public.customer_set_platform_marketing_preference
-- then did a bare UPDATE of that table and raised 42501 when nothing matched. Only
-- public.customer_register_verified_phone ever inserts the row, so a customer whose identity came
-- from the QR-join / claim path could never save the choice in either direction — and the UI
-- showed "could not be saved. Please try again.", advice that could never work. One of eleven
-- active production identities was in exactly that state.
--
-- WHAT THIS SUITE PROVES, against identities it builds itself, as the real customer principal:
--   1. The bug's precondition is real: a fresh identity has NO preferences row.
--   2. That customer CAN now save the choice — this is the assertion that fails pre-v808.
--   3. The row it created is scope-stamped by app.v92_prepare_platform_marketing_preference, so
--      customer_get_platform_marketing_preference actually reports opted_in afterwards. (Reader
--      agreement is not correctness on its own, hence 4.)
--   4. The append-only consent EVIDENCE was written for the created row, with the pinned privacy
--      sha and scope version and source 'customer_profile' — an INSERT must record consent
--      exactly as an UPDATE does.
--   5. Withdrawal works from the same starting point: a first-ever save of FALSE creates the row
--      opted out, the reader says false, and no opt-in is fabricated.
--   6. A customer who already has a row still updates it (positive control), and no second row
--      appears.
--   7. The idempotency contract survives: the same key replayed returns the stored answer, and
--      the same key with the opposite answer is still refused (23505).
--   8. A refusal is still a refusal, not a silent success: no authenticated session raises.
--
-- Assertions are recorded as rows; a final gate makes any FAIL fatal.

begin;

create temp table v696_out(seq integer, step text, outcome text) on commit drop;

create or replace function pg_temp.as_v808_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v808_system() to authenticated;

create or replace function pg_temp.as_v808_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v808_user(uuid) to authenticated;

-- A customer identity of the shape customer_create_identity produces: active, wallet_start, and
-- deliberately WITHOUT a customer_registration_preferences row.
create or replace function pg_temp.v696_identity(p_uid uuid) returns uuid
language plpgsql as $$
declare v_identity uuid;
begin
  insert into auth.users(id, email)
  values (p_uid, 'v808-' || substr(p_uid::text, 1, 8) || '@example.test');
  insert into public.customer_identities(auth_user_id, status, created_via)
  values (p_uid, 'active', 'wallet_start')
  returning id into v_identity;
  return v_identity;
end
$$;

do $v696_test$
declare
  uA uuid := gen_random_uuid();  iA uuid;
  uB uuid := gen_random_uuid();  iB uuid;
  uC uuid := gen_random_uuid();  iC uuid;
  v_res jsonb;
  v_read jsonb;
  v_count integer;
  v_err text;
  v_event public.customer_platform_marketing_consent_events%rowtype;
begin
  perform pg_temp.as_v808_system();
  iA := pg_temp.v696_identity(uA);
  iB := pg_temp.v696_identity(uB);
  iC := pg_temp.v696_identity(uC);

  -- ------------------------------------------------------------------ 1. the precondition
  select count(*) into v_count
    from public.customer_registration_preferences p where p.identity_id = iA;
  if v_count = 0 then
    insert into v696_out values (1,'a fresh QR-join style identity really has NO preferences row','PASS');
  else
    insert into v696_out values (1,'a fresh QR-join style identity really has NO preferences row',
      format('FAIL - %s rows', v_count));
  end if;

  -- ------------------------------------------------------------------ 2. the save now works
  perform pg_temp.as_v808_user(uA);
  v_err := null;
  begin
    select public.customer_set_platform_marketing_preference(true, 'v808-first-save-a') into v_res;
  exception when others then v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v808_system();
  if v_err is null and coalesce((v_res->>'opted_in')::boolean, false) then
    insert into v696_out values (2,'a customer with no preferences row CAN save the marketing choice','PASS');
  else
    insert into v696_out values (2,'a customer with no preferences row CAN save the marketing choice',
      format('FAIL - sqlstate=%s result=%s', coalesce(v_err,'<none>'), coalesce(v_res::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 3. the reader agrees
  perform pg_temp.as_v808_user(uA);
  v_read := public.customer_get_platform_marketing_preference();
  perform pg_temp.as_v808_system();
  if coalesce((v_read->>'opted_in')::boolean, false) then
    insert into v696_out values (3,'the created row is scope-stamped, so the reader reports the customer as opted in','PASS');
  else
    insert into v696_out values (3,'the created row is scope-stamped, so the reader reports the customer as opted in',
      format('FAIL - reader says %s', coalesce(v_read::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 4. the evidence exists
  select * into v_event from public.customer_platform_marketing_consent_events e
   where e.identity_id = iA and e.idempotency_key = 'v808-first-save-a';
  if found and v_event.opted_in
     and v_event.source = 'customer_profile'
     and v_event.scope_version = '2026-08-10-partner-sharing-v3'
     and v_event.privacy_sha256 = '960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f' then
    insert into v696_out values (4,'the INSERT recorded append-only consent evidence with the pinned scope and privacy sha','PASS');
  else
    insert into v696_out values (4,'the INSERT recorded append-only consent evidence with the pinned scope and privacy sha',
      format('FAIL - event=%s', coalesce(v_event.id::text,'<none>')));
  end if;

  -- ------------------------------------------------------------------ 5. withdrawal, from nothing
  perform pg_temp.as_v808_user(uB);
  v_err := null;
  begin
    select public.customer_set_platform_marketing_preference(false, 'v808-first-save-b') into v_res;
  exception when others then v_err := sqlstate; v_res := null;
  end;
  v_read := public.customer_get_platform_marketing_preference();
  perform pg_temp.as_v808_system();
  select count(*) into v_count from public.customer_registration_preferences p
   where p.identity_id = iB and p.platform_marketing_opted_in;
  if v_err is null
     and (v_res->>'opted_in')::boolean is false
     and (v_read->>'opted_in')::boolean is false
     and v_count = 0 then
    insert into v696_out values (5,'a first-ever save of FALSE creates the row opted OUT — no consent is fabricated','PASS');
  else
    insert into v696_out values (5,'a first-ever save of FALSE creates the row opted OUT — no consent is fabricated',
      format('FAIL - sqlstate=%s result=%s reader=%s opted_in_rows=%s',
             coalesce(v_err,'<none>'), coalesce(v_res::text,'<null>'), coalesce(v_read::text,'<null>'), v_count));
  end if;

  -- ------------------------------------------------------------------ 6. positive control
  perform pg_temp.as_v808_user(uA);
  v_err := null;
  begin
    select public.customer_set_platform_marketing_preference(false, 'v808-second-save-a') into v_res;
  exception when others then v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v808_system();
  select count(*) into v_count
    from public.customer_registration_preferences p where p.identity_id = iA;
  if v_err is null
     and (v_res->>'opted_in')::boolean is false
     and v_count = 1
     and not (select p.platform_marketing_opted_in
                from public.customer_registration_preferences p where p.identity_id = iA) then
    insert into v696_out values (6,'a customer who already has a row still updates it, and only one row exists','PASS');
  else
    insert into v696_out values (6,'a customer who already has a row still updates it, and only one row exists',
      format('FAIL - sqlstate=%s result=%s rows=%s',
             coalesce(v_err,'<none>'), coalesce(v_res::text,'<null>'), v_count));
  end if;

  -- ------------------------------------------------------------------ 7. idempotency survives
  perform pg_temp.as_v808_user(uC);
  v_err := null;
  begin
    perform public.customer_set_platform_marketing_preference(true, 'v808-idem-c');
    select public.customer_set_platform_marketing_preference(true, 'v808-idem-c') into v_res;
  exception when others then v_err := sqlstate; v_res := null;
  end;
  if v_err is null and coalesce((v_res->>'opted_in')::boolean, false) then
    v_err := null;
    begin
      perform public.customer_set_platform_marketing_preference(false, 'v808-idem-c');
    exception when others then v_err := sqlstate;
    end;
  else
    v_err := coalesce(v_err, 'replay-did-not-return-the-stored-answer');
  end if;
  perform pg_temp.as_v808_system();
  if v_err = '23505' then
    insert into v696_out values (7,'the same idempotency key replays its answer, and is refused (23505) for the opposite one','PASS');
  else
    insert into v696_out values (7,'the same idempotency key replays its answer, and is refused (23505) for the opposite one',
      format('FAIL - sqlstate=%s', coalesce(v_err,'<none>')));
  end if;

  -- ------------------------------------------------------------------ 8. a refusal stays a refusal
  perform pg_temp.as_v808_system();
  v_err := null;
  begin
    perform public.customer_set_platform_marketing_preference(true, 'v808-anon-attempt');
  exception when others then v_err := sqlstate;
  end;
  select count(*) into v_count from public.customer_platform_marketing_consent_events e
   where e.idempotency_key = 'v808-anon-attempt';
  if v_err is not null and v_count = 0 then
    insert into v696_out values (8,'a caller with no customer session is still refused, and writes nothing','PASS');
  else
    insert into v696_out values (8,'a caller with no customer session is still refused, and writes nothing',
      format('FAIL - sqlstate=%s events=%s', coalesce(v_err,'<none>'), v_count));
  end if;
end
$v696_test$;

select seq, step, outcome from v696_out order by seq;

do $v696_gate$
declare v_bad integer; v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v696_out;
  if v_all <> 8 then
    raise exception 'nestly_v808: % of 8 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v808: % assertion(s) FAILED: %', v_bad,
      (select string_agg(seq || ' ' || step || ' => ' || outcome, ' || ')
         from v696_out where outcome not like 'PASS%');
  end if;
end
$v696_gate$;

rollback;

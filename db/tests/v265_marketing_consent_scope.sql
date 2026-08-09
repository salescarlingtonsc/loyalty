-- Rollback-only acceptance for V265 marketing consent scope v3.
-- Run after the canonical chain through v265 in a disposable local database.
--
-- Proves:
--   * the events table admits the v3 scope and still admits v1 and v2 (history
--     is append-only and must remain readable);
--   * prepare, capture and reader all pin the SAME scope and the SAME active
--     privacy digest, so a grant cannot record evidence the reader rejects;
--   * no true preference row survives the scope advance without v3 evidence -
--     a v2 tick must not read as agreement to partner sharing;
--   * the reader actively REFUSES a preference row still pinned to the v2
--     scope/digest, not merely that no such row happens to exist;
--   * a fresh v3 grant produces matching evidence and the reader reports it;
--   * the evidence table is still append-only under UPDATE and DELETE;
--   * the marketing preference RPC ACLs stay closed to anon.
--
-- DIGEST RETARGET (2026-08-09 owner ruling): every pin in this suite was written against
-- the superseded 2026-08-06 / b9aa956263... Privacy Notice. The ruling that partners MAY
-- receive customer contact details for marketing made section 5 of app/privacy.html false,
-- so v265 publishes the corrected notice 2026-08-10 / 960434af79... as the active document
-- in the same transaction as the scope change. Asserting the old digest here would assert
-- that v265 did not happen. Retargeted, not removed.

begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.v264_as_customer(p_uid uuid) returns void
language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text,
    true
  );
end;
$$;
grant execute on function pg_temp.v264_as_customer(uuid) to public;

do $v264_pins$
declare
  v_constraint text;
  v_prepare text := pg_get_functiondef('app.v92_prepare_platform_marketing_preference()'::regprocedure);
  v_capture text := pg_get_functiondef('app.v92_capture_platform_marketing_consent()'::regprocedure);
  v_reader text := pg_get_functiondef('public.customer_get_platform_marketing_preference()'::regprocedure);
  v_bad bigint;
  -- Single source of truth for the pin, so a future notice correction is a one-line change
  -- instead of six scattered literals (the shape that made this suite stale in the first place).
  v_digest constant text := '960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f';
begin
  if (
    select count(*) from app.customer_legal_documents d
     where d.document_key='privacy' and d.active
       and d.document_version='2026-08-10'
       and d.document_sha256=v_digest
  ) <> 1 then
    raise exception 'v265 FAIL: the expected active Privacy Notice is not published exactly';
  end if;

  select pg_get_constraintdef(oid) into v_constraint from pg_constraint
   where conrelid='public.customer_platform_marketing_consent_events'::regclass
     and conname='customer_platform_marketing_consent_events_scope_version_check';
  if v_constraint not like '%2026-08-10-partner-sharing-v3%' then
    raise exception 'v265 FAIL: events scope constraint does not admit the v3 scope';
  end if;
  if v_constraint not like '%2026-07-28-selected-partners-v1%'
     or v_constraint not like '%2026-08-06-selected-partners-v2%' then
    raise exception 'v265 FAIL: events scope constraint dropped historical scopes';
  end if;

  if v_prepare not like '%2026-08-10-partner-sharing-v3%'
     or v_capture not like '%2026-08-10-partner-sharing-v3%'
     or v_reader not like '%2026-08-10-partner-sharing-v3%' then
    raise exception 'v265 FAIL: prepare, capture and reader do not all pin the v3 scope';
  end if;
  if v_prepare not like '%'||v_digest||'%'
     or v_capture not like '%'||v_digest||'%'
     or v_reader not like '%'||v_digest||'%' then
    raise exception 'v265 FAIL: prepare, capture and reader do not all pin the active digest';
  end if;

  select count(*) into v_bad from public.customer_registration_preferences p
   where p.platform_marketing_opted_in
     and (p.marketing_scope_version is distinct from '2026-08-10-partner-sharing-v3'
       or p.marketing_privacy_sha256 is distinct from v_digest);
  if v_bad <> 0 then
    raise exception 'v265 FAIL: % opted-in rows carry pre-v3 scope evidence', v_bad;
  end if;

  if has_function_privilege('anon','public.customer_get_platform_marketing_preference()','execute')
     or has_function_privilege('anon','public.customer_set_platform_marketing_preference(boolean,text)','execute')
     or not has_function_privilege('authenticated','public.customer_get_platform_marketing_preference()','execute')
     or not has_function_privilege('authenticated','public.customer_set_platform_marketing_preference(boolean,text)','execute') then
    raise exception 'v265 FAIL: marketing preference RPC ACLs are not exact';
  end if;

  raise notice 'v265 PASS: v3 scope admitted, pins consistent, no pre-v3 grant survives';
end
$v264_pins$;

-- ADDED: the pins block above only proves no v2-pinned true row HAPPENS to exist after the
-- reset. That is satisfied vacuously by a migration that simply deleted everything. This block
-- manufactures the dangerous row and proves the READER refuses it, which is the actual promise:
-- a customer who ticked under the narrower v2 wording must not read as having agreed to v3.
-- The prepare trigger would rewrite the pins on any normal write, so the triggers are disabled
-- for the two fixture writes only; everything rolls back.
do $v264_v2_row_is_not_a_v3_grant$
declare
  v_identity uuid;
  v_user uuid;
  v_reader jsonb;
begin
  select p.identity_id, p.auth_user_id into v_identity, v_user
    from public.customer_registration_preferences p order by p.identity_id limit 1;
  if v_identity is null then
    raise notice 'v265 SKIP: no customer registration preference rows in this fixture';
    return;
  end if;

  execute 'alter table public.customer_registration_preferences disable trigger user';
  update public.customer_registration_preferences
     set platform_marketing_opted_in = true,
         marketing_scope_version = '2026-08-06-selected-partners-v2',
         marketing_privacy_sha256 = 'b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245'
   where identity_id = v_identity;
  execute 'alter table public.customer_registration_preferences enable trigger user';

  perform pg_temp.v264_as_customer(v_user);
  v_reader := public.customer_get_platform_marketing_preference();
  reset role;
  if (v_reader->>'opted_in')::boolean is not false then
    raise exception 'v265 FAIL: a v2-pinned grant read as opted in: %', v_reader;
  end if;
  if v_reader->>'scope_version' <> '2026-08-10-partner-sharing-v3' then
    raise exception 'v265 FAIL: reader did not report the v3 scope: %', v_reader;
  end if;

  -- Put the fixture row back, triggers still off, so the roundtrip block below starts from a
  -- clean opted-out row and its "exactly one v3 grant event" count is not polluted.
  execute 'alter table public.customer_registration_preferences disable trigger user';
  update public.customer_registration_preferences
     set platform_marketing_opted_in = false,
         marketing_scope_version = null,
         marketing_privacy_sha256 = null
   where identity_id = v_identity;
  execute 'alter table public.customer_registration_preferences enable trigger user';

  raise notice 'v265 PASS: a v2-pinned preference row is not readable as a v3 grant';
end
$v264_v2_row_is_not_a_v3_grant$;

do $v264_grant_roundtrip$
declare
  v_user uuid;
  v_identity uuid;
  v_events bigint;
  v_reader jsonb;
  v_pinned boolean;
  v_digest constant text := '960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f';
begin
  -- A fresh v3 grant must create evidence the reader accepts. Without this the
  -- migration could "pass" by making every customer permanently opted out.
  -- ORDER BY added: the original bare `limit 1` picked a different row in each of the two
  -- selects it used, so identity and auth_user_id could disagree.
  select p.identity_id, p.auth_user_id into v_identity, v_user
    from public.customer_registration_preferences p order by p.identity_id limit 1;
  if v_identity is null then
    raise notice 'v265 SKIP: no customer registration preference rows in this fixture';
    return;
  end if;

  -- Driven through the customer-facing RPC rather than a raw UPDATE plus hand-set GUCs: the
  -- RPC is what production actually calls, and it sets app.v92_marketing_source /
  -- idempotency_key itself, so this exercises the real path end to end.
  perform pg_temp.v264_as_customer(v_user);
  perform public.customer_set_platform_marketing_preference(true, 'v264-roundtrip-key');
  v_reader := public.customer_get_platform_marketing_preference();
  reset role;

  select count(*) into v_events
    from public.customer_platform_marketing_consent_events e
   where e.identity_id = v_identity
     and e.opted_in
     and e.scope_version = '2026-08-10-partner-sharing-v3'
     and e.privacy_sha256 = v_digest;
  if v_events <> 1 then
    raise exception 'v265 FAIL: expected exactly one v3 grant event, found %', v_events;
  end if;

  select (p.marketing_scope_version = '2026-08-10-partner-sharing-v3'
          and p.marketing_privacy_sha256 = v_digest)
    into v_pinned
    from public.customer_registration_preferences p where p.identity_id = v_identity;
  if not v_pinned then
    raise exception 'v265 FAIL: the granting preference row is not pinned to v3';
  end if;

  if v_reader->>'scope_version' <> '2026-08-10-partner-sharing-v3'
     or (v_reader->>'opted_in')::boolean is not true then
    raise exception 'v265 FAIL: reader did not honour a fresh v3 grant: %', v_reader;
  end if;

  raise notice 'v265 PASS: a v3 grant records v3 evidence and reads back as opted in';
end
$v264_grant_roundtrip$;

-- ADDED: the suite claimed the evidence chain "stays append-only" but never tested it. A scope
-- advance whose whole point is that historical grants cannot be rewritten is worth one direct
-- probe of the immutability trigger.
do $v264_append_only$
declare
  v_evt_id uuid;
begin
  select e.id into v_evt_id
    from public.customer_platform_marketing_consent_events e
   where e.scope_version = '2026-08-10-partner-sharing-v3' limit 1;
  if v_evt_id is null then
    raise notice 'v265 SKIP: no v3 evidence row to probe for immutability';
    return;
  end if;

  begin
    update public.customer_platform_marketing_consent_events set opted_in = false where id = v_evt_id;
    raise exception 'v265 FAIL: UPDATE on the evidence table was permitted';
  exception when others then
    if sqlerrm like 'v265 FAIL%' then raise; end if;
  end;

  begin
    delete from public.customer_platform_marketing_consent_events where id = v_evt_id;
    raise exception 'v265 FAIL: DELETE on the evidence table was permitted';
  exception when others then
    if sqlerrm like 'v265 FAIL%' then raise; end if;
  end;

  raise notice 'v265 PASS: the consent evidence table rejects UPDATE and DELETE';
end
$v264_append_only$;

rollback;

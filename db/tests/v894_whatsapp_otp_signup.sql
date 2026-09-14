-- nestly_v894 rolled-back verification — the WhatsApp sign-up OTP challenge.
--
-- Run against production. Everything happens inside the transaction and the file ends in
-- `rollback;`, including the platform flag this switches on: the feature ships OFF and must
-- still be off when this file has finished.
--
--   1. with customer_whatsapp_otp false, nothing can be issued — the switch is the switch;
--   2. a number app.norm_phone refuses never reaches the table;
--   3. three codes in ten minutes is the per-number ceiling, and the fourth is refused;
--   4. a wrong code costs an attempt and says how many are left; the sixth guess is refused
--      outright even if it is correct;
--   5. the right code verifies exactly once — the second attempt is indistinguishable from
--      an expired one;
--   6. a send Meta refused expires its own challenge, so an undelivered code is not a live
--      guessing target;
--   7. the challenge table is RLS-enabled with no browser-role ACL, and the three functions
--      are executable by service_role alone.
--
-- The code itself never appears here, because it never appears in the database: these hashes
-- are what the edge function would have computed, and the rules below are the only thing the
-- database knows about them.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_phone text := '81863833';
  v_other text := '91234567';
  v_hash text := repeat('a', 64);
  v_wrong text := repeat('b', 64);
  v_challenge uuid;
  v_result jsonb;
  v_attempt integer;
begin
  -- 1. the platform switch, before anything else -----------------------------------------
  update app.platform_feature_flags set enabled = false where feature_key = 'customer_whatsapp_otp';
  v_result := public.internal_whatsapp_otp_issue_v894(
    gen_random_uuid(), v_phone, 'signup', v_hash, 300);
  assert v_result->>'reason' = 'feature_disabled',
    format('a disabled feature must refuse to issue, got %s', v_result);

  update app.platform_feature_flags set enabled = true where feature_key = 'customer_whatsapp_otp';

  -- 2. the phone domain is app.norm_phone's, not the caller's ------------------------------
  v_result := public.internal_whatsapp_otp_issue_v894(
    gen_random_uuid(), '12345678', 'signup', v_hash, 300);
  assert v_result->>'reason' = 'phone_invalid',
    format('a non-Singapore number must be refused, got %s', v_result);
  v_result := public.internal_whatsapp_otp_issue_v894(
    gen_random_uuid(), v_phone, 'recovery', v_hash, 300);
  assert v_result->>'reason' = 'purpose_unsupported',
    format('v894 is sign-up only, got %s', v_result);

  -- 3. three per ten minutes, per NUMBER ---------------------------------------------------
  for v_attempt in 1..3 loop
    v_result := public.internal_whatsapp_otp_issue_v894(
      gen_random_uuid(), v_phone, 'signup', v_hash, 300);
    assert (v_result->>'ok')::boolean, format('issue %s should have succeeded: %s', v_attempt, v_result);
  end loop;
  v_result := public.internal_whatsapp_otp_issue_v894(
    gen_random_uuid(), v_phone, 'signup', v_hash, 300);
  assert v_result->>'reason' = 'rate_limited',
    format('the fourth code in ten minutes must be refused, got %s', v_result);
  -- and the ceiling is that number's alone
  v_result := public.internal_whatsapp_otp_issue_v894(
    gen_random_uuid(), v_other, 'signup', v_hash, 300);
  assert (v_result->>'ok')::boolean,
    format('another number must not inherit the first one''s ceiling: %s', v_result);

  -- 4. a wrong guess costs an attempt ------------------------------------------------------
  delete from public.customer_whatsapp_otp_challenges_v894 where phone_norm in (v_phone, v_other);
  v_challenge := gen_random_uuid();
  v_result := public.internal_whatsapp_otp_issue_v894(v_challenge, v_phone, 'signup', v_hash, 300);
  assert (v_result->>'ok')::boolean, format('issue failed: %s', v_result);

  v_result := public.internal_whatsapp_otp_consume_v894(v_challenge, v_wrong);
  assert v_result->>'reason' = 'code_invalid', format('a wrong code must be refused: %s', v_result);
  assert (v_result->>'attempts_left')::integer = 4,
    format('the first wrong guess leaves four: %s', v_result);

  for v_attempt in 1..4 loop
    v_result := public.internal_whatsapp_otp_consume_v894(v_challenge, v_wrong);
  end loop;
  -- The fifth wrong guess exhausted the budget; the sixth is refused before the comparison,
  -- so even the CORRECT code cannot rescue it.
  v_result := public.internal_whatsapp_otp_consume_v894(v_challenge, v_hash);
  assert v_result->>'reason' = 'too_many_attempts',
    format('a burned challenge must not accept the right code: %s', v_result);

  -- 5. the right code, exactly once --------------------------------------------------------
  delete from public.customer_whatsapp_otp_challenges_v894 where phone_norm = v_phone;
  v_challenge := gen_random_uuid();
  perform public.internal_whatsapp_otp_issue_v894(v_challenge, v_phone, 'signup', v_hash, 300);
  v_result := public.internal_whatsapp_otp_consume_v894(v_challenge, v_hash);
  assert (v_result->>'ok')::boolean, format('the right code must verify: %s', v_result);
  assert v_result->>'phone_norm' = v_phone, format('the verified number must come back: %s', v_result);
  v_result := public.internal_whatsapp_otp_consume_v894(v_challenge, v_hash);
  assert v_result->>'reason' = 'challenge_invalid',
    format('a consumed challenge must not verify twice: %s', v_result);

  -- 6. a send Meta refused kills its own code ----------------------------------------------
  delete from public.customer_whatsapp_otp_challenges_v894 where phone_norm = v_phone;
  v_challenge := gen_random_uuid();
  perform public.internal_whatsapp_otp_issue_v894(v_challenge, v_phone, 'signup', v_hash, 300);
  perform public.internal_whatsapp_otp_record_send_v894(v_challenge, 'failed', '132001');
  v_result := public.internal_whatsapp_otp_consume_v894(v_challenge, v_hash);
  assert v_result->>'reason' = 'challenge_invalid',
    format('an undelivered code must not stay guessable: %s', v_result);
  assert exists (
    select 1 from public.customer_whatsapp_otp_challenges_v894
     where id = v_challenge and send_status = 'failed' and last_error_code = '132001'
  ), 'the refusal must be recorded on the row';

  -- A successful send leaves the code alive and records nothing about the recipient.
  delete from public.customer_whatsapp_otp_challenges_v894 where phone_norm = v_phone;
  v_challenge := gen_random_uuid();
  perform public.internal_whatsapp_otp_issue_v894(v_challenge, v_phone, 'signup', v_hash, 300);
  perform public.internal_whatsapp_otp_record_send_v894(v_challenge, 'sent', null);
  v_result := public.internal_whatsapp_otp_consume_v894(v_challenge, v_hash);
  assert (v_result->>'ok')::boolean, format('a sent code must still verify: %s', v_result);

  raise notice 'v894 challenge lifecycle verified';
end
$test$;

-- 7. the boundaries, read from the catalogue rather than asserted in prose -----------------
do $guards$
declare
  v_acl text;
begin
  assert (
    select relrowsecurity from pg_class
     where oid = 'public.customer_whatsapp_otp_challenges_v894'::regclass
  ), 'the challenge table must have RLS enabled';

  select coalesce(array_to_string(relacl::text[], ','), '') into v_acl
    from pg_class where oid = 'public.customer_whatsapp_otp_challenges_v894'::regclass;
  assert v_acl not like '%anon=%' and v_acl not like '%authenticated=%',
    format('no browser role may hold a grant on the challenge table: %s', v_acl);

  for v_acl in
    select coalesce(array_to_string(p.proacl::text[], ','), '')
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('internal_whatsapp_otp_issue_v894',
                         'internal_whatsapp_otp_record_send_v894',
                         'internal_whatsapp_otp_consume_v894')
  loop
    assert v_acl like '%service_role=X%', format('service_role must execute: %s', v_acl);
    assert v_acl not like '%anon=X%' and v_acl not like '%authenticated=X%',
      format('no browser role may execute an internal OTP function: %s', v_acl);
  end loop;

  -- The v824 ruling is not re-opened by this feature.
  assert not app.platform_feature_enabled('whatsapp_outbound'),
    'v894 must not turn the v824 master switch back on';

  raise notice 'v894 grants and switches verified';
end
$guards$;

rollback;

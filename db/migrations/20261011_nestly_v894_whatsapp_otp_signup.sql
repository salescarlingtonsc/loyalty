-- nestly_v894 — sign-up WhatsApp OTP, delivered by Meta, beside the SMS one.
--
-- OWNER, 2026-09-14: "instead of using twilio - we will directly use whatsapp OTP for sign ups
-- [...] for now dont need to remove twilio, just do whatsapp otp concurrently", and on whether
-- this re-opens the v824 ruling: "it is not whatsapp message, but just OTP only first."
--
-- WHAT WAS ALREADY THERE, AND WHY IT NEVER WORKED. c42 shipped a WhatsApp radio on the sign-up
-- channel picker, a capability probe (get_customer_phone_otp_capabilities) and the platform flag
-- customer_whatsapp_otp. All three are real. The radio never painted because the flag has been
-- false since 2026-07-22 and because window.__FRENLY_CUSTOMER_WHATSAPP_OTP_ENABLED__ is READ in
-- two places and WRITTEN in none. Behind them the channel did not go where the owner thinks: it
-- called GoTrue's signInWithOtp({channel:'whatsapp'}), which is delivered by Twilio — WhatsApp
-- routed through Twilio Verify, not Peekaa's own Meta WABA. That is the thing this migration
-- replaces.
--
-- WHY NOT THE SUPABASE SEND-SMS HOOK. It is the supported way to deliver an OTP yourself, but its
-- payload is {user, sms:{otp}} — there is NO channel field — so one hook cannot tell an SMS
-- request from a WhatsApp one, and enabling it takes over BOTH channels: Twilio Verify would stop
-- being used for SMS, because Verify cannot verify a code GoTrue generated. The owner asked for
-- the two channels to run concurrently, so WhatsApp gets its own challenge here and the SMS path
-- (GoTrue + Twilio Verify, 10 confirmed users, last 2026-09-05) is not touched by one line.
--
-- v824 IS NOT RE-OPENED. That ruling switched off app.platform_feature_flags.whatsapp_outbound and
-- whatsapp_retention_sends — appointment notices, bring-back, retention. Nothing below reads those
-- flags and nothing below re-arms those enqueue paths; both stay false. A sign-up code is not a
-- WhatsApp *message* in the sense the owner switched off. This path has its own switch, the c42
-- flag customer_whatsapp_otp, and this migration LEAVES IT FALSE: turning it on is the go-live
-- step, taken once Meta has approved the authentication template (section 1) and the secrets are
-- proven. Until then the capability probe keeps answering whatsapp:false and the radio stays dark.
--
-- SHAPE. Three SECURITY DEFINER functions owned by postgres and executable by service_role only,
-- exactly like internal_public_join_v89 and internal_gateway_rate_limit: issue a challenge, record
-- what Meta said about the send, consume a code. The browser reaches none of them — it goes through
-- the whatsapp-otp-start / whatsapp-otp-verify edge functions, which are origin-locked and
-- IP-rate-limited by the shared gateway before any of this runs.
--
-- THE CODE IS NEVER STORED. The edge function generates the six digits, hashes
-- sha256(pepper \0 challenge_id \0 code) with a pepper that exists only in the function's
-- environment, and sends the hash here. A dump of this table cannot be replayed into an account,
-- and neither can a read of it by anything holding service_role, because the pepper is not in the
-- database at all.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. the registry learns Meta's third template category
-- ---------------------------------------------------------------------------------------------
-- Meta categorises every template marketing | utility | authentication, prices them differently,
-- and applies a separate policy to the third: an authentication template's body may say nothing
-- but the code, it must carry a copy-code or one-tap button, and it may not be repurposed. The
-- v551 CHECK knew only the first two because Peekaa had only reminders and bring-back.
alter table public.whatsapp_template_registry_v551
  drop constraint whatsapp_template_registry_v551_category_check;
alter table public.whatsapp_template_registry_v551
  add constraint whatsapp_template_registry_v551_category_check
  check (category = any (array['marketing'::text, 'utility'::text, 'authentication'::text]));

-- status 'draft': not submitted to Meta yet, and the send path refuses anything that is not
-- 'approved', so registering it now cannot leak a send. meta_template_id is filled by
-- whatsapp-admin-templates when the submission comes back, as it was for the other five.
insert into public.whatsapp_template_registry_v551
  (template_key, meta_name, language_code, category, body_text, parameter_descriptors, status)
values
  ('signup_otp', 'peekaa_signup_otp', 'en', 'authentication',
   -- Meta writes an authentication template's copy, not Peekaa: this row records what it renders
   -- (code, security line, five-minute expiry footer, copy-code button) so the registry stays
   -- readable beside the other five. The submission itself lives in whatsapp-admin-templates.
   '{{1}} is your verification code. For your security, do not share this code. / FOOTER: This code expires in 5 minutes. / BUTTON: Copy code',
   '["otp_code"]'::jsonb, 'draft')
on conflict (template_key) do nothing;

-- ---------------------------------------------------------------------------------------------
-- 2. the challenge
-- ---------------------------------------------------------------------------------------------
create table if not exists public.customer_whatsapp_otp_challenges_v894 (
  id uuid primary key,
  phone_norm text not null,
  purpose text not null,
  code_hash text not null,
  attempt_count integer not null default 0,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  send_status text not null default 'pending',
  provider_message_id text,
  last_error_code text,
  created_at timestamptz not null default now(),
  -- app.norm_phone's own domain: Singapore local 8 digits, prefix 3/6/8/9. A number it cannot
  -- normalise never reaches this table, so a challenge can never be issued against one.
  constraint customer_whatsapp_otp_challenges_v894_phone_check
    check (phone_norm ~ '^[3689][0-9]{7}$'),
  -- v894 is sign-up only. Password recovery keeps the SMS path until the owner asks otherwise;
  -- widening this CHECK is the whole of that change on the database side.
  constraint customer_whatsapp_otp_challenges_v894_purpose_check
    check (purpose = 'signup'),
  constraint customer_whatsapp_otp_challenges_v894_hash_check
    check (code_hash ~ '^[0-9a-f]{64}$'),
  constraint customer_whatsapp_otp_challenges_v894_send_status_check
    check (send_status = any (array['pending', 'sent', 'failed'])),
  constraint customer_whatsapp_otp_challenges_v894_attempts_check
    check (attempt_count >= 0 and attempt_count <= 5)
);

comment on table public.customer_whatsapp_otp_challenges_v894 is
  'nestly_v894: one issued WhatsApp sign-up code. Holds a peppered hash, never the code. Rows are swept after 24h by the issue function.';

create index if not exists customer_whatsapp_otp_challenges_v894_phone_idx
  on public.customer_whatsapp_otp_challenges_v894 (phone_norm, created_at desc);
create index if not exists customer_whatsapp_otp_challenges_v894_sweep_idx
  on public.customer_whatsapp_otp_challenges_v894 (created_at);

alter table public.customer_whatsapp_otp_challenges_v894 enable row level security;
-- No policy is declared on purpose: nothing holding anon or authenticated may read a row, and
-- service_role reaches it only through the three functions below.
revoke all on table public.customer_whatsapp_otp_challenges_v894 from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 3. issue
-- ---------------------------------------------------------------------------------------------
-- The gateway already counts requests per IP. This counts them per NUMBER, which is the thing an
-- attacker cannot rotate: three live codes in ten minutes, eight in a day. A Singapore mobile
-- behind CGNAT shares an IP with hundreds of strangers (see public-join's v234 note) — it does not
-- share its own number with anybody.
create or replace function public.internal_whatsapp_otp_issue_v894(
  p_challenge_id uuid,
  p_phone text,
  p_purpose text,
  p_code_hash text,
  p_ttl_seconds integer default 300
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_phone_norm text;
  v_recent integer;
  v_daily integer;
begin
  if not app.platform_feature_enabled('customer_whatsapp_otp') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;
  v_phone_norm := app.norm_phone(p_phone);
  if v_phone_norm is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;
  if p_purpose is distinct from 'signup' then
    return jsonb_build_object('ok', false, 'reason', 'purpose_unsupported');
  end if;

  -- Housekeeping runs here rather than on a cron: the table is small, the sweep is one indexed
  -- delete, and a code older than a day is of no use to anybody including us.
  delete from public.customer_whatsapp_otp_challenges_v894
   where created_at < now() - interval '24 hours';

  select count(*) into v_recent
    from public.customer_whatsapp_otp_challenges_v894
   where phone_norm = v_phone_norm
     and created_at > now() - interval '10 minutes';
  if v_recent >= 3 then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited', 'retry_after', 600);
  end if;

  select count(*) into v_daily
    from public.customer_whatsapp_otp_challenges_v894
   where phone_norm = v_phone_norm
     and created_at > now() - interval '24 hours';
  if v_daily >= 8 then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited', 'retry_after', 3600);
  end if;

  insert into public.customer_whatsapp_otp_challenges_v894
    (id, phone_norm, purpose, code_hash, expires_at)
  values
    (p_challenge_id, v_phone_norm, p_purpose, p_code_hash,
     now() + make_interval(secs => greatest(60, least(900, coalesce(p_ttl_seconds, 300)))));

  return jsonb_build_object(
    'ok', true,
    'challenge_id', p_challenge_id,
    'phone_norm', v_phone_norm,
    'expires_in', greatest(60, least(900, coalesce(p_ttl_seconds, 300)))
  );
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. what Meta said
-- ---------------------------------------------------------------------------------------------
-- Recorded for the same reason whatsapp_template_sends_v557 records it: when nothing arrives, the
-- difference between "we never called Meta", "Meta refused" and "Meta accepted and the phone is
-- off" is the whole of the investigation. The wamid is NOT stored — it base64-decodes to the
-- recipient's number (v536's standing rule), and a delivery receipt for a login code is not worth
-- keeping a second copy of the number for.
create or replace function public.internal_whatsapp_otp_record_send_v894(
  p_challenge_id uuid,
  p_status text,
  p_error_code text default null
)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if p_status is null or p_status not in ('sent', 'failed') then
    return;
  end if;
  update public.customer_whatsapp_otp_challenges_v894
     set send_status = p_status,
         last_error_code = left(coalesce(p_error_code, ''), 32),
         -- A code we could not deliver must not stay valid: it is a live guessing target that
         -- nobody is waiting for. Expiring it here also stops it counting against the resend.
         expires_at = case when p_status = 'failed' then now() else expires_at end
   where id = p_challenge_id;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. consume
-- ---------------------------------------------------------------------------------------------
-- One row, one verdict, one write. The attempt is counted BEFORE the comparison so a wrong guess
-- costs the attacker an attempt even if the transaction is abandoned, and the row is locked for
-- update so two concurrent guesses cannot both see attempt_count = 4.
create or replace function public.internal_whatsapp_otp_consume_v894(
  p_challenge_id uuid,
  p_code_hash text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.customer_whatsapp_otp_challenges_v894%rowtype;
begin
  if not app.platform_feature_enabled('customer_whatsapp_otp') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  select * into v_row
    from public.customer_whatsapp_otp_challenges_v894
   where id = p_challenge_id
   for update;

  -- One sentence for "no such challenge", "already used" and "expired": the caller is unauthenticated
  -- and must not learn which of the three it is.
  if not found or v_row.consumed_at is not null or v_row.expires_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'challenge_invalid');
  end if;
  if v_row.attempt_count >= 5 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_attempts');
  end if;

  update public.customer_whatsapp_otp_challenges_v894
     set attempt_count = attempt_count + 1
   where id = p_challenge_id;

  if v_row.code_hash is distinct from p_code_hash then
    return jsonb_build_object(
      'ok', false, 'reason', 'code_invalid',
      'attempts_left', greatest(0, 4 - v_row.attempt_count)
    );
  end if;

  update public.customer_whatsapp_otp_challenges_v894
     set consumed_at = now()
   where id = p_challenge_id;

  return jsonb_build_object('ok', true, 'phone_norm', v_row.phone_norm, 'purpose', v_row.purpose);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. grants — service_role only, the internal_* convention verbatim
-- ---------------------------------------------------------------------------------------------
revoke all on function public.internal_whatsapp_otp_issue_v894(uuid, text, text, text, integer)
  from public, anon, authenticated;
revoke all on function public.internal_whatsapp_otp_record_send_v894(uuid, text, text)
  from public, anon, authenticated;
revoke all on function public.internal_whatsapp_otp_consume_v894(uuid, text)
  from public, anon, authenticated;
grant execute on function public.internal_whatsapp_otp_issue_v894(uuid, text, text, text, integer)
  to service_role;
grant execute on function public.internal_whatsapp_otp_record_send_v894(uuid, text, text)
  to service_role;
grant execute on function public.internal_whatsapp_otp_consume_v894(uuid, text)
  to service_role;

commit;

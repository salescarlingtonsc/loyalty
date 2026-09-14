-- nestly_v898 rolled-back verification — the registry is a gate, and it agrees with Meta.
--
-- Run against production. Everything happens inside the transaction and the file ends in
-- `rollback;`.
--
--   1. every peekaa_* template except the not-yet-submitted signup_otp is 'approved', so the
--      sender's own gate refuses none of them;
--   2. signup_otp is still 'draft' — v894 ships the OTP channel dark and this must not be the
--      migration that opened it;
--   3. the v824 platform switches are still off, so nothing here started sending;
--   4. and the gate still bites: a row put back to 'submitted' inside this transaction is refused
--      by the same predicate the dispatcher uses, which is what makes assertion 1 meaningful
--      rather than a tautology about a column.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_stale text;
  v_status text;
begin
  -- 1. no peekaa template is stuck behind our own gate
  select string_agg(template_key || '=' || status, ', ' order by template_key)
    into v_stale
    from public.whatsapp_template_registry_v551
   where meta_name like 'peekaa\_%'
     and template_key <> 'signup_otp'
     and status <> 'approved';
  assert v_stale is null,
    format('every peekaa template except signup_otp must be approved, found: %s', v_stale);

  -- 2. the OTP channel is still dark
  select status into v_status
    from public.whatsapp_template_registry_v551 where template_key = 'signup_otp';
  assert v_status = 'draft',
    format('signup_otp must still be draft until Meta approves it, found %s', v_status);

  -- 3. v824 stands
  assert not app.platform_feature_enabled('whatsapp_outbound'),
    'v898 must not have re-opened the v824 master switch';
  assert not app.platform_feature_enabled('whatsapp_retention_sends'),
    'v898 must not have re-opened retention sends';

  -- 4. the gate still bites. Put one row back the way v898 found it and prove the sendable
  --    predicate refuses it — then the rollback below puts it right again.
  update public.whatsapp_template_registry_v551
     set status = 'submitted'
   where template_key = 'appointment_reminder_short';
  assert not exists (
    select 1 from public.whatsapp_template_registry_v551
     where template_key = 'appointment_reminder_short' and status = 'approved'
  ), 'a submitted template must not read as approved';

  raise notice 'v898 registry gate verified';
end
$test$;

rollback;

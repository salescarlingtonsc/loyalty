-- nestly_v898 — the template registry says what Meta says.
--
-- OWNER, 2026-09-14: "run for me - approved", on the drift reported while setting up the
-- WhatsApp sign-up OTP.
--
-- WHAT WAS WRONG. public.whatsapp_template_registry_v551 is the sender's authority on whether a
-- template may be used: the enqueue paths and whatsapp-send-dispatch refuse any kind whose row is
-- not 'approved'. Three rows disagreed with Meta. Verified in WhatsApp Manager on 2026-09-14
-- against WABA 1725929281961827 — all five peekaa_* templates read "Active - Quality pending",
-- which is Meta's UI wording for API status APPROVED:
--
--   bring_back_v1               peekaa_bring_back_v1        27605756952454212
--   appointment_reminder_short  peekaa_appt_reminder_today  1075047798221867
--   appointment_updated         peekaa_appt_updated         2204154080535364
--
-- WHY IT MATTERED, AND WHY IT CHANGED NOTHING TODAY. A stale row is a fail-CLOSED drift: the
-- short-notice reminder and the reschedule notice were refused by our own gate, not by Meta.
-- Nobody noticed because v824 switched whatsapp_outbound off platform-wide on 2026-09-07 and the
-- whole lane has been dark since. This migration does not touch that switch — both v824 flags stay
-- false, and the guard below refuses to commit if either is on — so nothing starts sending because
-- of it. It removes a second, accidental brake that would otherwise still be on when the owner
-- releases the first one.
--
-- WRITTEN TO BE HISTORY-INDEPENDENT, WHICH THE FIRST DRAFT WAS NOT. Production and a fresh replay
-- of the chain did not agree on where these rows started: v551 seeds bring_back_v1 'submitted',
-- v581 seeds the two appointment rows 'draft' with a NULL meta_template_id, and production had
-- since moved them on by hand. A migration that keyed on the old status matched nothing on a
-- scratch cluster and then failed its own assertion — which is how the ci-proof-pack isolation and
-- reconciliation harnesses caught it, both of which replay the whole chain. This states the end
-- state outright instead, so it lands identically on either history and is a no-op if run twice.
--
-- NOT TOUCHED: body_text. Production carries the wording Meta actually approved for the two
-- appointment templates (the v581 fallback submission), while the v581 seed still carries the
-- wording first proposed. That divergence predates this migration, belongs to whoever owns the
-- appointment lane, and rewriting an applied migration's seed is not the way to close it.
--
-- THE DEFECT CLASS IS NOT CLOSED BY THIS MIGRATION. Nothing writes Meta's status back into the
-- registry: whatsapp-admin-templates has a 'status' action that READS the Graph API and returns it
-- to the caller, and no path that records it. Any future approval drifts the same way, silently
-- and fail-closed. Closing that means giving the admin plane a reconciling write (an internal
-- SECURITY DEFINER RPC it may call with the dispatch secret) — a separate change, flagged to the
-- owner rather than smuggled in here.

begin;

update public.whatsapp_template_registry_v551 as r
   set status = v.status,
       meta_template_id = coalesce(r.meta_template_id, v.meta_template_id),
       updated_at = now()
  from (values
    ('bring_back_v1',              'approved', '27605756952454212'),
    ('appointment_reminder_short', 'approved', '1075047798221867'),
    ('appointment_updated',        'approved', '2204154080535364')
  ) as v(template_key, status, meta_template_id)
 where r.template_key = v.template_key
   and (r.status is distinct from v.status or r.meta_template_id is null);

-- The registry is a gate. If it does not now say exactly what Meta says, this migration has made
-- things worse rather than better, and it must not commit.
do $$
declare
  v_unapproved text;
begin
  select string_agg(template_key || '=' || status, ', ' order by template_key)
    into v_unapproved
    from public.whatsapp_template_registry_v551
   where meta_name like 'peekaa\_%'
     and template_key <> 'signup_otp'   -- v894, genuinely not submitted to Meta yet
     and status <> 'approved';
  if v_unapproved is not null then
    raise exception 'v898: a peekaa template is still not approved in the registry: %', v_unapproved;
  end if;

  if exists (
    select 1 from public.whatsapp_template_registry_v551
     where template_key in ('bring_back_v1', 'appointment_reminder_short', 'appointment_updated')
       and meta_template_id is null
  ) then
    raise exception 'v898: an approved template is missing the Meta id the status claims it has';
  end if;

  -- signup_otp stays 'draft' until Meta approves it. Its submission was refused on 2026-09-14
  -- ("this WhatsApp business account does not have permission to create message template") because
  -- the WABA has no valid payment method; that is an account matter, not a schema one.
  if (select status from public.whatsapp_template_registry_v551 where template_key = 'signup_otp')
       is distinct from 'draft' then
    raise exception 'v898: signup_otp must still be draft; v894 ships the OTP channel dark';
  end if;

  -- v824 is not re-opened here, and this migration must be the proof of that rather than the
  -- place it quietly stopped being true.
  if exists (select 1 from app.platform_feature_flags
              where feature_key in ('whatsapp_outbound', 'whatsapp_retention_sends') and enabled) then
    raise exception 'v898: a v824 platform switch is enabled; this migration must not be the thing that turned it on';
  end if;
end $$;

commit;

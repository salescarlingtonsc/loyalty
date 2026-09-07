-- nestly_v824 — API WhatsApp sending is switched off platform-wide; manual WhatsApp stays.
--
-- OWNER RULING, 2026-09-08. On the appointment card's WhatsApp button (V330 — opens WhatsApp on
-- the staff member's own phone with a draft; Peekaa neither sends nor marks anything):
--   "this whatsapp is good, i just do not want the API whatsapp for now."
-- and earlier the same day: "i want to hide everything whatsapp inbox related. except for manual
-- whatsapp click. those API whatsapp i want it hide."
--
-- The app side shipped as HIDE_WHATSAPP_API_SURFACES_V824 (app/app.js, commit 6f190f85): the
-- automation card, the delivery strip and both consent surfaces are no longer painted. That
-- hides the controls. It does not stop the machine behind them, and the machine was found
-- running:
--
--   * app.platform_feature_flags.whatsapp_outbound = TRUE (set 2026-08-26, never changed)
--   * 24 businesses carry wa_confirmation_enabled / wa_reminder_short_enabled = true — the
--     column defaults, not a choice any owner made
--   * the appointment triggers (whatsapp_appointment_booked_v557, whatsapp_appointment_moved_v581)
--     call app.whatsapp_enqueue_appointment_notice_v557 on every booking and every move
--   * every API send ever attempted has FAILED: 7 rows in whatsapp_template_sends_v557, all
--     status='failed', all for the Cubbly demo tenant (the only firm holding the
--     whatsapp_appointment_notification capability), last attempt 2026-09-06
--
-- With the card hidden no owner can switch those off from the app, so the honest close of the
-- ruling is the platform master switch, which every enqueue path checks FIRST
-- (v557 line "(1) the PLATFORM master switch"; v581 likewise; the retention dispatcher reads
-- whatsapp_retention_sends, already false). One row, reversible by setting it back to true.
--
-- Precedent for changing this table by migration rather than by hand: nestly_v551 inserted the
-- flag, nestly_v571/v572/v574 updated it. A flag flip is a production behaviour change and gets
-- the same audit trail as any other.
--
-- KEPT, untouched, because they involve no API and nothing Peekaa sends: the appointment card's
-- WhatsApp button (V330), the customer share sheet's WhatsApp channel (V264), Bring-back's
-- "copy the contact list and message them yourself". They read the customer's phone number and
-- open WhatsApp; this flag is not on their path.
--
-- NOT touched: the 24 per-business wa_* columns (they are inert while the master is off, and
-- un-doing this ruling should not need 24 owners to re-tick anything), the template registry,
-- the dispatch edge functions, the triggers. Nothing is dropped.

begin;

update app.platform_feature_flags
   set enabled = false,
       changed_at = now()
 where feature_key in ('whatsapp_outbound', 'whatsapp_retention_sends')
   and enabled;

-- Belt and braces: the keys must exist for the reads above to be meaningful at all.
do $$
begin
  if (select count(*) from app.platform_feature_flags
       where feature_key in ('whatsapp_outbound', 'whatsapp_retention_sends')) <> 2 then
    raise exception 'v824: expected both whatsapp platform flags to exist';
  end if;
  if exists (select 1 from app.platform_feature_flags
              where feature_key in ('whatsapp_outbound', 'whatsapp_retention_sends') and enabled) then
    raise exception 'v824: a whatsapp platform flag is still enabled after the update';
  end if;
end $$;

commit;

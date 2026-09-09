-- nestly_v879 — a subscription reads "paid" only when the payment matches the contract.
--
-- OWNER, 2026-09-09: "yes, fix v680 and push once verified" — a billing risk exception, approved
-- explicitly after the defect was put in front of the owner with its blast radius.
--
-- THE DEFECT, found by the executed fixture v510_operating_system_crm_foundation (red on main,
-- correctly, since nestly_v680 landed). app.v680_apply_paid_period guards the obligation advance
-- with app.v510_verified_initial_payment — the reader v510 built so that a manual payment counts
-- only when the invoice's total, the payment's amount, the currency AND the service period all
-- equal the accepted contract's — and lets v510 veto the move inside a sub-transaction. The very
-- next statement, `set status = 'active', payment_status = 'paid', current_period_* = ...`, has
-- no guard at all. So a verified manual payment on ANY invoice of the business — a partial one,
-- an unrelated one — marked the subscription paid in full and stamped a fresh paid period.
-- v680's own header framed v510 as "the safety" and wired it to one write out of two; nothing in
-- that header argues for the asymmetry, and its stated problem (a renewal tenant stuck after a
-- genuine, correctly-sized payment) does not need it.
--
-- BLAST RADIUS, measured: nestly_v784 later ruled "money never closes the door", so this never
-- opened a workspace. It corrupted the billing ledger — everything that reads
-- subscriptions.payment_status / status / current_period_end: the billing summary (v758), the
-- due-day dunning buckets (v793), branch subscriptions (v786), the onboarding payment_verified
-- item. Zero production tenants were affected: every manual subscription today (15) is
-- `trialing` with NO accepted commercial terms.
--
-- THE RULE. The paid flip now asks the same question the obligation advance asks, with one
-- deliberate carve-out:
--   * a tenant WITH accepted/signed commercial terms flips to active/paid only when
--     app.v510_verified_initial_payment finds evidence that matches those terms exactly;
--   * a tenant WITHOUT accepted terms has no contracted sum to match — v510 is structurally
--     null for them — so a verified payment keeps flipping them exactly as before. That carve-out
--     is what keeps the fifteen live manual tenants activatable; without it they could never be.
-- When the gate says no, the payment is still recorded (last_paid_at, the audit row, the replay
-- record) — money did arrive — but status, payment_status, cadence and the paid period are left
-- exactly as they were, and the audit detail says `evidenced: false` so the reason is visible.
--
-- Provider payments are untouched: app.v680_apply_paid_period is reached only by
-- platform_record_subscription_payment_v664 and, via app.v680_manual_payment_period, by
-- platform_verify_manual_payment_v156 — both platform/manual routes. Stripe and Razorpay flows
-- never enter it (verified: those are its only two callers in the catalog).
--
-- Only nestly_v680 has ever defined this function, so production and a chain rebuild carry the
-- same body; the anchors below are code-only and asserted to match exactly once.

begin;

do $splice$
declare
  v_def text; v_new text; v_spec jsonb; v_target text; v_anchor text; v_inject text; v_hits integer;
  v_specs jsonb := jsonb_build_array(

    -- (1) One more local.
    jsonb_build_object(
      'anchor', $t$  v_obligation_moved boolean := false;
  v_replay jsonb;$t$,
      'inject', $t$  v_obligation_moved boolean := false;
  v_evidenced boolean := false;   -- nestly_v879: does this payment match the accepted contract?
  v_replay jsonb;$t$),

    -- (2) The flip, gated.
    jsonb_build_object(
      'anchor', $t$  update public.subscriptions
     set status = 'active',
         payment_status = 'paid',
         billing_cadence = coalesce(p_cadence, billing_cadence),
         cadence_months = case coalesce(p_cadence, billing_cadence)
                            when 'annual' then 12::smallint
                            when 'half_yearly' then 6::smallint
                            when 'quarterly' then 3::smallint
                            when 'monthly' then 1::smallint
                            else cadence_months end,
         current_period_start = v_new_start,
         current_period_end = v_new_end,
         next_payment_at = v_new_end,
         last_paid_at = v_paid_at,$t$,
      'inject', $t$  -- nestly_v879: "paid" means the CONTRACT was paid. With accepted terms on file, only evidence
  -- that matches them (app.v510_verified_initial_payment: amount, currency and service period all
  -- equal to the obligation) may flip status, payment_status, cadence and the paid period. With no
  -- accepted terms there is nothing to match, and a verified payment flips as it always did — the
  -- carve-out that keeps every live manual tenant activatable. Either way the payment itself is
  -- recorded below; only the entitlement waits for the evidence.
  v_evidenced := not exists (
      select 1 from public.sme_commercial_terms terms
       where terms.id = v_before.commercial_terms_id
         and terms.contract_status in ('accepted','signed')
         and coalesce(terms.accepted_value_cents, 0) > 0)
    or app.v510_verified_initial_payment(p_business) is not null;
  update public.subscriptions
     set status = case when v_evidenced then 'active' else status end,
         payment_status = case when v_evidenced then 'paid' else payment_status end,
         billing_cadence = case when v_evidenced then coalesce(p_cadence, billing_cadence) else billing_cadence end,
         cadence_months = case when not v_evidenced then cadence_months
                               else case coalesce(p_cadence, billing_cadence)
                                      when 'annual' then 12::smallint
                                      when 'half_yearly' then 6::smallint
                                      when 'quarterly' then 3::smallint
                                      when 'monthly' then 1::smallint
                                      else cadence_months end end,
         current_period_start = case when v_evidenced then v_new_start else current_period_start end,
         current_period_end = case when v_evidenced then v_new_end else current_period_end end,
         next_payment_at = case when v_evidenced then v_new_end else next_payment_at end,
         last_paid_at = v_paid_at,$t$),

    -- (3) The audit row says why.
    jsonb_build_object(
      'anchor', $t$            'obligation_period_moved', v_obligation_moved,$t$,
      'inject', $t$            'obligation_period_moved', v_obligation_moved,
            'evidenced', v_evidenced,$t$)
  );
begin
  v_target := 'app.v680_apply_paid_period';
  for v_spec in select * from jsonb_array_elements(v_specs) loop
    v_anchor := v_spec->>'anchor'; v_inject := v_spec->>'inject';
    v_def := pg_get_functiondef(v_target::regproc);
    if position(v_inject in v_def) > 0 then
      raise notice 'nestly_v879: this edit is already in %, skipping', v_target; continue;
    end if;
    v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor), 0);
    if v_hits is distinct from 1 then
      raise exception 'nestly_v879: anchor matched % time(s) in % — the body has drifted; re-derive the anchor',
        coalesce(v_hits, 0), v_target using errcode = 'XX001';
    end if;
    execute replace(v_def, v_anchor, v_inject);
  end loop;
end
$splice$;

-- Internal helper; its ACL is restated verbatim (never granted to the API roles).
revoke all on function app.v680_apply_paid_period(uuid, timestamp with time zone, text, text, uuid, text,
  timestamp with time zone, date, date, text, timestamp with time zone, integer, text)
  from public, anon, authenticated;

do $verify$
declare v_def text := pg_get_functiondef('app.v680_apply_paid_period'::regproc);
begin
  if position('v_evidenced := not exists' in v_def) = 0
     or position('set status = case when v_evidenced then ''active'' else status end' in v_def) = 0
     or position('''evidenced'', v_evidenced' in v_def) = 0 then
    raise exception 'nestly_v879: the paid flip is still unconditional' using errcode = 'XX001';
  end if;
  if position('set status = ''active'',' in v_def) > 0 then
    raise exception 'nestly_v879: an unconditional flip survives in the body' using errcode = 'XX001';
  end if;
end
$verify$;

commit;

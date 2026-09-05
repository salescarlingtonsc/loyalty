-- nestly_v775 — a capacity increase is charged today and says so in the payments history
-- (owner ruling 2026-09-05).
--
-- OWNER: "when I increase capacity from 10k to 40k the difference must be paid today (pro-rated),
-- the same concept as a new branch", and "I need a field to indicate a payment due to an
-- increase from 10k to 40k or 100k profiles".
--
-- Razorpay already charges the pro-rata difference the moment the PATCH lands (schedule_change_at
-- 'now'); what was missing was the mirror and the label. The edge command now captures that
-- update invoice with notes.reason = 'capacity_increase' and capacity_from / capacity_to. This
-- migration lets that reason through:
--   1. billing_provider_invoices.reason admits 'capacity_increase'.
--   2. apply_razorpay_billing_event_v755 is PATCHED IN PLACE (extract-and-diff, the v765 idiom):
--      its allow-list of note reasons gains 'capacity_increase', so the reason survives instead of
--      being folded into 'renewal'. Nothing else in the applier changes; the migration refuses to
--      apply if the exact allow-list text is not found.
--
-- The page renders the row as "Capacity increase · 10,000 → 40,000 profiles · dates".

begin;

-- 1 · the column admits the new reason
alter table public.billing_provider_invoices
  drop constraint if exists billing_provider_invoices_reason_ck;
alter table public.billing_provider_invoices
  drop constraint if exists billing_provider_invoices_reason_check;
alter table public.billing_provider_invoices
  add constraint billing_provider_invoices_reason_ck
  check (reason is null or reason = any (array[
    'initial','renewal','branch_added','plan_changed','card_change','capacity_increase','other'
  ]));

-- 2 · the applier keeps the reason
do $v775$
declare
  v_definition text;
  v_needle text := $needle$('initial','renewal','branch_added','plan_changed','card_change','other')$needle$;
  v_replacement text := $repl$('initial','renewal','branch_added','plan_changed','card_change','capacity_increase','other')$repl$;
begin
  select pg_get_functiondef('public.apply_razorpay_billing_event_v755'::regproc) into v_definition;
  if v_definition is null then
    raise exception 'v775: apply_razorpay_billing_event_v755 is missing';
  end if;
  if position(v_needle in v_definition) = 0 then
    if position(v_replacement in v_definition) > 0 then
      raise notice 'v775: applier already admits capacity_increase';
      return;
    end if;
    raise exception 'v775: the applier''s reason allow-list was not found verbatim; refusing to patch blind';
  end if;
  v_definition := replace(v_definition, v_needle, v_replacement);
  execute v_definition;
  raise notice 'v775: applier patched — capacity_increase admitted';
end
$v775$;

commit;

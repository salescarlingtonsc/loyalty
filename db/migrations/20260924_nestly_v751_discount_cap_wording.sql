-- nestly_v751 — a capped discount says so.
--
-- OWNER (2026-09-04): "for discounts: i need you to indicate very clearly. discount received is
-- capped at $xx. now is very vague."
--
-- THE GAP. app.v657_discount_label (nestly_v657, 2026-08-31) produced "30% off, up to 100.00" for
-- a capped whole-bill discount. Three things were unclear about that sentence: the bare number
-- after the comma named no currency, "up to" reads as an offer's own ceiling rather than what the
-- CUSTOMER receives being capped, and a whole-bill discount with no cap said only "30% off" — the
-- word "whole bill" was implicit, so an owner or customer reading it could not tell a whole-bill
-- discount from an incompletely-described one at a glance.
--
-- THE FIX. app.v657_discount_label now:
--   · always names the shape in words — "the whole bill" or "one item" — never leaves it implicit;
--   · states a cap as "— capped at $100.00", not ", up to 100.00", so the ceiling reads as what it
--     is (a stop on how much money comes off) and carries a currency mark.
-- Examples: "30% off the whole bill", "30% off the whole bill — capped at $100.00",
-- "10% off one item". (An item-scope discount cannot carry a cap today — see the v657 check
-- constraint tier_benefits_v365_max_discount_check, which only allows max_discount_cents when
-- discount_scope='bill' — so no "one item — capped at $" case exists to derive.)
--
-- The client mirror, growTierBenefitSentenceV365 in app/app.js, is updated in lockstep so the
-- dialog preview an owner reads while typing is character-for-character the sentence the server
-- will store (the same parity nestly_v369/v656/v657 already required). Every other surface —
-- the Tier membership page's rows, the customer app's tier card, the till's applied-discount
-- receipt line — reads either this same stored label or loyalty_tiers.perk_note, which is derived
-- from it (app.v365_apply_perk_note), so relabelling the stored text is sufficient for all of them.
-- The till's receipt line additionally dropped a bare "(capped)" suffix that told the counter the
-- ceiling was hit but never what it was — the same vagueness the owner flagged — now redundant
-- with the label itself stating its ceiling.
--
-- BACKFILL. Only rows the engine derived get relabelled: benefit_kind='discount_pct' rows, whose
-- label has never been anything but app.v657_discount_label's own output (nestly_v657's own
-- migration re-derived every one of them the same way). A benefit_kind='custom' row's label is the
-- owner's own typed sentence (nestly_v369) and is never touched by this or any relabelling here —
-- there is nothing machine-derived in it to correct.
--
-- Read-only otherwise. No table, column, policy or grant changes beyond restating
-- app.v657_discount_label's grant verbatim from the live proacl ({postgres=X/postgres} — already
-- revoked from public/anon, so this migration keeps that revoke rather than widening it).
--
-- Rollback suite: db/tests/v751_discount_cap_wording.sql

begin;

create or replace function app.v657_discount_label(p_discount numeric, p_scope text, p_max_cents integer)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $function$
  select regexp_replace(trim(to_char(p_discount, 'FM999990.99')), '\.$', '') || '% off '
    || case when coalesce(p_scope,'bill')='item' then 'one item' else 'the whole bill' end
    || case when p_max_cents is not null
            then ' — capped at $' || trim(to_char(p_max_cents::numeric/100, 'FM999999990.00')) else '' end
$function$;

revoke all on function app.v657_discount_label(numeric, text, integer) from public, anon;

-- Re-derive every discount label the engine owns, and refresh the perk_note lines those labels
-- feed — the same two steps nestly_v657 took when it last changed this wording.
update public.tier_benefits_v365 b
   set label = app.v657_discount_label(b.discount_percent, b.discount_scope, b.max_discount_cents)
 where b.benefit_kind = 'discount_pct'
   and b.deleted_at is null
   and b.label is distinct from app.v657_discount_label(b.discount_percent, b.discount_scope, b.max_discount_cents);

do $relabel$
declare r record;
begin
  for r in select distinct business_id, tier_id from public.tier_benefits_v365
            where benefit_kind='discount_pct' and deleted_at is null
  loop
    perform app.v365_apply_perk_note(r.business_id, r.tier_id);
  end loop;
end $relabel$;

commit;

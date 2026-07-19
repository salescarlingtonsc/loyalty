-- FRENLY v22 — FLAT-COMMISSION RECONCILIATION (P0 security fix + formal contract supersession).
-- Applied migration name: frenly_v22_flat_commission_reconciliation
--
-- WHY THIS EXISTS. v20 formally tombstoned the v13 flat-commission model (its apply-time guard
-- raises 'v13 flat commission is tombstoned' and its test suite asserted every flat artifact
-- absent); the financial engine was rehearsed percentage-only. The rebased v13
-- (`frenly_v13_flat_commission`, applied after v21) then reinstated flat commission — with
-- v20-compatible reversal/branch semantics, but with two defects this migration corrects:
--
--   1. SECURITY REGRESSION: `app.commission_flat_cents(...)` was created WITHOUT the v21-standard
--      ACL revoke, leaving a SECURITY DEFINER function with the Postgres default EXECUTE grant to
--      PUBLIC (hence anon/authenticated executable). Actual exposure was contained — `anon` holds
--      no USAGE on schema `app` and `app` is not API-exposed — but it violates v21's hardening
--      invariant, enforced by db/tests/v21_security_hardening.sql: "no SECURITY DEFINER function
--      in app/public executable by anon/PUBLIC".
--   2. CONTRACT DRIFT: v20's tombstone statement was never formally superseded, so production ran
--      a commission model its financial test suite still asserted was absent.
--
-- OWNER DECISION (2026-07-19): keep flat commission (option 2) — it implements the recorded
-- product ruling ("% of sales OR a fixed amount per selected service") — and reconcile formally.
--
-- WHAT v22 DOES (deliberately minimal):
--   1. Revokes ALL on app.commission_flat_cents from PUBLIC/anon/authenticated → owner-only,
--      byte-matching app.commission_rate_bps's ACL. Its ONLY caller is the SECURITY DEFINER
--      trigger function app.on_sale_commission_snapshot(), which runs as the function owner and
--      is unaffected by the revoke.
--   2. Records the tombstone supersession in the catalog (comments), so the contract history is
--      readable from the database itself.
--   3. Nothing else. The v20 test suite's percentage-only assertions are updated in the same
--      commit (db/tests/v20_financial_engine.sql) to assert the reconciled contract, and
--      db/tests/v22_flat_commission.sql adds the standing flat-commission behavioral suite.
--      Both suites + v21's must pass against production after this migration.

begin;

-- 1. THE ACL FIX. Owner-only, exactly like app.commission_rate_bps.
revoke all on function app.commission_flat_cents(uuid, text, uuid, uuid, timestamptz, integer)
  from public, anon, authenticated;

-- 2. THE CONTRACT RECORD.
comment on function app.commission_flat_cents(uuid, text, uuid, uuid, timestamptz, integer) is
  'Flat-commission resolver (v13 rebased; formally reconciled by v22). Owner-only ACL — the sole '
  'caller is app.on_sale_commission_snapshot() (SECURITY DEFINER trigger). v22 supersedes v20''s '
  '"v13 flat commission is tombstoned" statement: flat commission is the approved model per the '
  'owner''s % -or-flat-per-service ruling, with v20-compatible reversal semantics (a reversal row '
  'copies the original''s flat snapshot and public.sale_commission nets it negative in full).';

comment on column public.sales.commission_flat_cents is
  'IMMUTABLE SNAPSHOT of the resolved FLAT commission in cents at record time, or NULL if not '
  'flat-commission (then commission_rate_bps applies). When NOT NULL this WINS over the rate '
  '(0 is a real flat-zero). A reversal sale copies the original sale''s snapshot and the view '
  'nets it negative. Reinstated by frenly_v13_flat_commission and formally reconciled with the '
  'v20 financial engine by frenly_v22_flat_commission_reconciliation (supersedes the v20 tombstone).';

commit;

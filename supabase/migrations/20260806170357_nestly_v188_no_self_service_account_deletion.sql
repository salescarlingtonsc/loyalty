-- v188 — account closure goes through Peekaa, not a self-service button.
--
-- Owner ruling, 2026-08-07: "do not allow firms or users to delete account — it is redundant. If
-- they want they can email in their request or speak with their assigned consultant."
--
-- The UI stopped offering it in the same version. Removing a button is not a control, so the
-- submit RPC is revoked from `authenticated` here: a crafted PostgREST call now fails the same
-- way the missing button implies. Nothing else changes.
--
-- Deliberately KEPT:
--   * get_account_deletion_request_v131 — someone who submitted a request before this change must
--     still be able to see what happened to it. Read-only, self-scoped.
--   * the platform console's v133 list/resolve path — Peekaa still processes requests that arrive
--     by email, and the audit trail those write is the record of that work.
--   * the function itself, and service_role's grant, so a request taken by email can still be
--     recorded server-side against the right account rather than in a spreadsheet.
--
-- ⚖️ Flagged for the owner: the native iOS build ships through the App Store, whose guideline
-- 5.1.1(v) expects an app that offers account creation to also offer account deletion INITIATED
-- IN-APP. An email address may not satisfy a reviewer. This migration is what was asked for; the
-- store risk is a business decision, not a technical one.

begin;

revoke execute on function public.request_account_deletion_v131(text, text) from authenticated;

commit;

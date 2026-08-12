-- NESTLY v283: restore the two self-serve customer-claim paths.
--
-- GAP (from the 2026-08-12 product audit): a signed-in customer could link a
-- programme only via an invitation token. Both self-serve methods were dead —
-- the DEFAULT phone method (customer_claim_link_by_verified_phone) and the email
-- fallback (customer_claim_link_by_email) returned PGRST202. Root cause was NOT
-- undeployed code: both functions exist in prod but EXECUTE was granted only to
-- service_role, so PostgREST hid them from the authenticated role and the
-- already-shipped Claim button failed. Only customer_claim_link_invitation was
-- correctly granted to authenticated.
--
-- WHY THIS IS SAFE. Both are SECURITY DEFINER with a pinned search_path and take
-- NO contact argument: each derives the caller's OWN verified contact from
-- auth.users WHERE id = auth.uid() (requires phone_confirmed_at / email_confirmed_at),
-- links only when EXACTLY ONE unclaimed client matches (never reassigns an
-- already-linked record), is feature-flag gated, rate-limited to 5 attempts /
-- 15 min per identity, idempotent, and fully audited. A caller cannot coerce them
-- into linking another person's contact, so exposing them to authenticated (the
-- role that already calls them) only fixes the dead button. anon is deliberately
-- NOT granted — claiming is a post-authentication action.
--
-- Applied to production 2026-08-12; the grant mirrors the invitation sibling's
-- existing ACL exactly. Verified rolled back (db/tests/v283_*): SECURITY DEFINER +
-- pinned search_path, authenticated may execute, anon may not, and an arbitrary
-- authenticated caller against a nonexistent business creates no link.

begin;

grant execute on function public.customer_claim_link_by_verified_phone(text, text)
  to authenticated;
grant execute on function public.customer_claim_link_by_email(text, text)
  to authenticated;

commit;

-- FRENLY v66a - PS-2 LIVE: RESTORE security_invoker ON v_business_billing (close a v66 regression)
--
-- Forward-only, narrow. Do NOT edit/reapply v66. Single statement: re-set ONE reloption on ONE view.
-- No table, no function, no policy, no grant, no view-definition change.
--
-- WHY: v66 recreated public.v_business_billing with `create or replace view ... as <def>` to add the
-- `where b.is_synthetic = false` filter. Per PostgreSQL semantics, CREATE OR REPLACE VIEW resets the
-- view's storage parameters when the WITH clause is omitted, so the `security_invoker = true` this view
-- had carried since its introduction (v14/v49 billing projection) was silently dropped. The view is
-- granted SELECT to anon + authenticated; without security_invoker it executes with the view OWNER's
-- privileges (the SECURITY DEFINER default), bypassing the caller's RLS on public.businesses and
-- public.subscriptions. Any authenticated tenant hitting /rest/v1/v_business_billing could therefore
-- read every non-synthetic business's name, subscription status, pricing and billable-seat counts.
-- Supabase's security advisor flags this as ERROR `security_definer_view`.
--
-- WHAT: restore the caller-RLS (SECURITY INVOKER) posture. `ALTER VIEW ... SET (security_invoker=true)`
-- changes ONLY the reloption; the v66 definition, including the intended `where b.is_synthetic = false`
-- filter, is untouched. Pure security tightening (fail-safe: the worst case is a stricter view). This is
-- config/DDL only: writes zero sv_lots / sv_lot_movements / sv_topup_payments, and never transitions
-- sv_authority (stored value stays 'unbuilt' for every business).
--
-- NOTE (out of scope): the pre-existing view public.v_program_rules_all is ALSO flagged
-- security_definer_view, but it predates v66 (empty reloptions in the clean v64 baseline) and its
-- intended access semantics have not been reviewed here; it is deliberately left for a separate,
-- dedicated increment rather than changed opportunistically.

begin;

alter view public.v_business_billing set (security_invoker = true);

commit;

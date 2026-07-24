-- FRENLY v66b - PLATFORM HARDENING: security_invoker ON v_program_rules_all (close the LAST advisor ERROR)
--
-- Forward-only, narrow. Single statement: re-set ONE reloption on ONE view. No table, no function,
-- no policy, no grant, no view-definition change. Companion in spirit to v66a (v_business_billing).
--
-- WHY: public.v_program_rules_all (v55 authoring adapter, repointed v60) is a SECURITY DEFINER view
-- (empty reloptions since creation — pre-existing, NOT a v66 regression; confirmed empty in the clean
-- v64 baseline) granted SELECT to authenticated. Supabase's security advisor flags it as the one
-- remaining ERROR `security_definer_view`. Unlike v_business_billing this view is NOT leaking: its
-- body ends in `WHERE app.is_salon_owner(business_id) OR app.is_super_admin()`, so rows are already
-- caller-scoped. The flip is pure defense-in-depth: with security_invoker=true a direct REST read also
-- passes the underlying tables' RLS (member/owner/SA SELECT policies exist on businesses,
-- loyalty_program_versions, loyalty_tier_versions, loyalty_reward_versions, retention_program_versions,
-- referral_programs), making the in-body predicate belt-and-braces instead of the only line of defense.
--
-- WHAT DOES NOT CHANGE: the view's only real consumers are the SECURITY DEFINER RPCs
-- get_program_rules_draft (v55) and get_programs_overview (v60). Inside a SECURITY DEFINER function the
-- view evaluates as the function owner (table owner -> RLS bypass), so the Studio UI path returns
-- byte-identical results. The app never reads the view directly (0 references in app/index.html).
--
-- WHAT TIGHTENS FURTHER THAN EXPECTED (measured in rehearsal, deliberate): birthday_program_versions
-- carries NO table-level SELECT grant for authenticated at all, so under security_invoker any DIRECT
-- read of this view by an API role now fails outright with 42501 (privilege check on every underlying
-- relation) instead of returning caller-scoped rows. Since the RPCs are the only sanctioned consumers
-- and no app surface reads the view directly, direct-API denial is the desired fail-closed outcome; no
-- new grant is added. The suite asserts BOTH the direct-read denial and RPC-path parity.
--
-- Config/DDL only: writes zero sv_lots / sv_lot_movements / sv_topup_payments; sv_authority untouched.

begin;

alter view public.v_program_rules_all set (security_invoker = true);

commit;

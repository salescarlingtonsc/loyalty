# PS-2 LIVE v66a (restore security_invoker on v_business_billing) — Independent Review Verdict

## VERDICT: `PASS V66A`

Independent adversarial review of the exact frozen commit (SHA-256 of bytes + minimality/DDL scan +
behavioural RLS discrimination + full local rehearsal + read-only prod confirmation).

- **Frozen commit:** `b9f3fb822c2d12f5384265c7e3e3b3b095563a9b`
- **Canonical:** `db/migrations/20260724_frenly_v66a_ps2live_billing_view_secinvoker.sql`
- **Mirror:** `supabase/migrations/20260725040000_frenly_v66a_ps2live_billing_view_secinvoker.sql`
- **SHA-256 (both, byte-identical):** `4233e5463552c268046629c1333977a21a0326c0eaafc2ead2998086589bdfa2` — **MATCHED**

## What v66a fixes
v66's `create or replace view public.v_business_billing` reset the view's reloptions and dropped
`security_invoker = true`; because the view is granted SELECT to `anon`/`authenticated` it briefly ran as
the view owner (SECURITY DEFINER default), bypassing caller RLS on `businesses`/`subscriptions` — a
cross-tenant billing read (Supabase advisor ERROR `security_definer_view`). v66a is the one statement
`ALTER VIEW public.v_business_billing SET (security_invoker = true)` — reloption only; the v66 definition
(incl. the `where b.is_synthetic = false` filter) is untouched.

## Independent checks (all PASS)
1. **Byte fidelity** — canonical == mirror == expected SHA-256; `git show --stat` shows only the intended
   files, no stray edits.
2. **Minimality** — body is exactly `begin;` / one `ALTER VIEW … SET (security_invoker = true);` / `commit;`;
   zero create/table/function/policy/grant/revoke DDL; the view definition is NOT re-issued.
3. **Correctness** — after the ALTER, `reloptions = {security_invoker=true}`, the `is_synthetic=false`
   filter is preserved, and the prod advisor ERROR clears. Reloption-only is sufficient; a recreate is
   unnecessary.
4. **No legitimate reader broken** — under invoker: plain owner A sees exactly their own row; super admin
   sees both; `is_salon_member`/`is_salon_owner`/`is_super_admin` are SECURITY DEFINER so they still
   resolve; `anon` (never a legitimate billing reader) is correctly locked out.
5. **Test genuinely discriminates** — reviewer forced the view back to DEFINER and the suite ABORTED
   (`must carry security_invoker=true, got reloptions=[]`) and the behavioural leak reproduced (DEFINER →
   owner A sees 1 row for tenant B; invoker → 0). The suite cannot pass against a DEFINER view.
6. **Rehearsal** — from the clean v64 template: baseline `security_invoker=true` → after v65/v65a/v65b/v66
   **EMPTY (regression confirmed real)** → after v66a `security_invoker=true`; both the v66a and v66 SQL
   suites print SUITE PASS. Scratch DB dropped.
7. **Registration** — `generate-manifest --check`, `materialize --check-plan`/`--check`, and the four
   phase0/program-studio suites all green (25/0); v66a appended (no reordering) as pending version
   `20260725040000`, matching the mirror filename.
8. **Prod (read-only, `gadpooereceldfpfxsod`)** — `v_business_billing` reloptions = `security_invoker=true`;
   view def still has `is_synthetic = false`; ledger row version `20260725040000`; the security advisor's
   remaining `security_definer_view` ERROR is `v_program_rules_all` only — `v_business_billing` is cleared.
9. **Scope honesty** — `v_program_rules_all` has empty reloptions in the clean v64 baseline (pre-existing,
   not a v66 regression); v66 touched exactly one view; leaving `v_program_rules_all` for a separate
   increment is a defensible, documented decision.

## Defects
None (no HIGH/MED/LOW). Correct, minimal, complete, side-effect-free; the acceptance test discriminates
SECURITY INVOKER from DEFINER both structurally and behaviourally.

## Pre-existing item surfaced for the owner (out of v66/v66a scope)
`public.v_program_rules_all` is a SECURITY DEFINER view flagged ERROR by the advisor. It predates v66
(empty reloptions in the v64 baseline). Recommend a dedicated increment to review its intended access and,
if appropriate, set `security_invoker=true` — not folded into v66a to keep the hotfix single-purpose.

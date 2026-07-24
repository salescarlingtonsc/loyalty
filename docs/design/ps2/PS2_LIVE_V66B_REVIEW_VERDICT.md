# v66b (security_invoker on v_program_rules_all) — Independent Review Verdict

## VERDICT: `PASS V66B` — **PENDING PROD APPLY** (held for the owner's exact release phrase)

Independent adversarial review of the exact frozen commit, executed entirely in isolated worktrees
(the main tree was concurrently in use by the v67 builder).

- **Frozen commit:** `867b9a77fdce2575f5eca3da84f4329c2bca730a`
- **Canonical:** `db/migrations/20260724_frenly_v66b_program_rules_secinvoker.sql`
- **Mirror:** `supabase/migrations/20260725050000_frenly_v66b_program_rules_secinvoker.sql`
- **SHA-256 (both, byte-identical):** `34488c8e37b52b2164544341abb774801d7fa601c4ef11881f25e27413a0ba74` — **MATCHED**

## What v66b does
Closes the LAST security-advisor ERROR (`security_definer_view`): `public.v_program_rules_all`
(v55 authoring adapter) gains `security_invoker = true`. NOT a leak fix — the view body already ends
in `WHERE app.is_salon_owner(business_id) OR app.is_super_admin()` — pure defense-in-depth. Measured,
deliberate consequence: DIRECT API reads now fail outright with 42501 (`birthday_program_versions`
carries no authenticated table grant), while the only sanctioned consumers (SECURITY DEFINER RPC
`get_programs_overview`) are provably unaffected.

## Independent checks (all PASS)
1. **Byte fidelity + minimality** — SHA exact; body is begin / one ALTER VIEW SET reloption / commit;
   view definition not re-issued.
2. **Exposure change proven real, both directions** — before v66b: reloptions EMPTY and direct
   authenticated reads SUCCEED (plain owner and SA each saw rows); after: `security_invoker=true`,
   direct reads 42501, suite PASS; v66/v66a suites still PASS on the chain. Mechanism confirmed
   in-catalog: `has_table_privilege('authenticated', …)` true for every underlying table EXCEPT
   `birthday_program_versions` — exactly the one missing grant the header claims.
3. **Suite discriminates** — force-revert (`reset (security_invoker)`) → suite ABORTS rc=3; the
   definer-state pre-check proves the 42501 asserts would also trip. Fixture SA registration verified.
4. **No legitimate reader broken** — 0 references in app/index.html; only v55/v60 RPC consumers
   (SECURITY DEFINER, pinned search_path); no cron/trigger/view reads it.
5. **Registration** — appended cleanly (executable `…000142`, pending `20260725050000`), all manifest
   checks rc=0, full test suite **461/461** at the frozen SHA.
6. **"Previously red" claim honest** — at the parent commit the writer-registry test fails 2 and the
   v21 allowlist test fails 1 (exactly the Till-UI surfaces); at the freeze both are green. The freeze
   fixed real breakage. Curation itself audited: mint RPC correctly a writer; the two allowlisted
   read RPCs contain zero DML; the v21 fix reads actual grants from the migration file (no over-grant).
7. **Prod (read-only)** — `v_program_rules_all` still definer-state in prod; no `20260725050000`
   ledger row; `v_business_billing` correctly `security_invoker=true` (v66a). Nothing applied.

## Defects
- **INFO (doc-only, corrected here):** the migration header names `get_program_rules_draft` as a view
  consumer; in fact neither its v55 nor v60 body reads the view — only `get_programs_overview` does.
  Error is in the safe direction (over-claims unaffected consumers); no security property misstated.
  The header is frozen with the artifact; this verdict is the correction of record.
- No CRITICAL/HIGH/MEDIUM/LOW defects.

## Release state
Apply is deliberately **HELD**: v66b is platform hardening outside the RELEASE-APPROVED pilot scope
and closes no active leak, so the exact-phrase release gate applies. Until applied, the advisor ERROR
condition persists in prod by design. On the owner's exact phrase: apply `20260725050000`, verify
reloption + advisor 0 ERROR, normalize the ledger version, reconcile main.

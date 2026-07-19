# Production Launch Runbook

This runbook is the release order after the database transfer to `gadpooereceldfpfxsod` is complete. It is intentionally stricter than a code review: source files can demonstrate implementation, but launch closure requires redacted, hash-pinned staging and production evidence.

Run the offline gate from the repository root at every hold point:

```bash
node scripts/launch-readiness/check.mjs
node scripts/launch-readiness/check.mjs --json
```

The initial manifest is expected to fail. It lists the P0 proof that is still required. Do not edit a blocker to `VERIFIED_PRODUCTION` until its evidence artifact exists and has been independently reviewed.

## Evidence Rule

Store evidence under `docs/launch/.evidence/<run-id>/`; it is ignored locally and must not be committed. Each evidence artifact is JSON with this shape:

```json
{
  "kind": "launch_readiness_evidence_v1",
  "blockerId": "P0-CUTOVER-PARITY-001",
  "stage": "PRODUCTION",
  "targetRef": "gadpooereceldfpfxsod",
  "capturedAt": "2026-07-19T12:00:00Z",
  "result": "PASS",
  "checks": {
    "strictComparatorZeroFindings": true
  },
  "summary": "Redacted comparator and configuration parity checks passed."
}
```

Use only role labels, project references, release commits, test identifiers, counts, timings, and redacted outcomes. Do not place customer data, contact details, full URLs, database credentials, API keys, cookies, auth tokens, booking tokens, raw requests, or provider payloads in evidence. Hash the exact file with `shasum -a 256 <evidence-file>` and add the relative path and hash to the matching `evidence` array in `launch-blockers.json`.

`IMPLEMENTED` means a reviewed artifact exists. `VERIFIED_STAGING` means a staging test passed. Neither closes a P0. Only `VERIFIED_PRODUCTION` plus valid production evidence closes a P0.

## Post-Transfer Sequence

1. **Freeze and confirm migration completion.** Stop source writes, record the maintenance-window owner, and do not point the app at the target. Keep the source project available but read-only once the final restore begins.

2. **Prove source-to-target parity.** Use the strict verifier in `docs/supabase-sync/VERIFICATION_GATE.md` against the frozen source and final target. Confirm schema, migrations, data counts, tenant aggregates, ledger/liability totals, Auth users, Storage bytes, cron definitions, Realtime, policies, grants, functions, extensions, and configuration. The old and new projects matching the same weakness is not a pass.

3. **Apply repository migrations in canonical order.** First apply and test on rehearsal, then apply the approved `db/migrations` sequence to the final target: v18 -> v19 -> v20 -> v21. `supabase/functions` is only for Edge Function deployment; it is not a migration source. Re-run schema and data parity after each logically coupled migration group. Do not use a migration filename or successful SQL execution as closure; retain the post-apply catalog and behavior evidence.

4. **Deploy Edge Functions and public gateways.** Deploy only the reviewed public join, booking, and booking-management functions. Configure strict allowed origins, secret handling, privacy-preserving rate limits, idempotency, and redacted logs. Test direct anonymous RPC and PostgREST calls fail where a gateway is required.

5. **Close public access controls.** Revoke or make unreachable the phone-only `list_my_appointments` and `request_change` public RPC paths. Booking management must require an expiring, scoped opaque token; only its hash may be stored. Test missing, expired, replayed, cross-booking, and phone-only requests as failures.

6. **Run security and performance advisors.** Review Supabase database and API advisors after the final migration set. Run `db/tests/v21_security_hardening.sql` on rehearsal and retain its redacted result: it checks anonymous/PUBLIC SECURITY DEFINER execution, the v19 service-only allowlist, RLS helper grants, search paths, direct intake privileges, and always-true write policies. Resolve or document every warning related to RLS, permissive policies, security-definer search paths, public function execute grants, indexes, connection behavior, and network exposure. Then run real-principal, rolled-back adversarial tenant tests; a service-role test does not prove RLS.

7. **Verify financial integrity.** Run the production-safe rollback suite for sale reversal, full refund, partial-refund rejection, duplicate submission, over-refund denial, store-credit tender, payment linkage, cash effects, stock, points, referral, retention, commission, reporting, audit history, and role restrictions. Unsupported partial or value-redemption paths must reject explicitly and remain hidden from the UI.

8. **Verify reports and time.** Confirm reports and exports page past API defaults, reconcile to the sales and ledger snapshot, and test SGT day and month boundaries from Singapore and non-Singapore browser zones. Validate scheduled jobs and reminders in SGT. Record the present Singapore-only behavior and the per-business-timezone expansion decision.

9. **Set Auth and providers.** Configure production site URL and redirect allowlist, email confirmation, password rules, leaked-password protection, CAPTCHA or equivalent anti-automation, SMTP, OAuth only where intended, and session behavior. Use synthetic accounts to test sign-up, confirmation, sign-in, recovery, expiry, and rate limiting. Configure the notification provider or remove every promise of an outbound notification; test transactional delivery, failure, retry, unsubscribe, and consent separation.

10. **Set commercial reality.** Verify what the product actually collects: online provider lifecycle and webhook verification, or an explicitly manual invoice/access process. Do not market automated payments, subscriptions, refunds, tax handling, or invoicing that does not exist. Reconcile one synthetic commercial lifecycle end to end.

11. **Publish PDPA and operating controls.** Publish privacy, terms, and data-request pages. Rehearse access, correction, withdrawal, retention, deletion decisions, and incident triage using synthetic data. Confirm no privacy contact or certification claim is unsupported. Keep marketing consent opt-in and separately test withdrawal.

12. **Prepare recovery and observability.** Confirm target backups, PITR, restore owner, retention, and isolated restore rehearsal. Identify migration, Edge Function, and Vercel rollback artifacts. Configure release-correlated error capture and alerting for client, function, Auth, database, abuse-limit, notification, and scheduled-job failures with PII redaction. Once target writes start, never point traffic back to source without reconciling target writes.

13. **Rotate and remove development access.** Remove or isolate test accounts from merchant reporting. Rotate every credential shared in development, migration, or testing, including database passwords, provider keys, and any known test login. Recheck least-privilege operator access after rotation.

14. **Cut over URL, key, and CSP last.** Set the deployed app to the target URL and publishable key only after all earlier production evidence passes. Serve one canonical production URL. Inspect served HTML and headers to prove the old Supabase project reference has gone and CSP only permits required target and CDN origins. Do not put service-role credentials in static files or Vercel client variables.

15. **Final smoke, monitor, then declare launch.** With synthetic accounts, test owner and staff sign-in, onboarding, customer join, booking, tokenized booking management, sale, loyalty, credit, referral, reports, exports, authorization denials, password recovery, and notification behavior. Review the first monitoring window, keep source read-only, and rerun the gate. Launch is allowed only when it prints `Launch gate: PASS`.

## Required P0 Coverage

The manifest has stable blockers for cutover parity, public RPC abuse resistance, tokenized booking management, RLS and function grants, financial reversal and store credit, reporting scale, PDPA operations, Auth and SMTP, notifications, commercial reality, backups and rollback, observability, SGT time handling, target runtime URL/key/CSP, credential rotation, and the post-cutover smoke window.

The existing cutover comparator remains the source of truth for database parity. This gate consumes its redacted output as evidence but does not replace it, call a network API, deploy, or write to Supabase.

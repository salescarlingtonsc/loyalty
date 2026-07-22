# P0-POST-CUTOVER-SMOKE-016 — End-to-end SME workflows and first monitoring window

## 1. Classification

**OWNER-ACTION-SCRIPTED.** This is the last gate by design — `docs/launch/POST_CLAUDE_RUNBOOK.md` step
15 places it after every other gate, and `launch-blockers.json`'s own dependency shape (every other P0
feeds into this one) means it cannot be evidenced early. See `INDEX.md` for the critical path.

## 2. Preconditions

- Every other P0 gate `VERIFIED_PRODUCTION` first (this is the explicit ordering in
  `POST_CLAUDE_RUNBOOK.md`: "Launch is allowed only when it prints `Launch gate: PASS`" — i.e. this gate
  is evidenced *after* the other 16 are already true, and its own re-run of the gate checker is part of
  its evidence).
- The frozen commit from `P0-TARGET-RUNTIME-014` / `P0-RELEASE-BUILD-017` deployed and cut over.
- Synthetic accounts and businesses (not the removed/rotated test accounts from
  `P0-TEST-CREDENTIALS-015` — fresh, clearly labeled synthetic ones for this drill).

## 3. Procedure

1. After URL/key/CSP cutover is complete (per `P0-TARGET-RUNTIME-014`), run the full smoke matrix with
   synthetic data against the live deployed app: owner sign-in, staff sign-in, onboarding, customer join,
   booking, tokenized booking management, sale, loyalty earn/redeem, credit, referral, reports, exports,
   at least one authorization-denial case (wrong role attempts a privileged action), password recovery,
   and notification behavior (per whatever `P0-NOTIFICATIONS-009` decided).
2. Keep the retired source project (`kyzovonwnscrzmkvocid`) read-only throughout — do not write to it
   once target traffic has begun.
3. Monitor the first production traffic window (a specific duration the owner should set — e.g. 24-72
   hours) using the alerting configured under `P0-OBSERVABILITY-012`; confirm no unexplained Vercel,
   Edge Function, Auth, database, or notification error trend appears.
4. Re-run the offline gate checker itself as part of this evidence:
   ```bash
   node scripts/launch-readiness/check.mjs --json
   ```
   This should print `"ok": true` only once every other blocker's evidence is registered in
   `launch-blockers.json` — confirm that state, don't just assert it.
5. Confirm rollback readiness remains intact (per `docs/launch/ROLLBACK_RUNBOOK.md`) and that the
   source is genuinely not writable post-cutover (an actual negative test: attempt a write against the
   source and confirm it is rejected or that write access has been revoked).

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-POST-CUTOVER-SMOKE-016.json`
- Example `checks`: `{"fullSmokeMatrixPassed": true, "authorizationDenialCaseVerified": true,
  "sourceRemainsReadOnly": true, "monitoringWindowClean": true, "gateCheckerPrintsOk": true,
  "rollbackReadinessConfirmed": true}`
- This is the one artifact that can legitimately reference the overall gate result; still no customer
  data, tokens, or URLs — role labels, pass/fail, and the monitoring window duration only.
- Hash-pin and register per `INDEX.md`. Once this is registered and `VERIFIED_PRODUCTION`, `node
  scripts/launch-readiness/check.mjs` should print `Launch gate: PASS` for the first time.

## 5. Estimated wall-clock time

Smoke matrix itself: 1-2 hours. Monitoring window: however long the owner sets (a calendar-time wait,
not effort-time) before this artifact can honestly be captured.

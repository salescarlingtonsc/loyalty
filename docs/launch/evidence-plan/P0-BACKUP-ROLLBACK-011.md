# P0-BACKUP-ROLLBACK-011 — Backups, PITR, migration rollback, post-cutover rollback

## 1. Classification

**OWNER-ACTION-SCRIPTED.** `docs/launch/ROLLBACK_RUNBOOK.md` already exists, names the exact restore
points, the no-split-brain rule, per-migration-generation rollback guidance (though it still references
the pre-v41 migration numbering — see the discrepancy note in `INDEX.md`), and ends with three explicit
"Owner actions to close P0-BACKUP-ROLLBACK-011" — this plan does not need to invent a new procedure, it
needs those three owner actions actually performed and evidenced.

## 2. Preconditions

- Supabase Dashboard access to `gadpooereceldfpfxsod` → Project → Database → Backups (this agent's
  read-only Supabase MCP tools do not expose PITR/backup configuration).
- Willingness to create one disposable Supabase branch for the restore rehearsal (a write action for
  whoever performs it — not this agent).

## 3. Procedure

1. **Owner action 1** (from `ROLLBACK_RUNBOOK.md`): confirm PITR + retention window on
   `gadpooereceldfpfxsod` in the Dashboard; record the retention window and the named restore owner.
2. **Owner action 2:** rehearse a restore on an isolated Supabase branch — restore to a recent point,
   confirm the branch comes up with expected data, then discard the branch.
3. **Owner action 3:** record `ROLLBACK_RUNBOOK.md`'s decision path (the no-split-brain rule, the
   per-migration-generation guidance, the Edge Function `supabase functions delete` commands, and the
   "frontend has not been cut over" note) as the formally approved rollback plan — update the runbook's
   migration-range references from "v18 → v21" to the current v1-v49b canonical range if this hasn't
   been done since the manifest grew (see `INDEX.md` discrepancy list).
4. Confirm the Edge Function rollback commands in the runbook (`supabase functions delete public-join
   --project-ref gadpooereceldfpfxsod`, etc.) are still accurate against the currently deployed function
   set (`public-join`, `public-booking`, `manage-booking`, all confirmed `ACTIVE` today).

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-BACKUP-ROLLBACK-011.json`
- Example `checks`: `{"pitrConfirmed": true, "retentionWindowRecorded": true,
  "restoreOwnerNamed": true, "isolatedRestoreRehearsalPassed": true, "rollbackPlanApproved": true,
  "edgeFunctionRollbackCommandsVerifiedCurrent": true}`
- No backup file contents or restore-branch connection strings in the artifact — retention window
  (e.g. "7 days"), a role label for the restore owner, and pass/fail only.
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

45-90 minutes, mostly the Dashboard restore rehearsal.

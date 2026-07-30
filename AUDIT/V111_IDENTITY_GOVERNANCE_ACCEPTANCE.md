# v111 Customer Identity Governance — acceptance contract

v111 closes the missing proposal/proof/decision/reversal workflow behind the
customer lifecycle and revenue-attribution reports. It is a local-only forward
migration and test slice. It must not modify v106–v110 or production.

## Authority and scope

- Every proposal belongs to exactly one `business_id` and optionally one
  `branch_id`.
- Candidate/source/target identities must belong to that same business.
- Cross-business identities and evidence fail closed.
- Branch-scoped staff may propose only within a branch they can see.
- Only owner/global business authority may approve, reject or reverse.
- No identity is merged automatically.

## Durable records

- A proposal records the source identity, proposed target identity, reason,
  current status, proposer and timestamps.
- Proof/evidence is immutable and records a server-validated proof kind,
  evidence subject and metadata. Ambiguous evidence or evidence matching more
  than one candidate cannot authorize approval.
- Decision and reversal history is append-only. Source records are never
  erased.
- Approval records the exact before/after attribution changed by the decision.
- Reversal restores the exact prior attribution and appends a reversal event;
  it does not delete or rewrite the approval.
- A durable request ledger binds every mutation to a UUID idempotency key and a
  canonical request hash.

## Required RPC surface

Implement stable, explicitly granted RPCs for:

1. propose identity correction/link;
2. attach or record validated proof;
3. approve;
4. reject;
5. reverse an approved decision;
6. read proposal status and full append-only history.

Every mutation must satisfy:

- same idempotency key + same canonical payload returns the exact original
  receipt;
- same idempotency key + changed payload conflicts;
- concurrent/double approval, rejection or reversal converges safely and never
  applies attribution twice.
- every writer that creates or transitions a `customer_links` row to
  `verified` takes the exact same per-business/per-client advisory transaction
  lock as proposal/approval, then fails if that client is the source of an
  active attribution correction;
- a true two-session harness exercises both lock orderings: approval commits
  first and the later verified-link writer fails, or the verified link commits
  first and approval fails its source-link recheck.

## Required evidence

Create paired, byte-identical `db/migrations` and `supabase/migrations` files,
a rollback-only realistic SQL test and a static Node contract test. The SQL test
must cover:

- proposal → proof → approval;
- exact replay and changed-payload conflict for every mutation;
- rejection;
- reversal restoring the exact prior attribution;
- cross-business denial;
- ambiguous/multiple-candidate proof denial;
- branch denial;
- unauthorized approval/rejection/reversal;
- concurrent or repeated terminal operations;
- concurrent verified-link creation racing approval in both commit orderings;
- append-only history and source-record preservation.

No commit, push, deployment, production migration, production data mutation or
secret change is authorized.

## Independent-review regressions required

Sol's first bounded review additionally requires these exact cases before slice
acceptance:

- `firm_invitation` approval rechecks that the source is still unlinked after
  proof (verified-link TOCTOU denial);
- a source already used as another correction's effective target cannot start a
  one-hop chain or cycle (`A → B`, unlink `B`, then attempt `B → C`);
- disabled target identities are denied at proposal and approval;
- unauthorized approve, reject and reverse are all exercised;
- composite foreign keys bind proposal/business across proof, decision and
  attribution-event records, and bind referenced proof/prior-decision/decision
  to the same proposal/business;
- v106 revenue and v107 lifecycle consumers resolve the same current canonical
  attribution so an approved correction changes synchronized reporting, and a
  reversal restores the prior reporting attribution.

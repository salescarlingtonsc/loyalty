# Canonical migration order

Status: exact catalog-statement recovery and local materialization are complete through v40. Those
20 forward migrations passed a rollback-only PostgreSQL 17 rehearsal and were then atomically
applied to the owner-authorized disposable development/test project. v41 is an additional local-only
pending migration and has not been applied remotely. This is not production or release approval.

`supabase/canonical-migration-order.plan.json` is the sole proposed deploy order. It preserves the
45 trusted catalog versions and names exactly as they were applied to project
`gadpooereceldfpfxsod`, including the non-semantic placement of v13 after v21. It then assigns 21
new, unique versions (`20260721000001` through `20260721000020`, then the CLI-created
`20260721074441`) to the pending v24a-v41 files.
This removes every same-prefix collision without renaming or modifying the source SQL.

## Exact recovery result

All 45 applied migration rows were recovered from the owner-authorized disposable project's
`supabase_migrations.schema_migrations` catalog. The recovery manifest preserves 81 exact statement
records, including all 37 statements in `remote_schema`. This includes the locally absent histories:

- v3-v7;
- v11c;
- v14a-v14d; and
- v15a-v15d.

No historical SQL was reconstructed from note files. For 44 single-statement catalog rows, the
canonical SQL target is the exact statement byte sequence. `remote_schema` is classified as exact
catalog statements plus a deterministic executable reconstruction; its original multi-statement
migration-file separators and trailing bytes remain unavailable.

In addition, the canonical gate requires catalog hash evidence for **all 45** applied migrations.
This is mandatory because locally edited historical files (notably v19 and v21) cannot be trusted as
the bytes that were applied. The materializer validates every catalog record, even when a matching
source SQL file exists. This exposes local/catalog drift instead of silently blessing it.

## Catalog recovery contract

Authoritative SQL is stored as:

`supabase/migrations/<catalog-version>_<catalog-name>.sql`

`supabase/migrations/catalog-recovery.manifest.json` has this strict shape:

```json
{
  "schemaVersion": 1,
  "projectRef": "gadpooereceldfpfxsod",
  "hashAlgorithm": "sha256-raw-bytes",
  "migrations": [
    {
      "version": "20260718175514",
      "name": "frenly_v3_engine",
      "statementCount": 1,
      "statements": [
        {
          "index": 1,
          "octetLength": 123,
          "sha256": "<64 lowercase hex characters>",
          "base64": "<canonical unwrapped base64 of exact statement bytes>"
        }
      ],
      "canonicalization": "exact-statement-bytes",
      "canonicalOctetLength": 123,
      "canonicalSha256": "<64 lowercase hex characters>",
      "path": "supabase/migrations/20260718175514_frenly_v3_engine.sql"
    }
  ]
}
```

Every catalog array member is preserved separately as canonical, unwrapped base64 with its one-based
index, raw octet length, and SHA-256. For a one-statement migration, the executable SQL file is the
exact decoded statement bytes with no formatting, normalization, repair, or added newline.

The catalog's `remote_schema` migration is different: it contains 37 statements. Its executable file
is a deterministic reconstruction, not a raw migration-file claim. Decode the exact statement bytes,
join adjacent statements with `;\n\n`, then append `;\n` after the final statement. Record
`join-statements-with-semicolon-blank-line-and-final-semicolon-newline-v1`, plus the reconstructed
file's independent octet length and SHA-256. The verifier recomputes both the per-statement evidence
and this canonical file before accepting it.

Two tracked local targets were each one final LF shorter than their recovered single-statement
catalog evidence. Materialization deliberately restores those exact catalog bytes: v23g is 17,675
bytes with SHA-256 `c409f20f1bee94b1708da6fb08314785658a43934a0db5859aa464afc8428194`, and v24 is
12,748 bytes with SHA-256 `00674aa8d7b249229fefd7aaede1c471aba74d6b35dbe8be749bbaf17da8a909`.
This is evidence-backed recovery of prior one-byte local drift, not a semantic history rewrite.

## Local materialization and verification

The safe sequence is:

```sh
npm run canonical-migrations:plan:check
npm run canonical-migrations:materialize
npm run canonical-migrations:check
```

The materializer writes every catalog-applied target from verified catalog evidence, even when a
same-named local historical source exists. This deliberately prevents local legacy drift from being
promoted into deployed history. Pending v24a-v41 targets are copied byte-for-byte from their source
migrations. It emits
`supabase/canonical-migration-order.manifest.json` and a companion SHA-256 only after all 66 SQL files
exist, required evidence matches, no unplanned SQL exists, and every pending target equals its source.

The generated status `canonical_deployable_locally_not_applied` means only that the local artifact is
complete and deterministic. It is not approval to apply migrations, reset a database, deploy, commit,
or push. Database rehearsal and release remain separate owner/Sol gates.

## Remaining acceptance gates

1. Retain the 66-row local canonical history/hash while keeping the separately proven v24a-v40
   runtime evidence recorded in `V24A_V40_PERSISTENT_APPLICATION.md` distinct from unrun v41.
2. Obtain Sol's final read-only verdict on the installed disposable-database state.
3. Run the two-session v37/v40 concurrency harnesses only when a direct PostgreSQL connection is
   available; the managed connector serializes calls and cannot prove concurrency.
4. Keep all repository work local; commit, push, deploy, merge and production actions remain
   prohibited.

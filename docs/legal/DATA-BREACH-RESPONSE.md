# Data breach response runbook — Peekaa (NESTLY TECHNOLOGIES PTE. LTD.)

Purpose: a short, followable sequence for any suspected personal-data breach
(customer or business side). PDPA Part 6A makes assessment and notification a
statutory duty; following and documenting this sequence is a major part of the
company's defence in any claim or PDPC investigation.

## The clock

- **Assess without unreasonable delay** once a suspected breach is known
  (PDPC's benchmark: within 30 days is generally reasonable; sooner is better).
- If the breach is **notifiable**, notify **PDPC within 3 calendar days** of
  making that assessment, and notify affected individuals without unreasonable
  delay unless an exception applies (e.g. remedial action making significant
  harm unlikely, or law-enforcement instruction).
- A breach is notifiable if it (a) results in, or is likely to result in,
  **significant harm** to individuals (prescribed categories include full
  identifiers with financial data, credentials/passwords, health data), or
  (b) affects **500 or more** individuals.

## Sequence

1. **Contain.** Revoke or rotate the credential/key involved; disable the
   affected RPC, edge function, storage bucket policy or feature flag; if
   tenant-scoped, pause the tenant. Do not delete evidence — the ledgers and
   audit tables are append-only by design; leave them intact.
2. **Preserve.** Snapshot relevant logs (Supabase auth/API logs, Vercel and
   Cloudflare logs), affected row ids and time bounds. Record UTC timestamps
   for discovery and each action taken.
3. **Assess.** Who is affected (customers, staff, businesses), which fields,
   how many people, whether data left the system, and whether either
   notifiability limb is met. Write the conclusion down even if the answer is
   "not notifiable" — the documented assessment is itself the compliance
   artefact.
4. **Notify (if notifiable).** PDPC via the online breach-notification form
   within 3 days; affected individuals with plain-language description,
   what was involved, what has been done, and what they should do. Where the
   data belongs to a merchant's customers, notify the merchant immediately —
   under the platform's role split the merchant may hold its own notification
   duties, and Peekaa's contract role is to support them.
5. **Remediate and record.** Root-cause fix, a dated entry in
   `docs/qa/OWNER-ISSUE-LEDGER.md`, and — where the fix is code — a test that
   locks the fix in.

## Standing posture (what makes step 1 fast)

- RLS on every table; append-only credit/points/consent evidence; write
  guards on sensitive tables; SG-hosted primary database.
- Secrets live only in Supabase/Vercel configuration, never in the repo.
- Vendor list for breach coordination: Supabase (database/auth/storage),
  Vercel (hosting), Cloudflare (proxy/Turnstile). Keep their status pages and
  support channels bookmarked.
- The platform feature flags (`app.platform_feature_flags`) and per-business
  capability rows are the fastest kill switches for customer-facing surfaces.

## Insurance

Contractual caps and this runbook reduce exposure; they do not eliminate it.
Cyber liability insurance is the instrument that answers residual risk —
owner action item, not an engineering one.

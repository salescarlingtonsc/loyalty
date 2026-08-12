# V282 communications foundation — runbook

Four things the product already promised and could not keep: web push with no
scheduler and no key, a parked bottle that expired in silence, consent evidence
nobody could read, and a partner-sharing promise with no ledger behind it.

Migration: `db/migrations/20260812_nestly_v282_comms_foundation.sql`
(deploy version `20260812000100`). Rolled-back acceptance:
`db/tests/v282_comms_foundation.sql`. Client acceptance:
`tests/customer-modules/v282-comms-foundation.test.mjs`.

## Owner checklist — what must be supplied before push actually sends

Everything below is a secret. None of it is in the repository and none of it
can be.

### 1. VAPID key pair

The public half is already shipped: `config/runtime/production.json` →
`webPushPublicKey`, regenerated into `app/runtime-config.js`. It is a public
value by design — the browser sends it to the push service on subscribe.

The private half must be set as an Edge Function secret and nowhere else:

| Secret | Where | Value |
| --- | --- | --- |
| `CUSTOMER_PUSH_VAPID_PUBLIC_KEY` | Edge Function secrets | must equal `webPushPublicKey` in `config/runtime/production.json` |
| `CUSTOMER_PUSH_VAPID_PRIVATE_KEY` | Edge Function secrets | the 43-character private half of the same pair |
| `CUSTOMER_PUSH_VAPID_SUBJECT` | Edge Function secrets | `mailto:` address the push services can reach, e.g. `mailto:support@peekaa.asia` |

The three are read by `supabase/functions/customer-push-dispatch/index.ts` via
`requiredPushEnv`. A missing one makes the dispatcher return
`push_dispatcher_unavailable` rather than sending anything.

**The two halves must be from the same key pair.** If they are not, every push
is rejected by the push service with a 403 and recorded as a permanent failure.
Regenerating the pair invalidates every existing browser subscription: each
customer must turn device notifications off and on again. Do it once, now,
rather than later.

### 2. Dispatcher authentication

| Secret | Where | Must equal |
| --- | --- | --- |
| `CUSTOMER_PUSH_DISPATCH_SECRET` | Edge Function secrets | at least 32 characters; compared in constant time |
| `v282_push_dispatch_secret` | Supabase Vault | the same value as `CUSTOMER_PUSH_DISPATCH_SECRET` |
| `v282_supabase_url` | Supabase Vault | project URL, e.g. `https://gadpooereceldfpfxsod.supabase.co` — falls back to the existing `v156_supabase_url` if absent |

The database calls the function with header
`x-nestly-push-dispatch-secret`. If the Vault value and the function secret
disagree the tick returns 401 while everything looks healthy, so change both in
the same sitting.

`app.v282_run_customer_push_dispatch()` never raises when a precondition is
missing. It returns a named reason instead — `extensions_unavailable`,
`vault_unavailable`, `secret_unconfigured` — so an unconfigured deployment is
diagnosable from `cron.job_run_details` rather than appearing as a bare failure.

### 3. Schedules created by the migration

| Job | Cadence | What it does |
| --- | --- | --- |
| `nestly-v282-customer-push-dispatch` | every 5 minutes | POSTs the dispatcher; the claim RPC enqueues and leases in one call |
| `nestly-v282-bottle-expiry-daily` | `10 16 * * *` UTC = 00:10 SGT | expires lapsed in-storage bottles and enqueues expiry reminders |

The dispatcher tick is deliberately unconditional. The claim RPC both enqueues
new deliveries and leases them, so "is anything pending?" cannot be answered
from the deliveries table alone — a fresh inbox event has no delivery row yet.
A pending-check reading only deliveries would silently never fire for the first
event of a quiet period, which is the exact failure this work exists to end.

## What runs without any owner action

- The bottle expiry sweep and in-app reminders. They need no secret: the
  reminder lands in the customer's in-app inbox, which the wallet already
  renders. Push is the extra channel, not the mechanism.
- Consent history in the customer profile.
- The partner obligations console section under `#/platform/partners`.

## Reminder window

One number per business, `public.bar_bottle_settings.expiry_reminder_days`,
default 7, range 1–90. Owners set it in **Bottle keep → Keep window**; it saves
through `bar_save_expiry_reminder_days_v282` and reads back through
`bar_get_bottle_setup_v278`.

## Partner obligations — what this is and is not

`partner_registry_v282`, `partner_disclosures_v282` and
`partner_suppressions_v282` are the evidence layer behind the consent wording
pinned by v265 (`2026-08-10-partner-sharing-v3`), which tells a customer that
selected partners may receive their contact details.

**No data distribution exists.** Nothing in this migration writes a disclosure
automatically, and the console cannot cause one. The disclosure ledger is
expected to be empty until something actually distributes something, and that
emptiness is itself the honest answer to "what have you shared?".

A suppression row is an *instruction issued*, evidenced by `issued_at`. A null
`acknowledged_at` means the partner has not confirmed it — a fact worth being
able to see, not a gap to paper over. The acknowledgement can be recorded once
and nothing else about the row can ever move.

All three tables are RPC-only: RLS on, zero policies, ACL revoked from every
browser role, and every RPC holds `app.is_super_admin()`. A business owner is
refused with 42501 on all four.

⚖️ This records obligations. It does not assert that any particular consent
wording, retention period, or downstream partner contract is sufficient — that
remains a matter for counsel.

# Live reward_grants and sibling-policy audit

Read-only capture from Supabase project `gadpooereceldfpfxsod`, 2026-08-29.

## `public.reward_grants` column/mutability matrix

The live table has 20 columns. `trg_z_reward_grant_snapshot_guard` rejects UPDATE changes to every column below except `status`.

| Column | Type | Insert trigger behavior | UPDATE behavior | Current direct role exposure |
|---|---|---|---|---|
| `id` | uuid | generated | immutable | authenticated table privilege exists; RLS/policy blocks direct UPDATE except existing row scope |
| `business_id` | uuid | FK and snapshot checks | immutable | same |
| `program_id` | uuid | provenance snapshot | immutable | same |
| `client_id` | uuid | FK and snapshot checks | immutable | same |
| `period_index` | integer | period validation | immutable | same |
| `reward_type` | text | derived from rule | immutable | same |
| `reward_value` | numeric | derived from rule | immutable | same |
| `reward_item` | text | derived from rule | immutable | same |
| `status` | text | default `granted`; check is granted/redeemed/expired | **freely mutable by an active member through `grants_update`** | authenticated UPDATE privilege + member-wide UPDATE policy |
| `granted_at` | timestamptz | default now | immutable | same |
| `config_version_id` | uuid | stamped/validated | immutable | same |
| `reward_snapshot` | jsonb | required and populated | immutable | same |
| `reward_taxonomy_id` | uuid | derived and composite FK | immutable | same |
| `reward_label` | text | derived | immutable | same |
| `fulfillment_kind` | text | derived/check | immutable | same |
| `retention_program_version_id` | uuid | derived/composite FK | immutable | same |
| `period_start` | timestamptz | derived/validated | immutable | same |
| `period_end` | timestamptz | derived/validated | immutable | same |
| `campaign_id` | uuid | campaign validation/composite FK | immutable | same |
| `campaign_assignment` | text | treatment-only campaign shape | immutable | same |

Live policies:

```text
grants_select SELECT authenticated USING app.is_salon_member(business_id)
grants_update UPDATE authenticated USING app.is_salon_member(business_id) WITH CHECK NULL
reward_grants_sa_read SELECT authenticated USING app.is_super_admin()
```

Live table privileges include INSERT/UPDATE/DELETE/SELECT for `authenticated`; RLS denies direct INSERT and DELETE because there are no corresponding policies. The UPDATE policy plus the snapshot trigger leaves `status` as the effective mutable field. There is no UPDATE audit trigger.

## Live reward-grant writers

| Path | Writer | Evidence/result |
|---|---|---|
| SQL function | `public.issue_campaign_offer(uuid,uuid,uuid,text,bigint,uuid)` | Only current direct INSERT writer found by normalized `pg_get_functiondef` scan. `SECURITY DEFINER`; checks authenticated actor, owner, retention module write permission, idempotency, campaign/business/client scope. |
| SQL trigger | `trg_reward_grants_config_version` → `app.stamp_config_version()` | Mutates the incoming NEW row on INSERT; does not update another reward row. |
| SQL trigger | `trg_snapshot_reward_grant_taxonomy` → `app.snapshot_reward_grant_taxonomy()` | Mutates the incoming NEW row on INSERT; derives immutable reward/provenance fields. |
| SQL trigger | `trg_z_reward_grant_snapshot_guard` → `app.reward_grant_snapshot_guard()` | Guards UPDATE identity/economics/provenance/window fields; omits `status`. |
| SQL trigger | `trg_audit_grants` → `app.audit()` | INSERT-only audit row in `audit_log`; does not audit UPDATE status changes. |
| SQL trigger | `trg_reward_grant_signal_v494` → `app.bump_customer_wallet_signal_v479()` | INSERT-only wallet signal upsert. |
| Cron | All 35 live cron commands | No cron command directly writes `reward_grants`; the v361 job writes `bringback_grants_v361`, not this table. |
| Edge Functions | Repository/live function scan | No direct `reward_grants` writer found. |
| Browser app | `app/app.js`, `app/app-business.js`, `app/app-customer.js` | No direct table mutation found; references are explanatory text/read surfaces. |

## v590–v592 live object evidence

The exact function bodies and marker-table reconstruction are in `v590-v592-live-definitions.sql`. Live function definitions were retrieved with:

```sql
select p.oid::regprocedure, pg_get_functiondef(p.oid), p.proacl
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where p.prokind='f' and n.nspname='app'
  and p.proname in (
    'purge_cron_run_history_v590','v591_max_attempts',
    'support_ingest_status_v535','v551_ingest_retention_status',
    'v551_ingest_retention_optout','run_sv_tender_release',
    'support_tick_v592'
  );
```

`public.whatsapp_webhook_event_consumers` is RLS-enabled, has no policies or non-internal triggers, and has ACL only for `postgres` and `service_role`. Its primary key is `(event_id, consumer)` and its `event_id` foreign key cascades to `whatsapp_webhook_events(id)`.

## Sibling `is_salon_member(business_id)` mutation-policy scan

The following live policies matched a mutation command and the member predicate:

| Table | Policy | Command | Live predicate | Assessment |
|---|---|---|---|---|
| `appointment_services` | `appointment_services_delete_v572` | DELETE | appointment business member + appointments module write | Module-gated; retain negative tests. |
| `appointment_services` | `appointment_services_insert_v572` | INSERT | appointment business member + appointments module write | Module-gated. |
| `appointment_services` | `appointment_services_update_v572` | UPDATE | appointment business member + appointments module write | Module-gated with check. |
| `booking_requests` | `booking_requests_delete_v572` | DELETE | member + bookings module write | Module-gated; state-machine authorization still required. |
| `booking_requests` | `booking_requests_insert_v572` | INSERT | member + bookings module write | Module-gated; validate same-business service/branch. |
| `booking_requests` | `booking_requests_update_v572` | UPDATE | member + bookings module write | Module-gated; validate state transitions. |
| `change_requests` | `change_requests_update_v572` | UPDATE | member + bookings module write | Module-gated; RPC/state-machine authorization still required. |
| `notifications` | `notifications_update` | UPDATE | `app.is_salon_member(business_id)` | Review whether staff may update arbitrary notifications. |
| `resources` | `resources_all` | ALL | `app.is_salon_member(business_id)` | Review for missing module/role write restriction. |
| `reward_grants` | `grants_update` | UPDATE | `app.is_salon_member(business_id)` | **Confirmed HIGH: status is freely mutable by active member.** |
| `service_products` | `service_products_delete_v572` | DELETE | service business member + services module write | Module-gated; composite tenant proof still needed. |
| `service_products` | `service_products_insert_v572` | INSERT | service business member + services module write | Module-gated; composite tenant proof still needed. |
| `service_products` | `service_products_update_v572` | UPDATE | service business member + services module write | Module-gated with check. |
| `services` | `services_delete_v572` | DELETE | member + services module write | Module-gated; owner/catalog role intent should be tested. |
| `services` | `services_insert_v572` | INSERT | member + services module write | Module-gated. |
| `services` | `services_update_v572` | UPDATE | member + services module write | Module-gated. |
| `waitlist` | `waitlist_delete_v572` | DELETE | member + waitlist module write | Module-gated; same-business FK proof still needed. |
| `waitlist` | `waitlist_insert_v572` | INSERT | member + waitlist module write | Module-gated; same-business FK proof still needed. |
| `waitlist` | `waitlist_update_v572` | UPDATE | member + waitlist module write | Module-gated with check. |

Some v572 policies use role OID 0 (`PUBLIC`) rather than an explicit `TO authenticated` clause. The helper currently rejects anonymous users, but policy role normalization is recommended as defense in depth.

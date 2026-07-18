# v15 — booking capacity, holds, realtime notifications, intl phone, CSV import

Applied + verified 2026-07-18. Authoritative SQL lives in `supabase_migrations.schema_migrations`
(project `kyzovonwnscrzmkvocid`). Migrations, in order:

| # | name | scope |
|---|------|-------|
| a | `frenly_v15a_booking_capacity_schema` | booking_tables, notifications, columns, RLS, availability view, realtime |
| b | `frenly_v15b_booking_flows_notify_cron` | request_booking rewrite, notification triggers, expiry sweep + per-minute cron, RPCs |
| c | `frenly_v15c_convert_idempotency_guard` | double-conversion guard on convert_booking_request |
| d | `frenly_v15d_booking_consent` | marketing-consent on request_booking + propagate to client/consents |

Built by the Fable delegation workflow: **Opus** designed/built all DB logic and verified it
(33 + 20 rolled-back assertions); **Sonnet** built all UI in `app/index.html`; **Fable** pinned the
contract between them, independently re-verified the core engine, eyeballed the UI in-browser, and merged.

## Owner decisions driving this (2026-07-18)
1. **#6 phone** — portal accepts any country (picker, default +65 SG); the SG 8-digit number stays the
   loyalty key. Additive: `clients.phone_norm` unchanged (intl → NULL = no loyalty key, intended).
2. **#8 capacity** — POOL / inventory model, owner's words: firms define named table types
   (Small/Medium/Large or custom), each with a quantity; customer picks a type; it draws down until
   released. **Not time-slot/turn-time partitioned.**
3. **#8 overflow** — per-firm `booking_overflow` ('waitlist'|'reject').
4. **#10 sync** — CSV import now (`import_bookings`); live two-way sync scoped for later.
5. **#7 IA** — Loyalty/Retention/Referrals/Memberships/Gift cards nested under the Customers nav group;
   the Growth group is removed.

## Contract (what the UI is built against)

### New tables
- **`booking_tables`** (id, business_id, name, pax int null, quantity int, sort, active, created_at).
  RLS: members read, owners write, `booking_tables_sa_read`.
- **`notifications`** (id, business_id, kind, title, body, ref_table, ref_id, created_at, read_at).
  kind ∈ booking_new · booking_waitlisted · change_request · booking_expired · waitlist_ready.
  RLS: members SELECT + UPDATE(mark read); INSERT only via SECURITY DEFINER; `notifications_sa_read`.

### Changed tables
- **businesses** +`booking_overflow`('waitlist'|'reject' d.waitlist) +`booking_hold_minutes`(int d.15, 0=off)
  +`booking_auto_confirm`(bool d.true) +`notify_new_bookings`(bool d.true).
- **booking_requests** +`table_type_id` +`appointment_id` +`expires_at` +`marketing_consent`(bool d.false).
  status CHECK now: new · pending · confirmed · waitlisted · declined · expired · cancelled.
- **appointments** +`table_type_id`. **waitlist** +`booking_request_id` +`table_type_id`.

### View
- **`v_table_availability`** (business_id, table_type_id, name, pax, quantity, sort, held, available),
  `security_invoker`. held = live booking_requests(new,pending) + appointments(booked) on that type;
  available = greatest(quantity − held, 0).

### RPCs — anon + authenticated
- `request_booking(p_slug,p_name,p_email,p_phone,p_service,p_party,p_preferred,p_notes, p_table_type DEFAULT NULL, p_consent DEFAULT false)` → `{status,request_id,appointment_id?}`,
  status ∈ confirmed·pending·waitlisted·rejected. Auto-confirms when a chosen table has capacity;
  else applies overflow. Records consent (escalate-only) to the client + a `consents` row on convert.
- `get_booking_availability(p_slug)` → `[{table_type_id,name,pax,quantity,held,available}]`.
- `get_business_public(p_slug)` → prior keys **+** booking_overflow, booking_hold_minutes,
  booking_auto_confirm, uses_tables(bool), tables:[…availability…].
- `list_my_appointments` / `request_change` — now match SG numbers flexibly (booked as `+65…`,
  findable by the bare 8 digits) via `app.phone_match_key()`.

### RPCs — authenticated
- `convert_booking_request(p_request)` — member; draws down the table; idempotent (raises on re-convert).
- `set_booking_settings(p_business,p_hold_minutes,p_overflow,p_notify,p_auto_confirm DEFAULT NULL)` — OWNER; NULL keeps current.
- `get_notifications(p_business,p_limit DEFAULT 30)` → `{unread,items[]}` · `mark_notification_read(p_id)` · `mark_all_notifications_read(p_business)` — member.
- `import_bookings(p_business,p_rows jsonb)` → `{inserted,skipped,errors[]}` — OWNER; rows import as `new` for review.

### Realtime & cron
- `supabase_realtime` publishes **notifications, booking_requests, appointments** (REPLICA IDENTITY FULL).
- Cron `frenly-booking-expiry` runs `app.expire_stale_bookings()` every minute: pending/new-with-expiry
  past `expires_at` → 'expired', release held table, and if a waitlist exists raise a `waitlist_ready`
  notification so the firm knows to work it.

## Documented judgment calls
- **Pool model, NOT date-partitioned.** `available = quantity − live holds` globally; a hold releases on
  cancel/decline/expire/no_show/complete. ⚠️ If the owner later wants per-day availability ("how many
  tables free on Sat 20th"), a date dimension must be added. Flagged for owner confirmation.
- **State machine:** services-only booking → DB `new`, no hold (a salon won't lose an unreviewed request
  after 15 min). Table + capacity + auto_confirm=true → real appointment, `confirmed`, draws down.
  Table + capacity + auto_confirm=false → `pending` hold with expires_at; swept to `expired` + released.
  Capacity 0 → overflow.
- A 4th setting `booking_auto_confirm` was added (beyond the 3 the owner named) so the hold/timer path is
  actually reachable alongside auto-confirm.
- Intl phone stored raw on booking_requests.phone + clients.phone; phone_norm stays SG-only.

## Frontend (app/index.html, +459/−77 lines)
Bell in the top-right app bar (left of profile) with unread badge + frosted dropdown + "Pop-up alerts"
iOS toggle; one reused realtime channel per session with `killChannels()` cleanup; auto-refresh of the
bookings/appointments/waitlist page on relevant inserts. Refresh bug fixed
(`detectSessionInUrl:false` on the Supabase client + a try/catch error card in `route()`). Logo links to
dashboard. Portal: country-code picker (12 countries, SG default), marketing-consent checkbox, table-type
picker when `uses_tables`. Owner-only cards on Bookings: table CRUD + booking rules (overflow, hold
minutes, auto-confirm, notify) via set_booking_settings + live availability + CSV import.

## Open risks / flags (NOT fixed — for owner)
- ⚖️ `request_booking` + `get_booking_availability` are anon with NO rate limiting (junk-insert /
  capacity-probing vector; same class as the pre-existing `join_program`). Needs captcha/edge limit before scale.
- Availability is a live pool, not date-scoped (see judgment call). Confirm this matches intent.
- Live-sync to external reservation systems (Chope/SevenRooms/Oddle/Google) is scoped only. Options for
  later: per-provider inbound webhook edge function; scheduled pg_cron + pg_net pollers; email-parse intake.
- The `set_booking_settings` notify toggle is owner-gated; non-owner staff get an in-session mute only.
- Pre-existing, still open: `businesses.salons_insert WITH CHECK(true)`; leaked-password protection off.

Security advisor after v15: **0 ERROR**.

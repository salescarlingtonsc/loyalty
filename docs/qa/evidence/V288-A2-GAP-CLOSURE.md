# V288 — audit A2 gap closure (Appointments · Bookings · Waitlist · Bottles · Programmes)

Closes the A2 audit findings HIGH 1–6, MEDIUM 7, 8, 11, 12, 14, 15, 18, 19 and LOW 22, 23.
Client behaviour is pinned in `tests/business-ui/v288-a2-gap-closure.test.mjs`; the three server
truths are in `db/migrations/20260812_nestly_v288_a2_gap_closure.sql` with the rollback-only
acceptance in `db/tests/v288_a2_gap_closure.sql`.

## The beachhead blocker (HIGH 1) needed the server, not only the button

The audit read as a client-side gate: `canConvertBooking=canWriteModule('appointments')` in a
sector that has no appointments module. A read-only trace against production showed the gate is
also enforced twice server-side, and unconditionally:

- `public.staff_decide_booking_request_v73` (the v94 wrapper) — `require_branch_module_v94(…,'appointments','rw')` on confirm;
- `public.staff_decide_booking_request_v73_v94_base` — `app.can_module_write(p_business,'appointments')` on confirm.

`app.effective_platform_module_mode_v94` resolves a module the sector does not carry to
`'disabled'` (`p_module = any(business.enabled_modules)` … `else 'disabled'`), and
`app.staff_module_mode_v94` returns that platform mode verbatim for an **owner**. So for
`industry='fnb'` and `industry='bar'` the appointments requirement was unsatisfiable by anyone,
owner included: a cafe or bar could only ever DECLINE the requests its own public booking page
produced. Widening the button alone would have replaced a missing control with a 42501.

The migration therefore makes the appointments requirement conditional on the sector actually
having an appointments module, via `app.business_has_appointments_module_v288`. The bookings
boundary is required first and is untouched, and where the sector does carry appointments the
requirement still runs — including when the platform grants it read-only, which must still
refuse. This is an authorisation change and is left **unapplied** for owner sign-off.

## Production reads performed (SELECT only, MCP `5cc852de-*`)

`pg_get_functiondef` / `information_schema` reads of `app.can_module_write`,
`app.can_module_write_at_v94`, `app.staff_module_mode_v94`,
`app.effective_platform_module_mode_v94`, `staff_decide_booking_request_v73`,
`staff_decide_booking_request_v73_v94_base`, `app.bar_status_transition_allowed_v279`,
`public.bar_save_bottle_product_v278`, `public.booking_requests` columns and the
`bar_bottles` check constraints. No writes.

Two findings came out of those reads and shaped the migration:

1. `extend_bottle_v275` and `set_bottle_expiry_v278` ALREADY revive an `expired` bottle to
   `stored`. The audit's expired→stored gap was purely that the client drew no controls, so no
   transition-matrix change was needed and `app.bar_status_transition_allowed_v279` is untouched
   — retrieved stays a one-way door.
2. `bar_save_bottle_product_v278` accepts `p_name` and `p_price_cents` but its UPDATE branch
   writes only `size_ml`. A mistyped catalogue row was uncorrectable. `bar_save_bottle_product_v288`
   applies all three; v278 stays deployed and keeps the Add path.

## Browser evidence re-captured (system Chrome, Browser pane)

`app/app.js` changed, so every generated `tests/browser/*` fixture was regenerated from current
production source (`node tests/browser/generate-*.mjs`). Three checked-in captures pin a fixture
source hash and were therefore re-captured rather than hand-edited:

| evidence | fixture hash | viewports |
| --- | --- | --- |
| `docs/qa/evidence/v104-promotions-production-render-metrics.json` | `516c1544f822c36e736b9a4a6479e8891eb0cb9b40e15147083dfe0001e1019d` | 1440 (modal open), 390 (terms 0 open), 412 (terms 1 open) |
| `docs/qa/evidence/v142-connect-paynow-pos/metrics.json` | `287a9ed39d6c4fb8ab55364ed984109a548a438f910bbc16fd12e47f87f59864` | 1440 and 390, each driven through the real Record sale → PayNow QR → provider confirmation → print flow |
| `tests/browser/reward-overview-owner-visual.html` | `dbbf92ab2e47d3d8be3d8ea579d1cba0f2a8a442efd4095ec9b658a3340299e4` | 1440×1100 |

Every measurement in those files is a real browser measurement; no hash was edited by hand.

The checked-in PNGs beside those metrics were NOT re-shot: V288 changes nothing in the
promotion card or the Record sale receipt they picture, and the numeric captures above are
what the suite actually asserts. Re-shooting an unchanged render to refresh a timestamp
would make the evidence look newer than the verification behind it.

### Production-component source hash (reward overview)

`dbbf92ab2e47d3d8be3d8ea579d1cba0f2a8a442efd4095ec9b658a3340299e4`

Verified at 1440×1100: the extracted `growPage` runs to completion — `h1` reads "Programmes",
`#rewardJourneyTitle` renders, **zero console errors, no horizontal overflow
(scrollWidth 1440 = clientWidth 1440), and no visible interactive control under 44 px**.

## Known limitation carried forward

`npm run bundle-stamp` was deliberately NOT run for this change, so
`tests/phase0-foundation/app-bundle-stamp.test.mjs` fails on both of its byte-comparison
assertions. The surface bundles and the `/app.js?b=<hash>` fingerprint must be regenerated
before this is deployed.

# P0-SGT-TIMEZONE-013 — SGT business-date behavior across browser, database, reporting, jobs

## 1. Classification

**ENGINEERING-PREP-COMPLETE** for the parts with static coverage (and, on source inspection, likely for
the Week-view residual too); **OWNER-ACTION-SCRIPTED** for the live two-timezone rehearsal that turns
that inspection into accepted evidence.

**Verified today:** `scripts/reporting-scale/reporting-scale.test.mjs` (part of the 393/393 passing
`npm test` run today) includes and passes "Singapore-local day bounds keep 23:30 in-day and midnight in
the next day." `CLAUDE.md` records a **known residual** from the v10 era ("Week-view bucketing still
uses browser-local time — works on an SGT browser, architecturally fragile") and the v41 audit's UX-004
finding made the same claim on 2026-07-21, before v48 ("calendar details and rescheduling") shipped.
Reading the current `app/index.html` (post-v48) directly: `weekStart()` computes the visible Monday from
`Date.now()+8*3600000` and reads only `getUTCDay()`/`getUTCFullYear()`/etc., never a browser-local
getter; `eventParts()` converts every event timestamp the same way before deriving its bucketed
date/time. Neither function calls a browser-local `Date` accessor, so this static reading suggests the
CLAUDE.md-recorded residual has been closed by the v48 calendar rework — but that note predates this
plan and a source read is not the same evidence class as a live two-clock proof. Run the drill below to
turn "looks closed by inspection" into an accepted runtime fact rather than assuming it.

## 2. Preconditions

- Two systems (or one system with its OS clock/timezone changed) — one set to Asia/Singapore, one set to
  a materially different zone (e.g. UTC-8 or UTC+0) — to drive the browser through the actual UI, not
  just the SQL/reporting layer already covered by static tests.
- This gate shares its drill with `P0-REPORTING-SCALE-006` step 5 — run them together rather than twice.

## 3. Procedure

1. Re-run: `node --test scripts/reporting-scale/reporting-scale.test.mjs`.
2. From the SGT-clock browser, immediately before and after SGT midnight: create a booking, complete a
   sale, and check the appointments Week view and dashboard "today" bucket land in the correct SGT day.
3. Repeat step 2 from the non-SGT-clock browser at the *same real-world instants* and confirm identical
   placement — this is the specific test that would catch the "Week-view bucketing uses browser-local
   time" residual if it is still present.
4. Check retention-window and commission-period boundaries land on the correct SGT day using the same
   two-clock method.
5. Confirm scheduled jobs (points-expiry sweep, membership renewal, birthday draft activation, cron
   reminders) fire on SGT-anchored schedules regardless of the *database server's* configured timezone
   — a read-only check of `cron.job` definitions (already part of the cutover comparator's scope) can
   support this but the live-firing check is the actual proof.
6. Record the outcome plainly: the source reading above suggests the Week-view residual is closed
   (explicit `+8h`/UTC-getter arithmetic, no browser-local read), but only the live two-clock drill in
   steps 2-3 can turn that into accepted evidence. If the drill instead reproduces the old residual
   (Week view shifts by a day on the non-SGT clock), this gate cannot close and must be routed back as
   engineering work, not evidence-captured as a pass.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-SGT-TIMEZONE-013.json`
- Example `checks`: `{"staticSuitePassed": true, "bookingCorrectBothClocks": true,
  "saleCorrectBothClocks": true, "weekViewCorrectBothClocks": true,
  "retentionWindowCorrectBothClocks": true, "commissionPeriodCorrectBothClocks": true,
  "scheduledJobsSgtAnchored": true, "browserLocalResidualClosed": true}`
- If `browserLocalResidualClosed` would be `false`, do **not** submit this artifact as `result: "PASS"`
  — the checker requires every value in `checks` to be `true`; a genuine failure here means the gate
  stays `BLOCKED`, not that the finding gets quietly dropped from the checks object.
- Hash-pin and register per `INDEX.md` only once every check is genuinely true.

## 5. Estimated wall-clock time

60-90 minutes if the drill confirms the Week-view residual is closed, as the current source suggests;
open-ended engineering time if the drill instead reproduces it (would need to be re-routed to
implementation work before evidence can be captured).

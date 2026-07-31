# V118 task-first UX acceptance

Date: 2026-07-31
Scope: local feature branch, with owner-authorized release pending production evidence
Release authorization: **owner supplied `RELEASE APPROVED push and deploy` on 2026-07-31**

## Outcome

The workspace now leads with common jobs instead of analytics and configuration.
Appointments open in Day view with named team-member columns, while Week, List,
Print, CSV, and the creation form are secondary. Reports start with four plain
business questions instead of exposing the full accounting surface immediately.

This increment deliberately does **not** claim that every availability or
cross-surface requirement is complete.

## Acceptance matrix

| Requirement | Evidence | Result |
| --- | --- | --- |
| Owner/front desk sees only authorised primary tasks | Dashboard task cards are individually gated by Till, Appointments, Clients, and Loyalty permissions. Static regression: `v118-task-first-ux.test.mjs`. | Implemented locally |
| Analytics does not crowd the start of the day | Performance content is inside a closed `details` region below the task launcher. | Implemented locally |
| Appointments open to a day-by-team overview | Default view is Day; each selected team member has a named column containing time, customer, service, duration, and status. | Implemented locally |
| Empty columns do not falsely promise availability | Empty copy says only “No appointments scheduled”; the renderer contains no “available” claim. | Implemented locally |
| Creating an appointment is contextual and simple | The main form is hidden until requested. Clicking a recorded working-time gap snaps to 15 minutes and pre-fills date, named staff, and exact time. Branch breaks refuse creation. | Implemented locally |
| Authoritative schedule projection | Day columns are projected from persisted `staff_hours`, `staff_off_days`, `branch_hours`, and `branch_breaks`; missing configuration is labelled “Working hours not set” rather than inferred as free. | Implemented locally |
| Arbitrary blocked-time creation | V120 adds the durable entity, replay-safe RPCs, server-side booking guard, calendar authoring/loading, capacity projection, and deterministic desktop/390px states. Exact local evidence and remaining database/authenticated-browser blockers are recorded in `V120-STAFF-BLOCKED-TIME-ACCEPTANCE.md`. | Verified locally in V120; database/authenticated-browser proof open |
| Current-time marker in Day view | The Singapore-time marker is rendered only for today and only when it falls within the visible schedule range. | Implemented locally |
| Appointment completion records the same sale/loyalty identity | UI calls `set_appointment_status_v47`, labels the action “Complete & checkout”, and directs staff to Sales for the final points outcome. It no longer promises loyalty before ledger confirmation. A fresh live owner → staff → customer record comparison was not rerun for V118. | Implemented, unverified in this increment |
| Reports answer ordinary SME questions first | Four visible entries cover money, utilisation, customer return, and team performance; the detailed money report is collapsed. | Implemented locally |
| Mobile interaction | Task and report cards become one column at 560px. No authenticated 390px browser capture exists for V118 yet. | Static verified; browser open |
| Disabled, permission, branch, refresh, retry states | Permission hiding is statically verified. Full authenticated branch/refresh/retry acceptance was not rerun for V118. | **Open** |

## Regression command

```text
node --test tests/business-ui/v118-task-first-ux.test.mjs
```

## Production-readiness ruling

V118 is a meaningful simplification, but it is not honest to call the whole
appointment and reporting experience 100/100 yet. Exact-time selection,
persisted schedule projection, break exclusion, and the current-time marker
are implemented locally. V120 closes the time-specific staff-block authoring
gap at the local automated level. Authenticated mobile/branch/refresh/retry
acceptance, disposable database execution, and a fresh completion-to-customer
ledger comparison remain release blockers for the corresponding traceability
rows.

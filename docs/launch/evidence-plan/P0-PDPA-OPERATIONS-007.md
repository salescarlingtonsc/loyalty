# P0-PDPA-OPERATIONS-007 — PDPA public notices, consent operations, data-subject handling

## 1. Classification

**OWNER-DECISION**, with an **OWNER-ACTION-SCRIPTED** rehearsal once the decisions below are made.

**Verified today:** `app/privacy.html`, `app/terms.html`, and `app/data-request.html` exist, are linked
from the app shell (`legalLinks()` in `app/index.html`) and from the customer-facing sign-up screen
(terms/privacy checkboxes), and `node --test tests/pdpa-pages/pdpa-pages.test.mjs` passes 5/5 today,
including "privacy notice covers the required PDPA-facing subjects and role split," "terms set merchant
obligations and do not claim regulated payment processing," "data request page provides a usable,
minimised manual process," and "operations runbook blocks launch on formal DPO and operator evidence" —
i.e. the static suite itself already encodes that this gate cannot close without the owner decisions
below.

## 2. Preconditions (OWNER-DECISION — none of these can be inferred or guessed)

- Named Data Protection Officer / privacy operations owner and their contact route.
- Data retention periods per data category (customer profile, sales history, audit logs, etc.).
- Incident escalation owner and decision-log process.
- Confirmation that the currently published privacy/terms text's claims (processors, Singapore hosting,
  security measures) are accurate for the actual deployed stack, not aspirational.

## 3. Procedure

1. Re-run the static suite: `node --test tests/pdpa-pages/pdpa-pages.test.mjs`.
2. Owner supplies the named-role decisions above; update the published pages only if the current text
   overstates or understates what is actually true (do not let the pages make an unsupported
   compliance claim).
3. Smoke-test the deployed pages after the release build: confirm `/privacy.html`, `/terms.html`,
   `/data-request.html` resolve from the public join page, the customer portal, the auth screen, and a
   direct URL hit, and record the release commit they were checked against (this overlaps
   `P0-RELEASE-BUILD-017` — one drill can satisfy both).
4. Rehearse, with synthetic data only, one full cycle of each: access request, correction request,
   consent withdrawal, and deletion request, following whatever manual procedure `data-request.html`
   describes — confirm an operator can actually execute it end to end without ad hoc SQL against
   production.
5. Rehearse the incident-escalation path once (a fire-drill, not a real incident): confirm it assigns an
   owner, produces a decision log entry, and reaches a containment/notification decision within a
   reasonable window.
6. Confirm marketing consent is opt-in (not opt-out) and that withdrawal is independently testable from
   enrollment — this is already asserted at the schema level by `db/tests` consent-related suites but
   should be walked through once in the UI.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-PDPA-OPERATIONS-007.json`
- Example `checks`: `{"staticPageSuitePassed": true, "pagesResolveFromAllEntryPoints": true,
  "accessRequestRehearsed": true, "correctionRequestRehearsed": true,
  "withdrawalRequestRehearsed": true, "deletionRequestRehearsed": true,
  "incidentEscalationRehearsed": true, "consentOptInVerified": true}`
- `summary`: state who was named DPO/operator (role label, not personal contact details) and that the
  rehearsal used synthetic data only — never place a real contact email/phone or the DPO's personal
  details in the artifact itself (the checker's unsafe-content scan rejects an email/phone pattern
  outright; keep names out of the evidence file even if they are not literally emails/phones).
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

- Owner decisions: 30-60 minutes (mostly naming roles that likely already exist informally).
- Rehearsal once decisions are made: 60-90 minutes.

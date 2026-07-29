# v103 customer control audit

Date: 2026-07-29
Scope: customer home, programme selector, selected programme, rewards, history,
bookings, notifications, and account controls.

## Decision rule

Every visible control must answer one immediate customer question:

1. Where will this take me?
2. What will change?
3. Is the action available now?

A control is removed when it duplicates a persistent navigation action, exposes
an internal relationship-management concept, or cannot complete the action it
promises. Error recovery remains visible only for the failed surface.

## Persistent controls

| Control | Decision | Customer meaning |
| --- | --- | --- |
| Nestly logo | Keep | Return to customer Home. |
| Back icon on a selected programme | Keep | Return to the programme selector. It retains an accessible name. |
| Notification bell | Keep, make consistent | Open the dedicated Notifications view. It must not sometimes navigate and sometimes scroll to a hidden block. |
| Profile avatar | Keep | Open account options: profile/passkeys and sign out. |
| Home | Keep | Consolidated customer home and next action. |
| Programmes | Keep | Choose among linked business programmes. |
| Bookings | Keep | Review requests and appointments; a new booking CTA appears only for a business that enables it. |
| Scan QR | Keep as the single join control | Join another programme from a business-issued QR. |

## Selected-programme controls

| Control | Decision | Reason |
| --- | --- | --- |
| Add programme in the page header | Remove | Duplicates the persistent **Scan QR** action and was partially obscured in the reported viewport. |
| Programme switcher pills | Keep only with 2+ programmes | Gives a direct, labelled switch without forcing a round trip to the selector. |
| Book now | Keep only when that business enables customer booking | It completes a clear customer task and remains absent otherwise. |
| Disconnect | Remove | Destructive relationship management is not part of the normal loyalty journey and the consequence is not obvious to a customer. |
| Presentation “Try again” | Remove from the healthy wallet | Brand/presentation content is optional. If the authoritative wallet loaded, decoration failure falls back without claiming the programme failed. |
| Tier progress | Render only for a real configured tier or measurable next tier | Generic filler such as “Every visit still counts” is not progress and gives the customer no action. |
| Duplicate balance metrics | Remove | The point balance appears once. Store credit/package/membership values appear only when meaningful and never repeat points. |

## Rewards and history

| Control | Decision | Reason |
| --- | --- | --- |
| Redeem now | Keep beside every currently eligible QR reward | Starts one idempotent pending redemption and shows the QR. Points remain unchanged until staff scans and confirms. |
| Disabled/insufficient/ended reward | No dead CTA | Show a short state such as **More points needed**, **Redeem at counter**, or **Offer ended**. Do not ask the customer to diagnose a business setting. |
| How to use / Terms | Keep as labelled disclosure | Important supporting information, hidden until requested. |
| History | Keep as one collapsed disclosure | Purchases, points, reversals, and loyalty activity remain reachable without competing with the current reward task. |
| Notification preference checkboxes on programme detail | Remove | The bell already opens the dedicated Notifications route, where reminder preferences belong. A second programme-level control surface makes customers guess which notification setting is authoritative. |
| Load more history | Keep only when a continuation exists | It has one clear effect and preserves long histories. |
| Retry | Keep only on the section that actually failed | A presentation failure must not create a page-level retry beside already loaded wallet data. |
| Refresh on a successful empty history | Remove | An empty result is not an error; an extra button suggests otherwise. |

## Secondary programme content

| Control | Decision | Reason |
| --- | --- | --- |
| Package, gift-card, membership, and appointment disclosures/actions | Keep only when the capability and real customer record exist | Disabled or empty modules must not advertise what the business does not offer. |
| Feedback submission | Keep | Label states exactly what is sent and that it is private to the business. |
| Notification preferences | Secondary | Do not compete with rewards on the programme home. Preferences belong behind the notification/account journey or a collapsed settings disclosure. |

## Exact reported root cause

`customer_get_business_summary(text)` did not project the linked business UUID.
The customer UI then called UUID RPCs
`customer_get_business_actions_v89(uuid)` and
`customer_get_business_presentation_v95(uuid, uuid, text)` with
`p_business: undefined`. JSON omitted the argument, so PostgREST could not match
the RPC signature. The core wallet had already loaded, producing the
contradictory combination of a real balance/reward history and “This programme
could not be loaded.”

The v103 acceptance boundary is:

- the summary contract projects the verified linked business UUID;
- the client never sends an undefined UUID argument;
- optional presentation failure falls back to summary branding without
  declaring the authoritative programme unavailable;
- a genuine summary/capability failure still gets the existing focused retry
  screen.

## Local verification evidence

The local implementation is verified, but not yet closed or production-ready:

- focused customer, programme, inbox, telemetry, and registry regressions:
  **64/64 pass**;
- complete repository test suite: **pass**;
- static quality, production runtime configuration, migration manifest,
  canonical migration plan/materialization, build, and `git diff --check`:
  **pass**;
- rollback-only v103 SQL proves the linked UUID is returned while an unlinked
  firm, a different customer identity, and anonymous execution remain denied;
- the customer UI passes the validated UUID to both UUID-only programme RPCs
  and falls back to loaded summary content if only optional presentation fails.

Still outstanding before these items can be marked closed:

- authenticated target-environment customer reload after the v103 migration;
- desktop and 390px mobile visual artifacts with ordinary and 70,576 balances;
- a real customer **Redeem now** QR prepared and then scanned/confirmed by the
  correct staff/branch;
- owner release approval for the target migration and deployment.

## Independent review

Sol independently reviewed v103 on 2026-07-29 and **accepted the local
implementation only**. Sol verified the summary UUID contract, canonical
mirror, authenticated-only ACL, cross-firm/outsider/anonymous denials, the
customer control decisions, truthful fallback, genuine-error Retry, removal of
the unlink writer, and the regression assertions. Sol's focused review passed
83/83 tests with a clean diff check.

This acceptance is not a production-readiness certificate. The target
migration, authenticated desktop/mobile acceptance, real customer-to-staff
redemption scan, and deployment verification remain outstanding.

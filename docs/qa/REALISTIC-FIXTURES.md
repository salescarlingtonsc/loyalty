# Realistic acceptance fixtures

These fixtures are synthetic and reusable. They are designed to reveal
sector-, branch-, role-, price-, and entitlement-specific failures. Never
replace them with real customer PII.

## `SPA-GLOW` — Glow Atelier

Sector: Facial / Spa

Branches:

- Orchard — all core modules enabled.
- Tampines — bookings enabled, gift-card issuance disabled.

Roles:

- Owner: Olivia Tan
- Manager: Maya Lim
- Front desk: Farah Noor
- Service staff: Chen Wei, Aisha Rahman

Catalogue:

| Service/variant | Duration | Price |
| --- | ---: | ---: |
| Express facial | 30 min | SGD 45 |
| Spa ritual | 30 min | SGD 40 |
| Spa ritual | 60 min | SGD 60 |
| Spa ritual | 90 min | SGD 85 |
| Glow serum (retail) | N/A | SGD 68 selling price / SGD 24 product cost |

Packages:

- **5x Spa 60** — list value SGD 300, selling price SGD 270, savings SGD 30
  (10%), valid only for the 60-minute variant, owner-controlled purchase
  points.
- **3x Express facial** — list value SGD 135, selling price SGD 120, branch
  restricted to Orchard.

Configuration cases:

- gift-card issuance off, with one existing valid gift-card liability;
- customer booking on at Orchard and off in an alternate run;
- package purchase points on, then off;
- one firm-level module override and one Tampines branch override;
- logo upload success, replacement, invalid type, and denied-role attempts.
- Orchard staff availability: Chen Wei works 09:00–18:00, Aisha Rahman works
  10:00–19:00, the branch has a 12:30–13:30 break, and Chen has one
  **Supplier training** block on 31 July 2026 from 14:00–15:00 Singapore time.
  Keep one adjacent 15:00 appointment and use Spa Ritual 60 with configured
  before/after buffers to prove a block suppresses every overlapping start
  without hiding Aisha's availability.
- Appointment completion truth: Olivia completes `CUS-MEI`'s booked SGD 60
  Spa ritual 60 at Orchard. With exact-branch Loyalty `rw`, one linked sale and
  one +600 earn persist and all customer-safe wallet/summary/history readers
  agree after refresh. The same status call replays without duplication.
  Repeat with firm-disabled, branch-disabled, and branch-read-only Loyalty:
  checkout still records one sale, no new earn is created, and the prior 600
  balance remains persistent but is exposed only while effective policy permits
  customer Loyalty reads. Farah, assigned only to Orchard, cannot complete the
  Tampines comparison appointment.
- Two-staff calendar authoring: click Chen Wei's free 10:15 Day-view slot and
  save a Spa Ritual 60 appointment, then click Aisha Rahman's independently
  eligible column. Both staff/date/time values must be prefilled from the
  selected calendar cell, conflicts and Supplier training must stay
  non-selectable, and the saved appointments must survive refresh.
- Profitability setup: Glow serum sells for SGD 68 with SGD 24 product cost.
  The owner must see SGD 44 gross profit and about 64.7% gross margin before
  choosing a reward. A reward proposal must state its cost assumption and show
  contribution after reward; it is never auto-published.
- Feedback: `CUS-MEI` submits one four-star internal rating and one separate
  five-star fixture. The company has a syntactically valid, synthetic Google
  Business review URL configured; both persisted ratings offer the same
  optional external link so the product does not selectively solicit positive
  reviews. Five-star copy may be warmer. A comparison tenant cannot read either
  record.

Promotion cases:

- owner draft for **National Day Glow**;
- exact offer facts: **30% off Spa Ritual 60**, celebrating National Day,
  valid through **30 August 2026**;
- CTA: **Book now** when customer booking is enabled, otherwise **View offer**;
- a real 16:9 JPEG/WebP with descriptive alt text;
- two simultaneous active offers for the normal customer projection;
- a third active offer to prove the server returns no more than two;
- one future, one expired, and one inactive offer, plus a non-null Tampines
  branch author/read attempt that must be rejected because v104 promotions are
  company-wide;
- ten active offers followed by an eleventh publish attempt for quota proof;
- wording-assistant inputs containing a percentage, date, and named service to
  prove those facts remain exact after polishing.

## `CAFE-HARBOUR` — Harbour Kopi

Sector: F&B / Café

Branches: Tanjong Pagar, Toa Payoh

Catalogue:

- Kopi — SGD 2.20
- Iced kopi — SGD 2.80
- Kaya toast set — SGD 6.50

Programme:

- stamp or points configuration using café-specific recommendations;
- an ordered stamp path: stamp 5 unlocks one Kopi; stamp 10 unlocks one Kaya
  toast set, with the second threshold displayed as the next five stamps after
  the first unlock;
- birthday benefit disabled;
- gift-card issuance enabled in one run;
- a seasonal reward published by platform campaign controls.

This fixture verifies that café benchmarks appear only for café firms.

## `FIT-NORTHSTAR` — Northstar Fitness

Sector: Fitness

Catalogue:

- Drop-in class — SGD 28
- 10-class pack — SGD 240
- Personal training 60 min — SGD 95

Use it for bookings, memberships, package expiry, class capacity, staff
assignment, and mobile booking acceptance.

## Customer category projection

Use `CUS-MEI` with existing QR-created links to `SPA-GLOW`,
`CAFE-HARBOUR`, and `FIT-NORTHSTAR`. The customer selector groups them under
Personal care, Food & drink, and Fitness while preserving the existing
programme links. Add one governed but unmapped synthetic sector to verify an
Other fallback. The fixture must not add business search or create any new
relationship.

## Customers

| ID | Identity | Purpose |
| --- | --- | --- |
| `CUS-MEI` | Mei Lin, synthetic SG mobile ending 4567 | Linked to several firms; has 5x Spa 60 with 4/5 left, points, and booking history. |
| `CUS-LEE-A` | Lee Wei, synthetic mobile ending 1001 | Duplicate-name search case. |
| `CUS-LEE-B` | Lee Wei, synthetic mobile ending 2002 | Duplicate-name search case. |
| `CUS-ARUN` | Arun Kumar, synthetic mobile ending 8877 | Owns a valid $50 legacy gift while new issuance is disabled. |
| `CUS-NEW` | New synthetic identity | No programmes before QR join. |

All automated credentials must come from a non-committed test-secret mechanism.

## Platform CRM and billing

| ID | Scenario |
| --- | --- |
| `PLAT-PENDING` | New spa firm awaiting Super Admin approval, assigned to Consultant Sarah. |
| `PLAT-WON` | Active café firm, annual subscription paid, next payment present. |
| `PLAT-OVERDUE-01` | Quarterly firm on day 1 overdue. |
| `PLAT-OVERDUE-14` | Half-yearly firm on day 14 overdue; owner access pause expected. |
| `PLAT-REFUND` | Annual invoice refunded after payment; GST and refund excluded from commission. |
| `PLAT-STAFF-LEFT` | Consultant departed before eligibility anniversary; commission returns to company. |

## Required state variations

Every relevant journey chooses from this list and records which variants were
run:

- zero, one, and many records;
- enabled, disabled, and enabled-but-unconfigured module;
- owner, manager, front desk, customer, dual-role, Super Admin, Admin, assigned
  Sales/Consultant, and unassigned Sales/Consultant;
- all branches, one branch, and wrong branch;
- happy path, validation failure, permission denial, server failure, timeout
  after write, retry, double tap, refresh, back/forward, logout/login, and
  reconnect;
- desktop, 390px-class iPhone viewport, and 412px-class Android viewport.

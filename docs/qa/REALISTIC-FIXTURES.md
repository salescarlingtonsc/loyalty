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

## `CAFE-HARBOUR` — Harbour Kopi

Sector: F&B / Café

Branches: Tanjong Pagar, Toa Payoh

Catalogue:

- Kopi — SGD 2.20
- Iced kopi — SGD 2.80
- Kaya toast set — SGD 6.50

Programme:

- stamp or points configuration using café-specific recommendations;
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

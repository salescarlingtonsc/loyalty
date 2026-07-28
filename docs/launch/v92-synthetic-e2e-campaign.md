# Nestly v92/v93 synthetic end-to-end campaign

Status: passed on disposable rehearsal branch `wtegnefsgnyxhflzizcu` on
2026-07-28. No production write is authorized by this file.

The rehearsal exposed and v93 closes one frontline-only defect: the original
merchant QR scan omitted the active till branch. Quick Earn now sends its
already-authorized branch to `merchant_scan_redemption_qr_v93`; catalog
redemptions preserve that branch in the canonical eligibility snapshot, and
front-desk staff cannot redeem from an unassigned branch. The branchless v89
scanner is revoked from browser identities to prevent a downgrade around the
new branch boundary.

## Fixed scope

- Business: `ZZZ SYNTHETIC V92 E2E – Points`
- Slug: `zzz-synthetic-v92-points`
- UUID namespace: `92000000-0000-4000-8000-*`
- Recipients: `*@example.test` and `+65990000xx` only
- Idempotency namespace: `nestly:e2e:v92:*`
- Data lifetime: one database transaction, always followed by `ROLLBACK`
- Expected residue after the campaign: zero businesses and zero Auth users

## Personas

| Persona | Expected authority |
| --- | --- |
| Owner | Configure customer capabilities, rotate join QR, read/write all firm modules |
| Manager | Firm operations within assigned modules |
| Front desk | Record/amend a sale, manage appointments, scan redemption QR |
| Customer A | Join by merchant QR, see programme/history/booking, present reward QR |
| Customer B | Join independently; denied Customer A’s redemption |
| Outsider | Denied merchant redemption and all firm data |

## Deterministic journey

1. Create one structurally synthetic firm, branch, three staff, two services,
   two products and two FEFO stock batches.
2. Create two verified synthetic customer identities.
3. Rotate the merchant join QR and use that token to create exactly two
   independent verified firm/customer relationships.
4. Enable booking, redemption and appointment-change capabilities.
5. Publish a 1 point/SGD programme with a 20-point manual-item reward.
6. Front desk records a SGD 25.00 paid sale; Customer A must see +25 points.
7. Front desk corrects the sale to SGD 28.00; immutable reversal/replacement
   evidence must net to 28 points and appear in customer history.
8. Create an appointment; the customer appointment reader must return it.
9. Customer A presents a reward QR; this must not change points or redemption
   rows before scan.
10. Customer B, an outsider, and front desk at an unassigned branch are denied.
    The authenticated front desk is also denied by the legacy branchless v89
    scanner without changing the pending intent or redemption count. Front
    desk at its assigned branch then completes exactly one 20-point redemption
    through v93; replay is idempotent; final balance is 8; the canonical
    redemption snapshot retains that branch.
11. Final customer history must contain the corrected earn and redemption.
12. Roll back, then assert zero synthetic database residue.

## Stop conditions

Stop at the first schema/build mismatch, non-synthetic recipient, cross-tenant
success, duplicate economic effect, wallet/ledger mismatch, missing history
record, or rollback residue. Production must remain untouched until this
campaign, browser persona journeys, and Sol’s independent review all pass.

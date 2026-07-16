# ROLE_PERMISSION_MATRIX

## Roles observed in Flowesce
Five tiers (role-based; invites are Growth-gated, Solo = single owner login):
**Owner · Manager · Receptionist · Bookkeeper · Staff**. Plus "Expertise levels"
(Senior/Junior) which are *scheduling/pricing* tiers, not permission roles.
Flowesce's roles are **salon-operations** roles — there is no loyalty-manager,
finance, outlet-manager, partner, or member role in the console. That's a gap for a
dedicated loyalty platform.

| Capability (observed/inferred) | Owner | Manager | Receptionist | Bookkeeper | Staff |
|---|---|---|---|---|---|
| Billing / subscription | ✅ | – | – | – | – |
| Team & roles | ✅ | partial | – | – | – |
| Configure loyalty/membership | ✅ | likely | – | – | – |
| Take payment / Quick Sale | ✅ | ✅ | ✅ | – | ✅ |
| View reports / P&L | ✅ | ✅ | – | ✅ | – |
| Manage clients | ✅ | ✅ | ✅ | – | partial |
| Manual credit adjustment | ✅ | likely | – | – | – |
> partial/likely = inferred from role naming; verify live on Growth.

## Avocado target RBAC (loyalty-platform-native)
Avocado is multi-tenant SaaS for many business types incl. multi-outlet/franchise +
agencies. Design a **two-level** model: platform-level and tenant-level.

### Platform level
| Role | Purpose | Can |
|---|---|---|
| Platform super admin (us) | Operate the SaaS | all tenants (support-scoped, audited) |
| Agency / reseller | Manage many client tenants | switch between owned tenants, white-label |

### Tenant level
| Role | Purpose | View | Configure loyalty | Issue/redeem reward | Refund/reverse | Manual adjust | Reports | Export | Manage staff/billing |
|---|---|---|---|---|---|---|---|---|---|
| Company owner | Full control | all | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Loyalty/Marketing manager | Runs the program | all | ✅ | ✅ | – | approve-only | ✅ | ✅ | – |
| Finance | Liability & recon | financial | – | – | ✅ | ✅ (audited) | ✅ | ✅ | billing |
| Outlet manager | One branch | own outlet | – | ✅ | ✅ (own outlet) | approve-only | own outlet | own outlet | staff (own outlet) |
| Frontline staff | Desk/POS | member+balance | – | ✅ (redeem) | – | – | – | – | – |
| Support | Help members | member 360 | – | ✅ (guided) | ✅ (audited) | ✅ (audited) | – | – | – |
| Member (client) | Self-serve | own balance/history/referral code | – | request redeem | – | – | – | own data (PDPA) | – |
| Partner (coalition, later) | Cross-merchant | own scope | – | validate | – | – | own scope | – | – |

## Non-negotiables
- Every **refund, manual adjustment, redemption, export** is **audit-logged** with actor.
- **Tenant isolation** enforced at DB (RLS ✔) — never rely on UI hiding.
- Least privilege: frontline can redeem but not adjust balances or see P&L.
- Member data export honors PDPA access/portability.

# V149 final production reconciliation

## Lineage

- Production base: V145 reconciliation commit `addb6f006910` with production
  evidence commit `8531974c1799`.
- V148 is retained as the forward-port authority for V143 reward boundaries,
  product-backed rewards and tier drafts, plus V146 finance, V147 accounting,
  CRM and owner onboarding clarity.
- The final reviewed V142 Stripe Connect and fixed-amount PayNow POS changes are
  integrated on top of that lineage, including both Edge Functions and the
  canonical `20260802134128` migration.

## V135 cache decision

V135 is already in the production ancestry through merge `dfcda122e4f9` and is
fully superseded for cache convergence. V138 retained the Peekaa assets and
no-cache application-shell headers while advancing the service worker from the
V135 `v4-20260802-peekaa-brand` cache to
`v5-20260802-v138-peekaa-convergence`. The later implementation adds immediate
`skipWaiting()` activation and network-first static requests with an offline
cache fallback. Re-applying V135 would regress that newer cache authority, so
no duplicate cache patch is included.

## Release scope

This reconciliation contains no unrelated feature or architecture changes. Its
verification is limited to V142, the surviving V135 cache/auth behavior, V148,
the canonical migration chain, and the production static build.

# V310 — W4b customer programme stack: the tabs die, four cards stand

Wave W4b of the four-programme independence plan (ledger `PROGRAMME-INDEPENDENCE-001`;
client half of the W4 design contract). The business page's programme region becomes a
vertical stack — STAMPS → POINTS & GIFTS → TIER → REFERRAL — gated on the v310 server
payload (`programmes_contract='v310'`, non-empty `programmes[]`); any other answer
renders the v194 tab surface **byte-identically to the pre-change bundle** (the 4-hour
CDN window and the rollback path in one gate).

## What shipped

- `customerProgrammeStackV310` and its card set, inserted after
  `wireCustomerProgrammeTabsV194` with `customerProgrammeSummaryTabsV194` keeping its
  name, position, and the exact v174-pinned call-site literal as the ternary's false
  arm. All five legacy renderers remain declared and live on the fallback path.
- **Visibility obeys the server**: cards render on `customer_visible` (bound
  server-side to the same legacy capabilities the tabs read) or `paused_since` — never
  on `active` alone, so the two bundles cannot disagree during the CDN window (an
  active points programme with no reward configured stays invisible on both).
- **Stamps card**: a pure-CSS ring row (N = the cheapest stamp reward's cost, capped at
  24 for legibility; no known reward → plain count, no invented N), greyscale-legible
  (solid+tick vs dashed), `prefers-reduced-motion` honoured; the words "Reward points"
  never appear on it.
- **One-hero rule**: exactly one `.customer-programme-balance` in any stack (the Points
  card owns it; the stamps card uses its own count class; the Tier card's duplicated
  balance line is deleted in the stack path only — spendable and lifetime-earned are
  different numbers).
- **Claimable-now strip** built only from facts already on the page
  (`next_eligible_reward.available_now`, birthday `ready_to_activate`/`available` —
  the real status vocabulary); absent when empty; fires no read.
- **Per-programme paused sentences** (V289's points sentence preserved; each card reads
  its own `programmes[kind]`); referral card at stack position 4 on `{enabled:true}`
  only; W4c "Show my code" slot + copy shipped so W4c is wiring only.
- **i18n**: 19 keys × 4 locales (en/zh-CN/ms/ta) in one commit, including the tier
  distance sentence AND its unit words (visits/points/spent) — no code-switched English
  inside a Chinese/Malay/Tamil sentence. v293 parity green.

## Verification

- Builder + adversarial verifier (APPROVED with 4 findings, all fixed before ship):
  (1) `customer_visible` now obeyed — the verifier proved `active`-only rendering
  diverges from the tabs for a points programme with no reward configured;
  (2) the claimable strip's birthday branch checked a status (`'ready'`) this codebase
  never emits — now `ready_to_activate`/`available`;
  (3) tier unit words were English inside localized sentences — now ct()-routed ×4;
  (4) the gate accepted `programmes: []` (a v308-invariant violation server-side) —
  now floors at `length > 0` and falls back. Suite pins flipped accordingly.
- `tests/customer-wallet/v310-programme-stack.test.mjs` (21 tests) + 796/796 across
  customer-wallet, customer-modules and v148; two pre-existing pins changed minimally
  with in-file rationale (v174 call-site literal; v104's progressbar ban re-scoped to
  the exact span it protects).
- **Walkthrough** `tests/browser/verify-v310-customer-stack-walkthrough.mjs`, steps
  a–h against the REAL stamped repo bundles: fixed order + 1.16 screens at 390; no
  filler; paused card keeps its figure and sentence; **step (d): a pre-v310 payload
  renders the v194 tabs byte-identical to a build of the pre-change HEAD bundles
  (6453 bytes compared, guard against empty-vs-empty), and the tab wiring stays live**;
  exactly one hero; 10 rings/6 filled with greyscale-legibility computed-style checks;
  referral position and removal; dark theme via `peekaa.customer.theme`.
  The adversarial verifier independently re-ran the walkthrough on its own ports and
  reproduced every step including the byte comparison.
- Captures (`docs/qa/evidence/`): `v310-customer-stack-390.png`,
  `v310-customer-stack-dark-390.png`, `v310-customer-stack-four-390.png`,
  `v310-customer-stack-desktop-1440.png`.

## Regenerated fixture identity

reward-overview-owner-visual.html production-source-sha256 (regenerated for the V310
client source; supersedes the V306 hash for current-tree byte identity):

    afaf2e34776d9834632b6a66a4da4f70d9029f26dabfd09938588bb54dd1a11e

All nine embedded-source fixtures regenerated; v142 and v104 Chrome evidence
re-captured through real Chrome against the regenerated fixtures.

## Residuals (recorded)

- The V258 both-note and the "You're now at {tier}" line remain English in all four
  locales (ladder internals — W6 scope per the design contract's own note).
- A spine↔presentation unit mismatch (stamps spine row with a points unit word) can
  render a mixed figure/sentence; that mismatch class is exactly what the W4–W6
  migration path removes.
- The claimable strip reads only first-paint facts; folding in catalog
  `available_at_counter` and growth offers is a deliberate W4c/W6 decision, not an
  omission.

# Four independent programmes — re-architecture plan (pre-build)

Owner rulings (2026-08-13, verbatim intent):
1. Adopt Stampede-grade ease: easy programme setting, nice customer app interface.
2. Peekaa differentiates by running FOUR programmes, each strictly independent:
   (a) **Point System** — earn points per $ spent; points exchange for GIFTS from a
   business-editable catalogue that may change month to month;
   (b) **Tier Membership** — exactly 3 tiers, default names Silver / Gold / Diamond,
   achieved by ACCUMULATED POINTS; thresholds business-editable over time;
   (c) **Stamp Card** — Stampede shape: each stamp needs a minimum spend of $X,
   N stamps exchange for a GIFT; amounts and gifts business-decided;
   (d) **Referral** — customers benefit from referring friends.
3. Each programme is individual, not connected to the others. A business may switch
   ANY SUBSET live simultaneously.

These rulings **supersede**: v229/v230 "a firm chooses ONE use for points"
(points_mode exclusivity), v23g/v24 loyalty_model single-choice (stamps replace
points), the v305 wizard's four-way radio, and the "Switch to this →" replacement
language on Programmes tiles. Superseded rulings stay recorded in their migration
headers; this document is the new authority (PRODUCT-TRUTH to be updated in the
first build wave).

Evidence base: 10-agent audit/design/verification workflow on main@4a4fa41 (v305) —
5 read-only code audits (85 cited couplings/gaps), 3 independent design proposals,
2 adversarial verifiers (19/19 audit claims CONFIRMED against code; 32 additional
issues raised). Every claim below carries a file citation in the workflow record
(session workflow wf_9b7dd629-81a).

---

## 1. Why this is a re-architecture, not a feature

The four programmes are today FIELDS of one row, not entities:

- `loyalty_programs` is **one row per business** (`business_id unique`,
  v23d:25) holding earn rate, redeem pair, stamp knobs, tier basis, expiry and ONE
  `active` flag. `loyalty_model` is a single-valued discriminator
  (`classic | points_tiers | stamps`, v24:24-27) — stamps and points are exclusive
  **by construction**, and the same check is baked into the immutable version table
  (v26:44).
- `points_ledger` / `points_batches` have **no programme column**; stamps are stored
  AS points in the same ledger (v24 design note). Every balance in the product is an
  unscoped `sum(points)`.
- The earn trigger `app.on_sale_recorded` picks **one engine per sale** (if/elsif,
  v37b:653-654), and the partial unique index `points_earn_once_per_sale (sale_id)`
  (v2:70-71) makes a second earn row per sale **impossible** — it is also the only
  structural anti-double-earn protection, so it must be *replaced*, never dropped.
- One published config version spans everything (v26:37-38); publishing one
  programme republishes all of them atomically (v55:673-721).
- `businesses.points_mode` is a second, unversioned mode switch that gates
  redemption server-side (v229:53-59) and decides the whole customer surface
  (v231:81-83; app.js customerProgrammeModeV230).

Known cross-programme leaks that the ruling outlaws (all confirmed):
- Tier multiplier applies to STAMP earning too (v37b:655-656) — a Gold customer at a
  stamps business earns multiplied stamps.
- `tier_basis='points_earned'` sums the shared ledger unfiltered (v148:428-429) — at
  a stamps tenant the ladder would be measured in stamps.
- Reward catalogue has no programme dimension — a stamp would be spendable on a
  points gift the moment both earn into one ledger.
- The expiry sweep is business-scoped (`lp.kind='points'`, v20:987-1050) and its
  inactivity clock treats ANY positive ledger row as activity — one programme's
  activity would silently shield or expire another's balance.

## 2. Live bugs to hotfix FIRST (independent of the plan)

1. **Stamps switch leaves stale points_mode** — the v303 wizard's
   `targetPointsModeV303()` returns null for stamps and the null is treated as
   "no change" (app.js:23499, 23512). A firm that ran Tiers then switches to Stamp
   card keeps `points_mode='tiers'`, whose server gate **blocks every stamp
   redemption** (v229:53-59). High severity.
2. **Wizard writes illegal tier_basis** — the v305 Climbing step writes
   `'points'` into a column CHECK-constrained to `visits|spend|points_earned`
   (app.js:22346-49 → 23544); saves fail, and the same code path silently
   **downgrades existing 'spend'/'points_earned' ladders to 'visits'**
   (app.js:22552, 22588).
3. **'both' mode never shows the tier ladder** — `customer_portal_capabilities`
   returns tiers=false for points_mode='both' (v231:113), so the two-tab wallet is
   unreachable and a firm running points+tiers shows no ladder. Contradicts the
   ruling already.

## 3. Target architecture (synthesis of the three design proposals)

All three proposals independently converged on the same spine; differences were in
sequencing and typing. Decisions:

- **Programme spine**: `public.business_programmes (id, business_id, kind
  points|tiers|stamps|referral, active, sort, created/activated/deactivated_at)`,
  `unique (business_id, kind)` — at most one of each kind, forever. That constraint
  IS the product ruling ("four switches, never a list-builder"). Referral gets a
  spine row too (its `referral_programs` table stays; the spine unifies switching).
- **Typed per-kind config** on the versioned kernel (not jsonb — these fields are
  money-shaped and need CHECKs): `loyalty_program_versions` gains `programme_id`;
  PK becomes `(config_version_id, programme_id)`. Per-kind CHECKs police which
  columns each kind may set.
- **One physical ledger, N logical ledgers**: `points_ledger` and `points_batches`
  gain `programme_id` (backfilled, then NOT NULL). NEVER a second ledger — the
  append-only trigger, write guard, FEFO drains and reversal provenance all keep
  working. `points_earn_once_per_sale` becomes `unique (sale_id, programme_id)`,
  swapped in a single transaction.
- **Earn loop**: `app.on_sale_recorded` loops over active accruing programmes —
  modelled on the retention engine, which is ALREADY a versioned, per-row,
  looped-per-sale, per-programme-idempotent template in the same function
  (v37b:666-683). Programme_id resolved INSIDE the trigger, never caller-supplied.
- **Tier fuel (recommended resolution of the one inherent dependency)**: tiers are
  measured by **lifetime points earned from the Points engine** (`entry_type='earn'`
  scoped to the points programme). A tiers-only firm still accrues points silently:
  points programme `accrues=true, customer_visible=false` — nothing to spend, no
  balance shown, ladder moves. Spending never demotes (lifetime earn is monotone).
  Stamps NEVER feed tiers (kills the stamps→tier→multiplied-stamps loop). Tier
  multiplier applies to points earning only.
- **Redemption dispatch keys on the REWARD's programme**, not the business mode:
  `loyalty_rewards`/`loyalty_reward_versions` gain `programme_id`; the catalog
  reader groups by programme; `redeem_reward_core` drains only the reward's
  programme balance (closes the cross-programme double-spend the money verifier
  proved in the redeem path, v34:570).
- **Expiry per programme**: expiry_mode/days move to the programme row; the sweep
  and its inactivity clock scope by programme_id.
- **Publish**: keep ONE version header (per-programme version kernels triple the
  publish machinery for no owner-visible gain). Editors/wizard constrain a draft to
  one programme's changes; unchanged programmes clone byte-identically, so publish
  is behaviourally per-programme. Two hardenings ride along: publish must not
  detonate outstanding redemption-intent QRs (settle intents against the version
  pinned at intent creation), and the publish impact preview must state tier-member
  movements when thresholds change (see Decisions).

### Stamp programme — the Stampede shape
- Earn becomes **one stamp per qualifying visit** (sale amount ≥ min-spend floor),
  replacing today's proportional `floor(amount/stamp_per_cents)` (v37b:653). The
  old semantic remains available as a per-programme option ("1 stamp per $X") but
  the default and wizard language follow the ruling.
- **Card/cycle entity** (new): stamps accrue into a card of N slots; milestone
  gifts at mid-card positions **unlock without consuming stamps** (today claiming a
  5-stamp gift FEFO-drains 5 stamps and resets progress — not Stampede's shape);
  card completes at N → final gift + fresh card. Named gifts already exist
  (`fulfillment_kind='manual_item'`, credit_cents=0, v27:55-59) — the catalogue and
  redemption record machinery is reused as-is.
- Customer card gets a true **ring-row stamp visual** (N rings, milestone rings
  marked) — no stamps branch exists in the wallet today at all.

### Gifts month-to-month
Claim windows (`claim_available_from/until`) already rotate read-time with no cron —
mechanically done. The workflow is what's missing: a **"This month's gifts" board**
(clone last month / swap gift / one-tap retire), ended gifts auto-archived off the
customer catalogue after their window (they linger as "Offer ended" cards today,
v176b:261-272), and an optional **total stock cap** per gift ("first 20 tote bags") —
today usage_limit is per-customer only, so a limited physical gift is unbounded
platform-side.

### Referral
Already structurally independent (fires on counts_as_visit; pays credit_ledger;
module-independent). Planned additions: **friend-side reward** (new credit_ledger
entry_type + write-guard branch + RPC/UI fields + v300 customer-card copy
"You get $X · your friend gets $Y"), **join-time referral capture** on the
self-serve QR join (v215's text-patch precedent makes this cheap: v215:471,487),
one-per-customer idempotency, an explicit **no-double-dip rule** with the welcome
offer (friend gets referral gift OR welcome offer — configurable, default referral
wins), and two clawback fixes the verifier proved: welcome-offer $0 redemption sale
currently **triggers referral qualification** (zero-revenue payout), and referral
reversal **re-arms the referral** for a second payout with no spent-credit guard
(v20:3443-3489).

## 4. Customer card — the stack (all three designs converged)

Tabs die. The business page renders a **vertical programme stack**, fixed order
**STAMPS → POINTS & GIFTS → TIER → REFERRAL** (predictability beats cleverness at a
counter), preceded by a **"Claimable now" action strip** (renders only when
something is actionable) and a standing **"Show my code" member QR** — the biggest
customer-side gap vs Stampede; today the only QRs are the one-time join scan and
per-reward intent QRs.

Card anatomy (identical three slots, ~140px each):
1. THE FIGURE — one number or the stamp ring-row (`.customer-programme-balance`).
2. THE SENTENCE — one line, second person: "3 more stamps and the next coffee is on
   us." / "1,240 points — 260 more for the tote bag." / "Gold. 400 more points to
   Diamond." / "2 friends joined. $8 credit each time."
3. ONE action or ONE disclosure — gifts sheet, tier ladder `<details>` (reused
   verbatim), Share code.

Hard rules carried over: exactly ONE card prints a raw point number (Points owns
it; Tier speaks only in distance — they are different numbers: spendable balance vs
lifetime earned); per-programme paused sentences preserved; no filler cards; one
programme live ≈ today's beauty, four live ≈ 1.5 thumb-scrolls.

## 5. Business setup — four switches, one rail

Screen one of the wizard becomes a **switchboard**: four independent toggles with
sector defaults preselected (F&B → Stamps; salon/beauty → Points+Tiers; fitness →
Tiers+Referral; retail → Points), one education line each, footer: *"You can turn
any of these on or off later, on their own. They don't affect each other."* — a
sentence that becomes true. Then one mini-rail per switched-on programme
(stamps 3 screens · points 3 · tiers 3 · referral 3), single running % across the
whole sequence, live per-programme customer-card preview beside every choice,
Stampede-grade defaults everywhere. Referral joins the wizard (free at the data
layer). The 12-row "integrity matrix" copy and all "Switch to this →" replacement
language are deleted. Tier rail prefills **Silver / Gold / Diamond** (today's seeds
say Gold/Platinum/Diamond in one place and Bronze/Silver/Gold in another — both
wrong vs the ruling); 3 tiers is the default the wizard produces, more remain
possible in the deep editor unless the owner wants a hard cap (see Decisions).

This slots into the previously-agreed first-run Setup Rail (brand → programmes →
welcome offer → outlet → **printable QR finale with "scan it now"**), preview-mode
question still open (Decision D6).

## 6. Migration waves (each ships alone, provably no-op until the unlock)

Constraints honoured: `on_sale_recorded` is maintained by text-patching the live
definition (v121 precedent) — wave bodies must follow that discipline; /app.js is
CDN-pinned 4h so server payload changes are additive-first; every wave gets the
full rolled-back production rehearsal + full-tenant diffs.

- **W0 — hotfixes** (§2) + PRODUCT-TRUTH/ledger updates recording the rulings.
- **W1 — read model, zero writes**: a view deriving the four programme flags from
  today's columns, mirroring customer_portal_capabilities exactly.
- **W2 — spine**: `business_programmes` + backfill + one-way sync trigger from
  legacy columns (legacy stays authoritative; drift impossible). Subtlety proven by
  audit: a `points_mode='tiers'` tenant's earn rate must land with the TIER
  programme's fuel, or its ladder silently stops. Guard trigger installed: refuses
  a second accruing programme until W5 removes it.
- **W3 — ledger tag**: programme_id on points_ledger/points_batches, NULLABLE;
  batched backfill through the write-guard escape (unambiguous while single-
  programme — that window closes at W5, which is why order matters); new
  `unique (sale_id, programme_id)` index created CONCURRENTLY **alongside** the old.
- **W4 — read-path flip + new customer stack**: capabilities per-programme, wallet
  readers, catalog grouped, tier metric filtered, liability + analytics scoped
  (`points_outstanding_total` and programme-overview counts break on the second
  programme row otherwise). Customer stack ships here — visual change only, tenants
  still single-programme. W4 also owns the CURRENTNESS GAP recorded in the V309
  evidence doc: the ledger tag follows the business's model at write time, so a
  switched firm's later offsetting rows (expiry/redeem/adjust, sale_id NULL) land on
  the new programme while old earns keep the old tag — the first per-programme
  balance reader must migrate the pot at switch time or read switched firms
  single-pot.
  DESIGN LOCKED 2026-08-13 (W4 design contract, workflow wf_80e3e488-edd): W4 splits
  into W4a (migration v310 — 9 readers gain additive per-programme payloads, the D1
  tier-fuel filter with a fail-open guard is the wave's ONLY behaviour change, and a
  pot-split detector ships fail-closed), W4b (the customer stack, gated on
  programmes_contract='v310' so a pre-v310 server renders today's tabs byte-identically
  through the CDN window), and W4c (the "Show my code" member QR — deferred because no
  member identity exists that the counter scanner can parse; its two RPCs and the
  nestly:member: scan branch are contract-pinned). Currentness policy (a) adopted:
  every spendable balance stays single-pot in W4; per-programme objects carry
  balance_scope='business_pot' which W5 flips by VALUE to 'programme_pot' after the
  pot migration; retagging history was rejected out loud (append-only ledger).
  Ship order: W4a alone and proven live, then W4b, then W4c.
- **W5 — write path**: index swap in ONE transaction; programme_id NOT NULL; earn
  loop (retention-engine template); tier multiplier scoped to points; the
  `on conflict do nothing` earn insert made constraint-explicit (it currently
  swallows ANY conflict and desyncs ledger/batches when looped); corrections
  (v84 assumes one earn row per sale), owner adjust, redemption reversal, and the
  expiry sweep all made programme-scoped. Double-fire idempotency rehearsal on all
  four tenant shapes; standing double-earn detection query ships with the wave.
- **W6 — independence unlock**: switchboard wizard + four editors, per-programme
  active flags replace points_mode writes (which today mutate the live business
  outside the version kernel), stamp per-visit semantics + card/cycle + milestone
  unlock, gifts board + stock caps, referral friend-side + join capture + double-
  dip + clawback guards, guard trigger removed. Landing page and marketing copy
  updated to the four-programme story.

W0 is days; W1–W4 are each small-to-medium, W5 is the money wave (ship alone),
W6 is the big UX wave. The Stampede-parity FEEL (setup rail, customer stack,
switchboard copy) arrives at W4/W6 without waiting on anything else; W5 is what
makes "more than one live" true.

## 7. Owner decisions — ALL APPROVED 2026-08-13

> Owner reply: "proceed with all recommendations." Every decision below is
> adopted as recommended. For D6 the standing recommendation from the Stampede
> onboarding analysis applies: **preview-before-payment** — a new business
> builds and previews its programme first and pays to go live. Recorded in
> `docs/product/PRODUCT-TRUTH.md`; the build begins at W0.

- **D1 Tier fuel**: confirm tiers = lifetime points EARNED via the points engine
  (silent accrual for tiers-only firms; stamps never feed tiers; refunds never
  demote). Recommended as stated in §3.
- **D2 Stamp milestones**: confirm Stampede shape — mid-card gifts unlock WITHOUT
  consuming stamps; card resets only at full. (Today's engine deducts on claim.)
- **D3 Threshold edits**: raising a tier threshold re-evaluates members immediately;
  the publish preview must state "N members would move down" and require explicit
  confirmation. (Alternative — grandfathering — is real machinery; not recommended
  for now.)
- **D4 Gift stock caps**: add optional total-quantity cap per gift? Recommended yes.
- **D5 Referral friend-side + self-serve join capture + no-double-dip default**:
  confirm both-sides referral.
- **D6 (carried over, still open)**: preview-before-payment vs payment-first for
  new business onboarding.
- **D7 Tier count**: hard-enforce exactly 3 tiers, or default 3 / allow more?
  Ruling says "3 tiers"; existing tenants may hold other counts. Recommended:
  wizard produces exactly 3; deep editor allows more; no retroactive enforcement.

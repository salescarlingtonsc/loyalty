# V295 — audit medium-severity closure

Date: 2026-08-12
Branch: `codex/v176-platform-superadmin`
Trigger: the re-run 6-lens product audit (27 agents, adversarial verification) scored the
product **8.4/10** and confirmed 17 findings — **5 medium, 12 low, 0 high**. This record covers
the five mediums. Every one was a localization or accessibility seam; none touched ledger
correctness, money movement, tenant isolation or data integrity.

## What the audit confirmed, and what changed

### M1 — merchant-authored copy was fetched in English and thrown away

`customer_get_promotions_v155` and `customer_get_home_offers_v167` both accept and *implement*
`p_locale in ('en','zh-CN')` (verified in production: the promotions RPC joins
`business_localized_copy_v95` on `copy.locale = p_locale` and both localize media alt via
`coalesce(asset.alt_zh_cn, asset.alt_en)`). Four call sites passed a hardcoded `'en'`, so a
zh-CN customer read Chinese programme presentation directly beside English-forced offers.

The fix is not four literals: the expression was **inlined**, which is exactly why four of the
five sites silently kept `'en'` when the wallet went multilingual in v293. All five now go
through one named helper, `merchantCopyLocale()` — one place to change when a merchant locale
is added, and one name for a reviewer to grep.

### M2 — the wallet was localized only at the shell

v293 translated the chrome, section states and scanner. The section *bodies* were still raw
English literals. Closed at the chokepoint where possible: `walletSectionShell` now translates
its title/description, so all six detail sections localize at one site rather than six, and the
translated title is what lands in `data-section-title` — meaning `walletSectionError`'s
"<title> didn't load" reads in the member's language too. Loyalty activity, gift-card states,
bottles, bookings actions and the full claim flow are routed through `ct()`.

### M3 — the PDPA consent surface was entirely English

`renderCustomerCommunicationsV263` contained **0** `ct()` calls inside a four-language wallet.
This is the screen where comprehension is legally load-bearing: consent a member cannot read is
not consent. The route now has 21 `ct()` calls covering headings, category/channel labels, the
master switch, and every `say()` status that feeds the live region; the profile-page consent
cluster (marketing choices, communications entry, consent history) is localized with it.

### M4 — raw provider strings reached users, untranslated

16 sites rendered `error.message` straight into a toast or an `.err` block. A customer
cancelling a booking on a dropped connection read the literal string `Failed to fetch`; a
Malay-locale merchant read bare snake_case Postgres codes — while the *same failure class* in
the platform console was already mapped and localized by `platformErrorMessage`.

Note that routing the raw text through `workspaceTranslationV97` alone does **not** fix this:
that helper ends in `??source`, so an unknown string passes through verbatim. `humanErrorV295`
decides instead — known provider/network strings get real sentences, machine codes are **never
shown** (one honest localized fallback replaces them), and sentences the backend deliberately
wrote for humans are shown and translated. The raw text always goes to `console.error`, so
debuggability is unchanged.

### M5 — the CRM board was keyboard-dead

Prospect cards are `<article>`/`<tr>` carrying `role="button"` + `tabindex=0`, so the browser
does not synthesize a click from Enter/Space. The Onboarding board wired `onkeydown`; `renderCrm`
did not. A keyboard or switch user focused an element announced as a button and nothing
happened. Both routes now share one activation path.

## Verification

- **Full suite: 2782/2782.** No known failures, no carve-outs.
- Locale parity is machine-checked, not asserted by eye: `CUSTOMER_COPY` now carries **149 keys
  in each of en / zh-CN / ms / ta**, and `tests/customer-wallet/v293-customer-wallet-localization.test.mjs`
  fails if any locale drops one.
- Test-pin updates are 1:1 premise changes (a pin asserting a hardcoded English literal now
  asserts the `ct()` call that replaced it). No assertion was weakened or deleted.
- Production RPC contracts re-verified by `pg_proc` query against `gadpooereceldfpfxsod`, not
  inferred from a checked-in list.

## Regenerated fixture provenance

- `tests/browser/reward-overview-owner-visual.html` production-source-sha256:
  `687f5add834fbeb2fcfe54f0db2a4b48b2732e98603566ea356e017bcd486438`
- `docs/qa/evidence/v142-connect-paynow-pos/metrics.json` **recaptured in real Chrome**
  (playwright-core driving `/Applications/Google Chrome.app`): status PASS, sourceHash
  `6d3cf421d4694a889e3d84a21b748739c9b36d8179b41210b71278333b80957a`, desktop 1440 and mobile
  390 both with `scrollWidth === clientWidth` (no horizontal overflow).
- `docs/qa/evidence/v104-promotions-production-render-metrics.json` recaptured in real Chrome:
  status PASS, sourceHash `044b6933228f7ec9ff0bf42a4eb730580c22843defeaa8b07938a169a79b12e8`.
- All ten `tests/browser/generate-*.mjs` fixtures regenerated from current production source.

## Evidence limits

This is deterministic local production-component browser evidence plus live production ACL and
RPC-contract queries. It does **not** include a signed-in end-to-end pass of the wallet in each
of the four locales against production data — the locale plumbing, key parity and render-site
routing are proven statically and by fixture, not by a human reading every screen in Tamil.

Known unrelated failure, unchanged and pre-existing on `origin/main`:
`tests/browser/verify-reward-overview-owner.mjs` (a manual walkthrough script, not part of
`npm test`) times out waiting for `#rewardJourneyTitle`. Verified identical on a clean
`origin/main` worktree, so it is not a regression from this work.

## Not closed here

The audit's 12 confirmed **low**-severity findings remain open and are deliberately out of this
record's scope — chiefly the ~26 English-only native `confirm()` dialogs in the business
workspace, `walletDate`'s `en-SG` pin, the `#main` skip-link on the console surface, the
client-only staff-delete guard, and the platform read-only guard's ageing selector list.

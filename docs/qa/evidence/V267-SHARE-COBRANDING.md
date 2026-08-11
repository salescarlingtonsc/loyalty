# V267 — a shared promotion is co-branded Peekaa × the firm (2026-08-10)

Owner: "you can put peekaa x (company name) - with our logos together."

Builds on [V264](V264-PROMOTION-SHARE.md), which shipped the share button itself.

## What ships

- **The share sheet opens with the pairing**: the Peekaa mark, a `×`, and the firm's own logo,
  with **"Peekaa × Cubbly"** written beneath them.
- **The outgoing message carries it too**, on its own line directly above the link:

  ```
  National Day: 50% off first prata at Cubbly · Valid 7 August 2026 – 31 August 2026
  Peekaa × Cubbly
  https://www.peekaa.asia/#/b/kopi-tiam-tyeh
  ```

  That is the shape a forwarded WhatsApp message is skimmed in: the offer reads first, the
  pairing is the last thing before the URL. The device share sheet gets the same message and
  "Peekaa × Cubbly" as its title.
- WhatsApp and Telegram send text, so they carry the co-brand. **Facebook's sharer takes a URL
  only** and cannot carry a message — that is Facebook's endpoint, not a gap here.

## Decisions worth recording

**Never half a lockup.** A firm that has not uploaded a logo gets its initial in the same circle,
and the Peekaa mark still renders. The alternative — dropping one side — would ship an
uncontrolled mixture of "Peekaa alone" and "the firm alone" depending on whether a logo happened
to exist.

**A nameless business degrades to "Peekaa", not "Peekaa × ".** No dangling operator.

**The marks are decorative (`alt=""`).** The line beneath them already names the pairing, so a
screen reader hears "Peekaa × Cubbly" once rather than three times.

**customer_visible is the boundary.** A share reaches strangers, so a logo the firm has not
published to customers is never used — the same rule every other customer surface follows, via
one shared lookup rather than a per-RPC reimplementation.

## The server change this needed

`customer_get_business_summary` — the RPC behind the programme page, where the Share button lives
— was the one customer projection that did not return the firm's logo. Without v267 the lockup
would have fallen back to the firm's initial for **every** business, on every share: co-branding
in name only.

Migration `db/migrations/20260810_nestly_v267_summary_business_logo.sql`, applied to production
`gadpooereceldfpfxsod`:

- `app.v267_business_logo_url(uuid)` — one definition of "this firm's customer-facing logo",
  reusing the v95 brand-presentation → media-asset → public-URL chain.
- `'logo_url'` added to **both** projections in the RPC: the live one and the all-modules-off
  fallback. A customer whose firm has every module switched off still sees a Share button, so the
  two must not disagree about who the business is.
- Grants restated (`revoke … from public, anon`). `CREATE OR REPLACE` preserves the grants an
  existing database has, so this changed nothing in production — it is there so a replay from an
  empty database lands in the same place.

## Verification

**Rolled back against production** (`db/tests/v267_summary_business_logo.sql`) — the helper agrees
with the canonical v95 media URL; an asset with `customer_visible = false` returns NULL; an
unknown business returns NULL rather than `''` or a broken path; `logo_url` appears in both
projections. All assertions passed, then the transaction was aborted.

**Rendered in headless Chrome at 390 px** from the real production function and the real CSS:

```
{"cobrand":"Peekaa × Cubbly",
 "marks":["loaded:/icons/peekaa-192.png","loaded:<firm logo>"],
 "channels":["whatsapp","telegram","facebook","copy"]}
```

Both marks report `naturalWidth > 0` — drawn, not merely present in the markup.
Screenshot: `v267-share-cobrand-390.png` (the firm's logo there is a stand-in image; production
serves the tenant's own).

**Tests**: `tests/customer-wallet/v264-promotion-share.test.mjs` — 21 assertions, 6 new for v267.
Full suite 2309 tests, 12 failures, all pre-existing at HEAD (baseline captured by stashing this
work and re-running); no new failures.

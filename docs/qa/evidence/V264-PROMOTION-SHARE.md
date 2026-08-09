# V264 — customers can share a promotion (2026-08-09)

Owner: "i need a share button for promotions - to share to social media / whatsapp / FB / IG /
tiktok/wechat/ telegram - so customers can help businesses to share."

## How sharing actually works, and why this is built this way

**Instagram, TikTok and WeChat have no web share endpoint.** Nothing a web page can link to will
post to them. The only route is the **device share sheet** (`navigator.share`), which lists every
app the customer has installed. So the share sheet is the primary action — on a phone it covers
all seven of the owner's channels and anything else they use.

**WhatsApp, Telegram and Facebook do publish real share URLs.** They get explicit buttons, so a
desktop browser (usually with no share sheet) still works instead of dead-ending.

**Copy link is always offered**, because it works everywhere, including apps with no endpoint.

No fake buttons: a channel is drawn only when the tap genuinely reaches it. The sheet says in
plain words where Instagram, TikTok and WeChat live rather than showing three buttons that
would do nothing.

## What ships

- **Share** on the promotion card (next to View offer / Terms) and in the offer sheet.
- Tapping it opens the OS share sheet where one exists; otherwise an in-app sheet with WhatsApp,
  Telegram, Facebook and Copy link.
- The message carries the offer — "National Day: 50% off first prata at Cubbly · Valid 7 August
  2026 – 31 August 2026" — because the destination page cannot show the offer yet.
- The link is always the **canonical** public origin (`https://www.peekaa.asia/#/b/<slug>`), never
  whatever host the app happens to be running on, and it opens a page a stranger can use without
  an account.
- A business with no public page is not shared at all; the customer is told why.
- Dismissing the OS sheet ends it. That is a decision, not an error, and it is not answered with
  a second sheet.

## What is recorded, and what is not

`customer.promotion_shared` on the existing product-adoption spine (v264 migration, applied to
production): **the business and the channel chosen** — device, whatsapp, telegram, facebook, copy.
Never the recipient, never the message, never whether the post was completed. The app cannot learn
any of that from the OS share sheet and does not pretend to. This is what makes the feature
countable for the businesses the owner wants it to help.

## Two guards that caught real mistakes before shipping

- **v123** — the app allows exactly ONE `navigator.clipboard.writeText`, inside a shared helper
  that disables the button, announces the result and reports a refusal honestly. My first version
  opened a second clipboard path. Corrected to use `copyTextToClipboard`.
- **v100** — interaction contexts are a closed allowlist of dimensions. `channel` was added
  deliberately, with the reason recorded: it is chosen from a list the app drew, so it can never
  carry customer-typed text.

## Verification

- `tests/customer-wallet/v264-promotion-share.test.mjs` — 15 tests executing the real functions:
  canonical link, slug encoding, refusal when there is no public page, the exact WhatsApp/Telegram/
  Facebook endpoints with everything encoded, IG/TikTok/WeChat never faked, native-first ordering,
  AbortError ending quietly, and that nothing about a recipient is recorded.
- `db/tests/v264_promotion_share_event.sql` — ran against production and rolled back: the taxonomy
  row's flags, and that re-applying the migration neither duplicates the row nor overwrites its
  description.
- `v264-promotion-share-390.png` — the card and the fallback sheet at 390px, from production
  functions and CSS.
- Suite: 2288 tests, 14 failures — the 13-failure baseline plus
  `v97-workspace-localization-acceptance:413`, a regression introduced by another session's
  v257–v262 commit (`pointCostDerivedV262.textContent` interpolates copy inside the workspace
  region). Confirmed pre-existing by stashing this work and re-running: it still fails. Left for
  the session that owns that surface.

## Known limitation

A shared link previews as generic Peekaa branding in WhatsApp/Facebook, not the offer's own image
and title, because per-offer Open Graph tags need a server-rendered page and this is a static SPA
shell. The message text carries the offer, so the share is still meaningful. A per-offer public
page (with OG tags and the artwork) is the natural follow-up.

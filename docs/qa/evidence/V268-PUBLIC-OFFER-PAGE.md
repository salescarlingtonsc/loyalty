# V268 — the public offer page: shared links preview the offer itself (2026-08-12)

Owner: "yes please build the public offer page."

Completes the share feature: [V264](V264-PROMOTION-SHARE.md) shipped the button,
[V267](V267-SHARE-COBRANDING.md) the co-branding, and this ships the page a shared link lands on.

## The problem being solved

The crawler WhatsApp/Facebook/Telegram send to unfurl a link **never runs JavaScript and never
authenticates**. Every route in the app is a hash route on one static `index.html`, so every
shared link previewed as generic Peekaa branding no matter what was shared. The only fix is a
page the **server** renders per offer.

## What ships

- **`/o/<offer-id>`** — a Vercel function ([app/api/offer-share.js](../../app/api/offer-share.js),
  rewired in `vercel.json` and its template) serving per-offer Open Graph tags:
  - `og:title` — "National Day: 50% off first prata — Peekaa × Cubbly"
  - `og:image` — the offer's **own artwork, uncropped** (the standing rule: merchant EDMs have
    words baked in; the platform's chat-card crop is theirs, not ours)
  - `og:description` — the merchant's tagline/description plus the canonical validity line
- For a human the same page shows the artwork, the co-branded lockup and a "View this offer"
  button, then steps into `#/b/<slug>` after 1.2 s. **No crawler sniffing** — crawlers stop at
  the tags because they don't execute script; humans continue because they do.
- **The share button now sends `/o/<id>`** (offer id URL-encoded); a share with no offer id
  still sends the business page, and a business with no public page still shares nothing.
- A dead, expired or unknown link **302s to the app home — a recipient is never 404ed.**

## The one deliberately anon-callable RPC

`public.offer_share_page_v268(uuid)` (migration applied to production). v14's rule is that anon
RPCs are the enemy; this one is the exception because the caller **is a link-preview crawler** —
it cannot hold a session and cannot solve a Turnstile. Bounded by construction:

- primary-key lookup only — no free-text predicate, nothing to enumerate with; offer ids are
  unguessable uuids the customer chose to broadcast;
- returns only broadcast marketing content — the same fields a verified customer's promotion
  list already carries, nothing else;
- **visibility mirrors `customer_get_promotions_v155` exactly** (active ∧ in window ∧ published
  unbranched artwork ∧ business has a slug), so unpublishing an offer kills its share links at
  the same moment it leaves the app;
- `STABLE` — a read that can never write; 5-minute edge cache absorbs a viral share.

The function also refuses to become an open image proxy: only `/storage/v1/object/public/...`
paths may become `og:image`.

## Verification

**Rolled back against production** (`db/tests/v268_offer_share_page.sql`): a live offer resolves
with name/slug/artwork; deactivating it, expiring it, or unpublishing its artwork each kills the
page (the offer-write guards were opened with their own transaction-local GUCs, inside the
rollback); unknown id → NULL; anon holds EXECUTE; function is STABLE. All passed, then rolled back.

**Anon REST probe** with the publishable key returned the live Cubbly offer; an unknown uuid
returned `null`.

**Handler exercised locally** (mocked request/response): live offer → 200 with the full tag set
above; unknown uuid → 302 `/`; `<script>` as id → 302 `/` (uuid gate, no fetch made).

**Tests**: 3 new in `tests/customer-wallet/v264-promotion-share.test.mjs` (27 total) covering the
handler's honesty rules, the rewrite in both vercel configs, and the RPC's visibility mirroring.
The phase-1 rewrites inventory was updated deliberately — `/o/:id` is the one route that must NOT
fall through to the SPA shell. Full suite 2312 tests / 12 failures, all pre-existing at HEAD.

**Live** (after deploy): `/o/b795f388-…` on www.peekaa.asia serves the offer's tags; see the
deploy-verification section of the session log.

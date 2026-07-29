# Customer Adoption Assessment

## Join friction

Customers do not need an App Store/Play Store download. The programme is mobile web/PWA and starts from a merchant QR.

First-use sequence:

```text
Scan business QR
→ create/sign in to Nestly
→ phone + chosen password
→ one phone OTP for account creation
→ required profile
→ automatic business link
→ merchant programme
```

Returning login uses the password or a registered passkey and does not send an OTP.

Strengths:

- the business context survives authentication;
- no second QR scan is required;
- no customer business-search/self-link flow;
- passkey support exists;
- subsequent businesses can be added by scanning their QR;
- 390px layout has no horizontal overflow and 44px controls.

Friction:

- first use combines phone, password, OTP and profile;
- under-20-second completion has not been measured;
- local/unsupported Turnstile origins block progression, correctly but visibly;
- a passkey is only useful after registration.

Recommendation: keep phone verification, but defer nonessential profile fields until after the first programme is visible. Ask for date of birth only when a birthday benefit is relevant/opted into.

## Value clarity

Merchant-specific programme surfaces show:

- logo/brand;
- programme name/promise;
- points or stamps;
- reward/tier progress;
- available rewards and eligibility;
- expiry/benefits where enabled;
- bookings where enabled;
- full transaction/points history.

Features the merchant does not enable are hidden. This avoids the demotivating “why does this business not offer that?” problem.

The remaining weakness is prioritisation: the actionable-wallet service computes a ranked action, but the successful home experience does not consistently lead with that action, reason and CTA.

## Reward attainability

The platform is flexible enough to create attainable or unattainable programmes. It does not yet strongly prevent poor owner choices.

Recommended guardrails:

- show spend/visits required for the first reward before publish;
- warn when expected time-to-first-reward exceeds 4–6 visits or 30–45 days for frequent retail/F&B;
- display owner-estimated reward cost and expected contribution;
- require an immediate joining value or first meaningful progress;
- simulate three customer examples before activation.

## Mobile experience

Customer mobile experience is a relative strength:

- PWA/mobile web;
- fixed bottom navigation;
- safe-area support;
- compact programme cards;
- profile menu rather than a permanent profile module;
- notification control;
- passkey support;
- camera-based join/redeem paths;
- no authenticated data cached offline.

The long merchant detail page can become heavy because it contains rewards, transactions, gift cards, packages, memberships, appointments, feedback, inbox, birthday and preferences. Replace this with a concise “Today” summary plus progressive history/details.

## Communication relevance

The data model supports consent and preferences, but there is no verified real outbound campaign path. Therefore customer relevance has not been proven.

Before launch of promotions, enforce:

- marketing consent and channel permission at queue and send;
- quiet hours in Singapore time;
- per-business and global frequency caps;
- cross-outlet duplicate suppression;
- cancellation if the customer already purchased;
- cancellation if the offer expired/became unavailable;
- preferred language and channel;
- one-tap opt-out;
- reason transparency (“You usually visit every 2 weeks…” without exposing sensitive profiling).

## Trust

Strong trust features:

- customer does not self-link to arbitrary businesses;
- balances change only on server-confirmed actions;
- reward QR is pending until merchant scan;
- branch/role eligibility is rechecked at redemption;
- histories include corrections and point changes;
- birthday participation is separated from marketing;
- date of birth is not shown to the merchant;
- privacy/terms/data request links are present.

Trust gaps:

- first-time counter marketing consent wording is too easy to treat as a staff checkbox;
- provider delivery/opt-out enforcement is unproven;
- customer profile merge/data correction is limited;
- unsupported refunds may make customer and merchant histories diverge operationally until manual resolution.

## Gamification and repeat engagement

Appropriate existing elements:

- progress/milestones;
- rewards and tiers;
- time-limited expiry notices;
- birthday benefits;
- programme branding;
- points-earned/redeemed feedback;
- game-style local notification foundations.

Avoid indiscriminate sounds/animations. Recommended ethical pattern:

- subtle haptic/sound only after a confirmed earn or redemption and subject to device/user preference;
- celebration tied to real value, not spending pressure;
- progress and expiry clearly explained;
- no fake urgency;
- no streak loss that encourages harmful overspending.

Recommended customer “Today” screen:

1. selected merchant and current progress;
2. one next-best action;
3. nearest attainable reward;
4. upcoming booking;
5. genuinely new/expiring benefit;
6. history/details behind one tap.

## Application-download dependency

**No mandatory native application download.** This satisfies the central adoption principle. A PWA install is optional.

Missing low-friction alternatives:

- Apple Wallet pass;
- Google Wallet pass;
- payment-linked identity;
- receipt-linked joining;
- WhatsApp deep-link identity/re-engagement.

These are not all required immediately. Prioritise verified web QR + one outbound channel first.

## Why customers may ignore or abandon the programme

1. First-time setup takes too long at the counter.
2. The first reward appears too distant.
3. No timely relevant message brings them back.
4. The home page shows balances but not the clearest next action.
5. A refund or correction does not match their expectation.
6. They already have too many loyalty programmes and Nestly provides no immediate cross-business advantage.
7. They do not trust marketing consent or data use.

## Customer score

**70/100.**

This is high enough for a limited pilot because the mobile web, wallet, programme clarity and redemption trust are strong. It is not best-in-class until first-use speed, next-action presentation, real communications and refund consistency are proven.


# V296 — the avatar menu is gone; its contents moved where they belong (2026-08-13)

Owner, three annotated screenshots:
"remove this — here got profile already" (the header avatar) ·
"put here" (device notifications → the Messages page) ·
"Sign out put here" (→ under Account & privacy on Profile).

## What changed

The header avatar opened a menu holding three things. Since v281 made **Profile** a first-class
nav tab, that menu was a second door to a place the navigation already owns — and it hid two real
actions behind a tap. All three items were rehomed rather than deleted:

| Menu item | Where it went | Why there |
|---|---|---|
| Profile & passkeys | **removed** | the Profile tab is the door |
| Turn on device notifications | **Messages page** | it governs whether inbox updates also reach the lock screen — it belongs beside the inbox |
| Sign out | **last card on Profile** | reached by finishing the page, not by hunting an icon |

The header now carries the wordmark and the notification bell, nothing else.

**The one screen that keeps a header sign-out** is the first-programme quest — a customer with an
account who has joined no business yet. It has no navigation bar, so that button is the only way
out; it stays, but as a plain button, not the avatar menu. "Profile & passkeys" was dropped there
too: there is nothing to open yet.

## Deliberate details

- The Messages control is hidden in the native iOS shell, which cannot do web push — the same
  honesty rule as v295.
- Sign out runs the identical teardown the header button did (`killChannels()`, `signOut()`,
  `resetClientSessionState()`), so nothing about session hygiene changed with its position.
- The dead CSS went with it (`.customer-account-menu`, `.customer-avatar`, and their dark-mode
  overrides), and the push-state colour was re-scoped to the control itself so it survives.
- Escape handling died with the menu's hand-rolled listener; every customer dialog has used
  `CUI.activateDialog` since v286, which owns focus trap, Escape and Android Back centrally.

## Verified at 390 px in Chromium, from the real extracted markup and CSS

`{"headerControls":["peekaa","Notifications"],"avatarGone":true,`
`"navSlots":["Home","Rewards","Scan QR","Bookings","Profile"],"pushCardCols":1,`
`"signOutLast":true,"noOverflow":true}`

Screenshot: `v296-profile-signout-390.png`. Suite 2793/2793; five stale pins across four files
moved deliberately (they asserted the menu that no longer exists), plus a new pin file
`tests/customer-wallet/v296-header-menu-removed.test.mjs`.

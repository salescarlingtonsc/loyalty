# Publishing Peekaa to the iOS App Store — the owner's runbook

Everything on the code side is done and verified. What remains needs **your** Apple identity, so
this is written as steps you perform, with the exact commands where a command exists.

**Decision this runbook assumes** (see `docs/qa/evidence/V295-STORE-READINESS.md` for why):
the App Store app is the **customer** app. Businesses use the web workspace, installed to their
Home Screen. One database underneath, so nothing about sync changes.

---

## Before you start — what is already true

- Bundle id **`asia.peekaa.app`**, app name **Peekaa** (`capacitor.config.ts`).
- `npm run mobile:store:validate` **passes**: icons, and the Apple-required third-party privacy
  manifests. It fails closed, so a pass means something.
- Camera permission carries a reviewer-readable reason (Info.plist `NSCameraUsageDescription`).
- The backend already trusts the native origins (`capacitor://localhost`), so joining, booking
  and Turnstile work inside the app.
- Business sign-up and subscription purchase are **deliberately absent** in the native shell —
  Apple requires digital subscriptions sold in-app to use their payment system, so Peekaa sells
  only on the web. Owners see a "companion" screen explaining it.

---

## Step 1 — Enrol in the Apple Developer Program (you)

<https://developer.apple.com/programs/> — US$99/year, individual or organisation.
Organisation enrolment needs a D-U-N-S number and takes longer; individual is same-day-ish.

You will end up with a **Team ID** (10 characters, e.g. `A1B2C3D4E5`). Keep it.

## Step 2 — Create the app record

App Store Connect → **My Apps → + → New App**

| Field | Value |
|---|---|
| Platform | iOS |
| Name | Peekaa |
| Primary language | English (Singapore) or English (U.K.) |
| Bundle ID | `asia.peekaa.app` — register it in the Developer portal first if it is not listed |
| SKU | anything internal, e.g. `peekaa-customer-001` |

## Step 3 — Build and upload (on this Mac)

```bash
cd /Users/cs/Downloads/loyalty-main && npm run mobile:sync && npm run mobile:open:ios
```

That refreshes the web bundle into the iOS project and opens Xcode. Then, in Xcode:

1. Select the **App** target → **Signing & Capabilities** → tick *Automatically manage signing*
   and choose your Team. Xcode creates the provisioning profile.
2. Set the **Version** (1.0.0) and **Build** (1).
3. Choose **Any iOS Device (arm64)** as the destination — not a simulator.
4. **Product → Archive**, then **Distribute App → App Store Connect → Upload**.

The build appears in App Store Connect after 10–30 minutes of processing.

## Step 4 — TestFlight first. Do not skip this.

App Store Connect → your app → **TestFlight** → add yourself as an internal tester. Install on
your own iPhone and run the real journeys for a few days:

- scan a business QR → join → see the programme;
- have a staff member record a sale → confirm the balance updates while you watch (v295);
- book, then withdraw the request (v290);
- share an offer → confirm the phone's own share sheet appears (v286).

## Step 5 — Store listing

- **Screenshots**: take the largest iPhone size the upload panel asks for — Apple has moved the
  required set to the 6.9" display (1290×2796 is still accepted, 6.5" no longer required), and it
  scales the rest down for you. Treat App Store Connect's own panel as authoritative on the day
  rather than this line. Take them on your device or
  the simulator: Home, My Rewards, an offer, Bookings, Profile.
- **Description**: lead with the customer benefit — real spendable rewards at shops you already
  visit, no plastic cards. Mention that businesses subscribe separately at peekaa.asia.
- **Support URL** and **Privacy Policy URL**: use the live pages the app already links to.
- **App Privacy questionnaire**: you collect **name, phone number, email** linked to the user,
  used for *App Functionality*. You do **not** track users across other companies' apps, so
  answer "No" to tracking. Camera is used only for QR scanning and is not collected.
- **Age rating**: 4+.

## Step 6 — The reviewer's demo account (this is where apps get rejected)

Apple must be able to use the app fully without a business relationship. In **App Review
Information → Sign-In Required**, give them a **customer** account, not a merchant one:

- create a normal customer account on a spare number, join the demo tenant (Cubbly) so the
  reviewer lands on a populated wallet rather than an empty one;
- in **Notes**, write plainly: *"Peekaa is a loyalty app for shoppers. Businesses subscribe on
  peekaa.asia; no purchases are offered inside the app. The account above is a customer account
  with an active rewards programme."*

Do not hand them a business login — they will hit the "subscription changes are not available in
this app" screen and ask questions you do not need to answer.

## Step 7 — Submit

Select the TestFlight build, answer the export-compliance question (Peekaa uses only standard
HTTPS: answer **Yes** to encryption, then **Yes** to "exempt"), and submit. First review is
typically 24–48 hours.

---

## After approval

**Universal links** (optional, do it in week 2): with your Team ID,

```bash
APPLE_TEAM_ID=YOURTEAMID npm run mobile:store:associations
```

generates the `apple-app-site-association` file; serve it from the website so `peekaa.asia` links
open in the app. The generator refuses to emit placeholder identifiers, so it either produces the
real file or tells you what is missing.

**Every future release**: `npm run mobile:sync` → bump Build → Archive → Upload → submit. The
web/PWA side updates instantly; the App Store app updates per submission.

**Freeze rule, from launch day onwards**: once a binary is in the store it is a *snapshot* of the
web code. Never change the shape of an existing RPC that a shipped app calls — add a new
versioned one instead (`..._v268`, `..._v290`, the house habit already). That is what keeps old
installs working.

---

## Known limitation to schedule, not to fix before launch

**Lock-screen push does not fire inside the iOS app.** Peekaa's push is *Web Push*, which Apple
delivers to Home-Screen web apps but **not** inside an app's WebView. Native push needs Apple's
APNs: a `.p8` key from your developer account, the Push Notifications capability in Xcode, and a
sending path in the dispatcher.

It is deliberately **not** in the first build: the key does not exist until Step 1 is done, and
shipping an untested entitlement into a first App Review invites problems. Customers still get
everything in the in-app inbox, and the app now says so honestly instead of hiding the setting
(v295). Once you are enrolled, this is a contained piece of work — send me the Team ID and Key ID
and it goes into build 2, tested through TestFlight.

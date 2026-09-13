# Publishing Peekaa to Google Play — the owner's runbook

The companion to `IOS-APP-STORE-RUNBOOK.md`. Same app, same `dist/mobile` bundle, same database —
only the store, the signing model and the toolchain differ. Everything on the code side is done and
verified; what remains needs **your** Google identity and a keystore that must never enter git.

**Same decision as iOS**: the store app is the **customer** app. Business sign-up and subscription
purchase are absent in the native shell (`Capacitor.isNativePlatform()`, not an iOS-only check, so
the suppression already covers Android) — Google Play's payments policy is the same as Apple's, and
Peekaa sells only on the web.

---

## Before you start — what is already true

- Package **`asia.peekaa.app`**, label **Peekaa**, `versionName 1.2` (kept equal to the iOS
  `MARKETING_VERSION` — `npm run mobile:store:validate` refuses a drift), `versionCode 1`.
- `minSdk 24`, `target/compileSdk 36` — above Play's API 35 floor for new submissions.
- Cleartext traffic is off; the only permissions are `INTERNET` and `CAMERA` (QR scanning).
- The edge gateway already trusts the Android WebView origin `https://localhost`
  (`supabase/functions/_shared/validation.ts`), so joining, booking and Turnstile work in the app.
- Customer sign-in is phone OTP, so Android needs **no** extra Supabase redirect-URL configuration.
- Customers can delete their own account in-app (v749) — that is the Data Safety answer Play wants.
- Launcher icons are Peekaa's at every density; the 512 × 512 listing icon is
  `app/icons/peekaa-512.png`.

## Step 0 — Install the toolchain (this Mac has none of it)

There is no JDK and no Android SDK here, so no bundle can be built until this is done. Install
Android Studio, which brings its own JDK and SDK manager:

```bash
brew install --cask android-studio
```

Open it once and let the setup wizard install the SDK and accept the licences, then:

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
```

Put those two lines in `~/.zshrc`. Verify with `java -version` (expect 21) and
`ls "$ANDROID_HOME/platforms"`.

## Step 1 — Google Play Console account (you)

<https://play.google.com/console/signup> — **US$25 once**, not yearly.

Choose the account type deliberately, because it changes the launch timeline:

| | Personal | Organisation |
|---|---|---|
| Verification | ID document | D-U-N-S number, takes longer |
| **Closed test before going public** | **20 testers, 14 continuous days** | not required |

⚖️ That closed-testing requirement applies to personal developer accounts and is the single
biggest scheduling fact on this page — it is weeks, not days. If Peekaa is registered as a company
and you have or can get a D-U-N-S number (the same one an Apple organisation enrolment uses),
an organisation account skips it entirely. Treat the Console's own wording on the day as
authoritative; Google moves these rules.

## Step 2 — Create the upload key (once, and never lose it)

Play App Signing means Google holds the *app* signing key; you hold an *upload* key that only
proves the bundle is from you. Losing it is recoverable through support; losing it before you
enrol in Play App Signing is not.

```bash
cd /Users/cs/Downloads/loyalty-main/android
keytool -genkeypair -v -keystore peekaa-upload.jks -alias peekaa-upload \
  -keyalg RSA -keysize 2048 -validity 10000
```

Then create `android/keystore.properties` from the template beside it:

```
storeFile=peekaa-upload.jks
storePassword=…
keyAlias=peekaa-upload
keyPassword=…
```

Both files are git-ignored, and the test suite asserts they stay ignored. Back the `.jks` and the
passwords up somewhere that is not this laptop — a password manager, not a folder.

The build reads that file, or the `PEEKAA_UPLOAD_STORE_FILE` / `_STORE_PASSWORD` / `_KEY_ALIAS` /
`_KEY_PASSWORD` environment variables for CI. With neither present the release build simply
carries no signing config, and Play rejects the upload with a clear message rather than a silent
one.

## Step 3 — Build the bundle (on this Mac)

```bash
cd /Users/cs/Downloads/loyalty-main && npm run mobile:store:validate && npm run mobile:sync && (cd android && ./gradlew bundleRelease)
```

`mobile:sync` refreshes `dist/mobile` into `android/app/src/main/assets/public`. The artifact is

```
android/app/build/outputs/bundle/release/app-release.aab
```

Play takes the **.aab**, not an APK. To smoke-test on a real phone first, `./gradlew assembleDebug`
and install `app-debug.apk` over USB.

## Step 4 — Create the app record and upload

Play Console → **Create app**: name *Peekaa*, default language English (Singapore), **App**, **Free**.

Then **Release → Testing → Internal testing → Create new release** and upload the `.aab`. Internal
testing reaches your own testers within minutes and does not consume the 14-day clock — use it to
prove the build runs before you start a closed test that you cannot pause.

Play Console will ask to **enrol in Play App Signing** on the first upload. Accept.

## Step 5 — Test on a real device. Do not skip this.

Same journeys as the iOS runbook, on Android:

- scan a business QR → join → see the programme;
- have a staff member record a sale → the balance updates while you watch (v295);
- book, then withdraw the request (v290);
- share an offer → the Android share sheet appears (v286);
- press the **hardware back button** on every screen — this has no iOS equivalent and is the one
  behaviour the App Store review never exercised.

## Step 6 — App content declarations (this is where Play submissions stall)

Play Console → **Policy → App content**. Every item must be green before you can promote a release:

- **Privacy policy URL** — the live page the app already links to.
- **Data safety** — collected and linked to the user: *name, phone number, email*, for App
  Functionality; **no** sharing with third parties; **no** advertising or tracking. Camera is used
  for QR scanning and not collected. Answer **yes** to "users can request account deletion" and
  give the in-app route plus `admin.peekaa@gmail.com`.
- **Content rating questionnaire** — answer honestly; Peekaa lands at *Everyone / PEGI 3*.
- **Target audience** — 18+ (or 13+); **not** designed for children, so no Families policy.
- **Ads** — no ads.
- **Government apps**, **Financial features** — no. Peekaa's stored value is in-store credit
  recorded in the ledger, not a payment instrument, and nothing is purchased inside the app.
- **App access** — Play's equivalent of Apple's demo account. Give a **customer** login on a spare
  number joined to the demo tenant (Cubbly), with the same note: *"Peekaa is a loyalty app for
  shoppers. Businesses subscribe on peekaa.asia; no purchases are offered inside the app."*
  Do not hand them a business login.

## Step 7 — Store listing

- **App icon**: `app/icons/peekaa-512.png` (512 × 512).
- **Feature graphic**: 1024 × 500 PNG/JPG — **does not exist yet**, and Play will not publish
  without it. It is a banner, not a screenshot.
- **Phone screenshots**: at least 2, up to 8, 16:9 or 9:16, min 320px — Home, My Rewards, an offer,
  Bookings, Profile. Take them from the emulator or your phone.
- **Short description** (80 chars) and **full description** (4000) — lead with the customer
  benefit, real spendable rewards at shops you already visit, no plastic cards. Mention that
  businesses subscribe separately at peekaa.asia.
- **Category**: Lifestyle (or Shopping). **Contact email**, and the same support URL as iOS.

## Step 8 — Promote to production

Internal testing → closed testing (if your account type requires it) → production. First review of
a new developer account is typically a few days, longer than Apple's.

---

## After approval

**App Links** (the Android half of universal links). The manifest already claims
`https://www.peekaa.asia/*` with `autoVerify`, but verification fails until the website serves the
matching file. Once Play App Signing exists, copy the **SHA-256 certificate fingerprint** from
Play Console → *Release → Setup → App signing* — the *app signing key*, not the upload key — and:

```bash
APPLE_TEAM_ID=7P44JG77UF ANDROID_SHA256_CERT_FINGERPRINT=AA:BB:… \
  npm run mobile:store:associations -- --output tmp/associations
```

Copy the generated `assetlinks.json` to `app/.well-known/assetlinks.json` and deploy; it is then
served at `https://www.peekaa.asia/.well-known/assetlinks.json` (where it currently 404s). The generator emits both association files at once and refuses placeholder identifiers, so it either emits the real file or says what is
missing.

`www` only, deliberately, for the same reason as the iOS AASA: the apex 308-redirects to `www` and
neither Apple's nor Google's verifier follows redirects.

**Every future release**: `npm run mobile:sync` → bump **`versionCode`** (Play refuses a reused
one) → keep `versionName` equal to the iOS `MARKETING_VERSION` → `./gradlew bundleRelease` →
upload. The web/PWA side updates instantly; the store app updates per release.

**Freeze rule, unchanged from iOS**: a shipped binary is a snapshot of the web code. Never change
the shape of an existing RPC that a shipped app calls — add a new versioned one instead.

---

## Known limitation, same as iOS

**Lock-screen push does not fire inside the Android app.** Peekaa's push is Web Push, which the
Play build's WebView does not deliver. Native push needs Firebase Cloud Messaging: a Firebase
project, `android/app/google-services.json` (the Gradle file already applies the plugin when that
file appears), `@capacitor/push-notifications`, and a sending path in the dispatcher. Deliberately
not in the first build, for the same reason it is not in the first iOS build. Customers still get
everything in the in-app inbox.

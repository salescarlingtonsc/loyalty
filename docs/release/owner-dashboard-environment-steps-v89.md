# Owner dashboard and environment steps — v89

These are owner actions for the reviewed release window. They are not performed
by local builds or tests. Record screenshots or exported settings as release
evidence without copying secret values into Git.

## 1. Public Edge gateway origins

In Supabase Dashboard, open the `loyalty` project, then **Edge Functions →
Secrets**.

1. Set `PUBLIC_GATEWAY_ALLOWED_ORIGINS` to the exact comma-separated value:
   `https://nestly.asia,https://www.nestly.asia`.
2. Do not use `*`, paths, trailing routes, credentials, or an HTTP production
   origin. Preview/staging origins are additive and must be individually
   reviewed.
3. Confirm these existing secrets are present without revealing their values:
   `PUBLIC_GATEWAY_IP_PEPPER`, `PUBLIC_GATEWAY_TOKEN_SECRET`,
   `TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET_KEY`, and the project publishable-key
   binding used by the public gateway.
4. Deploy the reviewed versions of `public-join`, `public-booking`, and
   `manage-booking` with JWT verification disabled because these three handlers
   implement their own exact-origin, Turnstile, rate-limit and capability
   controls.

The shared code always trusts only the two canonical Nestly HTTPS origins even
if the environment value is accidentally empty. The environment value remains
explicit operational evidence and is the only way to add a reviewed preview
origin.

After deployment, run both checks:

```sh
curl -i -X OPTIONS \
  -H 'Origin: https://www.nestly.asia' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type,apikey,authorization' \
  'https://gadpooereceldfpfxsod.supabase.co/functions/v1/public-join'

curl -i -X OPTIONS \
  -H 'Origin: https://attacker.invalid' \
  -H 'Access-Control-Request-Method: POST' \
  'https://gadpooereceldfpfxsod.supabase.co/functions/v1/public-join'
```

The first response must be `204` with
`Access-Control-Allow-Origin: https://www.nestly.asia`. The hostile origin must
remain `403` with no allow-origin header. Repeat for `public-booking` and
`manage-booking`.

## 2. Production mobile OTP

Before deployment, confirm `config/runtime/production.json` contains
`"customerPhoneOtpEnabled": true`, regenerate `app/runtime-config.js` through
the repository runtime-config generator, and run its `--check` mode. This is a
public availability switch, not a provider secret or an authentication bypass;
the fresh database capability response and hosted Auth provider must also allow
the transport.

In Supabase Dashboard, open **Authentication → Providers → Phone**.

1. Confirm the Twilio production provider is enabled with the intended sender.
2. Remove every hosted **Test OTP** entry, including any prior demo phone.
   Production must not use `888888` or any other fixed OTP.
3. Keep phone auto-confirm disabled; possession is proved by the received OTP.
4. In **Authentication → Attack Protection → CAPTCHA**, confirm Cloudflare
   Turnstile is enabled with the production secret matching Nestly's public site
   key.
5. Confirm the private platform feature flags for customer phone registration
   and customer phone OTP are enabled only when the provider is ready.

The tracked `supabase/config.toml` intentionally contains no
`[auth.sms.test_otp]` section, so a normal CLI config push cannot restore a
fixed OTP. Do not add one to the tracked project config and do not use
`supabase config push` as a substitute for the reviewed Auth settings above.
Fixed OTPs may be used only in a separate disposable non-production Supabase
project whose configuration cannot target the Nestly production project.

Acceptance evidence must use a real Singapore mobile on the final
`https://www.nestly.asia` build: request one SMS, reject one wrong code, accept
the received code, finish profile registration, sign out, and sign in again.
Do not record the OTP or full phone number in the evidence.

## 3. Passkey follow-up

After OTP succeeds, confirm the customer can enroll a passkey on a physical
iPhone and later sign in with Face ID. Configure the stable relying-party ID as
`nestly.asia` with both exact Nestly HTTPS origins before enrolling production
credentials. Changing the relying-party ID later invalidates enrolled
passkeys.

## Stop conditions

Do not release while any canonical gateway preflight is `403`, any hostile
origin receives an allow-origin header, a hosted fixed test OTP remains, or the
real-device OTP/passkey acceptance evidence is incomplete.

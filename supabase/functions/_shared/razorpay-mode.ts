/* nestly_v790 — which Razorpay account a request talks to.

   Owner ruling (2026-09-05): a demo account "looks exactly as how live account will look like …
   backend no money enter our system". Once the platform keys are LIVE, that can only be true if a
   demo firm's checkout, commands and events go to the TEST account instead. So there are two
   credential sets:

     live  — RAZORPAY_KEY_ID / RAZORPAY_KEY_SECRET / RAZORPAY_WEBHOOK_SECRET (the platform's keys;
             before go-live these are themselves test keys, and everything below still holds)
     test  — TEST_KEY_ID / TEST_KEY_SECRET / TEST_WEBHOOK (the sandbox, kept for demo firms)

   The mode for a COMMAND is decided by the business the command belongs to (businesses.is_demo).
   The mode for an inbound WEBHOOK is decided by which secret verifies the signature. The mode for
   a checkout RETURN is decided by which key secret verifies the redirect signature. Nothing here
   ever falls back from live to test silently: a missing test set means demo firms use the
   platform keys, which is announced in the log so an operator can see money would move. */

import { livemodeFromKey, razorpayClient } from './razorpay-client.ts';

export type RazorpayMode = 'live' | 'test';

export type RazorpayCredentialSet = {
  mode: RazorpayMode;
  keyId: string;
  keySecret: string;
  /* true when the KEY is a live key (rzp_live_…); the platform set can be test before go-live */
  livemode: boolean;
  /* the sandbox set is only "test" when it actually exists; otherwise the platform set is reused */
  sandboxAvailable: boolean;
};

function env(name: string): string {
  return (Deno.env.get(name) || '').trim();
}

export function razorpayCredentials(mode: RazorpayMode): RazorpayCredentialSet {
  const liveId = env('RAZORPAY_KEY_ID');
  const liveSecret = env('RAZORPAY_KEY_SECRET');
  if (!liveId || !liveSecret) throw new Error('billing service unavailable');
  const testId = env('TEST_KEY_ID');
  const testSecret = env('TEST_KEY_SECRET');
  const sandboxAvailable = Boolean(testId && testSecret);
  if (mode === 'test' && sandboxAvailable) {
    return {
      mode: 'test',
      keyId: testId,
      keySecret: testSecret,
      livemode: livemodeFromKey(testId) === true,
      sandboxAvailable,
    };
  }
  return {
    mode: 'live',
    keyId: liveId,
    keySecret: liveSecret,
    livemode: livemodeFromKey(liveId) === true,
    sandboxAvailable,
  };
}

export function razorpayClientFor(credentials: RazorpayCredentialSet) {
  return razorpayClient({ keyId: credentials.keyId, keySecret: credentials.keySecret });
}

/* A demo firm talks to the sandbox. Unreadable is treated as NOT demo: the failure mode of
   guessing "demo" for a real firm would be a real customer whose payment never happened. */
export async function razorpayModeForBusiness(
  admin: { from: (table: string) => any },
  businessId: string,
): Promise<RazorpayMode> {
  try {
    const { data, error } = await admin
      .from('businesses')
      .select('is_demo')
      .eq('id', businessId)
      .maybeSingle();
    if (error) return 'live';
    return data?.is_demo === true ? 'test' : 'live';
  } catch {
    return 'live';
  }
}

/* The webhook secrets, labelled. Order matters only for the log: the platform's current secret,
   its previous one during a rotation (v759), then the sandbox's. */
export type WebhookSecretCandidate = {
  label: 'current' | 'previous' | 'test';
  secret: string;
  livemode: boolean;
};

export function webhookSecretCandidates(): WebhookSecretCandidate[] {
  const platformLivemode = livemodeFromKey(env('RAZORPAY_KEY_ID')) === true;
  const out: WebhookSecretCandidate[] = [
    { label: 'current', secret: env('RAZORPAY_WEBHOOK_SECRET'), livemode: platformLivemode },
    { label: 'previous', secret: env('RAZORPAY_WEBHOOK_SECRET_PREVIOUS'), livemode: platformLivemode },
    { label: 'test', secret: env('TEST_WEBHOOK'), livemode: false },
  ];
  return out.filter((candidate) => candidate.secret);
}

/* The plan id to send for a catalogue row, in the mode the request is running in. The catalogue
   carries the LIVE id in provider_base_price_id and the sandbox id in provider_test_price_id
   (v790); a test-mode request with no sandbox id recorded falls back to the base id, which is
   right before go-live (both columns hold test ids then) and loudly wrong after it (Razorpay
   answers 400 for an unknown plan, which the command records as failed). */
export async function planIdForMode(
  admin: { from: (table: string) => any },
  cataloguePlanId: string,
  credentials: RazorpayCredentialSet,
): Promise<string> {
  if (!cataloguePlanId || credentials.livemode) return cataloguePlanId;
  try {
    const { data, error } = await admin
      .from('billing_capacity_tier_catalog_v664')
      .select('provider_test_price_id')
      .eq('provider_base_price_id', cataloguePlanId)
      .limit(1)
      .maybeSingle();
    if (error) return cataloguePlanId;
    const testId = String(data?.provider_test_price_id || '').trim();
    return testId || cataloguePlanId;
  } catch {
    return cataloguePlanId;
  }
}

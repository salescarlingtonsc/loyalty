import { billingAdminClient, billingJson, requiredEnv } from '../_shared/billing-service.ts';
import { verifyCheckoutSignature } from '../_shared/razorpay-client.ts';
import { razorpayClientFor, razorpayCredentials, type RazorpayCredentialSet } from '../_shared/razorpay-mode.ts';
import { recoverProviderSubscription } from '../_shared/razorpay-provider-recovery.ts';

/* nestly_v755 — Razorpay Checkout's callback_url target.

   This function turns a provider redirect back into one of our own routes. Since nestly_v774 it
   also reads the named subscription back from Razorpay and mirrors any PAID invoice through the
   same pipeline the webhook feeds (see the synthesis block below) — the redirect itself is still
   never believed. A redirect is not a payment: the browser can be closed before it fires, it can
   be replayed, and its signature proves only that Razorpay produced it — never that money moved.
   subscription.charged on the webhook is the sole source of payment truth, exactly as
   invoice.paid was under Stripe. The signature check here is about not honouring a FORGED
   redirect, not about believing a genuine one. */

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function returnOrigin(): string {
  const configured = new URL(requiredEnv('BILLING_RETURN_ORIGIN'));
  if (
    configured.protocol !== 'https:' ||
    configured.username ||
    configured.password ||
    configured.pathname !== '/' ||
    configured.search ||
    configured.hash
  ) {
    throw new Error('billing service unavailable');
  }
  return configured.origin;
}

/* nestly_v764 — a card change comes back through this same callback (Razorpay Checkout in
   `subscription_card_change` mode still posts payment_id / subscription_id / signature), but it
   is not a signup and not a payment: it belongs on the settings page saying the card was
   updated. `mode=card` rides in the callback URL the command built. It is only a ROUTING hint —
   the signature check below is unchanged, so the worst a tampered `mode` can do is send a
   verified return to the wrong one of our own two settings routes. */
function cardRoutes(origin: string) {
  return {
    success: `${origin}/#/settings?billing=card_updated`,
    cancel: `${origin}/#/settings?billing=canceled`,
  };
}

function routes(origin: string, selfServe: boolean) {
  return selfServe
    ? {
      success: `${origin}/business#/onboarding/payment?status=processing`,
      cancel: `${origin}/business#/onboarding/payment?status=canceled`,
    }
    : {
      success: `${origin}/#/settings?billing=processing`,
      cancel: `${origin}/#/settings?billing=canceled`,
    };
}

function seeOther(location: string): Response {
  return new Response(null, {
    status: 303,
    headers: { location, 'cache-control': 'no-store' },
  });
}

async function readFields(req: Request): Promise<Record<string, string>> {
  const url = new URL(req.url);
  const fields: Record<string, string> = {};
  for (const [key, value] of url.searchParams) fields[key] = value;
  if (req.method === 'POST') {
    const contentType = req.headers.get('content-type') || '';
    if (contentType.includes('application/json')) {
      const body = await req.json().catch(() => ({}));
      for (const [key, value] of Object.entries(body || {})) {
        if (typeof value === 'string') fields[key] = value;
      }
    } else {
      const form = await req.formData().catch(() => null);
      if (form) {
        for (const [key, value] of form) {
          if (typeof value === 'string') fields[key] = value;
        }
      }
    }
  }
  return fields;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST' && req.method !== 'GET') {
    return billingJson(405, { error: 'method_not_allowed' });
  }
  let origin: string;
  try {
    origin = returnOrigin();
  } catch {
    return billingJson(500, { error: 'billing_return_unavailable' });
  }

  /* Default routing is the owner settings route. It is corrected to the self-serve onboarding
     route only from notes read back out of Razorpay — never from the query string, so a tampered
     redirect cannot move a signup onto the wrong screen. */
  let target = routes(origin, false);
  try {
    const fields = await readFields(req);
    const commandId = String(fields.cmd || '');
    const cardChange = String(fields.mode || '') === 'card';
    /* Set before the provider lookup so a card change still lands on the card route when
       Razorpay is unreachable — the lookup only refines the SIGNUP-vs-settings choice. */
    if (cardChange) target = cardRoutes(origin);
    const paymentId = String(fields.razorpay_payment_id || '');
    const subscriptionId = String(fields.razorpay_subscription_id || '');
    const signature = String(fields.razorpay_signature || '');

    /* nestly_v790: the redirect is signed with the key SECRET of whichever account created the
       subscription — the platform's, or the sandbox's for a demo firm. The signature check below
       tries both and the one that verifies is the account every later read uses. */
    const live = razorpayCredentials('live');
    const sandbox = razorpayCredentials('test');
    let account: RazorpayCredentialSet | null = null;
    for (const candidate of sandbox.mode === 'test' ? [live, sandbox] : [live]) {
      if (await verifyCheckoutSignature(paymentId, subscriptionId, signature, candidate.keySecret)) {
        account = candidate;
        break;
      }
    }
    if (subscriptionId && account) {
      try {
        const razorpay = razorpayClientFor(account);
        const subscription = await razorpay.getSubscription(subscriptionId);
        target = cardChange
          ? cardRoutes(origin)
          : routes(origin, String(subscription.notes?.self_serve || '') === '1');
        /* A redirect naming a command that is not the one this subscription was created for is
           not a Peekaa return; route it as a cancellation rather than a success. A CARD CHANGE is
           the deliberate exception: it runs under a new command id against the subscription the
           original checkout created, so notes.command_id can never match it. The signature — over
           payment_id|subscription_id with the API secret — is what proves the return is genuine
           in both cases; this comparison only tells two of OUR routes apart. */
        if (
          !cardChange && commandId && UUID.test(commandId) &&
          String(subscription.notes?.command_id || '') !== commandId
        ) {
          return seeOther(`${target.cancel}&reason=signature`);
        }
      } catch {
        // Lookup unavailable: keep the default owner route and still verify the signature.
      }
    }

    const verified = account !== null;
    if (!verified) {
      return seeOther(`${target.cancel}&reason=signature`);
    }
    /* nestly_v774 — "it loads super long, I need it to be immediate" (owner, 2026-09-05).
       Razorpay's webhook arrives 60–90 seconds after the card is charged (measured: paid
       09:24:28, webhook 09:25:51), and until it does the owner sits on "Setting up your
       workspace…". The redirect is still not payment truth — but the SIGNED redirect names a
       subscription we can read back from Razorpay right now, and a paid invoice read from the
       provider is the same truth the webhook would carry. So the return hop runs the v759
       recovery synthesis for this one subscription: it mirrors any paid invoice through the
       identical ingest → apply pipeline (the webhook, when it lands, is a duplicate), which
       fires the first-paid trigger and opens the workspace before the browser has even loaded
       the next page. Best effort: any failure here leaves the webhook path exactly as it was. */
    if (subscriptionId && !cardChange && account) {
      try {
        const outcome = await recoverProviderSubscription({
          admin: billingAdminClient(),
          razorpay: razorpayClientFor(account),
          subscriptionId,
          livemode: account.livemode,
        });
        console.log(JSON.stringify({
          scope: 'razorpay-billing-return',
          reason: 'return_hop_synthesis',
          subscription_id: subscriptionId,
          invoices: outcome.invoices.length,
          events: outcome.events.map((event) => `${event.event_type}:${event.status}`),
        }));
      } catch (error) {
        console.warn(JSON.stringify({
          scope: 'razorpay-billing-return',
          reason: 'return_hop_synthesis_failed',
          subscription_id: subscriptionId,
          message: String((error as Error)?.message || error),
        }));
      }
    }
    /* 'processing', not 'paid': the app polls its own billing state, which the synthesis above
       has usually already moved; the webhook remains the fallback. */
    return seeOther(target.success);
  } catch {
    return seeOther(`${target.cancel}&reason=signature`);
  }
});

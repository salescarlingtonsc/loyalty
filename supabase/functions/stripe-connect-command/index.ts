import Stripe from 'npm:stripe@18.5.0';
import {
  authenticatedUserId,
  billingAdminClient,
  billingCorsFor,
  billingCorsJson,
  billingPreflight,
  requiredEnv,
} from '../_shared/billing-service.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 4096;

function connectReturnOrigin(): string {
  const configured = new URL(requiredEnv('CONNECT_RETURN_ORIGIN'));
  if (configured.protocol !== 'https:' || configured.username || configured.password ||
      configured.pathname !== '/' || configured.search || configured.hash) {
    throw new Error('merchant payment service unavailable');
  }
  return configured.origin;
}

function capability(account: Stripe.Account): string {
  const value = account.capabilities?.paynow_payments;
  return ['active', 'pending', 'inactive'].includes(String(value))
    ? String(value)
    : account.requirements?.disabled_reason ? 'restricted' : 'unavailable';
}

function accountProjection(account: Stripe.Account) {
  const livemode = !requiredEnv('STRIPE_SECRET_KEY').startsWith('sk_test_');
  return {
    p_account_id: account.id,
    p_livemode: livemode,
    p_details_submitted: account.details_submitted === true,
    p_charges_enabled: account.charges_enabled === true,
    p_payouts_enabled: account.payouts_enabled === true,
    p_paynow_capability: capability(account),
    p_currently_due: account.requirements?.currently_due || [],
    p_eventually_due: account.requirements?.eventually_due || [],
    p_disabled_reason: account.requirements?.disabled_reason || null,
  };
}

function payNowQr(intent: Stripe.PaymentIntent) {
  const next = intent.next_action;
  if (next?.type !== 'paynow_display_qr_code' || !next.paynow_display_qr_code) return null;
  const qr = next.paynow_display_qr_code;
  return {
    data: qr.data,
    hosted_instructions_url: qr.hosted_instructions_url,
  };
}

Deno.serve(async (req) => {
  const preflight = billingPreflight(req);
  if (preflight) return preflight;
  if (!billingCorsFor(req)) return billingCorsJson(req, 403, { error: 'origin_not_allowed' });
  if (req.method !== 'POST') return billingCorsJson(req, 405, { error: 'method_not_allowed' });
  const length = Number(req.headers.get('content-length') || '0');
  if (length > MAX_BODY_BYTES || !req.headers.get('content-type')?.includes('application/json')) {
    return billingCorsJson(req, 400, { error: 'invalid_request' });
  }

  let actor = '';
  try {
    actor = await authenticatedUserId(req);
  } catch {
    return billingCorsJson(req, 401, { error: 'authentication_required' });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return billingCorsJson(req, 400, { error: 'invalid_request' });
  }
  const action = String(body.action || '');
  const businessId = String(body.business_id || '');
  const idempotencyKey = String(body.idempotency_key || '');
  if (!UUID.test(businessId) || !UUID.test(idempotencyKey)) {
    return billingCorsJson(req, 400, { error: 'invalid_request' });
  }

  const admin = billingAdminClient();
  const stripeSecret = requiredEnv('STRIPE_SECRET_KEY');
  const livemode = !stripeSecret.startsWith('sk_test_');
  const stripe = new Stripe(stripeSecret, {
    httpClient: Stripe.createFetchHttpClient(),
  });

  try {
    if (action === 'create_onboarding_link') {
      const { data: command, error: commandError } = await admin.rpc(
        'begin_merchant_connect_command_v142',
        { p_business: businessId, p_actor: actor, p_idempotency_key: idempotencyKey,
          p_livemode: livemode },
      );
      if (commandError || !command?.command_id) {
        return billingCorsJson(req, 403, { error: 'owner_payment_setup_required' });
      }
      let account: Stripe.Account;
      if (command.provider_account_id) {
        account = await stripe.accounts.retrieve(String(command.provider_account_id));
      } else {
        account = await stripe.accounts.create({
          type: 'express',
          country: 'SG',
          capabilities: {
            paynow_payments: { requested: true },
            transfers: { requested: true },
          },
          business_profile: { url: 'https://www.peekaa.asia' },
          metadata: { peekaa_business_id: businessId, peekaa_surface: 'merchant_pos_v142' },
        }, { idempotencyKey: String(command.provider_idempotency_key) });
      }
      const projection = accountProjection(account);
      const { error: completeError } = await admin.rpc('complete_merchant_connect_command_v142', {
        p_command: command.command_id,
        ...projection,
      });
      if (completeError) throw new Error('merchant account binding failed');
      const origin = connectReturnOrigin();
      const link = await stripe.accountLinks.create({
        account: account.id,
        refresh_url: `${origin}/#/settings`,
        return_url: `${origin}/#/settings`,
        type: 'account_onboarding',
        collection_options: { fields: 'eventually_due' },
      });
      return billingCorsJson(req, 200, {
        status: 'onboarding_required',
        redirect_url: link.url,
        expires_at: link.expires_at,
      });
    }

    if (action === 'create_paynow') {
      const branchId = String(body.branch_id || '');
      const clientId = String(body.client_id || '');
      const staffId = String(body.staff_id || '');
      const evaluationId = String(body.evaluation_id || '');
      if (![branchId, clientId, staffId, evaluationId].every((value) => UUID.test(value))) {
        return billingCorsJson(req, 400, { error: 'invalid_request' });
      }
      const { data: attempt, error: attemptError } = await admin.rpc('begin_pos_paynow_attempt_v142', {
        p_business: businessId,
        p_branch: branchId,
        p_client: clientId,
        p_staff: staffId,
        p_evaluation: evaluationId,
        p_actor: actor,
        p_idempotency_key: idempotencyKey,
        p_livemode: livemode,
      });
      if (attemptError || !attempt?.attempt_id) {
        return billingCorsJson(req, attemptError?.code === '42501' ? 403 : 409, {
          error: 'paynow_not_available',
          message: attemptError?.message || 'PayNow could not be prepared.',
        });
      }
      let intent: Stripe.PaymentIntent;
      const stripeAccount = String(attempt.provider_account_id);
      if (attempt.provider_payment_intent_id) {
        intent = await stripe.paymentIntents.retrieve(String(attempt.provider_payment_intent_id), {}, {
          stripeAccount,
        });
      } else {
        intent = await stripe.paymentIntents.create({
          amount: Number(attempt.amount_cents),
          currency: 'sgd',
          payment_method_types: ['paynow'],
          description: 'Peekaa merchant POS sale',
          metadata: {
            peekaa_pos_attempt_id: String(attempt.attempt_id),
            peekaa_business_id: businessId,
            peekaa_branch_id: branchId,
            peekaa_evaluation_id: evaluationId,
          },
        }, {
          stripeAccount,
          idempotencyKey: String(attempt.provider_idempotency_key),
        });
      }
      if (intent.amount !== Number(attempt.amount_cents) || intent.currency.toUpperCase() !== 'SGD') {
        throw new Error('provider amount mismatch');
      }
      const { error: attachError } = await admin.rpc('attach_pos_paynow_intent_v142', {
        p_attempt: attempt.attempt_id,
        p_account_id: stripeAccount,
        p_payment_intent_id: intent.id,
        p_provider_status: intent.status,
      });
      if (attachError) throw new Error('payment attempt binding failed');
      if (['requires_payment_method', 'requires_confirmation'].includes(intent.status)) {
        intent = await stripe.paymentIntents.confirm(intent.id, {
          payment_method_data: { type: 'paynow' },
        }, {
          stripeAccount,
          idempotencyKey: `${String(attempt.provider_idempotency_key)}-confirm`,
        });
        const { error: statusError } = await admin.rpc('attach_pos_paynow_intent_v142', {
          p_attempt: attempt.attempt_id,
          p_account_id: stripeAccount,
          p_payment_intent_id: intent.id,
          p_provider_status: intent.status,
        });
        if (statusError) throw new Error('payment attempt status binding failed');
      }
      const qr = payNowQr(intent);
      if (!qr && !['processing', 'succeeded'].includes(intent.status)) {
        throw new Error('PayNow QR unavailable');
      }
      let expiresAt = attempt.expires_at;
      if (qr) {
        const { data: activation, error: activationError } = await admin.rpc(
          'activate_pos_paynow_qr_v142',
          { p_attempt: attempt.attempt_id, p_account_id: stripeAccount,
            p_payment_intent_id: intent.id },
        );
        if (activationError || !activation?.expires_at) {
          throw new Error('PayNow QR activation failed');
        }
        expiresAt = activation.expires_at;
      }
      return billingCorsJson(req, 200, {
        attempt_id: attempt.attempt_id,
        status: intent.status === 'processing' ? 'processing' :
          intent.status === 'succeeded' ? 'provider_confirmed' : 'awaiting_payment',
        amount_cents: Number(attempt.amount_cents),
        currency: 'SGD',
        expires_at: expiresAt,
        qr,
      });
    }

    return billingCorsJson(req, 400, { error: 'unsupported_action' });
  } catch {
    return billingCorsJson(req, 502, { error: 'merchant_payment_provider_unavailable' });
  }
});

import { createClient } from 'npm:@supabase/supabase-js@2.110.7';
export {
  customerPushDeadlineElapsed,
  customerPushTtlSeconds,
  supportedCustomerPushEndpoint,
} from './customer-push-boundaries.mjs';

function env(name: string): string {
  return Deno.env.get(name) || '';
}

function serviceKey(): string {
  const current = env('SUPABASE_SECRET_KEYS');
  if (current) {
    const keys = JSON.parse(current);
    if (typeof keys.default === 'string' && keys.default) return keys.default;
  }
  const legacy = env('SUPABASE_SERVICE_ROLE_KEY');
  if (!legacy) throw new Error('push dispatcher unavailable');
  return legacy;
}

export function pushAdminClient() {
  const url = env('SUPABASE_URL');
  if (!url) throw new Error('push dispatcher unavailable');
  return createClient(url, serviceKey(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function requiredPushEnv(name: string): string {
  const value = env(name);
  if (!value) throw new Error('push dispatcher unavailable');
  return value;
}

export function pushDispatchAuthorized(req: Request): boolean {
  const expected = requiredPushEnv('CUSTOMER_PUSH_DISPATCH_SECRET');
  const supplied = req.headers.get('x-nestly-push-dispatch-secret') || '';
  if (expected.length < 32 || supplied.length !== expected.length) return false;
  let mismatch = 0;
  for (let index = 0; index < expected.length; index += 1) {
    mismatch |= expected.charCodeAt(index) ^ supplied.charCodeAt(index);
  }
  return mismatch === 0;
}

export function pushJson(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
}

export type PushLease = {
  delivery_id: string;
  lease_token: string;
  attempt: number;
  event_id: string;
  business_id: string;
  business_slug: string;
  source_kind:
    | 'c44_actionable_wallet'
    | 'c45_birthday_benefit'
    | 'v33_booking_action'
    | 'v48_appointment_reschedule'
    | 'v122_promotion_new'
    | 'v122_promotion_expiry'
    | 'v282_bottle_expiry';
  topic: string;
  title: string;
  body: string;
  route_key: 'wallet_business';
  deadline_at: string | null;
  endpoint: string;
  p256dh: string;
  auth: string;
};

export type PushDisposition = 'sent' | 'retry' | 'gone' | 'failed';

export type CustomerPushEventType =
  | 'value_expiry'
  | 'reward_ready'
  | 'visit_progress'
  | 'birthday_benefit'
  | 'booking_request_received'
  | 'appointment_time_changed'
  | 'promotion_alert';

/**
 * Returns null - never throws - for a lease this dispatcher cannot render.
 *
 * Audit finding 1.9: the throwing form was called INSIDE the send try-block, so
 * an unmapped topic (promotion_alerts, today) surfaced as a transport error
 * with no HTTP status. pushDisposition(null) is 'retry', so the delivery
 * retried five times and then stalled forever, invisible. An event type we
 * cannot render is a permanent, deterministic failure and must fail CLOSED:
 * the caller checks this BEFORE the try-block and records 'failed'.
 */
export function customerPushEventTypeOrNull(
  lease: PushLease,
): CustomerPushEventType | null {
  if (lease.source_kind === 'v33_booking_action') {
    return 'booking_request_received';
  }
  if (lease.source_kind === 'v48_appointment_reschedule') {
    return 'appointment_time_changed';
  }
  // V282: promotion_alerts became push-eligible in v255/v263, but this mapping
  // was never added, so every promotional push fell through to the null branch
  // and was recorded as a permanent 'unsupported_push_event' failure. The
  // promotion cron has been enqueueing them every fifteen minutes since.
  if (lease.topic === 'promotion_alerts') return 'promotion_alert';
  if (
    lease.topic === 'value_expiry' || lease.topic === 'reward_ready' ||
    lease.topic === 'visit_progress' || lease.topic === 'birthday_benefit'
  ) {
    return lease.topic;
  }
  return null;
}

export function customerPushEventType(lease: PushLease): CustomerPushEventType {
  const eventType = customerPushEventTypeOrNull(lease);
  if (eventType === null) throw new Error('unsupported push event');
  return eventType;
}

export function pushDisposition(statusCode: number | null): PushDisposition {
  if (statusCode === null || statusCode === 408 || statusCode === 425 ||
      statusCode === 429 || statusCode >= 500) return 'retry';
  if (statusCode === 404 || statusCode === 410) return 'gone';
  return statusCode >= 200 && statusCode < 300 ? 'sent' : 'failed';
}

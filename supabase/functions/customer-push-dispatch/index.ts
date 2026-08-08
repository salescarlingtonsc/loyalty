import webpush from 'npm:web-push@3.6.7';
import {
  type PushDisposition,
  type PushLease,
  customerPushDeadlineElapsed,
  customerPushEventType,
  customerPushEventTypeOrNull,
  customerPushTtlSeconds,
  pushAdminClient,
  pushDispatchAuthorized,
  pushDisposition,
  pushJson,
  requiredPushEnv,
  supportedCustomerPushEndpoint,
} from '../_shared/customer-push.ts';

const MAX_CLAIM = 50;
const MAX_CONCURRENCY = 8;

function errorStatus(error: unknown): number | null {
  if (!error || typeof error !== 'object') return null;
  const value = (error as { statusCode?: unknown }).statusCode;
  return typeof value === 'number' && Number.isInteger(value) ? value : null;
}

function errorCode(error: unknown, status: number | null): string {
  if (status !== null) return `web_push_http_${status}`;
  const code = error && typeof error === 'object'
    ? (error as { code?: unknown }).code
    : null;
  return typeof code === 'string' && /^[A-Za-z0-9_.-]{1,48}$/.test(code)
    ? code
    : 'web_push_transport_error';
}

async function mapBounded<T>(
  rows: T[],
  worker: (row: T) => Promise<void>,
): Promise<void> {
  let cursor = 0;
  await Promise.all(Array.from(
    { length: Math.min(MAX_CONCURRENCY, rows.length) },
    async () => {
      while (cursor < rows.length) {
        const row = rows[cursor++];
        await worker(row);
      }
    },
  ));
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return pushJson(405, { error: 'method_not_allowed' });
  try {
    if (!pushDispatchAuthorized(req)) {
      return pushJson(401, { error: 'dispatcher_authentication_required' });
    }
  } catch {
    return pushJson(503, { error: 'push_dispatcher_unavailable' });
  }

  const workerId = crypto.randomUUID();
  const admin = pushAdminClient();
  const { data, error } = await admin.rpc('internal_customer_push_claim_v95', {
    p_worker_id: workerId,
    p_limit: MAX_CLAIM,
    p_lease_seconds: 120,
  });
  if (error || !Array.isArray(data)) {
    return pushJson(503, { error: 'push_claim_failed' });
  }

  webpush.setVapidDetails(
    requiredPushEnv('CUSTOMER_PUSH_VAPID_SUBJECT'),
    requiredPushEnv('CUSTOMER_PUSH_VAPID_PUBLIC_KEY'),
    requiredPushEnv('CUSTOMER_PUSH_VAPID_PRIVATE_KEY'),
  );

  let sent = 0;
  let retry = 0;
  let gone = 0;
  let failed = 0;
  let reportFailed = false;

  await mapBounded(data as PushLease[], async (lease) => {
    let disposition: PushDisposition = 'retry';
    let status: number | null = null;
    let code = '';
    const sendBoundaryAt = Date.now();
    if (!supportedCustomerPushEndpoint(lease.endpoint)) {
      disposition = 'gone';
      code = 'unsupported_push_endpoint';
    } else if (customerPushDeadlineElapsed(lease.deadline_at, sendBoundaryAt)) {
      disposition = 'failed';
      code = 'deadline_elapsed';
    } else if (customerPushEventTypeOrNull(lease) === null) {
      // Fails CLOSED. An unmappable event type can never succeed on a later
      // attempt, so it is recorded as a permanent failure with a named code
      // rather than left to burn five retries and stall (audit finding 1.9).
      disposition = 'failed';
      code = 'unsupported_push_event';
    } else try {
      const ttl = customerPushTtlSeconds(lease.deadline_at, sendBoundaryAt);
      const payload = JSON.stringify({
        event_type: customerPushEventType(lease),
        business_slug: lease.business_slug,
        notification_id: lease.event_id,
        title: lease.title,
        body: lease.body,
      });
      const response = await webpush.sendNotification({
        endpoint: lease.endpoint,
        keys: { p256dh: lease.p256dh, auth: lease.auth },
      }, payload, {
        TTL: ttl,
        urgency: lease.topic === 'value_expiry' ? 'high' : 'normal',
      });
      status = response.statusCode;
      disposition = pushDisposition(status);
    } catch (error) {
      status = errorStatus(error);
      disposition = pushDisposition(status);
      code = errorCode(error, status);
    }

    const { error: reportError } = await admin.rpc(
      'internal_customer_push_report_v95',
      {
        p_delivery_id: lease.delivery_id,
        p_lease_token: lease.lease_token,
        p_worker_id: workerId,
        p_result: disposition,
        p_http_status: status,
        p_error_code: code || null,
        p_retry_after: null,
        p_idempotency_key: crypto.randomUUID(),
      },
    );
    if (reportError) reportFailed = true;
    if (disposition === 'sent') sent++;
    else if (disposition === 'retry') retry++;
    else if (disposition === 'gone') gone++;
    else failed++;
  });

  return pushJson(reportFailed ? 503 : 200, {
    claimed: data.length,
    sent,
    retry,
    gone,
    failed,
    report_failed: reportFailed,
  });
});

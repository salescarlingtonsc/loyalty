/* nestly_v755 — Razorpay replaces Stripe for platform billing (owner decision 2026-09-04).
   There is no npm SDK here on purpose: the whole surface we need is six REST calls behind HTTP
   Basic auth, and the signature verification is a single HMAC. A dependency-free client keeps the
   edge cold-start small and, more importantly, keeps the two signature helpers PURE so the Node
   test suite can execute them against known vectors instead of grepping this file. */

export type RazorpayCredentials = {
  keyId: string;
  keySecret: string;
};

export class RazorpayApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly description: string;
  /* `nonExecutionProven` is the property the billing-command disposition rules read. It is true
     only when Razorpay has told us the request was REJECTED before it could change anything —
     a 4xx other than 429. A timeout, a 429 or a 5xx leaves the outcome genuinely unknown, and an
     unknown outcome must be recorded 'uncertain', never 'failed'. */
  readonly nonExecutionProven: boolean;

  constructor(status: number, code: string, description: string) {
    super(description || code || `razorpay_http_${status}`);
    this.name = 'RazorpayApiError';
    this.status = status;
    this.code = code;
    this.description = description;
    this.nonExecutionProven = status >= 400 && status < 500 && status !== 429;
  }
}

export class RazorpayTransportError extends Error {
  readonly nonExecutionProven = false;
  constructor(message: string) {
    super(message);
    this.name = 'RazorpayTransportError';
  }
}

/* Razorpay has no `livemode` flag anywhere in a webhook payload, so the ONLY way to know which
   mode a deployment is operating in is the key prefix. Same reasoning as the Stripe V281 check
   this replaces: an unrecognised prefix disables the check rather than the webhook. */
export function livemodeFromKey(keyId: string): boolean | null {
  if (keyId.startsWith('rzp_live_')) return true;
  if (keyId.startsWith('rzp_test_')) return false;
  return null;
}

function toBytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

/* WebCrypto's BufferSource wants a plain ArrayBuffer; a TextEncoder result is typed over
   ArrayBufferLike, which a SharedArrayBuffer also satisfies. Copying out the exact byte range
   gives the concrete buffer the type asks for. */
function toBuffer(value: string): ArrayBuffer {
  const bytes = toBytes(value);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function toHex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

export async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    toBuffer(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return toHex(await crypto.subtle.sign('HMAC', key, toBuffer(message)));
}

/* Constant-time: every byte of the expected digest is examined on every call and the verdict is
   an accumulated OR, so the loop cannot exit early and the elapsed time carries no information
   about HOW MANY leading characters of a forged signature were correct. A length mismatch is
   folded into the same accumulator (compared against the expected value itself) rather than
   short-circuiting, for the same reason. */
export function constantTimeEqual(expected: string, supplied: string): boolean {
  const expectedBytes = toBytes(expected);
  const suppliedBytes = toBytes(supplied);
  const sameLength = expectedBytes.length === suppliedBytes.length;
  const comparison = sameLength ? suppliedBytes : expectedBytes;
  let difference = sameLength ? 0 : 1;
  for (let index = 0; index < expectedBytes.length; index += 1) {
    difference |= expectedBytes[index] ^ comparison[index];
  }
  return difference === 0;
}

/* X-Razorpay-Signature is HMAC-SHA256 of the RAW request body, hex, with the webhook secret.
   The body must never be JSON.parse'd and re-serialised before this runs — re-serialisation
   changes key order and whitespace and would fail every genuine event. */
export async function verifyWebhookSignature(
  rawBody: string,
  signatureHeader: string,
  webhookSecret: string,
): Promise<boolean> {
  if (!signatureHeader || !webhookSecret) return false;
  const expected = await hmacSha256Hex(webhookSecret, rawBody);
  return constantTimeEqual(expected, signatureHeader.trim());
}

/* nestly_v759 — the secret ROTATION window.

   Razorpay's own guidance: "If you have changed your webhook secret, remember to use the old
   secret for webhook signature validation while retrying older requests." A rotation is not
   atomic — the deliveries already queued at the moment the dashboard secret changes are still
   signed with the OLD secret, and Razorpay retries them for 24h. Verifying against the new
   secret alone answers every one of those 400, and 24h of 400s disables the endpoint.

   So the window accepts EITHER secret and reports which one matched, so the accepted log line
   can say when the previous secret is still carrying traffic (i.e. when it is safe to remove).
   `previous` is optional: unset or empty means only the current secret is accepted, which is the
   steady state. Each candidate is compared with the same constant-time helper — the loop does
   not short-circuit inside a digest, it only stops once a full digest has matched. */
export type WebhookSecretMatch = 'current' | 'previous';

export async function verifyWebhookSignatureRotating(
  rawBody: string,
  signatureHeader: string,
  secrets: { current: string; previous?: string | null },
): Promise<WebhookSecretMatch | null> {
  const candidates: Array<[WebhookSecretMatch, string]> = [
    ['current', secrets.current || ''],
    ['previous', (secrets.previous || '').trim()],
  ];
  for (const [label, secret] of candidates) {
    if (!secret) continue;
    if (await verifyWebhookSignature(rawBody, signatureHeader, secret)) return label;
  }
  return null;
}

/* Checkout redirect callback: HMAC-SHA256 of `${payment_id}|${subscription_id}` with the API key
   SECRET (not the webhook secret). This proves the redirect came from Razorpay; it is NOT
   evidence of payment — only the webhook writes payment truth. */
export async function verifyCheckoutSignature(
  paymentId: string,
  subscriptionId: string,
  signature: string,
  keySecret: string,
): Promise<boolean> {
  if (!paymentId || !subscriptionId || !signature || !keySecret) return false;
  const expected = await hmacSha256Hex(keySecret, `${paymentId}|${subscriptionId}`);
  return constantTimeEqual(expected, signature.trim());
}

const DEFAULT_TIMEOUT_MS = 15000;
const API_BASE = 'https://api.razorpay.com/v1';

function basicAuth({ keyId, keySecret }: RazorpayCredentials): string {
  return `Basic ${btoa(`${keyId}:${keySecret}`)}`;
}

export type RazorpayRequest = {
  method: 'GET' | 'POST' | 'PATCH';
  path: string;
  query?: Record<string, string | number | undefined>;
  body?: Record<string, unknown>;
  timeoutMs?: number;
};

export function razorpayClient(credentials: RazorpayCredentials) {
  async function request<T>({
    method,
    path,
    query,
    body,
    timeoutMs = DEFAULT_TIMEOUT_MS,
  }: RazorpayRequest): Promise<T> {
    const url = new URL(`${API_BASE}${path}`);
    for (const [key, value] of Object.entries(query || {})) {
      if (value !== undefined && value !== null && value !== '') {
        url.searchParams.set(key, String(value));
      }
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let response: Response;
    try {
      response = await fetch(url.toString(), {
        method,
        headers: {
          authorization: basicAuth(credentials),
          accept: 'application/json',
          ...(body ? { 'content-type': 'application/json' } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });
    } catch (error) {
      throw new RazorpayTransportError(
        `razorpay request failed: ${String((error as Error)?.name || 'network')}`,
      );
    } finally {
      clearTimeout(timer);
    }
    const text = await response.text();
    let parsed: unknown = null;
    try {
      parsed = text ? JSON.parse(text) : null;
    } catch {
      parsed = null;
    }
    if (!response.ok) {
      const detail = (parsed as { error?: { code?: string; description?: string } })?.error;
      throw new RazorpayApiError(
        response.status,
        String(detail?.code || `http_${response.status}`),
        String(detail?.description || 'razorpay request rejected'),
      );
    }
    return parsed as T;
  }

  return {
    request,
    getPlan: (planId: string) => request<RazorpayPlan>({ method: 'GET', path: `/plans/${planId}` }),
    getSubscription: (subscriptionId: string) =>
      request<RazorpaySubscription>({ method: 'GET', path: `/subscriptions/${subscriptionId}` }),
    listSubscriptions: (query: Record<string, string | number | undefined>) =>
      request<RazorpayList<RazorpaySubscription>>({ method: 'GET', path: '/subscriptions', query }),
    createSubscription: (body: Record<string, unknown>) =>
      request<RazorpaySubscription>({ method: 'POST', path: '/subscriptions', body }),
    updateSubscription: (subscriptionId: string, body: Record<string, unknown>) =>
      request<RazorpaySubscription>({
        method: 'PATCH',
        path: `/subscriptions/${subscriptionId}`,
        body,
      }),
    cancelSubscription: (subscriptionId: string, cancelAtCycleEnd: 0 | 1) =>
      request<RazorpaySubscription>({
        method: 'POST',
        path: `/subscriptions/${subscriptionId}/cancel`,
        body: { cancel_at_cycle_end: cancelAtCycleEnd },
      }),
    /* nestly_v764 — the only way to withdraw a change Razorpay has scheduled for cycle end.
       There is no PATCH that "unschedules"; this endpoint is it. */
    cancelScheduledChanges: (subscriptionId: string) =>
      request<RazorpaySubscription>({
        method: 'POST',
        path: `/subscriptions/${subscriptionId}/cancel_scheduled_changes`,
      }),
    resumeSubscription: (subscriptionId: string) =>
      request<RazorpaySubscription>({
        method: 'POST',
        path: `/subscriptions/${subscriptionId}/resume`,
        body: { resume_at: 'now' },
      }),
    /* `expand[]=card` is the only way to get last4/network for a card payment: the bare payment
       object carries `card_id` but no card body. Razorpay reads repeated `expand[]` params, so
       the option is spelled with the literal bracket key rather than a normalised name. */
    getPayment: (paymentId: string, options?: { expandCard?: boolean }) =>
      request<RazorpayPayment>({
        method: 'GET',
        path: `/payments/${paymentId}`,
        query: options?.expandCard ? { 'expand[]': 'card' } : undefined,
      }),
    listPayments: (query: Record<string, string | number | undefined>) =>
      request<RazorpayList<RazorpayPayment>>({ method: 'GET', path: '/payments', query }),
    /* nestly_v759 — a Razorpay subscription's settled cycles are only reachable as INVOICES;
       there is no "list the payments of this subscription" endpoint. Each invoice carries the
       payment_id that settled it, which is what the recovery path then expands. */
    getSubscriptionInvoices: (
      subscriptionId: string,
      query?: Record<string, string | number | undefined>,
    ) =>
      request<RazorpayList<RazorpayInvoice>>({
        method: 'GET',
        path: `/subscriptions/${subscriptionId}/invoices`,
        query,
      }),
  };
}

export type RazorpayClient = ReturnType<typeof razorpayClient>;

export type RazorpayList<T> = {
  entity: string;
  count: number;
  items: T[];
};

export type RazorpayPlan = {
  id: string;
  period: string;
  interval: number;
  item: {
    id?: string;
    name?: string;
    amount: number;
    currency: string;
    description?: string;
  };
  notes?: Record<string, string>;
};

export type RazorpaySubscription = {
  id: string;
  entity?: string;
  plan_id: string;
  customer_id?: string | null;
  status: string;
  current_start?: number | null;
  current_end?: number | null;
  ended_at?: number | null;
  quantity?: number;
  notes?: Record<string, string>;
  charge_at?: number | null;
  start_at?: number | null;
  end_at?: number | null;
  total_count?: number;
  paid_count?: number;
  remaining_count?: number;
  created_at?: number;
  expire_by?: number | null;
  short_url?: string | null;
  has_scheduled_changes?: boolean;
  change_scheduled_at?: number | null;
};

export type RazorpayInvoice = {
  id: string;
  entity?: string;
  payment_id?: string | null;
  subscription_id?: string | null;
  customer_id?: string | null;
  amount?: number;
  amount_paid?: number;
  currency?: string;
  status?: string;
  paid_at?: number | null;
  issued_at?: number | null;
  billing_start?: number | null;
  billing_end?: number | null;
  notes?: Record<string, string>;
};

export type RazorpayPayment = {
  id: string;
  amount: number;
  currency: string;
  status: string;
  order_id?: string | null;
  invoice_id?: string | null;
  method?: string;
  card_id?: string | null;
  card?: {
    id?: string;
    last4?: string | null;
    network?: string | null;
    type?: string | null;
    issuer?: string | null;
  } | null;
  captured?: boolean;
  created_at?: number;
  notes?: Record<string, string>;
  error_code?: string | null;
  error_description?: string | null;
};

/* period/interval on a Razorpay plan is the cadence the owner reviewed in the catalogue. A plan
   whose shape does not match is a DIFFERENT product than the one that was priced and approved,
   so the command refuses rather than charging it. */
export function razorpayPlanMatchesCatalogue(
  plan: RazorpayPlan | null | undefined,
  expected: { cadence: string; amountCents: number; currency: string },
): boolean {
  if (!plan || !plan.item) return false;
  const expectedPeriod = expected.cadence === 'annual' ? 'yearly' : 'monthly';
  return (
    plan.period === expectedPeriod &&
    Number(plan.interval) === 1 &&
    Number(plan.item.amount) === Number(expected.amountCents) &&
    String(plan.item.currency || '').toUpperCase() ===
      String(expected.currency || '').toUpperCase()
  );
}

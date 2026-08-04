import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migration = readFileSync(new URL('../../db/migrations/20260804_nestly_v156_subscription_operations_crm.sql', import.meta.url), 'utf8');
const mirror = readFileSync(new URL('../../supabase/migrations/20260804120000_nestly_v156_subscription_operations_crm.sql', import.meta.url), 'utf8');
const consoleSource = readFileSync(new URL('../../app/platform-console.js', import.meta.url), 'utf8');
const webhook = readFileSync(new URL('../../supabase/functions/stripe-billing-webhook/index.ts', import.meta.url), 'utf8');
const dispatcher = readFileSync(new URL('../../supabase/functions/subscription-document-dispatch/index.ts', import.meta.url), 'utf8');
const pdf = readFileSync(new URL('../../supabase/functions/_shared/subscription-document-pdf-v156.ts', import.meta.url), 'utf8');
const supabaseConfig = readFileSync(new URL('../../supabase/config.toml', import.meta.url), 'utf8');

test('V156 canonical source and deploy migration remain byte-identical', () => {
  assert.equal(mirror, migration);
  assert.match(migration, /^-- Peekaa V156/);
  assert.match(migration, /begin;[\s\S]*commit;\s*$/);
});

test('seller settings use only owner-provided facts and fail closed while legal fields are missing', () => {
  for (const value of ['Peekaa', 'NESTLY TECHNOLOGIES PTE. LTD.', '202634502E', 'Standard Chartered Bank (Singapore) Limited', '9496', '001', 'SCBLSG22', '7897246357', 'Lee Chuan Seng', '+65 8186 3833']) assert.match(migration, new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(migration, /'unconfigured'/);
  assert.match(migration, /p_profile\.uen is not null[\s\S]*registered_address is not null[\s\S]*billing_email is not null[\s\S]*default_payment_terms is not null/);
  assert.match(migration, /gst_status='registered'[\s\S]*gst_registration_number[\s\S]*gst_rate_bps>0/);
  assert.match(migration, /gst_status<>'registered'[\s\S]*gst_registration_number is null and gst_rate_bps=0/);
  assert.doesNotMatch(migration, /Tax Invoice/);
});

test('document numbering, snapshots, PDF files and delivery records are collision-safe and private', () => {
  assert.match(migration, /primary key\(document_type,document_year\)/);
  assert.match(migration, /QTN['"]? when|when 'quotation' then 'QTN'/);
  assert.match(migration, /when 'invoice' then 'INV'/);
  assert.match(migration, /when 'receipt' then 'REC'/);
  assert.match(migration, /unique\(operation_key\)/);
  assert.match(migration, /snapshot_sha256/);
  assert.match(migration, /finalized subscription documents are immutable; void or reissue instead/);
  assert.match(migration, /bucket_id text not null default 'sme-private'/);
  assert.match(dispatcher, /createSignedUrl/);
  assert.match(dispatcher, /\.from\(BUCKET\)\.upload/);
  assert.match(dispatcher, /upsert: false/);
  assert.match(dispatcher, /idempotency-key': delivery\.id/);
});

test('Stripe paid invoice is the only automatic receipt and CRM won trigger', () => {
  assert.match(migration, /v_event\.event_type='invoice\.paid'/);
  assert.match(migration, /values\('receipt',v_number/);
  assert.match(migration, /Verified subscription payment received/);
  assert.match(migration, /current_stage_key='client'/);
  assert.doesNotMatch(migration, /checkout\.session\.completed'[\s\S]{0,600}document_type,'receipt'/);
  assert.doesNotMatch(migration, /payment_intent\.succeeded'[\s\S]{0,600}document_type,'receipt'/);
  assert.match(migration, /provider_invoice_id text references public\.billing_provider_invoices/);
  assert.match(migration, /where provider_invoice_id is not null and document_type='invoice'/);
  assert.match(migration, /where provider_invoice_id is not null and document_type='receipt'/);
});

test('webhook processing and email dispatch remain idempotent and fail closed', () => {
  assert.match(webhook, /constructEventAsync/);
  assert.match(webhook, /ingest_stripe_billing_event_v77/);
  assert.match(webhook, /apply_stripe_billing_event_v77/);
  assert.match(webhook, /SUBSCRIPTION_OPERATIONS_DISPATCH_SECRET/);
  assert.match(dispatcher, /RESEND_API_KEY/);
  assert.match(dispatcher, /TRANSACTIONAL_EMAIL_FROM/);
  assert.match(dispatcher, /provider_unconfigured/);
  assert.match(migration, /delivery_key text not null unique/);
  assert.match(migration, /'stripe-paid:'\|\|v_invoice\.provider_invoice_id/);
  assert.match(migration, /unique\(source_type,source_id,lifecycle_status\)/);
  assert.match(migration, /platform_billing_event_preparations_v156/);
  assert.match(migration, /v156_replay_blocked_billing_events/);
  assert.match(migration, /status='processing' and last_attempt_at<clock_timestamp\(\)-interval '15 minutes'/);
  assert.match(migration, /v156_service_claim_dispatch/);
  assert.match(supabaseConfig, /\[functions\.subscription-document-dispatch\]\s*verify_jwt = false/);
  assert.match(dispatcher, /provider_accepted/);
  assert.match(dispatcher, /function escapeHtml/);
});

test('payment failure, recovery and renewal tasks are deduplicated', () => {
  assert.match(migration, /task_key text not null unique/);
  assert.match(migration, /renewal_30','renewal_14','renewal_7/);
  assert.match(migration, /payment_failed','payment_action_required','past_due/);
  assert.match(migration, /resolution='Payment recovered'/);
  assert.match(migration, /r\.cadence='annual'/);
  assert.match(migration, /v_day in \(30,14,7\)/);
});

test('manual payments require private evidence and a distinct verifier before receipt issuance', () => {
  assert.match(migration, /platform_record_manual_payment_v156/);
  assert.match(migration, /platform_verify_manual_payment_v156/);
  assert.match(migration, /a second authorised admin must verify manual payment/);
  assert.match(migration, /verified_by<>recorded_by/);
  assert.match(migration, /evidence_object_path text not null check\(evidence_object_path ~ '\^platform-subscriptions\/manual-evidence\/'\)/);
  assert.match(migration, /Payment received via bank transfer/);
  assert.match(migration, /manual_policy_review_required/);
  assert.match(migration, /platform_prepare_manual_evidence_upload_v156/);
  assert.match(migration, /storage\.objects[\s\S]*bucket_id='sme-private'/);
  assert.match(migration, /platform_request_manual_evidence_read_v156/);
  assert.match(dispatcher, /manual_evidence_upload/);
  assert.match(dispatcher, /manual_evidence_read/);
  assert.doesNotMatch(migration, /update public\.billing_provider_invoices[\s\S]{0,300}status='paid'/);
});

test('platform and tenant data separation is server-enforced', () => {
  assert.match(migration, /enable row level security/g);
  assert.match(migration, /revoke all on table[\s\S]*from public,anon,authenticated/);
  assert.match(migration, /app\.is_super_admin\(\) or app\.v89_platform_can\('billing',p_mode\)/);
  assert.match(migration, /app\.v89_platform_role\(\)='sales_staff'/);
  assert.match(migration, /grant execute on function public\.platform_get_subscription_operations_v156/);
  assert.doesNotMatch(migration, /grant (select|insert|update|delete) on (table )?public\.platform_/i);
  assert.match(migration, /billing contact scope does not match/);
});

test('admin UX exposes internal subscription operations and retains accessible CRM list alternative', () => {
  assert.match(consoleSource, /key:'subscription-operations',moduleKey:'billing'/);
  assert.match(consoleSource, /renderSubscriptionOperations/);
  assert.match(consoleSource, /platform_get_subscription_operations_v156/);
  assert.match(consoleSource, /aria-live="polite" id="v156LiveStatus"/);
  assert.match(consoleSource, /data-onboarding-view="kanban"/);
  assert.match(consoleSource, /data-onboarding-view="list"/);
  assert.match(consoleSource, /renderCustomerLifecycle/);
  assert.match(consoleSource, /manualPaymentModal/);
  assert.match(consoleSource, /platform_create_prospect_v76/);
  assert.match(consoleSource, /p_idempotency_key:createAttemptKey/);
  assert.match(consoleSource, /if\(!form\.get\('contact_email'\)&&!form\.get\('contact_phone'\)\)/);
});

test('paid-through and out-of-order payment truth use paid invoice state', () => {
  assert.match(migration, /if not found and v_event\.event_type='invoice\.paid'/);
  assert.match(migration, /if v_invoice\.paid_normalized then[\s\S]*ignored_stale/);
  assert.match(migration, /provider_invoice_id=v_invoice\.provider_invoice_id and status='open'/);
  assert.match(migration, /paid_invoice\.period_end[\s\S]*paid_through/);
  assert.match(migration, /paid_invoice[\s\S]*and i\.paid_normalized/);
});

test('PDF renderer is A4, paginated and carries required payment language', () => {
  assert.match(pdf, /595\.28, 841\.89/);
  assert.match(pdf, /Page \$\{index \+ 1\} of \$\{pages\.length\}/);
  assert.match(pdf, /Transfer reference:/);
  assert.match(pdf, /This quotation is a commercial offer and does not confirm payment/);
  assert.match(pdf, /This receipt confirms payment received and is not a request for further payment/);
  assert.match(pdf, /Billing contact:/);
});

import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const migration=readFileSync(new URL('../../db/migrations/20260802_nestly_v142_connect_paynow_pos.sql',import.meta.url),'utf8');
const canonical=readFileSync(new URL('../../supabase/migrations/20260802134128_nestly_v142_connect_paynow_pos.sql',import.meta.url),'utf8');
const command=readFileSync(new URL('../../supabase/functions/stripe-connect-command/index.ts',import.meta.url),'utf8');
const webhook=readFileSync(new URL('../../supabase/functions/stripe-connect-webhook/index.ts',import.meta.url),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

const till=section('async function tillPage(){','/* ---------- sales ---------- */');
const settings=section('async function loadMerchantPaymentsV142(){','/* ---------- provider-backed subscription billing ---------- */');

test('V142 source and canonical migration are byte-identical',()=>{
  assert.equal(canonical,migration);
});

test('merchant onboarding is owner-facing and explicitly separate from Peekaa subscription billing',()=>{
  assert.match(app,/Customer payments/);
  assert.match(settings,/Separate from your Peekaa subscription/);
  assert.match(settings,/Set up Stripe/);
  assert.match(settings,/create_onboarding_link/);
  assert.match(command,/type: 'express'/);
  assert.match(command,/country: 'SG'/);
  assert.match(command,/paynow_payments: \{ requested: true \}/);
  assert.match(command,/stripe\.accountLinks\.create/);
  assert.match(command,/type: 'account_onboarding'/);
  assert.match(command,/refresh_url: `\$\{origin\}\/\#\/settings`/);
  assert.match(command,/return_url: `\$\{origin\}\/\#\/settings`/);
  assert.doesNotMatch(command,/\#\/settings\?payments=/);
  assert.doesNotMatch(migration,/merchant_payment_commands_v142[\s\S]{0,900}provider_idempotency_key text not null unique/);
});

test('each sale QR uses the merchant connected account and the database-authoritative exact SGD amount',()=>{
  assert.match(command,/begin_pos_paynow_attempt_v142/);
  assert.match(command,/amount: Number\(attempt\.amount_cents\)/);
  assert.match(command,/currency: 'sgd'/);
  assert.match(command,/payment_method_types: \['paynow'\]/);
  assert.match(command,/stripeAccount/);
  assert.match(command,/idempotencyKey: String\(attempt\.provider_idempotency_key\)/);
  assert.doesNotMatch(command,/body\.amount|body\.amount_cents/);
  assert.match(till,/Amount locked:/);
  assert.match(till,/The customer cannot change this amount/);
});

test('the PaymentIntent is attached to the attempt before confirmation can emit a paid event',()=>{
  const createAt=command.indexOf('paymentIntents.create');
  const attachAt=command.indexOf("rpc('attach_pos_paynow_intent_v142'");
  const confirmAt=command.indexOf('paymentIntents.confirm');
  assert.ok(createAt>=0&&attachAt>createAt&&confirmAt>attachAt,{createAt,attachAt,confirmAt});
  const createBlock=command.slice(createAt,attachAt);
  assert.doesNotMatch(createBlock,/confirm\s*:\s*true/);
  assert.match(command,/requires_payment_method.*requires_confirmation/s);
  assert.match(command,/idempotencyKey: `\$\{String\(attempt\.provider_idempotency_key\)\}-confirm`/);
});

test('manual external PayNow cannot be mistaken for provider-verified PayNow QR',()=>{
  assert.match(till,/\['paynow','External PayNow'\]/);
  assert.match(till,/verifiedPaynowReady\?\[\['paynow_qr','PayNow QR'\]\]/);
  assert.match(till,/tender==='paynow_qr'\)return beginPaynowPaymentV142/);
  assert.match(till,/PayNow \(Stripe verified\)/);
});

test('browser refresh recovers one stable payment attempt instead of creating another charge',()=>{
  assert.match(till,/sessionStorage\.setItem\(PAYNOW_SLOT/);
  assert.match(till,/async function resumePaynowPaymentV142/);
  assert.match(till,/action:'create_paynow',\.\.\.request/);
  assert.match(till,/if\(readPaynowRequestV142\(\)\)requestAnimationFrame/);
  assert.match(migration,/pos_payment_attempt_business_idem_v142 unique/);
  assert.match(migration,/where business_id=p_business and idempotency_key=p_idempotency_key/);
  assert.match(migration,/where business_id=p_business and evaluation_id=p_evaluation/);
  assert.match(command,/provider_payment_intent_id/);
  assert.match(command,/paymentIntents\.retrieve/);
  assert.match(migration,/app\.can_module_read_at_v94\(p_business,p_branch,'clients'\)/);
  assert.match(migration,/checkout_evaluation_operations o[\s\S]*o\.business_id=p_business[\s\S]*o\.evaluation_id=p_evaluation[\s\S]*o\.actor=p_actor/);
});

test('only a verified Connect webhook can finalize the sale and loyalty effects',()=>{
  assert.match(webhook,/constructEventAsync/);
  assert.match(webhook,/STRIPE_CONNECT_WEBHOOK_SECRET/);
  assert.match(webhook,/event\.account/);
  assert.match(webhook,/ingest_stripe_connect_event_v142/);
  assert.match(webhook,/apply_stripe_connect_payment_event_v142/);
  assert.match(migration,/v_event\.event_type='payment_intent\.succeeded'/);
  assert.match(migration,/public\.record_cart_sale\(/);
  assert.match(migration,/'paynow','v142-pos-'/);
  assert.match(migration,/status='refund_required'/);
  assert.match(webhook,/stripe\.refunds\.create/);
  assert.doesNotMatch(till,/record_cart_sale[\s\S]{0,500}p_method:'paynow_qr'/);
});

test('webhook rejects test/live mode mismatch before durable ingestion',()=>{
  const modeAt=webhook.indexOf('event.livemode !== expectedLivemode');
  const ingestAt=webhook.indexOf("rpc('ingest_stripe_connect_event_v142'");
  assert.ok(modeAt>=0&&ingestAt>modeAt,{modeAt,ingestAt});
  assert.match(webhook,/stripeSecret\.startsWith\('sk_test_'\)/);
  assert.match(webhook,/ignored: true, reason: 'mode_mismatch'/);
  assert.match(migration,/and livemode=p_livemode/);
});

test('test Connect accounts cannot be retrieved with live keys and promotion is one-way',()=>{
  assert.match(command,/p_livemode: livemode/);
  assert.match(migration,/where business_id=p_business and livemode=p_livemode/);
  assert.match(migration,/v_command\.livemode is distinct from p_livemode/);
  assert.match(migration,/not \(v_existing\.livemode=false and p_livemode=true\)/);
  assert.match(migration,/provider_account_id=excluded\.provider_account_id,livemode=excluded\.livemode/);
  assert.match(migration,/case when p_livemode then 'live-' else 'test-' end/);
  const beginAt=migration.indexOf('create or replace function public.begin_merchant_connect_command_v142');
  const downgradeAt=migration.indexOf('live merchant payment binding cannot be downgraded to test mode',beginAt);
  const commandInsertAt=migration.indexOf('insert into public.merchant_payment_commands_v142',beginAt);
  assert.ok(beginAt>=0&&downgradeAt>beginAt&&commandInsertAt>downgradeAt,
    {beginAt,downgradeAt,commandInsertAt});
  const beginRpcAt=command.indexOf("rpc(\n        'begin_merchant_connect_command_v142'");
  const providerCreateAt=command.indexOf('stripe.accounts.create');
  assert.ok(beginRpcAt>=0&&providerCreateAt>beginRpcAt,{beginRpcAt,providerCreateAt});
});

test('provider envelope mismatches and late successes require a provider refund, never a paid receipt',()=>{
  assert.match(migration,/v_attempt\.livemode is distinct from v_event\.livemode/);
  assert.match(migration,/v_amount is distinct from v_attempt\.amount_cents/);
  assert.match(migration,/v_currency is distinct from v_attempt\.currency/);
  assert.match(migration,/jsonb_build_object\('status','refund_required','attempt_id',v_attempt\.id,[\s\S]*'provider_account_id',v_attempt\.provider_account_id,[\s\S]*'payment_intent_id',v_attempt\.provider_payment_intent_id\)/);
  assert.match(migration,/v_event\.event_created_at>v_attempt\.expires_at/);
  assert.doesNotMatch(migration,/now\(\)>v_attempt\.expires_at/);
  assert.match(webhook,/applied\?\.status === 'refund_required'/);
  assert.match(webhook,/stripe\.refunds\.create/);
  assert.match(webhook,/const \{ error: markError \} = await admin\.rpc\('mark_pos_paynow_refund_state_v142'/);
  assert.match(webhook,/if \(markError\) throw new Error\('refund projection failed'\)/);
});

test('PayNow refunds remain pending until a signed terminal refund event',()=>{
  assert.match(webhook,/event\.type === 'refund\.updated'/);
  assert.match(webhook,/event\.type === 'refund\.failed'/);
  assert.match(webhook,/apply_stripe_connect_refund_event_v142/);
  assert.match(webhook,/p_provider_status: refund\.status/);
  assert.doesNotMatch(webhook,/mark_pos_paynow_refunded_v142/);
  assert.match(migration,/when p_provider_status='succeeded' then 'refunded'/);
  assert.match(migration,/when p_provider_status in \('failed','canceled'\) then 'refund_failed'/);
  assert.match(migration,/else 'refund_pending' end/);
  assert.match(migration,/v_attempt\.provider_refund_id is distinct from v_event\.object_id/);
  assert.match(migration,/app\.v142_signed_refund_event/);
  assert.match(migration,/not v_signed_event and v_attempt\.refund_event_id is not null/);
  assert.match(migration,/when not v_signed_event then 'refund_pending'/);
  assert.match(till,/Stripe accepted the refund request and is still processing it/);
  assert.match(till,/Issue a manual refund in Stripe/);
});

test('PayNow reserves one immutable exact-price evaluation for the full provider QR lifetime',()=>{
  assert.match(migration,/v_paynow_expires_at:=now\(\)\+interval '61 minutes'/);
  assert.match(migration,/set_config\('app\.v142_extend_checkout','on',true\)/);
  assert.match(migration,/update public\.checkout_evaluations set expires_at=v_paynow_expires_at where id=p_evaluation/);
  assert.doesNotMatch(migration,/insert into public\.checkout_evaluations\(/);
  assert.doesNotMatch(migration,/source_evaluation_id/);
  assert.match(migration,/pos_payment_attempt_eval_v142 unique \(evaluation_id\)/);
  assert.match(migration,/checkout evaluation is reserved for provider payment/);
  assert.match(migration,/app\.v142_provider_finalize/);
  assert.match(migration,/set_config\('app\.v142_provider_finalize',v_attempt\.id::text,true\)/);
  assert.match(migration,/create or replace function public\.activate_pos_paynow_qr_v142/);
  assert.match(migration,/if v_attempt\.qr_activated_at is null then/);
  assert.match(migration,/v_qr_expires_at:=clock_timestamp\(\)\+interval '61 minutes'/);
  const qrAt=command.indexOf('const qr = payNowQr(intent)');
  const activateAt=command.indexOf("'activate_pos_paynow_qr_v142'",qrAt);
  const responseAt=command.indexOf('return billingCorsJson(req, 200',activateAt);
  assert.ok(qrAt>=0&&activateAt>qrAt&&responseAt>activateAt,{qrAt,activateAt,responseAt});
  assert.match(till,/Stripe PayNow QRs stay valid for up to 1 hour/);
  assert.doesNotMatch(till,/QR expires \$\{esc\(attempt\.expires_at/);
});

test('provider QR data is rendered locally without a CSP-blocked remote image',()=>{
  assert.match(command,/data: qr\.data/);
  assert.doesNotMatch(command,/image_url_(?:png|svg):/);
  assert.match(till,/new QRCode\(qrHost,\{text:String\(qr\.data\)/);
  assert.doesNotMatch(till,/<img src="\$\{esc\(qr\.image_url/);
});

test('event inbox duplicate projection reflects whether INSERT actually inserted',()=>{
  assert.match(migration,/v_inserted boolean := false/);
  assert.match(migration,/returning \* into v_existing/);
  assert.match(migration,/v_inserted:=found/);
  assert.match(migration,/'duplicate',not v_inserted/);
});

test('merchant payment tables have no browser table grants and expose bounded status readers',()=>{
  for(const table of ['merchant_payment_accounts_v142','merchant_payment_commands_v142','pos_payment_attempts_v142','stripe_connect_event_inbox_v142']){
    assert.match(migration,new RegExp(`alter table public\\.${table} enable row level security`));
    assert.match(migration,new RegExp(`revoke all on public\\.${table} from public, anon, authenticated`));
  }
  assert.match(migration,/grant execute on function public\.get_merchant_payment_status_v142\(uuid\) to authenticated/);
  assert.match(migration,/grant execute on function public\.get_pos_paynow_attempt_v142\(uuid\) to authenticated/);
  assert.doesNotMatch(migration,/grant (?:select|insert|update|delete|all) on public\.(?:merchant_payment|pos_payment|stripe_connect)/i);
});

test('receipt lookup is bounded to active same-business staff and exact-branch module reads',()=>{
  assert.match(migration,/select 1 from public\.staff s where s\.business_id=v_attempt\.business_id[\s\S]*s\.user_id=auth\.uid\(\) and s\.active/);
  assert.match(migration,/app\.can_module_read_at_v94\(v_attempt\.business_id,v_attempt\.branch_id,'clients'\)/);
  assert.match(migration,/app\.can_module_read_at_v94\(v_attempt\.business_id,v_attempt\.branch_id,'till'\)/);
  assert.match(migration,/app\.can_module_read_at_v94\(v_attempt\.business_id,v_attempt\.branch_id,'sales'\)/);
  assert.match(migration,/when v_attempt\.status in \('prepared','awaiting_payment','processing'\)[\s\S]*v_attempt\.expires_at<=now\(\) then 'expired'/);
});

test('uncertain refresh recovery preserves the stable attempt and refund-required is not presented as refunded',()=>{
  assert.match(till,/if\(\/\^\[0-9a-f-\]\{36\}\$\/i\.test\(String\(request\.attempt_id\|\|''\)\)\)/);
  assert.match(till,/Payment outcome is still being checked\. Do not create another QR yet\./);
  assert.match(till,/previous PayNow request is still reserved/);
  assert.match(till,/refund request is being sent—do not charge this customer again/);
  assert.match(till,/data\.status==='refunded'/);
  assert.match(till,/valid for up to 1 hour/);
});

test('successful checkout presents a printable receipt without a customer-service phone field',()=>{
  assert.match(till,/id="posReceiptV142"/);
  assert.match(till,/id="tPrintReceiptV142"/);
  /* V385: the button no longer calls window.print() inline. In an iOS home-screen web app
     window.print() is a documented no-op — the owner pressed the button and nothing happened —
     so the handler now routes the standalone case through a real print window. */
  assert.match(till,/printPosReceiptV385\(\)/);
  assert.match(till,/Provider reference:/);
  assert.match(till,/Receipt \$\{esc\(String\(d\.saleId\)/);
  assert.doesNotMatch(till,/customer service phone|support phone/i);
  assert.match(app,/@media print[\s\S]*pos-receipt-print/);
  /* And the handler itself really does branch, rather than renaming the same no-op: a standalone
     web app gets its own print window, every other browser keeps the in-page path, and the
     print-only body class is always cleared even when print() throws. */
  const printer=app.slice(app.indexOf('const posReceiptStandaloneV385'));
  assert.match(printer,/navigator\?\.standalone===true/);
  assert.match(printer,/window\.open\('','_blank'\)/);
  assert.match(printer,/printWindow\.print\(\)/);
  assert.match(printer,/catch\(error\)\{clear\(\);toast\(/);
});

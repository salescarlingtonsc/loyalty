import { PDFDocument, StandardFonts, rgb } from 'npm:pdf-lib@1.17.1';

type Snapshot = Record<string, unknown>;
type DocumentInput = {
  number: string;
  type: string;
  snapshot: Snapshot;
};

const PAGE = [595.28, 841.89] as const;
const MARGIN = 48;

function text(value: unknown): string {
  return value == null ? '' : String(value);
}

function money(cents: unknown, currency = 'SGD'): string {
  const amount = Number(cents || 0) / 100;
  return new Intl.NumberFormat('en-SG', { style: 'currency', currency }).format(amount);
}

function date(value: unknown): string {
  const parsed = value ? new Date(String(value)) : null;
  return parsed && Number.isFinite(parsed.valueOf())
    ? new Intl.DateTimeFormat('en-SG', { day: '2-digit', month: '2-digit', year: 'numeric', timeZone: 'Asia/Singapore' }).format(parsed)
    : '';
}

function wrap(value: string, max = 82): string[] {
  const words = value.replace(/\s+/g, ' ').trim().split(' ').filter(Boolean);
  const lines: string[] = [];
  let current = '';
  for (const word of words) {
    const candidate = current ? `${current} ${word}` : word;
    if (candidate.length <= max) current = candidate;
    else {
      if (current) lines.push(current);
      current = word.length > max ? `${word.slice(0, max - 1)}…` : word;
    }
  }
  if (current) lines.push(current);
  return lines.length ? lines : [''];
}

export async function renderSubscriptionDocumentPdf(input: DocumentInput): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const snapshot = input.snapshot || {};
  const seller = (snapshot.seller || {}) as Snapshot;
  const customer = (snapshot.customer || snapshot.business || {}) as Snapshot;
  const bank = (seller.bank || {}) as Snapshot;
  const contact = (seller.contact || {}) as Snapshot;
  const currency = text(snapshot.currency || seller.currency || 'SGD');
  const title = input.type === 'receipt' ? 'RECEIPT' : input.type === 'quotation' ? 'QUOTATION' : input.type === 'subscription_summary' ? 'SUBSCRIPTION SUMMARY' : 'INVOICE';
  let page = pdf.addPage(PAGE);
  let y = PAGE[1] - MARGIN;
  const pages = [page];

  const newPage = () => {
    page = pdf.addPage(PAGE);
    pages.push(page);
    y = PAGE[1] - MARGIN;
  };
  const line = (value: string, options: { bold?: boolean; size?: number; gap?: number; color?: ReturnType<typeof rgb> } = {}) => {
    const size = options.size || 10;
    for (const part of wrap(value)) {
      if (y < 70) newPage();
      page.drawText(part, { x: MARGIN, y, size, font: options.bold ? bold : regular, color: options.color || rgb(0.16, 0.18, 0.2) });
      y -= options.gap || size + 5;
    }
  };
  const spacer = (height = 10) => { y -= height; };

  line(text(seller.brand_name || 'Peekaa'), { bold: true, size: 22, color: rgb(0.64, 0.16, 0.12), gap: 26 });
  line(`by ${text(seller.legal_name || '')}`, { bold: true, size: 11 });
  if (seller.uen) line(`UEN: ${text(seller.uen)}`);
  if (seller.registered_address) line(text(seller.registered_address));
  spacer(12);
  line(title, { bold: true, size: 18, gap: 24 });
  line(`Document number: ${input.number}`, { bold: true });
  if (snapshot.stripe_invoice_number) line(`Stripe invoice: ${text(snapshot.stripe_invoice_number)}`);
  if (snapshot.stripe_invoice_id) line(`Stripe reference: ${text(snapshot.stripe_invoice_id)}`);
  if (snapshot.issue_date) line(`Issue date: ${date(snapshot.issue_date)}`);
  if (snapshot.expiry_date) line(`Expiry date: ${date(snapshot.expiry_date)}`);
  if (snapshot.due_date) line(`Due date: ${date(snapshot.due_date)}`);
  spacer();

  line('BILL TO', { bold: true, size: 11 });
  line(text(customer.legal_entity_name || customer.business_display_name || ''));
  if (customer.registration_number) line(`Registration: ${text(customer.registration_number)}`);
  const address = customer.billing_address as Snapshot | string | undefined;
  if (address) line(typeof address === 'string' ? address : Object.values(address).filter(Boolean).join(', '));
  if (customer.contact_name) line(`Attn: ${text(customer.contact_name)}`);
  if (customer.primary_email) line(text(customer.primary_email));
  spacer();

  if (snapshot.plan) line(`Plan: ${text(snapshot.plan)}`, { bold: true });
  if (snapshot.billing_interval) line(`Billing interval: ${text(snapshot.billing_interval)}`);
  if (snapshot.active_since) line(`Active since: ${date(snapshot.active_since)}`);
  if (snapshot.service_period_start || snapshot.paid_period_start) {
    line(`Service period: ${date(snapshot.service_period_start || snapshot.paid_period_start)} – ${date(snapshot.service_period_end || snapshot.paid_period_end)}`);
  }
  if (snapshot.next_renewal) line(`Next renewal: ${date(snapshot.next_renewal)}`);
  if (snapshot.scheduled_end) line(`Scheduled to end: ${date(snapshot.scheduled_end)}`);
  if (snapshot.no_scheduled_end) line('No scheduled end date');

  const items = Array.isArray(snapshot.line_items) ? snapshot.line_items as Snapshot[] : [];
  if (items.length) {
    spacer();
    line('ITEMS', { bold: true, size: 11 });
    for (const item of items) {
      const quantity = Number(item.quantity || 1);
      line(`${text(item.description || item.name || 'Subscription service')}  × ${quantity}  ${money(Number(item.unit_amount_cents || 0) * quantity, currency)}`);
    }
  }
  spacer();
  if (snapshot.subtotal_cents != null) line(`Subtotal: ${money(snapshot.subtotal_cents, currency)}`);
  if (Number(snapshot.discount_cents || 0) > 0) line(`Discount: -${money(snapshot.discount_cents, currency)}`);
  if (Number(snapshot.tax_cents || 0) > 0) line(`GST: ${money(snapshot.tax_cents, currency)}`);
  if (snapshot.total_cents != null) line(`Total: ${money(snapshot.total_cents, currency)}`, { bold: true });
  if (snapshot.amount_paid_cents != null || snapshot.amount_received_cents != null) line(`Amount paid: ${money(snapshot.amount_paid_cents ?? snapshot.amount_received_cents, currency)}`);
  if (snapshot.balance_due_cents != null) line(`Balance due: ${money(snapshot.balance_due_cents, currency)}`);
  if (input.type === 'receipt') line(text(snapshot.payment_method_label || 'Payment received'), { bold: true });

  if (input.type !== 'subscription_summary') {
    spacer(14);
    line('PAYMENT DETAILS', { bold: true, size: 11 });
    line(`Account name: ${text(bank.account_name)}`);
    line(`Bank: ${text(bank.bank_name)}`);
    line(`Bank / branch code: ${text(bank.bank_code)} / ${text(bank.branch_code)}`);
    line(`SWIFT: ${text(bank.swift_code)}`);
    line(`Account number: ${text(bank.account_number)}`);
    if (input.type === 'invoice') line(`Transfer reference: ${input.number} – ${text(customer.business_display_name || customer.legal_entity_name)}`);
  }
  spacer(12);
  line(`Billing contact: ${text(contact.name)} · ${text(contact.mobile)}`);
  if (snapshot.notes) line(`Notes: ${text(snapshot.notes)}`);
  if (input.type === 'quotation') line('This quotation is a commercial offer and does not confirm payment.');
  if (input.type === 'receipt') line('This receipt confirms payment received and is not a request for further payment.');

  pages.forEach((value, index) => {
    value.drawText(`Page ${index + 1} of ${pages.length}`, { x: PAGE[0] - 105, y: 28, size: 9, font: regular, color: rgb(0.4, 0.4, 0.4) });
  });
  pdf.setTitle(`${title} ${input.number}`);
  pdf.setAuthor('NESTLY TECHNOLOGIES PTE. LTD.');
  pdf.setProducer('Peekaa subscription operations v156');
  return pdf.save({ useObjectStreams: false });
}

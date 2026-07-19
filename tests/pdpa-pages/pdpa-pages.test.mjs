import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = resolve(import.meta.dirname, '../..');
const pages = {
  privacy: readFileSync(resolve(root, 'app/privacy.html'), 'utf8'),
  terms: readFileSync(resolve(root, 'app/terms.html'), 'utf8'),
  request: readFileSync(resolve(root, 'app/data-request.html'), 'utf8')
};
const operations = readFileSync(resolve(root, 'docs/compliance/PDPA_OPERATIONS.md'), 'utf8');

function visibleText(html) {
  return html
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&(?:nbsp|copy|mdash|ndash);/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function assertHasIds(html, ids) {
  for (const id of ids) {
    assert.match(html, new RegExp(`id=["']${id}["']`), `missing section id ${id}`);
  }
}

test('all public policy pages are responsive, accessible and mutually linked', () => {
  for (const [name, html] of Object.entries(pages)) {
    assert.match(html, /<!DOCTYPE html>/i, `${name} lacks an HTML doctype`);
    assert.match(html, /<html lang="en">/i, `${name} lacks a page language`);
    assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1\.0">/i);
    assert.match(html, /<a class="skip" href="#main">Skip to content<\/a>/i);
    assert.match(html, /<main id="main">/i);
    assert.match(html, /<nav[^>]+aria-label="Policy navigation"/i);
    assert.match(html, /@media\(max-width:/i, `${name} lacks a responsive breakpoint`);
    assert.match(html, /:focus-visible/i, `${name} lacks visible keyboard focus styles`);
    assert.doesNotMatch(html, /<script\b/i, `${name} must remain script-free`);

    for (const path of ['privacy.html', 'terms.html', 'data-request.html']) {
      assert.match(html, new RegExp(`href=["']${path}(?:#[^"']*)?["']`), `${name} does not link to ${path}`);
    }
  }
});

test('privacy notice covers the required PDPA-facing subjects and role split', () => {
  const html = pages.privacy;
  const text = visibleText(html);

  assertHasIds(html, [
    'roles', 'data', 'purposes', 'sharing', 'marketing', 'rights',
    'retention', 'security', 'children', 'updates', 'contact'
  ]);

  for (const phrase of [
    'data intermediary',
    'separately responsible',
    'primary application database is configured for hosting in Singapore',
    'outside Singapore',
    'standard of protection comparable to the PDPA',
    'Do Not Call',
    'withdraw consent',
    'Access, correction, withdrawal and deletion requests',
    'notifiable',
    "Children's personal data"
  ]) {
    assert.match(text, new RegExp(phrase, 'i'), `privacy notice missing: ${phrase}`);
  }

  assert.match(html, /Interim Privacy Contact/i);
  assert.match(html, /not a statement that the named contact has been formally appointed/i);
  assert.match(html, /mailto:leechuanseng\.biz@gmail\.com/i);
  assert.match(html, /do not sell personal data/i);
  assert.doesNotMatch(text, /guarantee(?:d|s)? absolute security/i);
});

test('terms set merchant obligations and do not claim regulated payment processing', () => {
  const html = pages.terms;
  const text = visibleText(html);

  assertHasIds(html, [
    'agreement', 'service', 'merchant', 'customers', 'payments', 'acceptable-use',
    'privacy', 'availability', 'ip', 'termination', 'liability', 'changes', 'law'
  ]);

  for (const phrase of [
    'Merchant obligations',
    'Do Not Call',
    'loyalty points',
    'merchant, not Frenly',
    'not proof of payment settlement',
    'does not mean Frenly collected',
    'laws of Singapore',
    'account closure',
    'Intellectual property'
  ]) {
    assert.match(text, new RegExp(phrase, 'i'), `terms missing: ${phrase}`);
  }

  assert.match(html, /mailto:leechuanseng\.biz@gmail\.com/i);
  assert.doesNotMatch(text, /Frenly is (?:a|the) payment processor/i);
  assert.match(text, /it is not:.*a guarantee.*increase revenue/i);
});

test('data request page provides a usable, minimised manual process', () => {
  const html = pages.request;
  const text = visibleText(html);

  assertHasIds(html, ['request-types', 'process', 'send-request', 'special-cases', 'outcomes']);
  for (const phrase of [
    'Access',
    'Correction',
    'Withdraw consent',
    'Deletion or closure',
    'acknowledge receipt',
    'verify identity proportionately',
    'applicable PDPA timeframes',
    'authorised representative',
    'Do not email sensitive identity or payment information'
  ]) {
    assert.match(text, new RegExp(phrase, 'i'), `data request page missing: ${phrase}`);
  }

  assert.match(html, /mailto:leechuanseng\.biz@gmail\.com\?subject=Frenly%20data%20request/i);
  assert.match(text, /Do not send your password, one-time code, full payment-card number/i);
  assert.doesNotMatch(text, /we (?:guarantee|promise) (?:a )?response within/i);
  assert.doesNotMatch(html, /type=["']file["']/i);
  assert.doesNotMatch(html, /<form\b/i);
});

test('operations runbook blocks launch on formal DPO and operator evidence', () => {
  for (const phrase of [
    'Public launch is **blocked**',
    'Legal operator identity',
    'Formal DPO designation',
    'DPO registration and public contact',
    'Interim Privacy Contact',
    'organisation',
    'data intermediary',
    'Personal data inventory',
    'Consent register',
    'Incident register',
    'three calendar days',
    'Singapore region',
    'merchant data-processing agreement'
  ]) {
    assert.match(operations, new RegExp(phrase.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'), `runbook missing: ${phrase}`);
  }

  assert.match(operations, /ACRA BizFile\+ registration has been unavailable since 1 December 2024/i);
  assert.match(operations, /Formal designation and public availability are legal duties; registration is an additional Frenly launch-control requirement/i);
  assert.match(operations, /https:\/\/www\.pdpc\.gov\.sg\//i);
});

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

/* nestly_v671: associated domains — the AASA file the website serves and the entitlements the
   binary carries are two halves of one contract, edited in different places by different tools.
   Apple verifies them against each other at install time and fails silently, so the repo pins
   them against each other here instead: every identifier is DERIVED from the project files, not
   restated, and a drift in any of the four (AASA, entitlements, pbxproj team, capacitor appId)
   fails this suite before it can fail invisibly on a customer's phone. */

const root = new URL('../../', import.meta.url);
const read = rel => readFileSync(new URL(rel, root), 'utf8');

const aasa = JSON.parse(read('app/.well-known/apple-app-site-association'));
const team = read('ios/App/App.xcodeproj/project.pbxproj').match(/DEVELOPMENT_TEAM = ([A-Z0-9]{10});/)?.[1];
const bundleId = read('capacitor.config.ts').match(/appId:\s*'([a-z.]+)'/)?.[1];
const entitlements = read('ios/App/App/App.entitlements');

test('the AASA app identifiers are the real team and bundle id, never placeholders', () => {
  assert.ok(team, 'the signing team is recorded in the project');
  assert.equal(bundleId, 'asia.peekaa.app');
  const appId = `${team}.${bundleId}`;
  assert.deepEqual(aasa.applinks.details.flatMap(d => d.appIDs), [appId]);
  assert.deepEqual(aasa.webcredentials.apps, [appId]);
});

test('the binary claims exactly the domains the website can verify', () => {
  /* www only, deliberately: the apex 308-redirects to www, and Apple’s association fetch
     does not follow redirects — an apex entitlement would sit permanently unverified. */
  assert.match(entitlements, /<string>applinks:www\.peekaa\.asia<\/string>/);
  assert.match(entitlements, /<string>webcredentials:www\.peekaa\.asia<\/string>/);
  assert.doesNotMatch(entitlements, /<string>(?:applinks|webcredentials):peekaa\.asia<\/string>/);
});

test('the universal-link paths cover the routes the app actually handles', () => {
  const patterns = aasa.applinks.details.flatMap(d => d.components.map(c => c['/']));
  assert.deepEqual(patterns, ['/business*', '/join*', '/customer*']);
  /* /join* must cover both spellings the QR and share paths emit. */
  assert.ok(patterns.some(p => p === '/join*'), 'join links open in the app');
});

test('the website serves the association file as JSON', () => {
  const vercel = JSON.parse(read('app/vercel.json'));
  const rule = vercel.headers.find(h => h.source === '/.well-known/apple-app-site-association');
  assert.ok(rule, 'a header rule exists for the AASA path');
  assert.equal(rule.headers.find(h => h.key === 'Content-Type')?.value, 'application/json');
});

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { defaultManifestPath, evaluateGate, runCli } from '../../scripts/launch-readiness/check.mjs';

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function makeRoot() {
  const root = mkdtempSync(path.join(tmpdir(), 'launch-readiness-'));
  mkdirSync(path.join(root, 'docs', 'launch'), { recursive: true });
  mkdirSync(path.join(root, 'docs', 'launch', '.evidence', 'proof'), { recursive: true });
  return root;
}

function baseManifest() {
  return {
    schemaVersion: 'launch_readiness_manifest_v1',
    target: { projectRef: 'gadpooereceldfpfxsod', market: 'Singapore', environment: 'production' },
    policy: {
      p0ClosureStatus: 'VERIFIED_PRODUCTION',
      evidenceRoot: 'docs/launch/.evidence',
      evidenceKind: 'launch_readiness_evidence_v1'
    },
    blockers: [
      {
        id: 'P0-TEST-GATE-001',
        severity: 'P0',
        title: 'Synthetic P0',
        status: 'BLOCKED',
        owner: 'Release engineering',
        verification: {
          stage: 'PRODUCTION',
          method: 'Run synthetic validation.',
          successCriteria: ['Synthetic check passes.'],
          evidenceRequirements: ['Redacted synthetic proof.']
        },
        evidence: []
      }
    ]
  };
}

function writeManifest(root, manifest) {
  const manifestPath = path.join(root, defaultManifestPath);
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  return manifestPath;
}

function attachPassingEvidence(root, manifest) {
  const evidence = {
    kind: 'launch_readiness_evidence_v1',
    blockerId: manifest.blockers[0].id,
    stage: 'PRODUCTION',
    targetRef: manifest.target.projectRef,
    capturedAt: '2026-07-19T00:00:00Z',
    result: 'PASS',
    checks: { syntheticCheck: true },
    summary: 'Synthetic production proof passed.'
  };
  const content = `${JSON.stringify(evidence, null, 2)}\n`;
  const relativePath = 'docs/launch/.evidence/proof/P0-TEST-GATE-001.json';
  writeFileSync(path.join(root, relativePath), content);
  manifest.blockers[0].status = 'VERIFIED_PRODUCTION';
  manifest.blockers[0].evidence = [{ path: relativePath, sha256: sha256(content) }];
}

test('repository manifest is intentionally blocked until production evidence exists', () => {
  const manifest = JSON.parse(readFileSync(path.resolve(defaultManifestPath), 'utf8'));
  const result = evaluateGate(manifest);
  assert.equal(result.ok, false);
  assert.equal(result.summary.p0Total, 17);
  assert.equal(result.summary.p0ProvenClosed, 0);
  assert.equal(result.summary.p0Blocked, 17);
});

test('IMPLEMENTED and VERIFIED_STAGING P0 statuses remain launch-blocking', () => {
  const root = makeRoot();
  const manifest = baseManifest();
  manifest.blockers[0].status = 'IMPLEMENTED';
  manifest.blockers[0].verification.stage = 'IMPLEMENTATION';
  const implemented = evaluateGate(manifest, { root });
  assert.equal(implemented.ok, false);
  assert.equal(implemented.summary.p0Blocked, 1);

  manifest.blockers[0].status = 'VERIFIED_STAGING';
  manifest.blockers[0].verification.stage = 'STAGING';
  const staging = evaluateGate(manifest, { root });
  assert.equal(staging.ok, false);
  assert.equal(staging.summary.p0Blocked, 1);
});

test('schema validation rejects unstable IDs and unknown manifest fields', () => {
  const root = makeRoot();
  const manifest = baseManifest();
  manifest.blockers[0].id = 'launch-blocker';
  manifest.unreviewedShortcut = true;
  const result = evaluateGate(manifest, { root });
  assert.equal(result.ok, false);
  assert.ok(result.issues.some((entry) => entry.code === 'INVALID_ID'));
  assert.ok(result.issues.some((entry) => entry.code === 'UNKNOWN_FIELD'));
});

test('hash-pinned production evidence closes a P0 only when its artifact matches', () => {
  const root = makeRoot();
  const manifest = baseManifest();
  attachPassingEvidence(root, manifest);
  const result = evaluateGate(manifest, { root });
  assert.equal(result.ok, true);
  assert.equal(result.summary.p0ProvenClosed, 1);
});

test('missing or changed evidence blocks a claimed production closure', () => {
  const root = makeRoot();
  const manifest = baseManifest();
  attachPassingEvidence(root, manifest);
  const evidencePath = path.join(root, manifest.blockers[0].evidence[0].path);
  writeFileSync(evidencePath, `${readFileSync(evidencePath, 'utf8')} `);
  const result = evaluateGate(manifest, { root });
  assert.equal(result.ok, false);
  assert.equal(result.summary.p0Blocked, 1);
  assert.ok(result.issues.some((entry) => entry.code === 'EVIDENCE_HASH_MISMATCH'));
});

test('CLI exits one for an unproven P0 and zero only with valid production evidence', () => {
  const root = makeRoot();
  const manifest = baseManifest();
  writeManifest(root, manifest);
  assert.equal(runCli([], { root }), 1);

  attachPassingEvidence(root, manifest);
  writeManifest(root, manifest);
  assert.equal(runCli([], { root }), 0);
});

test('manifest rejects evidence that contains PII-shaped values or secrets', () => {
  const root = makeRoot();
  const manifest = baseManifest();
  attachPassingEvidence(root, manifest);
  const evidencePath = path.join(root, manifest.blockers[0].evidence[0].path);
  const evidence = JSON.parse(readFileSync(evidencePath, 'utf8'));
  evidence.summary = 'Synthetic proof for person@example.com.';
  const content = `${JSON.stringify(evidence, null, 2)}\n`;
  writeFileSync(evidencePath, content);
  manifest.blockers[0].evidence[0].sha256 = sha256(content);
  const result = evaluateGate(manifest, { root });
  assert.equal(result.ok, false);
  assert.ok(result.issues.some((entry) => entry.code === 'UNSAFE_CONTENT'));
});

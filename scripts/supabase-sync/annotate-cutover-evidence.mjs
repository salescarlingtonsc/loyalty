#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';

const [evidencePath, metadataPath, expectedTargetRef] = process.argv.slice(2);
if (!evidencePath || !metadataPath || !expectedTargetRef) {
  console.error('Usage: annotate-cutover-evidence.mjs <comparison.json> <deferred-cron.json> <target-ref>');
  process.exit(2);
}

const evidence = JSON.parse(readFileSync(evidencePath, 'utf8'));
const metadata = JSON.parse(readFileSync(metadataPath, 'utf8'));
writeFileSync(evidencePath, `${JSON.stringify({
  ...evidence,
  verified_target_ref: expectedTargetRef,
  ...metadata
}, null, 2)}\n`, { mode: 0o600 });

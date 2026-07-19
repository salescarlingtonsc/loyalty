#!/usr/bin/env node
import { readFileSync } from 'node:fs';

const [evidencePath, expectedTargetRef] = process.argv.slice(2);
if (!evidencePath || !expectedTargetRef) {
  console.error('Usage: validate-cutover-evidence.mjs <comparison.json> <target-ref>');
  process.exit(2);
}

const evidence = JSON.parse(readFileSync(evidencePath, 'utf8'));
const valid = evidence.ok === true &&
  evidence.launch_blocked === false &&
  evidence.verified_target_ref === expectedTargetRef &&
  evidence.cron_activation_deferred === true &&
  evidence.actual_target_cron_jobs === 0 &&
  Number(evidence.source_cron_jobs) >= 0 &&
  evidence.summary?.findings === 0 &&
  evidence.summary?.blockers === 0 &&
  Number(evidence.summary?.source_required_paths) > 0 &&
  evidence.summary?.source_required_paths === evidence.summary?.target_required_paths &&
  Array.isArray(evidence.findings) && evidence.findings.length === 0;

if (!valid) {
  console.error(`Cutover comparator evidence blocks target ${expectedTargetRef}.`);
  process.exit(1);
}

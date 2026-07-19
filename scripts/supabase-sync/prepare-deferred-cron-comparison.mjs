#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';

const [sourcePath, targetPath, normalizedTargetPath, metadataPath, expectedTargetRef] = process.argv.slice(2);
if (!sourcePath || !targetPath || !normalizedTargetPath || !metadataPath || !expectedTargetRef) {
  console.error('Usage: prepare-deferred-cron-comparison.mjs <source.json> <target.json> <normalized-target.json> <metadata.json> <target-ref>');
  process.exit(2);
}

const source = JSON.parse(readFileSync(sourcePath, 'utf8'));
const target = JSON.parse(readFileSync(targetPath, 'utf8'));
const sourceCron = source.inventory?.sections?.cron_jobs;
const targetCron = target.inventory?.sections?.cron_jobs;

if (source.inventory?.project_ref !== 'kyzovonwnscrzmkvocid' ||
    target.inventory?.project_ref !== expectedTargetRef ||
    !Array.isArray(sourceCron) || !Array.isArray(targetCron)) {
  throw new Error('Cutover envelopes have invalid refs or cron sections');
}
if (targetCron.length !== 0) {
  throw new Error('Target cron must be empty before strict verification and activation');
}

const normalized = structuredClone(target);
normalized.inventory.sections.cron_jobs = structuredClone(sourceCron);
writeFileSync(normalizedTargetPath, `${JSON.stringify(normalized, null, 2)}\n`, { mode: 0o600 });
writeFileSync(metadataPath, `${JSON.stringify({
  cron_activation_deferred: true,
  actual_target_cron_jobs: targetCron.length,
  source_cron_jobs: sourceCron.length
}, null, 2)}\n`, { mode: 0o600 });

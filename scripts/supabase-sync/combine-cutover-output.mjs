#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';

const [inventoryPath, reconciliationPath, outputPath, expectedRef, expectedScope] = process.argv.slice(2);
if (!inventoryPath || !reconciliationPath || !outputPath || !expectedRef || !expectedScope) {
  console.error('Usage: combine-cutover-output.mjs <inventory.json> <reconciliation.json> <output.json> <project-ref> <scope>');
  process.exit(2);
}

const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));
const inventory = readJson(inventoryPath);
const reconciliation = readJson(reconciliationPath);

if (inventory.kind !== 'supabase_cutover_inventory_v1' ||
    reconciliation.kind !== 'supabase_cutover_reconciliation_v1') {
  throw new Error('Cutover outputs have unexpected kinds');
}
for (const output of [inventory, reconciliation]) {
  if (output.project_ref !== expectedRef || output.scope !== expectedScope) {
    throw new Error('Cutover output project ref or scope does not match the requested database');
  }
}

writeFileSync(outputPath, `${JSON.stringify({ inventory, reconciliation }, null, 2)}\n`, { mode: 0o600 });

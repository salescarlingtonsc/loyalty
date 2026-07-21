import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { validate } = require('../../app/runtime-config-loader.js');
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..', '..');

function parseArgs(argv) {
  const result = { check: false, config: null };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--check') result.check = true;
    else if (argv[index] === '--config' && argv[index + 1]) result.config = argv[++index];
    else throw new Error('Usage: node scripts/runtime-config/generate.mjs --config <path> [--check]');
  }
  if (!result.config) throw new Error('A runtime config path is required.');
  return result;
}

function runtimeSource(config) {
  const serialized = JSON.stringify(config, null, 2).replaceAll('<', '\\u003c');
  return `/* Generated from an explicit public runtime configuration. Do not place secrets here. */\n`
    + `window.__FRENLY_RUNTIME_CONFIG__ = Object.freeze(${serialized});\n`;
}

function websocketOrigin(httpOrigin) {
  const url = new URL(httpOrigin);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  return url.origin;
}

async function expectedArtifacts(configPath) {
  const raw = JSON.parse(await readFile(configPath, 'utf8'));
  const config = validate(raw);
  const template = await readFile(path.join(repoRoot, 'config/runtime/vercel.template.json'), 'utf8');
  const renderedTemplate = template
    .replaceAll('{{SUPABASE_HTTP_ORIGIN}}', config.supabaseUrl)
    .replaceAll('{{SUPABASE_WS_ORIGIN}}', websocketOrigin(config.supabaseUrl));
  const vercel = `${JSON.stringify(JSON.parse(renderedTemplate), null, 2)}\n`;
  return { runtime: runtimeSource(config), vercel };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const configPath = path.resolve(repoRoot, args.config);
  const expected = await expectedArtifacts(configPath);
  const targets = [
    [path.join(repoRoot, 'app/runtime-config.js'), expected.runtime],
    [path.join(repoRoot, 'app/vercel.json'), expected.vercel]
  ];
  if (args.check) {
    for (const [target, content] of targets) {
      assert.equal(await readFile(target, 'utf8'), content,
        `${path.relative(repoRoot, target)} is not generated from ${path.relative(repoRoot, configPath)}`);
    }
    return;
  }
  for (const [target, content] of targets) await writeFile(target, content, 'utf8');
}

await main();

import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const indexHtml = await readFile(new URL('../../app/index.html', import.meta.url), 'utf8');
const appScript = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

// The SPA's JavaScript is whatever the browser executes at boot: any remaining
// executable inline scripts in the shell markup, plus the deferred external
// bundle app/app.js that now carries the application itself. Every one of them
// must parse before browser boot.
function executableInlineScripts(html) {
  return [...html.matchAll(/<script(?<attrs>[^>]*)>(?<source>[\s\S]*?)<\/script>/gi)]
    .filter(({ groups }) => !/\bsrc\s*=/i.test(groups?.attrs || ''))
    .filter(({ groups }) => {
      const type = (groups?.attrs || '').match(/\btype\s*=\s*["']([^"']+)["']/i)?.[1]?.toLowerCase();
      return !type || ['text/javascript', 'application/javascript'].includes(type);
    })
    .map(({ groups }, index) => ({ filename: `app/index.html:inline-${index + 1}.js`, source: groups?.source || '' }));
}

test('every executable inline script in the SPA parses before browser boot', () => {
  const scripts = [...indexHtml.matchAll(/<script(?<attrs>[^>]*)>/gi)];
  assert.ok(scripts.length > 0, 'index.html must contain executable scripts');
  // v183: the tag carries a cache-busting fingerprint (?b=<hash>), so match the path, not the
  // whole attribute value.
  assert.match(indexHtml, /<script[^>]*\bsrc\s*=\s*["'][^"']*\/?app\.js(?:\?b=[0-9a-f]{12})?["']/i,
    'index.html must load the application bundle app/app.js');

  const units = [...executableInlineScripts(indexHtml), { filename: 'app/app.js', source: appScript }];
  assert.ok(units.length > 0, 'at least one executable script must be syntax-checked');

  for (const { filename, source } of units) {
    assert.doesNotThrow(() => new vm.Script(source, { filename }),
      `${filename} must be valid JavaScript`);
  }
});

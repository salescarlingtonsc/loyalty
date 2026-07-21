import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const indexHtml = await readFile(new URL('../../app/index.html', import.meta.url), 'utf8');

test('every executable inline script in the SPA parses before browser boot', () => {
  const scripts = [...indexHtml.matchAll(/<script(?<attrs>[^>]*)>(?<source>[\s\S]*?)<\/script>/gi)];
  assert.ok(scripts.length > 0, 'index.html must contain executable scripts');

  let checked = 0;
  scripts.forEach(({ groups }, index) => {
    const attrs = groups?.attrs || '';
    if (/\bsrc\s*=/i.test(attrs)) return;
    const type = attrs.match(/\btype\s*=\s*["']([^"']+)["']/i)?.[1]?.toLowerCase();
    if (type && !['text/javascript', 'application/javascript'].includes(type)) return;
    checked += 1;
    assert.doesNotThrow(
      () => new vm.Script(groups?.source || '', { filename: `app/index.html:inline-${index + 1}.js` }),
      `inline script ${index + 1} must be valid JavaScript`
    );
  });

  assert.ok(checked > 0, 'at least one executable inline script must be syntax-checked');
});

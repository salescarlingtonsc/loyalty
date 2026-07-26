import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(new URL('../../app/customer-ui.js', import.meta.url), 'utf8');

test('route focus remains accessible without forcing the workspace to scroll', () => {
  const start = source.indexOf('function focusRoute(');
  const end = source.indexOf('const liveRegionState', start);
  assert.ok(start >= 0 && end > start, 'focusRoute helper must remain present');
  const block = source.slice(start, end);
  assert.match(block, /target\.focus\(\{preventScroll:true\}\)/);
  assert.doesNotMatch(block, /preventScroll:false/);
});

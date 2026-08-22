/**
 * The URLs scripts/quality/regen-visual-fixtures.mjs hands to the two Chrome-capture scripts
 * (V104_FIXTURE_URL / V142_FIXTURE_URL), pulled into their own side-effect-free module so a test
 * can prove they are derived from the server's OWN port rather than a hardcoded default (see
 * fixture-cross-tree-guard.mjs / REG-009 for why that distinction matters).
 */
export function visualFixtureUrls(port) {
  const origin = `http://127.0.0.1:${port}`;
  return {
    V104_FIXTURE_URL: `${origin}/tests/browser/v104-promotions-visual.html`,
    V142_FIXTURE_URL: `${origin}/tests/browser/v142-connect-paynow-visual.html`,
  };
}

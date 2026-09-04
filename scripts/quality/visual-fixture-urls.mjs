/**
 * The URL scripts/quality/regen-visual-fixtures.mjs hands to its Chrome-capture script
 * (V104_FIXTURE_URL), pulled into its own side-effect-free module so a test can prove it is
 * derived from the server's OWN port rather than a hardcoded default (see
 * fixture-cross-tree-guard.mjs / REG-009 for why that distinction matters).
 *
 * nestly_v755: V142_FIXTURE_URL (Stripe Connect / PayNow QR) is retired along with the feature
 * it captured — Razorpay SG has no equivalent. See RAZORPAY_SWAP_SPEC.md.
 */
export function visualFixtureUrls(port) {
  const origin = `http://127.0.0.1:${port}`;
  return {
    V104_FIXTURE_URL: `${origin}/tests/browser/v104-promotions-visual.html`,
  };
}

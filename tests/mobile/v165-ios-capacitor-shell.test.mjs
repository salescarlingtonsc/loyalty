import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { test } from 'node:test';

const root = new URL('../../', import.meta.url);

function read(relativePath) {
  return readFileSync(new URL(relativePath, root), 'utf8');
}

test('V165 uses the existing Capacitor iPhone wrapper for Peekaa', () => {
  const config = read('capacitor.config.ts');

  assert.match(config, /appId:\s*'asia\.peekaa\.app'/);
  assert.match(config, /appName:\s*'Peekaa'/);
  assert.match(config, /webDir:\s*'dist\/mobile'/);
  assert.match(config, /androidScheme:\s*'https'/);
  assert.doesNotMatch(config, /url:\s*['"]https?:\/\//, 'native shell must not hard-code the Vercel deployment URL');

  assert.ok(existsSync(new URL('ios/App/App.xcodeproj', root)), 'iOS Xcode project exists');
  assert.ok(
    existsSync(new URL('ios/App/App.xcodeproj/project.xcworkspace', root)),
    'Xcode workspace exists inside the generated project',
  );
});

test('V165 iOS shell has the expected app identity and QR camera permission', () => {
  const plist = read('ios/App/App/Info.plist');

  assert.match(plist, /<key>CFBundleDisplayName<\/key>\s*<string>Peekaa<\/string>/);
  assert.match(plist, /<key>LSRequiresIPhoneOS<\/key>\s*<true\/>/);
  assert.match(plist, /<key>NSCameraUsageDescription<\/key>/);
  assert.match(plist, /scan a business, customer, or redemption QR code/);
});

test('V165 locks the Capacitor Swift package resolution used by Xcode', () => {
  const resolved = JSON.parse(
    read('ios/App/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'),
  );

  const capacitorSwiftPm = resolved.pins.find((pin) => pin.identity === 'capacitor-swift-pm');
  assert.ok(capacitorSwiftPm, 'Capacitor SwiftPM package is resolved');
  assert.equal(capacitorSwiftPm.location, 'https://github.com/ionic-team/capacitor-swift-pm.git');
  assert.equal(capacitorSwiftPm.state.version, '8.5.0');
  assert.match(capacitorSwiftPm.state.revision, /^[0-9a-f]{40}$/);
});

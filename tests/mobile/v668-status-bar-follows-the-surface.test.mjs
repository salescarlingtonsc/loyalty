import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

/* nestly_v668 (owner, physical iPhone photo: the strip above the WebView was black against
   Peekaa's light page). The cause was not the status bar's style but the WebView's own
   background: left unset it follows the DEVICE appearance, and Peekaa's theme is a stored
   preference that defaults to LIGHT (v190) rather than the device's. On a dark-mode phone the
   two disagreed, so every safe-area strip the scroll view insets away rendered black.

   These assertions EXECUTE the bridge against a stubbed Capacitor rather than grepping the
   source, because the failure mode being guarded is a wrong VALUE ('DARK' where 'LIGHT'
   belongs), which a substring check would happily pass. */

const root = new URL('../../', import.meta.url);
const read = relativePath => readFileSync(new URL(relativePath, root), 'utf8');

function loadBridge({ native = true } = {}) {
  const styles = [];
  const window = {
    Capacitor: {
      isNativePlatform: () => native,
      getPlatform: () => 'ios',
      Plugins: {
        StatusBar: {
          setStyle: async ({ style }) => { styles.push(style); },
        },
      },
    },
    navigator: { onLine: true },
    location: { href: 'https://localhost/' },
    addEventListener() {},
    dispatchEvent() {},
    open() {},
    CustomEvent: class { constructor(type, init) { this.type = type; Object.assign(this, init); } },
  };
  const context = vm.createContext({ window, CustomEvent: window.CustomEvent, URL, console });
  vm.runInContext(read('app/native-bridge.js'), context);
  return { bridge: window.NestlyNativeBridge, styles };
}

test('a light Peekaa surface asks iOS for dark status-bar icons', async () => {
  const { bridge, styles } = loadBridge();
  assert.equal(await bridge.syncStatusBar(false), true);
  /* Capacitor's Style.LIGHT describes the BACKGROUND, not the icons: it means dark content for
     a light background. Reading it the other way round is what would reinstate the bug. */
  assert.deepEqual(styles, ['LIGHT']);
});

test('a dark Peekaa surface asks iOS for light status-bar icons', async () => {
  const { bridge, styles } = loadBridge();
  await bridge.syncStatusBar(true);
  assert.deepEqual(styles, ['DARK']);
});

test('on the web the status bar call is a no-op, not a crash', async () => {
  const { bridge, styles } = loadBridge({ native: false });
  assert.equal(await bridge.syncStatusBar(true), false);
  assert.deepEqual(styles, []);
});

test('the theme switch is the one place that drives the native bar', () => {
  const core = read('app/app-core.js');
  /* applyCustomerThemeV190 already owns the theme-color meta; the native bar rides with it so
     the two can never disagree. `dark` is the same boolean both consumers receive. */
  assert.match(core, /syncStatusBar\?\.\(dark\)/);
});

test('the native shell supplies Peekaa’s background, not the device’s', () => {
  const config = read('capacitor.config.ts');
  /* The colour the WebView paints before first paint and under the safe areas. It must equal
     --bg in app.css and background_color in the manifest — native cannot read a CSS variable,
     so this is the one permitted repetition of it. */
  assert.match(config, /backgroundColor:\s*'#F4F2EE'/);
  assert.match(read('app/app.css'), /--bg:#F4F2EE/);
  assert.equal(JSON.parse(read('app/manifest.webmanifest')).background_color, '#F4F2EE');

  /* Declared in config so the native plugin applies it at launch, before the WebView loads —
     a runtime JS call would leave a frame of the wrong bar. */
  assert.match(config, /overlaysWebView:\s*true/);
  assert.match(config, /style:\s*'LIGHT'/);
});

test('the launch screen can never flash the device’s black', () => {
  const storyboard = read('ios/App/App/Base.lproj/LaunchScreen.storyboard');
  assert.doesNotMatch(storyboard, /systemBackgroundColor/,
    'systemBackground resolves to black in dark mode, which is the flash being removed');
  /* Matches the Splash asset itself (#F7EBDB), so any edge the aspect-fill leaves is the same
     cream rather than a second colour. */
  assert.match(storyboard, /red="0\.968627/);
});

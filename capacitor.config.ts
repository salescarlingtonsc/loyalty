import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'asia.peekaa.app',
  appName: 'Peekaa',
  webDir: 'dist/mobile',
  server: {
    androidScheme: 'https',
  },
  ios: {
    contentInset: 'automatic',
    /* The WebView's own background, seen wherever the page has not painted yet: before first
       paint, and in the safe-area strips the scroll view insets away. Left unset it follows the
       DEVICE appearance, so a dark-mode phone showed a black band against Peekaa's light page —
       the app's theme is its own preference (v190 defaults to light), never the device's. This is
       the same value as --bg in app.css and background_color in the manifest; native cannot read
       a CSS custom property, so the canonical colour is repeated here and nowhere else. */
    backgroundColor: '#F4F2EE',
  },
  android: {
    allowMixedContent: false,
  },
  plugins: {
    /* Applied natively at launch, before the WebView loads, so the bar is never briefly wrong.
       overlaysWebView lets the page paint its own top strip — every shell already reserves it
       with padding:max(..., env(safe-area-inset-top)) — and the style is corrected at runtime
       from the app's theme in applyCustomerThemeV190(). LIGHT means dark icons for a light
       background, which is the default surface. */
    StatusBar: {
      overlaysWebView: true,
      style: 'LIGHT',
    },
  },
};

export default config;

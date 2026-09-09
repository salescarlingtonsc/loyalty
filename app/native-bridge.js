(function installNestlyNativeBridge(global) {
  'use strict';

  const capacitor = global.Capacitor;
  const isNative = Boolean(capacitor?.isNativePlatform?.());
  const plugins = capacitor?.Plugins || {};
  const publicOrigin = 'https://www.peekaa.asia';
  const publicUrl = (path = '/') => {
    const target = new URL(String(path || '/'), `${publicOrigin}/`);
    if (target.origin !== publicOrigin) throw new Error('Peekaa public links must use the canonical origin');
    return target.href;
  };

  /* Shared by biometricSignIn.availability() and appLock.available() below. Hoisted out here,
     rather than having appLock.available() call `bridge.biometricSignIn.availability()`,
     because `bridge` does not exist yet while its own object literal is still being built. */
  async function biometricAvailability() {
    if (!isNative || !plugins.BiometricCredential?.availability) return { available: false, biometry: 'none' };
    try { return await plugins.BiometricCredential.availability(); }
    catch { return { available: false, biometry: 'none' }; }
  }

  const bridge = Object.freeze({
    isNative,
    platform: isNative ? capacitor.getPlatform?.() || 'native' : 'web',
    publicOrigin,
    publicUrl,
    async networkStatus() {
      if (!isNative || !plugins.Network?.getStatus) {
        return { connected: global.navigator.onLine, connectionType: 'unknown' };
      }
      return plugins.Network.getStatus();
    },
    async haptic(style = 'Light') {
      if (!isNative || !plugins.Haptics?.impact) return false;
      await plugins.Haptics.impact({ style });
      return true;
    },
    async share({ title = 'Peekaa', text = '', url = '' } = {}) {
      if (isNative && plugins.Share?.share) {
        await plugins.Share.share({ title, text, url, dialogTitle: title });
        return true;
      }
      if (global.navigator.share) {
        await global.navigator.share({ title, text, url });
        return true;
      }
      return false;
    },
    /* nestly_v670 — Face ID sign-in for the shell, backed by the app-local BiometricCredential
       plugin (Keychain item behind a biometry-gated access control; reading it IS the Face ID
       prompt). Passkeys cannot run in a WKWebView (v669), so this is the native equivalent.
       Every method degrades to an inert answer on the web and on a native build without the
       plugin, so callers never need a try/catch ladder. The password passes through here for
       exactly one call and is never retained, logged, or attached to anything. */
    biometricSignIn: {
      async availability() { return biometricAvailability(); },
      async enrolled() {
        if (!isNative || !plugins.BiometricCredential?.enrolled) return false;
        try { return (await plugins.BiometricCredential.enrolled())?.enrolled === true; }
        catch { return false; }
      },
      async store({ phone, password } = {}) {
        if (!isNative || !plugins.BiometricCredential?.store) return false;
        if (!phone || !password) return false;
        try { return (await plugins.BiometricCredential.store({ phone, password }))?.status === 'ok'; }
        catch { return false; }
      },
      async retrieve() {
        if (!isNative || !plugins.BiometricCredential?.retrieve) return { status: 'unavailable' };
        try {
          const result = await plugins.BiometricCredential.retrieve();
          return ['ok', 'missing', 'canceled', 'failed'].includes(result?.status) ? result : { status: 'failed' };
        } catch { return { status: 'failed' }; }
      },
      async clear() {
        if (!isNative || !plugins.BiometricCredential?.clear) return true;
        try { return (await plugins.BiometricCredential.clear())?.status === 'ok'; }
        catch { return false; }
      },
    },
    /* nestly_v860 — biometric APP LOCK: a re-auth gate the customer can opt into, requiring
       their face/fingerprint (or the device passcode, iOS's own fallback) to re-enter the app.
       Separate from biometricSignIn above: this never reads or writes the stored sign-in
       credential, it only asks "is this still the device owner?" and remembers whether the
       customer wants that check on. Same defensive shape as biometricSignIn: every method
       degrades to an inert answer on the web and on a native build without the plugin, and a
       throwing or malformed plugin answer never leaks upward as a truthy success.
       IMPORTANT: the JS bundle ships to peekaa.asia the moment it's pushed, but the App Store
       build lags behind it by days to weeks. An installed build can be running a Swift plugin
       that predates these three methods, so every branch here must answer inertly in that
       case ('unavailable' / false) — never throw — exactly as if app lock did not exist yet. */
    appLock: {
      /* Availability is a question about THIS BUILD, not only about the phone. The web bundle
         reaches a customer the moment it is pushed; the App Store build follows days later, so an
         installed shell can be running a native half that predates the app lock while the JS
         already offers it. Asking the phone alone would answer "yes, Face ID is right here" and
         put a switch on screen that nothing behind it can honour — so the plugin method the lock
         actually needs is part of the question. */
      async available() {
        if (!isNative || !plugins.BiometricCredential?.authenticate) return { available: false, biometry: 'none' };
        return biometricAvailability();
      },
      async authenticate({ reason = 'Unlock Peekaa' } = {}) {
        if (!isNative || !plugins.BiometricCredential?.authenticate) return { status: 'unavailable' };
        try {
          const result = await plugins.BiometricCredential.authenticate({ reason: String(reason).slice(0, 120) });
          return ['ok', 'canceled', 'failed', 'lockout', 'unavailable'].includes(result?.status)
            ? { status: result.status }
            : { status: 'failed' };
        } catch { return { status: 'failed' }; }
      },
      async enabled() {
        if (!isNative || !plugins.BiometricCredential?.lockPreference) return false;
        try { return (await plugins.BiometricCredential.lockPreference())?.enabled === true; }
        catch { return false; }
      },
      async setEnabled(enabled) {
        if (!isNative || !plugins.BiometricCredential?.setLockPreference) return false;
        const want = enabled === true;
        try {
          const result = await plugins.BiometricCredential.setLockPreference({ enabled: want });
          return result?.status === 'ok' && result?.enabled === want;
        } catch { return false; }
      },
    },
    /* The status bar follows the APP's surface, not the device's appearance. Peekaa's theme is a
       stored preference that defaults to light (v190), so on a dark-mode phone the two disagree
       and iOS would paint white icons over Peekaa's light page. Called from
       applyCustomerThemeV190(), which is the one place the surface flips.
       Capacitor's Style.Light means "dark icons, for a light background" — the naming describes
       the background, not the icons, and reading it the other way inverts the fix. */
    async syncStatusBar(dark = false) {
      if (!isNative || !plugins.StatusBar?.setStyle) return false;
      await plugins.StatusBar.setStyle({ style: dark ? 'DARK' : 'LIGHT' });
      return true;
    },
    async openExternal(url) {
      const target = new URL(url, global.location.href);
      if (target.protocol !== 'https:') throw new Error('Only HTTPS links are allowed');
      if (isNative && plugins.Browser?.open) {
        await plugins.Browser.open({ url: target.href });
        return true;
      }
      global.open(target.href, '_blank', 'noopener,noreferrer');
      return true;
    },
  });

  global.NestlyNativeBridge = bridge;
  if (!isNative) return;

  plugins.App?.addListener?.('appUrlOpen', ({ url }) => {
    try {
      const target = new URL(url);
      if (target.protocol !== 'https:' || target.hostname !== 'www.peekaa.asia') return;
      global.location.assign(`${target.pathname}${target.search}${target.hash}`);
    } catch {
      // Ignore malformed provider callbacks rather than navigating unexpectedly.
    }
  });
  plugins.Network?.addListener?.('networkStatusChange', (status) => {
    global.dispatchEvent(new CustomEvent('nestly:native-network', { detail: status }));
  });
})(window);

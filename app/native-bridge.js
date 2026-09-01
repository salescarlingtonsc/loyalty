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

(function installNestlyNativeBridge(global) {
  'use strict';

  const capacitor = global.Capacitor;
  const isNative = Boolean(capacitor?.isNativePlatform?.());
  const plugins = capacitor?.Plugins || {};
  const publicOrigin = 'https://www.nestly.asia';
  const publicUrl = (path = '/') => {
    const target = new URL(String(path || '/'), `${publicOrigin}/`);
    if (target.origin !== publicOrigin) throw new Error('Nestly public links must use the canonical origin');
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
    async share({ title = 'Nestly', text = '', url = '' } = {}) {
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
      if (target.protocol !== 'https:' || target.hostname !== 'www.nestly.asia') return;
      global.location.assign(`${target.pathname}${target.search}${target.hash}`);
    } catch {
      // Ignore malformed provider callbacks rather than navigating unexpectedly.
    }
  });
  plugins.Network?.addListener?.('networkStatusChange', (status) => {
    global.dispatchEvent(new CustomEvent('nestly:native-network', { detail: status }));
  });
})(window);

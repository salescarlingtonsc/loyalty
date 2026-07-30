// Production browser PushSubscription endpoints supported by Nestly:
// - Chromium: fcm.googleapis.com, current /wp/ and retained /fcm/send/ shapes.
// - Firefox: updates.push.services.mozilla.com, current /wpush/v2/ and retained /push/.
// - Safari/WebKit: any Apple-controlled subdomain of push.apple.com, as WebKit
//   explicitly requires for tightly managed endpoint allowlists.
// The URL must be HTTPS with no credentials, custom port, or fragment. Path
// tokens are opaque and queries are preserved, but the authority is never.
export function supportedCustomerPushEndpoint(value) {
  const authority = typeof value === 'string'
    ? value.match(/^https:\/\/([^/?#]+)/)?.[1] || ''
    : '';
  if (!authority || authority.includes('@') || authority.includes(':')) return false;
  let url;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (
    url.protocol !== 'https:' || url.username || url.password || url.port ||
    url.hash || !url.pathname || url.pathname === '/'
  ) return false;

  const host = url.hostname.toLowerCase();
  if (host === 'fcm.googleapis.com') {
    return /^\/(?:wp|fcm\/send)\/[^/?#]+$/.test(url.pathname);
  }
  if (host === 'updates.push.services.mozilla.com') {
    return /^\/(?:wpush\/v2|push)\/[^/?#]+$/.test(url.pathname);
  }
  return host !== 'push.apple.com' &&
    /^(?:[a-z0-9-]+\.)+push\.apple\.com$/.test(host) &&
    /^\/[^#\s]+$/.test(url.pathname);
}

export function customerPushDeadlineElapsed(deadlineAt, nowMs = Date.now()) {
  if (deadlineAt === null || deadlineAt === undefined || deadlineAt === '') {
    return false;
  }
  const deadlineMs = Date.parse(String(deadlineAt));
  return !Number.isFinite(deadlineMs) || deadlineMs <= nowMs;
}

export function customerPushTtlSeconds(deadlineAt, nowMs = Date.now()) {
  if (deadlineAt === null || deadlineAt === undefined || deadlineAt === '') {
    return 86400;
  }
  const deadlineMs = Date.parse(String(deadlineAt));
  if (!Number.isFinite(deadlineMs)) return 0;
  return Math.max(0, Math.min(86400, Math.floor((deadlineMs - nowMs) / 1000)));
}

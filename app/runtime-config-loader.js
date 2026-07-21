(function initFrenlyRuntimeConfig(globalObject) {
  'use strict';

  const PRODUCTION_PROJECT_REF = 'gadpooereceldfpfxsod';
  const ENVIRONMENTS = new Set(['development', 'test', 'staging', 'production']);
  const REMOTE_HOST = /^(?<ref>[a-z0-9]{20})\.supabase\.co$/;
  const PUBLISHABLE_KEY = /^sb_publishable_[A-Za-z0-9_-]{20,}$/;
  const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

  class RuntimeConfigError extends Error {
    constructor(code) {
      super('Frenly runtime configuration is unavailable.');
      this.name = 'RuntimeConfigError';
      this.code = code;
    }
  }

  function fail(code) {
    throw new RuntimeConfigError(code);
  }

  function exactKeys(value, expected, code) {
    const actual = Object.keys(value).sort();
    const wanted = [...expected].sort();
    if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
      fail(code);
    }
  }

  function decodeBase64Url(value) {
    const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
    const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
    if (typeof globalObject.atob === 'function') return globalObject.atob(padded);
    if (typeof Buffer !== 'undefined') return Buffer.from(padded, 'base64').toString('utf8');
    fail('CONFIG_KEY');
  }

  function isLegacyAnonKey(value) {
    const parts = value.split('.');
    if (parts.length !== 3 || parts.some((part) => !/^[A-Za-z0-9_-]+$/.test(part))) return false;
    try {
      const header = JSON.parse(decodeBase64Url(parts[0]));
      const payload = JSON.parse(decodeBase64Url(parts[1]));
      return header && typeof header.alg === 'string' && payload && payload.role === 'anon';
    } catch {
      return false;
    }
  }

  function validate(raw) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) fail('CONFIG_MISSING');
    exactKeys(raw, [
      'schemaVersion', 'environment', 'projectRef', 'supabaseUrl', 'supabasePublishableKey'
    ], 'CONFIG_SCHEMA');
    if (raw.schemaVersion !== 1) fail('CONFIG_SCHEMA');
    if (!ENVIRONMENTS.has(raw.environment)) fail('CONFIG_ENVIRONMENT');
    if (typeof raw.projectRef !== 'string') fail('CONFIG_PROJECT_REF');
    if (typeof raw.supabaseUrl !== 'string') fail('CONFIG_URL');
    if (typeof raw.supabasePublishableKey !== 'string') fail('CONFIG_KEY');

    let url;
    try {
      url = new URL(raw.supabaseUrl);
    } catch {
      fail('CONFIG_URL');
    }
    if (url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
      fail('CONFIG_URL');
    }

    const remote = url.hostname.match(REMOTE_HOST);
    const loopback = LOOPBACK_HOSTS.has(url.hostname);
    if (remote) {
      if (url.protocol !== 'https:' || url.port || raw.projectRef !== remote.groups.ref) {
        fail('CONFIG_PROJECT_REF');
      }
    } else if (loopback) {
      if (!['development', 'test'].includes(raw.environment)
          || !['http:', 'https:'].includes(url.protocol)
          || raw.projectRef !== 'local') {
        fail('CONFIG_PROJECT_REF');
      }
    } else {
      fail('CONFIG_URL');
    }

    if ((raw.environment === 'production') !== (raw.projectRef === PRODUCTION_PROJECT_REF)) {
      fail('CONFIG_ENVIRONMENT_BOUNDARY');
    }
    if (!PUBLISHABLE_KEY.test(raw.supabasePublishableKey)
        && !isLegacyAnonKey(raw.supabasePublishableKey)) {
      fail('CONFIG_KEY');
    }

    return Object.freeze({
      schemaVersion: raw.schemaVersion,
      environment: raw.environment,
      projectRef: raw.projectRef,
      supabaseUrl: url.origin,
      supabasePublishableKey: raw.supabasePublishableKey
    });
  }

  function requireConfig(target = globalObject) {
    return validate(target && target.__FRENLY_RUNTIME_CONFIG__);
  }

  function renderFailure(root) {
    if (!root) return;
    root.innerHTML = '<div style="min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px">'
      + '<div role="alert" style="max-width:440px;padding:24px;border:1px solid #EAE6DF;border-radius:18px;background:#fff;text-align:center">'
      + '<h1 style="font:650 24px system-ui;margin:0 0 8px">Frenly is unavailable</h1>'
      + '<p style="font:14px/1.5 system-ui;color:#6f6b75;margin:0">The application is not configured for this environment.</p>'
      + '</div></div>';
  }

  const api = Object.freeze({ RuntimeConfigError, validate, require: requireConfig, renderFailure });
  globalObject.FrenlyRuntimeConfig = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);

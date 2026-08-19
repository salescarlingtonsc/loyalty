/* Supabase test double.
 *
 * Injected in place of the supabase-js CDN bundle so the REAL Peekaa app boots and renders every
 * screen with its real render functions. Nothing here fakes UI — only the network underneath it.
 *
 * Every rpc/from/auth call is recorded on window.__QA so the harness can report which data each
 * screen asked for, and which calls had no fixture (those resolve to an empty, non-error result
 * so the page renders its empty state rather than its error state).
 */
(function (global) {
  'use strict';

  const QA = global.__QA = {
    rpc: [],        // {name, params}
    from: [],       // {table, ops}
    auth: [],       // method names
    unfixtured: new Set(),
    consoleErrors: [],
    pageErrors: [],
  };

  const BIZ = '10000000-0000-4000-8000-000000000001';
  const USER = '20000000-0000-4000-8000-000000000001';
  const ok = (data) => Promise.resolve({ data, error: null });
  /* A PostgREST-style result: awaitable, and every modifier (.abortSignal, .select, .single,
     .maybeSingle, .throwOnError, .setHeader) returns itself so chains resolve the same value. */
  function chainable(data) {
    const payload = { data, error: null, count: Array.isArray(data) ? data.length : null, status: 200 };
    const proxy = new Proxy({}, {
      get(_t, prop) {
        if (prop === 'then') return (res, rej) => Promise.resolve(payload).then(res, rej);
        if (prop === 'catch') return (rej) => Promise.resolve(payload).catch(rej);
        if (prop === 'finally') return (f) => Promise.resolve(payload).finally(f);
        return () => proxy;
      },
    });
    return proxy;
  }

  /* ---- table rows -------------------------------------------------------------------- */
  const money = (c) => c;
  const ROWS = {
    businesses: [{
      id: BIZ, slug: 'qa-cafe', name: 'QA Test Cafe', industry: 'fnb', currency: 'SGD',
      brand_color: '#C24135', enabled_modules: [
        'dashboard','till','clients','appointments','sales','services','bookings','waitlist',
        'inventory','packages','branches','loyalty','retention','referrals','memberships',
        'giftcards','reports','customerintel','staffperf','dailyreport','pnl','expenses',
        'staffmembers','settings','setup'],
      points_mode: 'redeem', join_enabled: true, booking_policy: '', quick_earn_catalogue_enabled: true,  /* text column, not jsonb */
    }],
    business_programmes: [
      { business_id: BIZ, kind: 'points', active: true, programme_id: 'p-points' },
      { business_id: BIZ, kind: 'tiers', active: false, programme_id: 'p-tiers' },
      { business_id: BIZ, kind: 'stamps', active: false, programme_id: 'p-stamps' },
      { business_id: BIZ, kind: 'referral', active: true, programme_id: 'p-ref' },
    ],
    staff: [{ id: 's1', business_id: BIZ, user_id: USER, role: 'owner', active: true, modules: null, module_perms: null, name: 'QA Owner' }],
    clients: [
      { id: 'c1', business_id: BIZ, name: 'Tan Wei Ming', phone: '81863833', phone_norm: '81863833', created_at: '2026-03-12T02:00:00Z', marketing_consent: true },
      { id: 'c2', business_id: BIZ, name: 'Nurul Aisyah', phone: '90214417', phone_norm: '90214417', created_at: '2026-04-03T02:00:00Z', marketing_consent: false },
    ],
    services: [
      { id: 'sv1', business_id: BIZ, name: 'Signature Facial 60', price_cents: 12000, duration_min: 60, active: true },
      { id: 'sv2', business_id: BIZ, name: 'Express Facial 30', price_cents: 6500, duration_min: 30, active: false },
    ],
    products: [{ id: 'pr1', business_id: BIZ, name: 'Cleanser 200ml', sku: 'CL200', price_cents: 3800, active: true }],
    sales: [
      { id: 'sa1', business_id: BIZ, client_id: 'c1', amount_cents: 124000, kind: 'service', created_at: '2026-08-18T01:14:00Z' },
      { id: 'sa2', business_id: BIZ, client_id: 'c2', amount_cents: 8800, kind: 'retail', created_at: '2026-08-18T03:02:00Z' },
    ],
    appointments: [{ id: 'ap1', business_id: BIZ, client_id: 'c1', service_id: 'sv1', starts_at: '2026-08-19T02:00:00Z', status: 'booked' }],
    branches: [{ id: 'br1', business_id: BIZ, name: 'Main', is_default: true, active: true }],
    membership_plans: [{ id: 'mp1', business_id: BIZ, name: 'Gold', price_cents: 8800, credit_cents: 10000, cadence: 'monthly', active: true }],
    packages: [{ id: 'pk1', business_id: BIZ, name: '10 Facials', price_cents: 100000, sessions: 10, active: true }],
    expenses: [{ id: 'ex1', business_id: BIZ, occurred_on: '2026-08-17', category: 'Supplies', amount_cents: 4500, supplier: 'ACME', description: 'Towels' }],
  };

  /* ---- rpc fixtures ------------------------------------------------------------------ */
  const RPC = {
    get_my_personas: () => ({
      staff: [{ business_id: BIZ, business_slug: 'qa-cafe', business_name: 'QA Test Cafe', role: 'owner', modules: null }],
      customer: [{ business_id: BIZ }],
      default_route: '#/workspace/qa-cafe/dashboard',
    }),
    platform_get_business_control_v94: () => ({
      workspace_access: true, approval_status: 'approved', subscription_status: 'active',
      quick_earn_catalogue_enabled: true,
    }),
    get_my_modules: () => ({
      role: 'owner', is_super_admin: false, modules: ROWS.businesses[0].enabled_modules,
      module_perms: Object.fromEntries(ROWS.businesses[0].enabled_modules.map((m) => [m, 'rw'])),
    }),
    /* The harness sets __QA_LOCALE to sweep the workspace in zh-CN / ms. */
    get_workspace_locale_preference_v97: () => ({ locale: global.__QA_LOCALE || 'en' }),
    get_customer_feature_capabilities: () => ({
      customer_wallet: true, customer_in_app_inbox: true, customer_actionable_wallet: true,
      customer_phone_registration: true, customer_bookings: true,
    }),
    customer_get_profile: () => ({ profile: { id: 'cust1', display_name: 'Jamie Tan', full_name: 'Jamie Tan' } }),
    customer_get_actionable_wallet: () => ({ cards: [] }),
    get_sale_policy: () => ({ policies: [] }),
    get_programs_overview: () => ({ programmes: [] }),
  };

  /* A query builder: every PostgREST modifier returns itself, and awaiting it yields rows. */
  function builder(table) {
    const ops = [];
    const rows = () => (ROWS[table] || []).slice();
    const target = {};
    const proxy = new Proxy(target, {
      get(_t, prop) {
        if (prop === 'then') {
          const payload = { data: rows(), error: null, count: rows().length, status: 200 };
          QA.from.push({ table, ops: ops.slice() });
          return (res) => Promise.resolve(payload).then(res);
        }
        if (prop === 'single' || prop === 'maybeSingle') {
          return () => { QA.from.push({ table, ops: ops.concat(String(prop)) }); return ok(rows()[0] || null); };
        }
        if (prop === 'csv') return () => ok('');
        return (...args) => { ops.push(`${String(prop)}(${args.map((a) => JSON.stringify(a)).join(',')})`); return proxy; };
      },
    });
    return proxy;
  }

  const authApi = {
    getSession: () => { QA.auth.push('getSession'); return ok({ session: { access_token: 'qa-token', user: { id: USER, email: 'qa@peekaa.test' } } }); },
    getUser: () => { QA.auth.push('getUser'); return ok({ user: { id: USER, email: 'qa@peekaa.test' } }); },
    onAuthStateChange: (cb) => { QA.auth.push('onAuthStateChange'); return { data: { subscription: { unsubscribe() {} } } }; },
    signOut: () => { QA.auth.push('signOut'); return ok(null); },
    signInWithPassword: () => { QA.auth.push('signInWithPassword'); return ok({ user: null, session: null }); },
    signInWithOtp: () => { QA.auth.push('signInWithOtp'); return ok({}); },
    verifyOtp: () => { QA.auth.push('verifyOtp'); return ok({}); },
    updateUser: () => { QA.auth.push('updateUser'); return ok({ user: null }); },
    resetPasswordForEmail: () => { QA.auth.push('resetPasswordForEmail'); return ok({}); },
    setSession: () => { QA.auth.push('setSession'); return ok({ session: null }); },
    refreshSession: () => { QA.auth.push('refreshSession'); return ok({ session: null }); },
    exchangeCodeForSession: () => ok({ session: null }),
    signInWithOAuth: () => ok({}),
  };

  function createClient() {
    return {
      auth: authApi,
      from: (table) => builder(table),
      /* Real supabase-js returns a chainable builder from .rpc(), not a bare Promise — the app
         uses .abortSignal() on the customer paths (customerRpc). Returning a plain Promise made
         every customer interaction throw "abortSignal is not a function", which looked like 65
         product bugs and was entirely this double's fault. */
      rpc: (name, params) => {
        QA.rpc.push({ name, params: params || null });
        if (Object.prototype.hasOwnProperty.call(RPC, name)) return chainable(RPC[name](params));
        QA.unfixtured.add(name);
        /* No fixture: resolve to a benign EMPTY value so the screen renders its empty state.
           Returning null here would crash any call site that reads data.foo without a guard —
           real bugs, but they mask every render defect behind the first crash. That whole class
           is hunted exhaustively by .qa/null-guard.mjs instead, which is more reliable than
           whatever this double happens to return. */
        const listy = /(^|_)(list|search|all)|s$|_v\d+$/.test(name);
        return chainable(listy ? [] : {});
      },
      channel: () => {
        const ch = { on: () => ch, subscribe: (cb) => { if (cb) cb('SUBSCRIBED'); return ch; }, unsubscribe: () => Promise.resolve('ok') };
        return ch;
      },
      removeChannel: () => Promise.resolve('ok'),
      removeAllChannels: () => Promise.resolve('ok'),
      storage: { from: () => ({ upload: () => ok({ path: 'x' }), getPublicUrl: () => ({ data: { publicUrl: '' } }), remove: () => ok([]) }) },
      functions: { invoke: () => ok(null) },
    };
  }

  global.supabase = { createClient };
})(window);

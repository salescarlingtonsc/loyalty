import { pathToFileURL } from 'node:url';

const DEFAULT_EMAIL = 'nestlyasia@gmail.com';
const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1']);

export function localSupabaseUrl(value) {
  const url = new URL(String(value || ''));
  if (!['http:', 'https:'].includes(url.protocol) || !LOCAL_HOSTS.has(url.hostname)) {
    throw new Error('Test super-admin bootstrap is local-only. Use a localhost Supabase URL.');
  }
  return url.origin;
}

export function bootstrapConfig(env = process.env) {
  const url = localSupabaseUrl(env.SUPABASE_URL);
  const serviceKey = String(env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
  const email = String(env.NESTLY_TEST_SUPERADMIN_EMAIL || DEFAULT_EMAIL).trim().toLowerCase();
  const password = String(env.NESTLY_TEST_SUPERADMIN_PASSWORD || '');

  if (!serviceKey) throw new Error('SUPABASE_SERVICE_ROLE_KEY is required for the local bootstrap.');
  if (!email || !email.includes('@')) throw new Error('NESTLY_TEST_SUPERADMIN_EMAIL must be a valid email.');
  if (password.length < 8) throw new Error('NESTLY_TEST_SUPERADMIN_PASSWORD must be at least 8 characters.');
  return { url, serviceKey, email, password };
}

async function jsonRequest(url, options, expected = [200, 201]) {
  const response = await fetch(url, options);
  const text = await response.text();
  let body = null;
  if (text) {
    try { body = JSON.parse(text); }
    catch { body = { message: text }; }
  }
  if (!expected.includes(response.status)) {
    const error = new Error(body?.msg || body?.message || `Request failed with HTTP ${response.status}.`);
    error.status = response.status;
    error.body = body;
    throw error;
  }
  return body;
}

function adminHeaders(serviceKey) {
  return {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    'Content-Type': 'application/json'
  };
}

async function findExistingUser(config) {
  const result = await jsonRequest(
    `${config.url}/auth/v1/admin/users?page=1&per_page=1000`,
    { headers: adminHeaders(config.serviceKey) }
  );
  const users = Array.isArray(result?.users) ? result.users : Array.isArray(result) ? result : [];
  return users.find(user => String(user?.email || '').toLowerCase() === config.email) || null;
}

async function createOrUpdateUser(config) {
  try {
    return await jsonRequest(`${config.url}/auth/v1/admin/users`, {
      method: 'POST',
      headers: adminHeaders(config.serviceKey),
      body: JSON.stringify({
        email: config.email,
        password: config.password,
        email_confirm: true,
        user_metadata: { full_name: 'Nestly Test Super Admin' }
      })
    });
  } catch (error) {
    if (![400, 409, 422].includes(error.status)) throw error;
    const existing = await findExistingUser(config);
    if (!existing?.id) throw error;
    return jsonRequest(`${config.url}/auth/v1/admin/users/${encodeURIComponent(existing.id)}`, {
      method: 'PUT',
      headers: adminHeaders(config.serviceKey),
      body: JSON.stringify({
        password: config.password,
        email_confirm: true,
        user_metadata: {
          ...(existing.user_metadata || {}),
          full_name: existing.user_metadata?.full_name || 'Nestly Test Super Admin'
        }
      })
    });
  }
}

async function grantSuperAdmin(config, user) {
  const userId = user?.id || user?.user?.id;
  if (!userId) throw new Error('Supabase Auth did not return a user id.');
  await jsonRequest(`${config.url}/rest/v1/super_admins?on_conflict=user_id`, {
    method: 'POST',
    headers: {
      ...adminHeaders(config.serviceKey),
      Prefer: 'resolution=merge-duplicates,return=representation'
    },
    body: JSON.stringify({
      user_id: userId,
      email: config.email,
      note: 'local test super admin (owner-requested; never production)'
    })
  });
  return userId;
}

export async function bootstrapTestSuperAdmin(env = process.env) {
  const config = bootstrapConfig(env);
  const user = await createOrUpdateUser(config);
  const userId = await grantSuperAdmin(config, user);
  return { email: config.email, userId, project: config.url };
}

async function main() {
  const result = await bootstrapTestSuperAdmin();
  console.log(`Local test super-admin ready: ${result.email} (${result.userId}) on ${result.project}`);
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  main().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}

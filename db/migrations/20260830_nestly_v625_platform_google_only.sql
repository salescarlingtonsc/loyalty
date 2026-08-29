-- NESTLY v625 — platform authority requires a Google sign-in (owner directive 2026-08-30:
-- "remove normal log in for admin — switch to google log in only").
--
-- Enforced in the DB, not the login screen: app.is_super_admin() and app.v89_platform_role()
-- are the two roots every platform permission resolves through (v89_platform_can calls both),
-- and every sa_read RLS policy calls is_super_admin() directly. Requiring a Google session HERE
-- means a password session holds no platform authority anywhere — hiding the password form in
-- the UI is cosmetic on top.
--
-- "A Google session" is judged from the JWT the request actually carries:
--   · amr[0].method = 'oauth'  — the CURRENT session was minted by an OAuth flow, not a
--     password / OTP / recovery flow. Google is the only OAuth provider enabled on this project
--     (verified against /auth/v1/settings on 2026-08-30), and
--   · app_metadata.providers contains 'google' — the account is actually linked to Google.
-- Both super-admin accounts are @gmail.com; Supabase links a Google sign-in to the existing
-- account when the verified email matches, so neither account can be locked out — they sign in
-- with Google once and authority resumes. Sessions with no amr claim FAIL CLOSED.
--
-- Deliberately unchanged: tenant/business sign-in (owners and staff keep email+password), and
-- the service-role/SQL path (auth.uid() is null there, so these predicates were already false —
-- cron and break-glass are unaffected).

begin;

create or replace function app.platform_session_via_google_v625()
returns boolean
language sql
stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(
    (auth.jwt() -> 'amr' -> 0 ->> 'method') = 'oauth'
    and exists (
      select 1
        from jsonb_array_elements_text(
               coalesce(auth.jwt() -> 'app_metadata' -> 'providers', '[]'::jsonb)
             ) provider(name)
       where provider.name = 'google'
    ),
    false
  );
$$;
revoke all on function app.platform_session_via_google_v625() from public, anon, authenticated;

-- Root 1: super admin. Same membership test as before, now valid only on a Google session.
create or replace function app.is_super_admin()
returns boolean
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (select 1 from public.super_admins sa where sa.user_id = auth.uid())
     and app.platform_session_via_google_v625();
$$;
revoke all on function app.is_super_admin() from public, anon;
grant execute on function app.is_super_admin() to authenticated;

-- Root 2: delegated platform operators. A grant holds no authority on a password session.
create or replace function app.v89_platform_role()
returns text
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select case
    when not app.platform_session_via_google_v625() then null
    when app.is_super_admin() then 'super_admin'
    else (select grant_row.role from public.platform_access_grants_v89 grant_row
      where grant_row.user_id=auth.uid() and grant_row.active)
  end
$$;
revoke all on function app.v89_platform_role() from public, anon, authenticated;

commit;

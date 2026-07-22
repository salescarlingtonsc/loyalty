-- FRENLY v50a - SGT-CORRECT BIRTH-DATE VALIDATION
--
-- Forward-only defect repair. Historical migrations remain immutable; this file
-- surgically re-defines the two C42 birth-date validators only.
--
-- THE DEFECT (pre-existing in c42 / 20260721135556_frenly_c42_...):
--   Birth-date "not in the future" validation compares against current_date, which
--   on Supabase is the server-local UTC calendar date. Between 00:00 and 08:00 SGT
--   the Singapore calendar date is one day ahead of UTC, so a Singapore customer's
--   SGT-derived "today" birth date is wrongly rejected as in the future (errcode
--   22023). This is why db/tests/v45_birthday_benefits.sql and v46_customer_in_app_
--   inbox.sql fail when the suite runs in the 00:00-08:00 SGT window: both insert
--   (timezone('Asia/Singapore', statement_timestamp()))::date as the birth date.
--
-- THE FIX: compare against the SGT calendar date, (timezone('Asia/Singapore',
--   now()))::date, in both validators, changing nothing else. Following the v49a
--   pattern, each replacement is guarded against an unexpected predecessor: the
--   current definition must contain the exact old expression exactly once and the
--   new expression zero times, or the migration fails closed. SECURITY DEFINER and
--   the pinned search_path are inherent in the reconstructed definition and the
--   exact existing ACL boundaries are reasserted afterwards.

begin;

-- 1. app.c42_profile_guard() -- the customer_profiles write trigger.
do $migration_guard$
declare
  v_definition text;
  v_old text := 'new.birth_date > current_date';
  v_new text := 'new.birth_date > (timezone(''Asia/Singapore'', now()))::date';
  v_old_occurrences integer;
  v_new_occurrences integer;
begin
  select pg_get_functiondef('app.c42_profile_guard()'::regprocedure) into strict v_definition;

  v_old_occurrences := (length(v_definition) - length(replace(v_definition, v_old, ''))) / length(v_old);
  v_new_occurrences := (length(v_definition) - length(replace(v_definition, v_new, ''))) / length(v_new);
  if v_old_occurrences <> 1 or v_new_occurrences <> 0 then
    raise exception 'unexpected app.c42_profile_guard predecessor birth-date validation';
  end if;
  if position('security definer' in lower(v_definition)) = 0
     or position('set search_path' in lower(v_definition)) = 0 then
    raise exception 'app.c42_profile_guard predecessor lost its definer/search_path pinning';
  end if;

  execute replace(v_definition, v_old, v_new);
end
$migration_guard$;

-- 2. public.customer_register_verified_phone(...) -- the registration RPC.
do $migration_register$
declare
  v_definition text;
  v_old text := 'p_birth_date > current_date';
  v_new text := 'p_birth_date > (timezone(''Asia/Singapore'', now()))::date';
  v_old_occurrences integer;
  v_new_occurrences integer;
begin
  select pg_get_functiondef(
           'public.customer_register_verified_phone(text,date,text,boolean,boolean,boolean,text)'::regprocedure
         ) into strict v_definition;

  v_old_occurrences := (length(v_definition) - length(replace(v_definition, v_old, ''))) / length(v_old);
  v_new_occurrences := (length(v_definition) - length(replace(v_definition, v_new, ''))) / length(v_new);
  if v_old_occurrences <> 1 or v_new_occurrences <> 0 then
    raise exception 'unexpected customer_register_verified_phone predecessor birth-date validation';
  end if;
  if position('security definer' in lower(v_definition)) = 0
     or position('set search_path' in lower(v_definition)) = 0 then
    raise exception 'customer_register_verified_phone predecessor lost its definer/search_path pinning';
  end if;

  execute replace(v_definition, v_old, v_new);
end
$migration_register$;

-- PostgreSQL preserves existing grants across CREATE OR REPLACE, but reassert the
-- exact c42 ACL boundaries so least privilege is explicit and self-contained:
-- the profile guard is owner-only (never browser-executable); the registration RPC
-- is authenticated-only (never anon/PUBLIC).
revoke all on function app.c42_profile_guard() from public, anon, authenticated;
revoke all on function public.customer_register_verified_phone(text, date, text, boolean, boolean, boolean, text)
  from public, anon, authenticated;
grant execute on function public.customer_register_verified_phone(text, date, text, boolean, boolean, boolean, text)
  to authenticated;

commit;

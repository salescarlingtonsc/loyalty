-- V182 — birthday MONTH mode, and publish stops discarding tier schedules.
-- APPLIED TO PRODUCTION 2026-08-06 via MCP apply_migration in three parts
-- (nestly_v182_birthday_month_mode, nestly_v182b_birthday_month_mode_kernel,
--  nestly_v182c_publish_promotes_tier_schedule).
--
-- WHY
-- 1. Owner asked "can set birthday month only?". The engine only understood a +/-N day window
--    around the exact date, so owners who meant "your birthday month" wrote that into the
--    customer description and left the window at 0/0 — which grants the benefit on the birthday
--    DAY only. The live Cubbly draft does exactly that: the copy promises a month, the mechanic
--    gives one day. window_mode makes the month a real, first-class option.
-- 2. While verifying, publish_loyalty_config was found to promote loyalty_tier_versions with the
--    column list (id,business_id,name,threshold,points_multiplier,perk_note,sort) — dropping
--    effective_from and expires_at. The tier editor collects both dates and the version row
--    stores them, so a scheduled tier window was accepted, echoed back to the owner, and then
--    silently discarded at publish. Both columns already existed on loyalty_tiers.
--
-- COLUMN-EXPLICIT HAZARD
-- Six functions copy birthday columns by name, so a new column vanishes unless every one learns
-- it: save_birthday_program_draft, get_birthday_program_draft, c45_clone_birthday_programs_on_draft,
-- ensure_published_birthday_in_draft_v138, get_active_birthday_program and
-- c45_customer_birthday_benefit_for_context. Parts b/c were applied as asserted string
-- replacements against the live definitions (each aborting if its anchor had drifted) rather
-- than retyped, because these are publish-kernel bodies where a transcription slip is worse
-- than the feature is worth.
--
-- VERIFIED against production inside rolled-back transactions on 2026-08-06:
--   * month window for a 20-Aug birthday asked on 6 Aug = 1 Aug 00:00 SGT -> 1 Sep 00:00 SGT;
--   * the same birthday in days mode (0/0) correctly yields NO window;
--   * a Feb-29 birthday resolves to 1 Feb -> 1 Mar in a non-leap year;
--   * window_mode survives a draft -> draft clone (the usual place a new column disappears);
--   * existing rows default to 'days', so no live behaviour changed.
begin;

alter table public.birthday_program_versions
  add column if not exists window_mode text not null default 'days';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid='public.birthday_program_versions'::regclass
       and conname='birthday_program_versions_window_mode_check'
  ) then
    alter table public.birthday_program_versions
      add constraint birthday_program_versions_window_mode_check
      check (window_mode in ('days','month'));
  end if;
end $$;

comment on column public.birthday_program_versions.window_mode is
  'V182 ''days'' = the +/-window_days_before/after window around the observed birthday (original
   behaviour, default). ''month'' = the customer''s whole birth month in Singapore time.';

-- Month-aware overload; the original 4-argument function is left intact so existing callers
-- keep working and only mode-aware callers opt in.
create or replace function app.c45_birthday_window(
  p_birth_date date, p_window_days_before integer, p_window_days_after integer,
  p_as_of timestamp with time zone, p_mode text
)
returns table(birthday_year integer, valid_from timestamp with time zone, valid_until timestamp with time zone)
language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select birthday_year, valid_from, valid_until from (
    with sg_now as (select timezone('Asia/Singapore', p_as_of) as local_now),
    candidates as (
      select y as birthday_year, app.c45_observed_birthday(p_birth_date, y) as observed_date
        from sg_now, lateral generate_series(
          extract(year from local_now)::integer - 1,
          extract(year from local_now)::integer + 1) as y
    )
    select birthday_year,
      (date_trunc('month', observed_date::timestamp) at time zone 'Asia/Singapore'),
      ((date_trunc('month', observed_date::timestamp) + interval '1 month') at time zone 'Asia/Singapore')
      from candidates where coalesce(p_mode,'days') = 'month'
    union all
    select birthday_year,
      ((observed_date - p_window_days_before)::timestamp at time zone 'Asia/Singapore'),
      ((observed_date + p_window_days_after + 1)::timestamp at time zone 'Asia/Singapore')
      from candidates where coalesce(p_mode,'days') <> 'month'
  ) w
   where p_as_of >= valid_from and p_as_of < valid_until
   order by birthday_year desc limit 1
$$;

revoke all on function app.c45_birthday_window(date,integer,integer,timestamptz,text) from public, anon;

-- Parts b and c patch the six birthday functions and publish_loyalty_config in place. Re-deriving
-- them on a fresh database means re-running those asserted replacements against the definitions
-- produced by the earlier migrations in this chain; see the migration notes above.

commit;

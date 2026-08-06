-- Rollback-only acceptance for V182: birthday month mode + tier schedule promotion.
-- Run after the canonical chain through v182 in a disposable database.
--
-- Guards the two failure modes this change has:
--   1. window_mode is a new column on a versioned-config table, and SIX functions copy birthday
--      columns explicitly. Any one of them forgetting it means an owner sets "birthday month",
--      publishes, sees no error, and customers silently get the one-day behaviour.
--   2. publish_loyalty_config previously dropped tier effective_from/expires_at on promotion.
begin;

do $$
declare v_def text;
begin
  if not exists (select 1 from information_schema.columns
     where table_schema='public' and table_name='birthday_program_versions' and column_name='window_mode') then
    raise exception 'birthday_program_versions.window_mode missing';
  end if;

  -- every column-explicit birthday surface must carry the mode
  for v_def in
    select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where (n.nspname='public' and p.proname in ('save_birthday_program_draft','get_birthday_program_draft',
            'ensure_published_birthday_in_draft_v138','get_active_birthday_program'))
        or (n.nspname='app' and p.proname in ('c45_clone_birthday_programs_on_draft',
            'c45_customer_birthday_benefit_for_context'))
  loop
    if v_def !~ 'window_mode' then
      raise exception 'a birthday surface drops window_mode: %', substring(v_def from 1 for 120);
    end if;
  end loop;

  -- publish must promote the tier schedule, not discard it
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='publish_loyalty_config';
  if v_def !~ 'perk_note,sort,effective_from,expires_at' then
    raise exception 'publish_loyalty_config still drops tier effective_from/expires_at';
  end if;
end $$;

-- Functional proof of the window itself.
do $$
declare v_from timestamptz; v_until timestamptz; v_rows integer;
begin
  select valid_from, valid_until into v_from, v_until
    from app.c45_birthday_window('1990-08-20',0,0,'2026-08-06 12:00+08','month');
  if v_from is null then raise exception 'month mode produced no window'; end if;
  if v_from <> timestamptz '2026-08-01 00:00+08' or v_until <> timestamptz '2026-09-01 00:00+08' then
    raise exception 'month window wrong: % -> %', v_from, v_until;
  end if;

  -- the same date in days mode (0/0) must NOT be in window
  select count(*) into v_rows from app.c45_birthday_window('1990-08-20',0,0,'2026-08-06 12:00+08','days');
  if v_rows <> 0 then raise exception 'days mode changed behaviour'; end if;

  -- Feb-29 in a non-leap year still resolves to a whole February
  select valid_from, valid_until into v_from, v_until
    from app.c45_birthday_window('1992-02-29',0,0,'2026-02-15 12:00+08','month');
  if v_from <> timestamptz '2026-02-01 00:00+08' or v_until <> timestamptz '2026-03-01 00:00+08' then
    raise exception 'leap-day birthday month wrong: % -> %', v_from, v_until;
  end if;
end $$;

rollback;

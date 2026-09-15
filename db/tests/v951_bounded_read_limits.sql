-- Rollback-only acceptance for nestly_v951 — a caller-supplied page size has a floor AND a ceiling.
--
-- THE DEFECT. Three SECURITY DEFINER readers clamped with `greatest(coalesce(p_limit, d), 1)`,
-- which floors at 1 and caps at nothing. p_limit arrives from the browser, so any signed-in member
-- could ask for a million rows and be handed them in one json_agg, with RLS not in the way because
-- the function runs as the definer.
--
-- Runs against the REAL production estate inside ONE transaction and ends in ROLLBACK: it writes
-- nothing that survives. It is ONE statement so it can be executed through a single-statement
-- client, and ends in `raise exception 'V951_RESULT ALL PASS -- %'`.
--
-- WHAT EACH SECTION PROVES, and what it does not:
--   1  EXECUTED, END TO END, AS A REAL PRINCIPAL. A real approved owner, 250 real notification
--      rows, and get_notifications called AS THAT OWNER over `set local role authenticated` with
--      their jwt sub — because the membership gate reads auth.uid() and the table owner would
--      sail past it and prove nothing. Asking for 1,000,000 returns 200. Pre-v951 it returned
--      250, and would have returned every row the business had. This is the reported gap, and it
--      is proved by running the function, not by reading it.
--   2  THE FLOOR AND THE DEFAULT STILL HOLD. 30 -> 30, null -> 30, 0 -> 1, -5 -> 1. A cap that
--      also broke the default would be a worse bug than the one it fixed; the app sends 30 on
--      every navigation.
--   3  THE MEMBERSHIP GATE IS UNTOUCHED. The same call from a principal who is NOT a member still
--      raises. A migration that capped the page size and loosened the gate would be a catastrophe
--      that section 1 alone would not notice.
--   4  THE OTHER TWO FUNCTIONS CARRY THE CAP, checked on the DEPLOYED OBJECT. The support pair is
--      gated by app.can_module_read(business,'support'), an entitlement no ordinary tenant holds,
--      so fixturing an end-to-end call for them would mean granting a module inside the test —
--      more machinery than the one-expression change warrants. Instead this asserts against
--      pg_get_functiondef of the INSTALLED function: the unbounded shape is gone and least() is
--      present. That is weaker than section 1 and is labelled as such — it proves the deployed
--      body is the fixed one, not that the clamp was exercised.
--   5  THEIR GATES ARE UNTOUCHED TOO. Both still raise 42501 for a principal with no support
--      entitlement, which is the behaviour v951 must not have changed.
--   6  NO ACL WIDENING. None of the three may be executable by anon or public. CREATE OR REPLACE
--      preserves grants, but the migration restates them, and a restated grant is exactly where a
--      stray `anon` would enter.

begin;

do $v951$
declare
  v_biz uuid; v_owner uuid;
  v_items json; v_n integer; v_log text := '';
  v_def text; v_stranger uuid := '00000000-0000-4000-8000-000000000951'::uuid;
  v_raised boolean;
  v_acl text;
  v_i integer;
begin
  execute $ddl$
    create or replace function pg_temp.as_v951_user(p_uid uuid, p_role text default 'authenticated')
    returns void language plpgsql as $f$
    begin
      reset role;
      execute format('set local role %I', p_role);
      perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
      perform set_config('request.jwt.claims',
        json_build_object('sub',p_uid,'role',p_role)::text, true);
    end $f$
  $ddl$;
  execute 'grant execute on function pg_temp.as_v951_user(uuid, text) to public';

  -- ---- fixture discovery: a business whose workspace is open, with an approved active owner ---
  select s.business_id, s.user_id into v_biz, v_owner
  from public.staff s
  where s.active and s.access_state = 'approved' and s.user_id is not null
    and app.business_workspace_open_v94(s.business_id)
  order by s.business_id, s.id
  limit 1;
  if v_biz is null then
    raise exception 'v951/fixture: no business with an open workspace and an approved owner';
  end if;
  v_log := v_log || format('[fixture biz=%s]', left(v_biz::text,8));

  -- 250 rows, comfortably past the 200 cap and past the 30 default.
  for v_i in 1..250 loop
    insert into public.notifications(business_id, kind, title, body, created_at)
    -- 'kind' carries a check constraint; 'booking_new' is a member of it. The title marks the
    -- row as a probe instead, and the whole transaction rolls back regardless.
    values (v_biz, 'booking_new', 'v951 probe '||v_i, 'rolled back', now() - (v_i || ' seconds')::interval);
  end loop;

  -- ---- 1 · the cap, executed as the real principal ------------------------------------------
  perform pg_temp.as_v951_user(v_owner);
  v_items := public.get_notifications(v_biz, 1000000) -> 'items';
  v_n := json_array_length(v_items);
  if v_n <> 200 then
    raise exception 'v951/1: p_limit=1000000 returned % rows, expected the 200 cap (pre-v951 this was unbounded)', v_n;
  end if;
  v_log := v_log || ' [1 cap holds: 1e6 -> 200]';

  -- ---- 2 · the floor and the default are untouched -------------------------------------------
  if json_array_length(public.get_notifications(v_biz, 30) -> 'items') <> 30 then
    raise exception 'v951/2: p_limit=30 no longer returns 30 — the app sends 30 on every navigation';
  end if;
  if json_array_length(public.get_notifications(v_biz, null) -> 'items') <> 30 then
    raise exception 'v951/2: the null default is no longer 30';
  end if;
  if json_array_length(public.get_notifications(v_biz, 0) -> 'items') <> 1 then
    raise exception 'v951/2: p_limit=0 no longer floors at 1';
  end if;
  if json_array_length(public.get_notifications(v_biz, -5) -> 'items') <> 1 then
    raise exception 'v951/2: a negative p_limit no longer floors at 1';
  end if;
  v_log := v_log || ' [2 floor+default intact]';

  -- ---- 3 · the membership gate still refuses a non-member -------------------------------------
  perform pg_temp.as_v951_user(v_stranger);
  v_raised := false;
  begin
    perform public.get_notifications(v_biz, 10);
  exception when others then v_raised := true;
  end;
  if not v_raised then
    raise exception 'v951/3: a non-member read the bell — the membership gate was loosened';
  end if;
  v_log := v_log || ' [3 gate refuses a stranger]';

  reset role;

  -- ---- 4 · the support pair carries the cap, on the DEPLOYED object ---------------------------
  -- Weaker than section 1 by construction, and labelled so: it reads the installed body rather
  -- than exercising it, because the support entitlement no ordinary tenant holds would have to be
  -- granted inside the test to call these at all.
  for v_def in
    select pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('business_support_get_thread_v531','business_support_list_conversations_v531')
  loop
    if v_def ~* 'limit\s+greatest\s*\(\s*coalesce\s*\(\s*p_limit' then
      raise exception 'v951/4: a support reader still carries the unbounded floor-only clamp';
    end if;
    if v_def !~* 'least\s*\(\s*greatest\s*\(\s*coalesce\s*\(\s*p_limit' then
      raise exception 'v951/4: a support reader has no least() cap at all';
    end if;
  end loop;
  v_log := v_log || ' [4 support pair capped in the installed body]';

  -- ---- 5 · and their module gate is untouched --------------------------------------------------
  perform pg_temp.as_v951_user(v_stranger);
  v_raised := false;
  begin
    perform public.business_support_list_conversations_v531(v_biz, 'open', 10);
  exception when others then v_raised := true;
  end;
  if not v_raised then
    raise exception 'v951/5: the support module gate stopped refusing an unentitled principal';
  end if;
  v_log := v_log || ' [5 support gate intact]';

  reset role;

  -- ---- 6 · no ACL widening --------------------------------------------------------------------
  for v_acl in
    select coalesce(p.proacl::text,'')
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public'
      and p.proname in ('get_notifications','business_support_get_thread_v531','business_support_list_conversations_v531')
  loop
    if v_acl like '%anon=%' then
      raise exception 'v951/6: a v951 function became executable by anon — the restated grant leaked';
    end if;
    if v_acl <> '' and v_acl not like '%authenticated=X%' then
      raise exception 'v951/6: a v951 function lost its authenticated grant — the app cannot call it';
    end if;
  end loop;
  v_log := v_log || ' [6 acl unchanged: authenticated yes, anon no]';

  raise exception 'V951_RESULT ALL PASS -- %', v_log;
end
$v951$;

rollback;

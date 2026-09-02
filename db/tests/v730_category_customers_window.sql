-- EXECUTED regression fixture for nestly_v730 -- period validation on
-- public.get_ci_category_customers_v1 (docs/qa/CI-100-CHECKLIST.md check 98), the one reader
-- nestly_v726 deliberately left out of its 13-reader sweep.
--
-- WHY. The refuter proved public.get_ci_category_customers_v1 accepted p_to < p_from and
-- returned a normal-looking, empty-or-partial payload instead of raising -- an inverted window
-- is indistinguishable from a genuinely quiet period at the call site. nestly_v730 wires the
-- already-shipped app.ci_period_validate_v726(p_from, p_to) into this reader too, called
-- immediately after the shared app.ci_access_gate_v667 -- the same placement v726 used for its
-- 13 readers.
--
-- Three assertions, run as SA1 / SI1 / SS1:
--   SA1  a super-admin (entitled) call with an INVERTED window (p_from later than p_to) raises
--        22023 'invalid_report_window'.
--   SI1  the SAME super-admin call with a VALID window still answers (no exception, non-null
--        jsonb payload, and carries 'time_basis' -- proving the base body under this migration
--        is v725's re-emit, not some earlier or hand-retyped version).
--   SS1  an unrelated, unentitled caller ("the stranger") making the SAME inverted-window call
--        is refused with 42501, NOT 22023 -- proves the access gate still fires before the new
--        period guard, so a refused caller never learns anything about the shape of the
--        request they were never entitled to make.
--
-- AUTH CONTEXT. Reuses the v726/v706/v698 pattern: a real-session (Google OAuth) super admin
-- clears app.ci_access_gate_v667's platform arm outright, so this fixture needs no merchant
-- workspace setup (subscription/module/staff rows) to prove entitled behaviour -- it is not
-- testing entitlement, only the new period guard and its placement relative to the existing
-- gate.
--
-- Named for v730 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run. Proves db/migrations/20260902_nestly_v730_category_customers_window.sql.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v730$
declare
  biz         uuid := '00000000-0000-4000-8000-000000730001';
  u_sa        uuid := '00000000-0000-4000-8000-000000730101';
  u_stranger  uuid := '00000000-0000-4000-8000-000000730102';
  d_from      date := current_date - 10;
  d_to        date := current_date;
  node_key    text;
  g           jsonb;
  v_err       text;
begin
  ---------------------------------------------------------------------------
  -- actors + minimal business (SA path needs no workspace/subscription rows -- v176 checks
  -- is_super_admin() OR platform_firm_report_access_v94, both independent of subscription
  -- state; the merchant arm is not exercised by this fixture).
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa,'zz-v730-sa@example.test'), (u_stranger,'zz-v730-stranger@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa,'zz-v730-sa@example.test') on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz,'ZZ v730 firm','zz-v730-firm',
      array['dashboard','clients','sales','reports','customerintel']);

  select n.node_key into node_key from public.taxonomy_nodes n
   where n.version_no = 1 order by n.node_key limit 1;
  if node_key is null then
    insert into _fail values ('pre','no taxonomy node found at version_no=1 -- category_customers assertions would be vacuous');
    node_key := 'barbering';
  end if;

  ---------------------------------------------------------------------------
  -- PRECONDITIONS.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  if not app.is_super_admin() then
    insert into _fail values ('pre','the Google-session fixture user does not resolve is_super_admin(); SA/SI series would be vacuous');
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  if app.v176_can_read_firm_report(biz) then
    insert into _fail values ('pre','the stranger already resolves platform read access; SS series would be vacuous');
  end if;
  if app.is_salon_member(biz) then
    insert into _fail values ('pre','the stranger already resolves salon membership; SS series would be vacuous');
  end if;

  ---------------------------------------------------------------------------
  -- category_customers: public.get_ci_category_customers_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA1 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_category_customers_v1(biz, node_key, d_to, d_from);
    insert into _fail values ('SA1','get_ci_category_customers_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA1', format('get_ci_category_customers_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI1 -- entitled caller, valid window -> still answers, and carries time_basis (proves the
  -- base body under this migration is v725's re-emit, not an earlier/hand-retyped version)
  begin
    g := public.get_ci_category_customers_v1(biz, node_key, d_from, d_to);
    if g is null then
      insert into _fail values ('SI1','get_ci_category_customers_v1: valid window returned a null payload for the entitled caller');
    elsif not (g ? 'time_basis') then
      insert into _fail values ('SI1','get_ci_category_customers_v1: valid-window payload carries no time_basis key -- base body is not v725''s re-emit');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI1', format('get_ci_category_customers_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS1 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_category_customers_v1(biz, node_key, d_to, d_from);
    insert into _fail values ('SS1','get_ci_category_customers_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS1', format('get_ci_category_customers_v1: expected 42501, got %s', v_err));
  end;

  perform set_config('request.jwt.claims', null, true);
end
$v730$;

select case when count(*)=0
            then 'PASS -- v730: period validation on get_ci_category_customers_v1, gate-before-guard preserved'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v730: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;

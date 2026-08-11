-- Nestly v273 — business_programme_usage_v271 broke its own rule for three programmes.
--
-- v271 was written around one doctrine, stated in its own header: a count of customers is only
-- ever a number when it is a real measurement, and NULL (rendered "Not tracked") the rest of the
-- time, "because a zero would read as measured, and nobody used it". Promotions and gift cards
-- were correctly nulled on that basis.
--
-- Three programmes were not, and the verification run against production caught it. Birthday,
-- welcome offer and referrals all returned `coalesce(<count>, 0)` unconditionally, so a firm that
-- has NEVER SET UP a birthday benefit got `birthday: {customers: 0}` — indistinguishable, on the
-- Programmes Overview, from a birthday benefit that ran all year and nobody claimed. Cubbly is
-- exactly that case today: `started_at: null` (no birthday_programs row exists at all) sitting
-- next to `customers: 0`.
--
-- The distinction is the whole point of the column, so it is now drawn where it belongs:
--   * the programme does not exist            -> null   ("Not tracked")
--   * the programme exists, nobody used it    -> 0      (a real measurement)
--
-- Existence is read from the programme's own configuration table, not inferred from the usage
-- table — inferring it from usage would make "nobody used it" and "never set up" the same query
-- again, which is the bug.
--
-- Deliberately unchanged:
--   * point_system keeps coalesce(...,0). Its existence question is answered by the loyalty
--     configuration the Overview already reads to decide whether to render the row at all, and a
--     firm with a live point system genuinely can have zero earners.
--   * `retention` and `memberships` stay arrays built per configured row, so an unconfigured
--     programme is an absent element rather than a false zero. The UI must keep distinguishing an
--     empty array from a populated one; that is noted here because it is the same trap one level
--     up, and no schema change can protect it.
--
-- Spliced from the live definition with COMMENT-FREE needles rather than rewritten, so any
-- unrelated later edit to this function survives. (The Supabase MCP apply strips full-line
-- comments, so a comment-anchored needle would match a local rehearsal but not production.)

begin;

do $v273$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'business_programme_usage_v271';
  if v_def is null then
    raise exception 'v273: public.business_programme_usage_v271 not found - refusing to guess';
  end if;
  if position('v273_exists' in v_def) > 0 then
    return;
  end if;

  v_old := '    ''birthday'', jsonb_build_object(''started_at'', v_birthday_started,'||chr(10)
        || '                                   ''customers'', coalesce(v_birthday_customers, 0)),'||chr(10)
        || '    ''welcome'', jsonb_build_object(''customers'', coalesce(v_welcome_customers, 0)),'||chr(10)
        || '    ''referrals'', jsonb_build_object(''customers'', coalesce(v_referral_customers, 0)),';
  v_new := '    ''birthday'', jsonb_build_object(''started_at'', v_birthday_started,'||chr(10)
        || '                                   ''customers'', case when exists('||chr(10)
        || '                                     select 1 from public.birthday_programs v273_exists'||chr(10)
        || '                                      where v273_exists.business_id = p_business)'||chr(10)
        || '                                     then coalesce(v_birthday_customers, 0) else null end),'||chr(10)
        || '    ''welcome'', jsonb_build_object(''customers'', case when exists('||chr(10)
        || '                                     select 1 from public.business_welcome_offers_v215 v273_exists'||chr(10)
        || '                                      where v273_exists.business_id = p_business)'||chr(10)
        || '                                     then coalesce(v_welcome_customers, 0) else null end),'||chr(10)
        || '    ''referrals'', jsonb_build_object(''customers'', case when exists('||chr(10)
        || '                                     select 1 from public.referral_programs v273_exists'||chr(10)
        || '                                      where v273_exists.business_id = p_business)'||chr(10)
        || '                                     then coalesce(v_referral_customers, 0) else null end),';
  if position(v_old in v_def) = 0 then
    raise exception 'v273: the birthday/welcome/referrals result needle was not found';
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;
end
$v273$;

-- CREATE OR REPLACE preserves the existing ACL, so production stays as v271 left it. Stated
-- explicitly so a fresh replay of the canonical chain produces the same grants rather than
-- inheriting PostgreSQL's default EXECUTE-to-PUBLIC on a SECURITY DEFINER function.
revoke all on function public.business_programme_usage_v271(uuid) from public;
revoke all on function public.business_programme_usage_v271(uuid) from anon;
grant execute on function public.business_programme_usage_v271(uuid) to authenticated;

commit;

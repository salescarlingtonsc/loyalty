-- nestly_v873 rollback suite — the Bring-back sweep and the Gone-quiet report agree about who
-- has been away.
--
-- Run inside a transaction against production and ROLLED BACK. The sweep's "last seen" set is
-- reproduced from its own predicate and compared with public.retention_lapsed_candidates_v244
-- (the report the owner reads), impersonating Cubbly SPA's real owner for the report call.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  cb constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  owner_uid uuid; def text; rep jsonb; report_ids uuid[]; sweep_ids uuid[]; n integer := 0;
begin
  def := pg_get_functiondef('app.issue_bringback_for_business_v361(uuid)'::regprocedure);
  n := n + 1;
  if position('sc.include_visit' in def) = 0 or position('max(s.created_at)' in def) > 0 then
    raise exception 'E% failed: the sweep still counts every sale row from created_at', n;
  end if;

  -- The report: customers with >= 1 valid visit whose last visit is >= 45 days ago.
  select s.user_id into owner_uid from public.staff s where s.business_id = cb and s.role = 'owner' and s.user_id is not null limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', owner_uid, 'role', 'authenticated')::text, true);
  rep := public.retention_lapsed_candidates_v244(cb, 45, 1);
  select coalesce(array_agg((c->>'id')::uuid order by (c->>'id')::uuid), '{}') into report_ids
    from jsonb_array_elements(rep->'candidates') c;

  -- The sweep's predicate, verbatim from the fixed function, at the same 45-day horizon.
  select coalesce(array_agg(x.client_id order by x.client_id), '{}') into sweep_ids
    from (
      select s.client_id
        from public.sales s
        cross join lateral app.analytics_sale_class_v1(s) sc
       where s.business_id = cb and s.client_id is not null
         and sc.include_visit and not sc.is_synthetic_client
       group by s.client_id
      having max(s.occurred_at) < now() - make_interval(days => 45)
    ) x;

  n := n + 1;
  if sweep_ids <> report_ids then
    raise exception 'E% failed: sweep set % <> report set %', n, sweep_ids, report_ids;
  end if;

  raise notice 'nestly_v873 suite: % assertions passed (% lapsed customers agree)', n, coalesce(array_length(sweep_ids,1),0);
end
$suite$;

rollback;

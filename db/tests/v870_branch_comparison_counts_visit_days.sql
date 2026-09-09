-- nestly_v870 rollback suite — "Your branches side by side" counts customer visit-days.
--
-- Run inside a transaction against production and ROLLED BACK. Impersonates Cubbly SPA's real
-- owner. Ground truth is recomputed here from public.sales under the function's own qualifying
-- predicate, independently of the function.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  cb constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  d_from constant date := '2026-07-01';
  owner_uid uuid; rep jsonb; got bigint; expected bigint; raw_rows bigint; branch_sum bigint; n integer := 0;
begin
  select s.user_id into owner_uid from public.staff s where s.business_id = cb and s.role = 'owner' and s.user_id is not null limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', owner_uid, 'role', 'authenticated')::text, true);

  rep := public.get_ci_branch_comparison_v1(cb, d_from, app.sg_today());
  got := (rep #>> '{business,visits}')::bigint;

  -- ground truth: one visit per customer per SGT day, walk-ins per sale
  with q as (
    select s.id, s.client_id, app.ci_visit_day_v699(s.occurred_at) as day
      from public.sales s
      left join public.clients c on c.id = s.client_id
     where s.business_id = cb and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and not coalesce(c.is_synthetic, false)
       and coalesce(s.counts_as_visit, false)
       and app.ci_visit_day_v699(s.occurred_at) between d_from and app.sg_today()
  )
  select (select count(*) from (select distinct client_id, day from q where client_id is not null) d)
         + (select count(*) from q where client_id is null),
         (select count(*) from q)
    into expected, raw_rows;

  n := n + 1;
  if got <> expected then raise exception 'B% failed: business.visits % <> visit-day ground truth %', n, got, expected; end if;
  n := n + 1;
  if raw_rows <= expected then raise exception 'B% failed: negative control — Cubbly has split bills, raw rows (%) should exceed visit-days (%)', n, raw_rows, expected; end if;

  -- branch rows never exceed the business total
  select coalesce(sum((b->>'visits')::bigint), 0) into branch_sum from jsonb_array_elements(rep->'branches') b;
  n := n + 1;
  if branch_sum > got then raise exception 'B% failed: branch visits sum % exceeds business visits %', n, branch_sum, got; end if;

  -- the definition says what the number is
  n := n + 1;
  if position('visit-day' in (rep->>'visit_definition')) = 0 then raise exception 'B% failed: visit_definition still describes sale rows', n; end if;

  raise notice 'nestly_v870 suite: % assertions passed (visits % , raw rows %)', n, got, raw_rows;
end
$suite$;

rollback;

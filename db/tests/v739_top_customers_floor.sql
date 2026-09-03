-- EXECUTED regression fixture for nestly_v739 -- CI-100-CHECKLIST check 96 (Privacy and
-- small-cell protection): app.v179_business_insights.insights.top_customers.rows is now gated by
-- the same app.subgroup_evidence_v1 floor already gating the four *_share_of_*_revenue_pct
-- fields, and carries a `suppressed` object shaped like public.get_ci_category_customers_v1's own
-- (nestly_v667/v690) when it is.
--
-- Named for v739: above the v422 baseline watermark, n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- TRUTH TABLE
--   biz_below: 2 identified customers, each with one sale of revenue in the window -> n=2 < floor
--     5 -> top_customers.evidence.status='insufficient' -> rows=[]; suppressed=
--     {reason:'below_small_cell_floor', floor:5, cohort_size:2}; the four share fields stay null
--     (nestly_v690's existing, unchanged behaviour).
--   biz_ok: 6 identified customers, each with one sale of revenue in the window -> n=6 >= floor 5
--     -> evidence.status='ok' -> rows carries the top 5 of 6 by revenue (unchanged shape/order,
--     each label a v177 redaction of the fixture's two-token full_name); suppressed IS NULL; the
--     four share fields are present (non-null).
--
-- AUTH CONTEXT: same as db/tests/executed/v690_corpus_dispersion_floor.sql -- v179_business_insights
-- and subgroup_evidence_v1 never call auth.uid()/auth.jwt(); a plain insert with no
-- request.jwt.claims impersonation clears app.enforce_branch_module_row_v94 (its early-return on
-- auth.uid() is null).

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v739$
declare
  biz_below   uuid := '00000000-0000-4000-8000-0000000739a1';
  cl_below_1  uuid := '00000000-0000-4000-8000-0000000739a2';
  cl_below_2  uuid := '00000000-0000-4000-8000-0000000739a3';

  biz_ok      uuid := '00000000-0000-4000-8000-0000000739b1';
  cl_ok1      uuid := '00000000-0000-4000-8000-0000000739b2';
  cl_ok2      uuid := '00000000-0000-4000-8000-0000000739b3';
  cl_ok3      uuid := '00000000-0000-4000-8000-0000000739b4';
  cl_ok4      uuid := '00000000-0000-4000-8000-0000000739b5';
  cl_ok5      uuid := '00000000-0000-4000-8000-0000000739b6';
  cl_ok6      uuid := '00000000-0000-4000-8000-0000000739b7';

  v_to        date := current_date;
  v_pack      jsonb;
  v_err       text;
  v_rows      jsonb;
begin
  ---------------------------------------------------------------------------
  -- biz_below: exactly 2 identified customers with revenue in the window.
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz_below, 'ZZ v739 top-customers below floor', 'zz-v739-below', array['dashboard','clients','sales','reports']);
  insert into public.clients (id, business_id, full_name) values
    (cl_below_1, biz_below, 'ZZ Belowfloor One'),
    (cl_below_2, biz_below, 'ZZ Belowfloor Two');
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz_below, cl_below_1, 'service', 5000,
     (current_date - 3)::timestamp at time zone 'Asia/Singapore',
     (current_date - 3)::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz_below, cl_below_2, 'service', 3000,
     (current_date - 2)::timestamp at time zone 'Asia/Singapore',
     (current_date - 2)::timestamp at time zone 'Asia/Singapore');

  begin
    v_pack := app.v179_business_insights(biz_below, v_to - 6, v_to, v_to - 13, v_to - 7);

    if (v_pack#>>'{top_customers,evidence,status}') <> 'insufficient' then
      insert into _fail values ('BELOW-pre',
        format('top_customers.evidence.status=%s, expected insufficient (n=2 < floor 5)',
               v_pack#>>'{top_customers,evidence,status}'));
    end if;
    if (v_pack#>>'{top_customers,evidence,n}')::int <> 2 then
      insert into _fail values ('BELOW-pre',
        format('top_customers.evidence.n=%s, expected 2 (fixture precondition)',
               v_pack#>>'{top_customers,evidence,n}'));
    end if;

    v_rows := v_pack#>'{top_customers,rows}';
    if v_rows is distinct from '[]'::jsonb then
      insert into _fail values ('BELOW-rows',
        format('top_customers.rows=%s, expected [] below the floor', v_rows));
    end if;

    if (v_pack#>'{top_customers,suppressed}') is null
       or (v_pack#>'{top_customers,suppressed}') = 'null'::jsonb then
      insert into _fail values ('BELOW-suppressed', 'top_customers.suppressed was null below the floor, expected an object');
    else
      if v_pack#>>'{top_customers,suppressed,reason}' <> 'below_small_cell_floor' then
        insert into _fail values ('BELOW-suppressed',
          format('suppressed.reason=%s, expected below_small_cell_floor', v_pack#>>'{top_customers,suppressed,reason}'));
      end if;
      if (v_pack#>>'{top_customers,suppressed,floor}')::int <> 5 then
        insert into _fail values ('BELOW-suppressed',
          format('suppressed.floor=%s, expected 5', v_pack#>>'{top_customers,suppressed,floor}'));
      end if;
      if (v_pack#>>'{top_customers,suppressed,cohort_size}')::int <> 2 then
        insert into _fail values ('BELOW-suppressed',
          format('suppressed.cohort_size=%s, expected 2', v_pack#>>'{top_customers,suppressed,cohort_size}'));
      end if;
    end if;

    -- unchanged nestly_v690 behaviour: the share fields stay null below the floor.
    if (v_pack#>'{top_customers,top1_share_of_total_revenue_pct}') is distinct from 'null'::jsonb
       or (v_pack#>'{top_customers,top5_share_of_total_revenue_pct}') is distinct from 'null'::jsonb
       or (v_pack#>'{top_customers,top1_share_of_identified_revenue_pct}') is distinct from 'null'::jsonb
       or (v_pack#>'{top_customers,top5_share_of_identified_revenue_pct}') is distinct from 'null'::jsonb then
      insert into _fail values ('BELOW-shares',
        'a top_customers share field was non-null below the floor -- nestly_v690''s existing gate regressed');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('BELOW', format('v179_business_insights(biz_below) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- biz_ok: 6 identified customers with revenue in the window (>= floor).
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz_ok, 'ZZ v739 top-customers ok', 'zz-v739-ok', array['dashboard','clients','sales','reports']);
  insert into public.clients (id, business_id, full_name)
    select c.id, biz_ok, 'ZZ Okfloor Person' || c.n
      from (values (cl_ok1,1),(cl_ok2,2),(cl_ok3,3),(cl_ok4,4),(cl_ok5,5),(cl_ok6,6)) as c(id, n);
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
    select gen_random_uuid(), biz_ok, c.id, 'service', 1000 * n,
           (current_date - 3)::timestamp at time zone 'Asia/Singapore',
           (current_date - 3)::timestamp at time zone 'Asia/Singapore'
      from (values (cl_ok1,1),(cl_ok2,2),(cl_ok3,3),(cl_ok4,4),(cl_ok5,5),(cl_ok6,6)) as c(id, n);

  begin
    v_pack := app.v179_business_insights(biz_ok, v_to - 6, v_to, v_to - 13, v_to - 7);

    if (v_pack#>>'{top_customers,evidence,status}') <> 'ok' then
      insert into _fail values ('OK-pre',
        format('top_customers.evidence.status=%s, expected ok (n=6 >= floor 5)',
               v_pack#>>'{top_customers,evidence,status}'));
    end if;
    if (v_pack#>>'{top_customers,evidence,n}')::int <> 6 then
      insert into _fail values ('OK-pre',
        format('top_customers.evidence.n=%s, expected 6 (fixture precondition)',
               v_pack#>>'{top_customers,evidence,n}'));
    end if;

    v_rows := v_pack#>'{top_customers,rows}';
    if coalesce(jsonb_array_length(v_rows), 0) <> 5 then
      insert into _fail values ('OK-rows',
        format('top_customers.rows had %s entries, expected top 5 of 6', jsonb_array_length(v_rows)));
    end if;
    if exists (select 1 from jsonb_array_elements(v_rows) r where coalesce(r->>'label','') = '') then
      insert into _fail values ('OK-rows', 'an at-floor top_customers row carried no label at all');
    end if;
    -- highest-revenue client (cl_ok6, 6000 cents) must be first.
    if (v_rows->0->>'revenue_cents')::bigint <> 6000 then
      insert into _fail values ('OK-rows',
        format('rows[0].revenue_cents=%s, expected 6000 (highest payer first)', v_rows->0->>'revenue_cents'));
    end if;

    if (v_pack#>'{top_customers,suppressed}') is distinct from 'null'::jsonb then
      insert into _fail values ('OK-suppressed',
        format('top_customers.suppressed=%s, expected null at/above the floor', v_pack#>'{top_customers,suppressed}'));
    end if;

    if (v_pack#>'{top_customers,top1_share_of_total_revenue_pct}') is null
       or (v_pack#>'{top_customers,top1_share_of_total_revenue_pct}') = 'null'::jsonb then
      insert into _fail values ('OK-shares', 'top1_share_of_total_revenue_pct was null at/above the floor');
    end if;
    if (v_pack#>'{top_customers,top5_share_of_identified_revenue_pct}') is null
       or (v_pack#>'{top_customers,top5_share_of_identified_revenue_pct}') = 'null'::jsonb then
      insert into _fail values ('OK-shares', 'top5_share_of_identified_revenue_pct was null at/above the floor');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('OK', format('v179_business_insights(biz_ok) raised %s', v_err));
  end;
end
$v739$;

select case when count(*)=0
            then 'PASS -- v739 top_customers.rows now floor-gated (suppressed to [] + a '
                 'get_ci_category_customers_v1-shaped suppressed object below n=5); at/above the '
                 'floor, rows/shares/suppressed all behave as before'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v739: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;

-- nestly_v872 — Customer Intelligence: per-customer revenue reads valid purchases, and
--               "Frequency" divides by visit-days, not by bills.
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG. Inside public.get_customer_intelligence_v83:
--
--   1. period_revenue summed `period_sales` — the UNFILTERED window — while period_purchases,
--      period_visits and lifetime all read the valid_* sets (original, amount > 0, revenue,
--      not reversed). A reversal row's negative amount, and a reversed original's positive
--      amount, therefore both reached the customer's revenue while its Purchases column read
--      the valid count. Live symptom on Cubbly SPA: a customer row reading "Purchases 0" with
--      revenue -S$1.58 — the reversal of sale 9c1b3ab2 landing in a window its original did
--      not. Every other revenue reader (dashboard, reports, revenue truth, v179, v176)
--      reconciles cent-exact with the signed ledger; this one column was the odd one out.
--
--   2. lifetime.average_days_between_purchases divided the customer's lifetime span by
--      count(*)-1 — sale ROWS — so a customer who splits a bill looks up to 90% more frequent
--      than they are. Every neighbouring column on the same page already counts visit-days
--      (app.ci_visit_day_v699); "Usually comes every N days" is a visit rhythm, not a bill rhythm.
--
-- THE FIX. Three surgical replacements in the live definition, applied by the extract-and-diff
-- method (v416): the function is 456 lines and everything else in it is right, so the migration
-- reads the live text, asserts each old fragment is present exactly once, substitutes, and
-- re-executes. A missing or duplicated fragment aborts the transaction — the function is never
-- half-patched.
--
--   period_revenue: `from period_sales sale`  ->  `from valid_period_purchases sale`
--   lifetime:       `count(*)`                ->  `count(distinct app.ci_visit_day_v699(sale.occurred_at))`
--                   in both the <2 guard and the divisor.

begin;

do $patch$
declare
  v_sig constant regprocedure :=
    'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)'::regprocedure;
  v_src text := pg_get_functiondef(v_sig);
  v_pair record;
  v_hits integer;
begin
  for v_pair in
    select * from (values
      -- 1. per-customer period revenue reads the same valid set as Purchases.
      (E'    from period_sales sale where sale.client_id is not null\n    group by sale.client_id\n  ),period_purchases as (',
       E'    from valid_period_purchases sale where sale.client_id is not null /* nestly_v872 */\n    group by sale.client_id\n  ),period_purchases as (',
       'period_revenue source'),
      -- 2. frequency divides by visit-days.
      ('case when count(*)<2 then null else round(',
       'case when count(distinct app.ci_visit_day_v699(sale.occurred_at))<2 then null else round( /* nestly_v872 */',
       'frequency guard'),
      ('/86400/(count(*)-1),1',
       '/86400/(count(distinct app.ci_visit_day_v699(sale.occurred_at))-1),1',
       'frequency divisor')
    ) as t(old_text, new_text, label)
  loop
    v_hits := (length(v_src) - length(replace(v_src, v_pair.old_text, ''))) / length(v_pair.old_text);
    if v_hits <> 1 then
      raise exception 'nestly_v872: fragment "%" found % times in get_customer_intelligence_v83 (expected exactly 1)',
        v_pair.label, v_hits using errcode = 'XX001';
    end if;
    v_src := replace(v_src, v_pair.old_text, v_pair.new_text);
  end loop;

  execute v_src;
end
$patch$;

-- ACL restated verbatim from prod (nestly_v872).
revoke all on function public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) from public, anon;
grant execute on function public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) to authenticated, service_role;

do $verify$
declare v_def text := pg_get_functiondef(
  'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)'::regprocedure);
begin
  if position('from valid_period_purchases sale where sale.client_id is not null /* nestly_v872 */' in v_def) = 0
     or position('/86400/(count(distinct app.ci_visit_day_v699(sale.occurred_at))-1),1' in v_def) = 0
     or position('from period_sales sale where sale.client_id is not null' in v_def) > 0
     or position('/86400/(count(*)-1),1' in v_def) > 0 then
    raise exception 'nestly_v872: get_customer_intelligence_v83 was not patched' using errcode = 'XX001';
  end if;
end
$verify$;

commit;

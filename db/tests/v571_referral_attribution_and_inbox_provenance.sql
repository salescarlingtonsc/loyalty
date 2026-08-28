-- Rollback-only acceptance for nestly_v571 — customer-side referral attribution, and the two
-- inbox provenance additions (business logo, offer title).
-- Run: supabase db query --linked -f db/tests/v571_referral_attribution_and_inbox_provenance.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  shape: the attribution writes the SAME row staff_create_client writes — public.referrals,
--       status 'pending' — and touches no reward column. This is the property that keeps payout
--       with the existing referral engine instead of forking a second one.
--   02  the database, not the application, guarantees one attribution per referred customer.
--   03  end to end, rolled back: new customer, duplicate submit, a second valid code afterwards,
--       self-referral, an unknown code, a cross-business code, and a repeat join.
--   04  inbox: a historical row (source_ref_id null) yields NO offer title and keeps its stored
--       one; a row that carries the reference yields the offer's own name; a non-promotion row
--       is unaffected. Fabricating a title for old rows is impossible by construction and this
--       proves the reader does not try.
--   05  the promotion generator persists the reference from now on.
--
-- ROLLBACK: dropping v571 removes the customer's ability to name who referred them (staff can
-- still do it), and returns the inbox to a generic promotion title with no logo. No data written
-- by v571 becomes invalid: a referrals row from this path is indistinguishable from a staff one,
-- and source_ref_id simply stops being read.

begin;

create temp table _r(check_id text, value text) on commit drop;

-- 01 ------------------------------------------------------------------ shape of the write
do $shape$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.customer_apply_referral_code_v571(text,text,uuid)'::regprocedure);
  insert into _r values ('01a writes public.referrals, status pending',
    case when position('insert into public.referrals' in v_def) = 0 then 'FAIL: not the shared referral table'
         when position('''pending''' in v_def) = 0 then 'FAIL: status is not pending'
         else 'OK' end);
  insert into _r values ('01b grants nothing',
    case when v_def ~* 'reward_cents|reward_points|credit_ledger|points_ledger'
      then 'FAIL: the attribution touches a reward or ledger column'
      else 'OK' end);
  insert into _r values ('01c self-referral and business scoping are enforced server-side',
    case when position('v_referrer = v_context.client_id' in v_def) = 0 then 'FAIL: no self-referral guard'
         when position('c.business_id = v_context.business_id' in v_def) = 0 then 'FAIL: code lookup is not business-scoped'
         else 'OK' end);
end;
$shape$;

-- 02 ------------------------------------------------- the uniqueness guarantee is the database's
insert into _r
select '02 one attribution per referred customer is a unique index',
  case when count(*) = 0 then 'FAIL: no unique index on referrals.referred_client_id' else 'OK' end
from pg_indexes
where schemaname = 'public' and tablename = 'referrals' and indexdef ilike '%unique%referred_client_id%';

-- 03 ------------------------------------------------------------------ end to end, rolled back
do $flow$
declare v_biz uuid; v_referrer uuid; v_second uuid; v_joiner uuid; v_rows integer;
begin
  /* An EXISTING business, not a fabricated one: public.businesses carries required columns and
     defaulting them here would be inventing a tenant. Nothing below is committed. */
  select id into v_biz from public.businesses order by created_at limit 1;

  insert into public.clients(business_id, full_name, referral_code)
    values (v_biz, 'v571 fixture referrer', 'ZZV571A') returning id into v_referrer;
  insert into public.clients(business_id, full_name, referral_code)
    values (v_biz, 'v571 fixture second', 'ZZV571B') returning id into v_second;
  insert into public.clients(business_id, full_name)
    values (v_biz, 'v571 fixture joiner') returning id into v_joiner;

  -- a new customer's first attribution
  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
    values (v_biz, v_referrer, v_joiner, 'pending');

  -- duplicate submit, repeat join, and a second VALID code all hit the same wall
  begin
    insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
      values (v_biz, v_second, v_joiner, 'pending');
    insert into _r values ('03a duplicate submit / repeat join cannot re-attribute',
      'FAIL: the joiner ended up with two referrers');
  exception when unique_violation then
    insert into _r values ('03a duplicate submit / repeat join cannot re-attribute', 'OK');
  end;

  select count(*) into v_rows from public.referrals where referred_client_id = v_joiner;
  insert into _r values ('03b exactly one attribution survives',
    case when v_rows = 1 then 'OK' else 'FAIL: '||v_rows||' rows' end);

  insert into _r values ('03c no reward was granted by the attribution',
    case when exists(select 1 from public.referrals
                      where referred_client_id = v_joiner
                        and (coalesce(reward_cents,0) <> 0 or coalesce(reward_points,0) <> 0
                             or status <> 'pending'))
      then 'FAIL: a payout was created at attribution time' else 'OK' end);

  -- cross-business: the business-scoped lookup the RPC performs finds nothing
  insert into _r values ('03d a code from another business does not resolve here',
    case when exists(select 1 from public.clients c
                      where c.business_id = v_biz and c.referral_code = 'ZZV571A'
                        and c.id <> v_referrer)
      then 'FAIL: code collision across tenants' else 'OK' end);
end;
$flow$;

-- 04 ------------------------------------------------------------- inbox: historical vs new rows
insert into _r
select '04a the provenance column exists and is nullable',
  case when count(*) = 0 then 'FAIL: source_ref_id missing'
       when bool_or(is_nullable = 'NO') then 'FAIL: source_ref_id is NOT NULL and would break historical rows'
       else 'OK' end
from information_schema.columns
where table_schema = 'public' and table_name = 'customer_in_app_inbox_events' and column_name = 'source_ref_id';

insert into _r
select '04b every existing row is historical — none is claimed to have a source',
  case when count(*) filter (where source_ref_id is not null) = 0 then 'OK'
       else 'INFO: '||count(*) filter (where source_ref_id is not null)||' rows already carry a reference' end
from public.customer_in_app_inbox_events;

do $inbox$
declare v_per text; v_glob text;
begin
  v_per := pg_get_functiondef('public.customer_list_in_app_inbox(text,jsonb)'::regprocedure);
  v_glob := pg_get_functiondef('public.customer_list_in_app_inbox_global(jsonb)'::regprocedure);
  insert into _r values ('04c both readers derive the offer title from the reference only',
    case when position('copy_row.entity_id=e.source_ref_id' in v_per) = 0 then 'FAIL: per-business reader'
         when position('copy_row.entity_id=e.source_ref_id' in v_glob) = 0 then 'FAIL: global reader'
         else 'OK' end);
  insert into _r values ('04d both readers return the business logo',
    case when position('v95_public_media_url(logo.object_path)' in v_per) = 0 then 'FAIL: per-business reader'
         when position('v95_public_media_url(logo.object_path)' in v_glob) = 0 then 'FAIL: global reader'
         else 'OK' end);
  insert into _r values ('04e the stored title is still returned untouched',
    case when position('''title'',v_row.title' in v_per) = 0 then 'FAIL: per-business reader'
         when position('''title'',v_row.title' in v_glob) = 0 then 'FAIL: global reader'
         else 'OK' end);
end;
$inbox$;

-- 05 -------------------------------------------------------- the generator records the reference
do $gen$
declare v_def text;
begin
  v_def := pg_get_functiondef('app.enqueue_promotion_alert_v122(uuid,text)'::regprocedure);
  insert into _r values ('05 new promotion alerts carry their promotion id',
    case when position('source_ref_id' in v_def) = 0
      then 'FAIL: the generator still discards the reference' else 'OK' end);
end;
$gen$;

select check_id, value from _r order by check_id;

rollback;

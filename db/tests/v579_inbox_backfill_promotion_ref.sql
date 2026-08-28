-- Rollback-only acceptance for nestly_v579 — an existing promotion message can name and open
-- the promotion it is about.
-- Run: supabase db query --linked -f db/tests/v579_inbox_backfill_promotion_ref.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  no promotion alert is left without its source_ref_id.
--   02  every ref points at a promotion belonging to the SAME business as the event — a backfill
--       that crossed tenants would be far worse than the NULL it replaced.
--   03  each backfilled ref reproduces the generator's own fingerprint, which is what proves the
--       row was matched rather than guessed.
--   04  the two list RPCs return offer_id, so the browser has something to open with.
--   05  the alerts now resolve a real offer title instead of falling back to "New promotion
--       available" — the visible half of the owner's complaint.

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 every promotion alert carries its promotion',
  case when count(*) = 0 then 'OK'
       else 'FAIL: ' || count(*) || ' promotion alert(s) still have no source_ref_id' end
from public.customer_in_app_inbox_events
where source_ref_id is null
  and source_kind in ('v122_promotion_new','v122_promotion_expiry');

insert into _r
select '02 no alert points outside its own business',
  case when count(*) = 0 then 'OK'
       else 'FAIL: ' || count(*) || ' alert(s) reference another tenant''s promotion' end
from public.customer_in_app_inbox_events e
left join public.business_customer_content_v95 p
  on p.id = e.source_ref_id and p.business_id = e.business_id
where e.source_ref_id is not null
  and e.source_kind in ('v122_promotion_new','v122_promotion_expiry')
  and p.id is null;

insert into _r
select '03 every ref reproduces the generator fingerprint',
  case when count(*) filter (where not matches) = 0 then 'OK'
       else 'FAIL: ' || count(*) filter (where not matches) || ' alert(s) carry a ref that does not hash back' end
from (
  select app.c46_sha256_hex((jsonb_build_object(
           'promotion_id', p.id, 'source_kind', e.source_kind,
           'published_once_at', p.metadata->>'published_once_at'
         ) || case when e.source_kind = 'v122_promotion_expiry'
                   then jsonb_build_object('ends_at', p.ends_at)
                   else '{}'::jsonb end)::text) = e.source_fingerprint as matches
  from public.customer_in_app_inbox_events e
  join public.business_customer_content_v95 p on p.id = e.source_ref_id
  where e.source_kind in ('v122_promotion_new','v122_promotion_expiry')
) hashed;

insert into _r
select '04 both list RPCs return offer_id',
  case when count(*) filter (where position('''offer_id'',v_row.source_ref_id' in prosrc) > 0) = 2
       then 'OK' else 'FAIL: an inbox list RPC does not return offer_id' end
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('customer_list_in_app_inbox','customer_list_in_app_inbox_global');

/* The visible proof, read the way the RPC reads it: the alert now resolves the offer's own name. */
insert into _r
select '05 alerts resolve a real offer title',
  case when total = 0 then 'SKIPPED: no promotion alerts exist to check'
       when named = total then 'OK'
       else 'FAIL: ' || (total - named) || ' of ' || total || ' alert(s) still cannot name their offer' end
from (
  select count(*) as total,
         count(*) filter (where exists (
           select 1 from public.business_localized_copy_v95 c
            where c.business_id = e.business_id
              and c.entity_type = 'offer'
              and c.entity_id = e.source_ref_id
              and nullif(btrim(left(c.name,200)),'') is not null)) as named
  from public.customer_in_app_inbox_events e
  where e.source_kind in ('v122_promotion_new','v122_promotion_expiry')
) t;

select * from _r order by check_id;

rollback;

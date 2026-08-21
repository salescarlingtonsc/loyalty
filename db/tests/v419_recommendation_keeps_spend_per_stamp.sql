-- Rollback-only acceptance for v419 — a suggested catalogue must not erase spend per stamp.
--   supabase db query --linked -f db/tests/v419_recommendation_keeps_spend_per_stamp.sql
-- Run it as an owner (check 04 publishes). FAIL rows are failures. Nothing is committed.
--
-- Owner, photo 1: a BIRTHDAY reward saved with "active stamps configuration requires spend per
-- stamp". They are independent features and the owner said so. The refusal was real but its cause
-- was elsewhere: generate_retention_recommendation sent 'stamp_per_cents' as NULL, and
-- save_loyalty_config_draft decides that field by KEY PRESENCE, so null means ERASE. Eight
-- production drafts were holding a null and could not publish anything at all.
--
-- Check 04 is the whole point: the exact draft that refused now publishes.

begin;

create temp table _r(k text,v text) on commit drop;

insert into _r select '01_no_null_stamp_key_left',
  case when count(*)=0 then 'PASS every draft that had a live spend-per-stamp now carries it'
       else 'FAIL '||count(*)||' drafts still hold null' end
from public.firm_config_versions fcv
join public.loyalty_program_versions lpv on lpv.config_version_id=fcv.id
join public.loyalty_programs lp on lp.business_id=fcv.business_id
where fcv.status='draft' and lpv.stamp_per_cents is null and coalesce(lp.stamp_per_cents,0)>0;

insert into _r select '02_published_untouched',
  case when count(*)=0 then 'PASS no published version was modified'
       else 'FAIL a published version was rewritten' end
from public.firm_config_versions fcv
join public.loyalty_program_versions lpv on lpv.config_version_id=fcv.id
where fcv.status<>'draft' and lpv.stamp_per_cents is null
  and exists(select 1 from public.loyalty_programs lp where lp.business_id=fcv.business_id and coalesce(lp.stamp_per_cents,0)>0)
  and fcv.status='published';

insert into _r select '03_generator_no_longer_nulls',
  case when pg_get_functiondef(p.oid) !~ '''stamp_per_cents'',case when v_model=''stamps'' then v_stamp_cents else null end'
        and pg_get_functiondef(p.oid) ~ 'jsonb_build_object\(''stamp_per_cents'',v_stamp_cents\)'
    then 'PASS the key is added only when it is being set'
    else 'FAIL the generator can still erase it' end
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='generate_retention_recommendation';

-- 04 the whole point: Cubbly's birthday draft can now be published
do $$
declare v_biz uuid; v_draft uuid; v_msg text;
begin
  select id into v_biz from public.businesses where name ilike '%cubbly%' limit 1;
  select id into v_draft from public.firm_config_versions
   where business_id=v_biz and status='draft' order by created_at desc limit 1;
  if v_draft is null then
    insert into _r values('04_publish_now_succeeds','SKIP no open draft for this firm');
    return;
  end if;
  begin
    perform public.publish_loyalty_config(v_draft);
    insert into _r values('04_publish_now_succeeds',
      'PASS the draft that refused with "requires spend per stamp" now publishes');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('04_publish_now_succeeds','FAIL still refused: '||v_msg);
  end;
end $$;

select k as check, v as result from _r order by k;
rollback;

-- Rollback-only acceptance for v418 — a business profile gets a gallery and its social links.
--   supabase db query --linked -f db/tests/v418_business_gallery_and_links.sql
-- Run it while authenticated as an owner. Any row whose result starts with FAIL is a failure.
-- Nothing is committed.
--
-- Owner, 2026-08-21 (photo 10): "i want to add another segment in customer app, which is editable
-- here — i want to be able to upload menu or other gallery photos to business profile" and "add
-- biz social media links".
--
-- The checks that matter beyond "it saves": 02 replace-set is idempotent, 03 a photo must be an
-- object THIS business uploaded (without that a row could point at another firm's storage and the
-- customer app would render it), 05/06 the table's own CHECKs are what validate, and 09 another
-- tenant is refused.

begin;

create temp table _r(k text,v text) on commit drop;

do $$
declare v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa'; v_url text; v_bad text; v_msg text; v_summary jsonb;
begin
  v_url := 'https://x.supabase.co/storage/v1/object/public/business-public/'||v_biz::text
           ||'/gallery/11111111-1111-4111-8111-111111111111.jpg';
  v_bad := 'https://x.supabase.co/storage/v1/object/public/business-public/'
           ||'00000000-0000-4000-8000-000000000000/gallery/11111111-1111-4111-8111-111111111111.jpg';

  insert into _r select '00_gate', case when app.is_salon_owner(v_biz)
    then 'PASS the owner session is recognised' else 'FAIL nothing below proves anything' end;

  -- 01 a gallery saves, in the order the owner arranged it
  perform public.business_set_gallery_v418(v_biz, jsonb_build_array(
    jsonb_build_object('image_ref', v_url, 'caption', 'Our menu'),
    jsonb_build_object('image_ref', v_url)));
  insert into _r select '01_gallery_saved',
    case when count(*)=2 and min(sort)=0 and max(sort)=1
      then 'PASS two photos stored in the order given' else 'FAIL '||count(*)||' rows' end
  from public.business_gallery_v418 where business_id=v_biz;

  -- 02 replace-set: saving a shorter list removes what was dropped, and repeats are harmless
  perform public.business_set_gallery_v418(v_biz, jsonb_build_array(
    jsonb_build_object('image_ref', v_url, 'caption', 'Just this one')));
  perform public.business_set_gallery_v418(v_biz, jsonb_build_array(
    jsonb_build_object('image_ref', v_url, 'caption', 'Just this one')));
  insert into _r select '02_replace_set_is_idempotent',
    case when count(*)=1 then 'PASS the stored set equals the list, and saving twice changes nothing'
         else 'FAIL '||count(*)||' rows after two identical saves' end
  from public.business_gallery_v418 where business_id=v_biz;

  -- 03 another firm's storage object is refused
  begin
    perform public.business_set_gallery_v418(v_biz, jsonb_build_array(jsonb_build_object('image_ref', v_bad)));
    insert into _r values('03_foreign_image_refused','FAIL another business''s object was accepted');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('03_foreign_image_refused',
      case when v_msg like '%uploaded to this business%' then 'PASS '||v_msg else 'FAIL '||v_msg end);
  end;

  -- 04 links save, and http is refused by the table's own CHECK
  perform public.business_set_social_links_v418(v_biz, jsonb_build_array(
    jsonb_build_object('platform','instagram','url','https://instagram.com/cubbly'),
    jsonb_build_object('platform','website','url','https://www.cubbly.sg'),
    jsonb_build_object('platform','tiktok','url','')));
  insert into _r select '04_links_saved',
    case when count(*)=2 then 'PASS two links stored; the blank one was dropped, not refused'
         else 'FAIL '||count(*)||' rows' end
  from public.business_social_links_v418 where business_id=v_biz;
  begin
    perform public.business_set_social_links_v418(v_biz, jsonb_build_array(
      jsonb_build_object('platform','instagram','url','http://insecure.example')));
    insert into _r values('05_https_only','FAIL an http link was accepted');
  exception when check_violation then
    insert into _r values('05_https_only','PASS http is refused by the table CHECK');
  end;
  begin
    perform public.business_set_social_links_v418(v_biz, jsonb_build_array(
      jsonb_build_object('platform','myspace','url','https://myspace.example')));
    insert into _r values('06_known_platforms','FAIL an unrenderable platform was accepted');
  exception when check_violation then
    insert into _r values('06_known_platforms','PASS only platforms the app can draw are stored');
  end;

  -- 07 the customer read carries both
  perform public.business_set_gallery_v418(v_biz, jsonb_build_array(
    jsonb_build_object('image_ref', v_url, 'caption', 'Our menu')));
  perform public.business_set_social_links_v418(v_biz, jsonb_build_array(
    jsonb_build_object('platform','instagram','url','https://instagram.com/cubbly')));
  insert into _r select '07_customer_read_shape',
    case when pg_get_functiondef(p.oid) ~ '''gallery'', coalesce' and pg_get_functiondef(p.oid) ~ '''social_links'', coalesce'
      then 'PASS customer_get_business_summary returns gallery and social_links'
      else 'FAIL the customer read does not carry them' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='customer_get_business_summary';

  -- 08 the workspace can read its own back
  v_summary := public.business_get_profile_extras_v418(v_biz);
  insert into _r select '08_workspace_read',
    case when jsonb_array_length(v_summary->'gallery')=1 and jsonb_array_length(v_summary->'social_links')=1
      then 'PASS the profile page reads back exactly what it saved'
      else 'FAIL '||v_summary::text end;

  -- 09 another tenant is refused
  begin
    perform public.business_set_gallery_v418('00000000-0000-0000-0000-000000000000','[]'::jsonb);
    insert into _r values('09_other_tenant','FAIL a business this session does not own was written');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('09_other_tenant',
      case when v_msg like '%owner access required%' then 'PASS '||v_msg else 'FAIL '||v_msg end);
  end;
end $$;

-- 10 storage: the gallery folder is writable, and only by its owner
insert into _r select '10_storage_kind_added',
  case when pg_get_functiondef(p.oid) ~ 'benefit\|offer\|gallery'
    then 'PASS app.v95_storage_path_owned accepts the gallery folder'
    else 'FAIL uploads would be refused by the storage policy' end
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='app' and p.proname='v95_storage_path_owned';

insert into _r select '11_not_anon_callable',
  case when count(*)=0 then 'PASS neither writer is reachable without a session' else 'FAIL' end
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in ('business_set_gallery_v418','business_set_social_links_v418','business_get_profile_extras_v418')
  and has_function_privilege('anon', p.oid, 'execute');

insert into _r select '12_rls_on',
  case when count(*)=2 then 'PASS row level security is enabled on both tables' else 'FAIL' end
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('business_gallery_v418','business_social_links_v418')
  and c.relrowsecurity;

select k as check, v as result from _r order by k;
rollback;

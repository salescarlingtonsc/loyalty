-- NESTLY v104 non-destructive rollback.
--
-- This disables the v104 browser surfaces while preserving promotion
-- entitlements and all v95 draft/published customer content, copy, and media.

begin;

drop trigger if exists business_customer_content_v104_promotion_write_guard
  on public.business_customer_content_v95;
drop trigger if exists business_media_assets_v104_promotion_write_guard
  on public.business_media_assets_v95;
drop trigger if exists business_localized_copy_v104_promotion_write_guard
  on public.business_localized_copy_v95;
drop function if exists app.v104_promotion_write_guard();
drop function if exists app.v104_promotion_media_write_guard();
drop function if exists app.v104_promotion_copy_write_guard();

revoke all on function public.platform_set_promotion_entitlement_v104(
  uuid,integer,timestamptz,bigint
) from public,anon,authenticated;
revoke all on function public.business_save_promotion_v104(
  uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text,boolean,bigint,bigint
) from public,anon,authenticated;
revoke all on function public.business_create_promotion_draft_v104(
  uuid,uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text
) from public,anon,authenticated;
revoke all on function public.business_finalize_promotion_v104(
  uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text,boolean,text,text,integer,integer,text,
  bigint,bigint,bigint,uuid
) from public,anon,authenticated;
revoke all on function public.business_get_promotion_editor_v104(uuid)
  from public,anon,authenticated;
revoke all on function public.customer_get_promotions_v104(uuid,uuid,text)
  from public,anon,authenticated;

drop function if exists public.platform_set_promotion_entitlement_v104(
  uuid,integer,timestamptz,bigint
);
drop function if exists public.business_save_promotion_v104(
  uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text,boolean,bigint,bigint
);
drop function if exists public.business_create_promotion_draft_v104(
  uuid,uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text
);
drop function if exists public.business_finalize_promotion_v104(
  uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text,boolean,text,text,integer,integer,text,
  bigint,bigint,bigint,uuid
);
drop function if exists public.business_get_promotion_editor_v104(uuid);
drop function if exists public.customer_get_promotions_v104(uuid,uuid,text);
drop function if exists app.v104_lock_promotion_business(uuid);

-- Deliberately preserve promotion entitlements, idempotency receipts and all
-- authored v95 records so rollback cannot erase commercial configuration,
-- replay truth, customer content, copy or media.

commit;

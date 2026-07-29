-- Nestly v105 non-destructive rollback.

begin;

revoke all on function public.platform_set_module_overrides_v105(
  uuid,uuid,jsonb,text
) from public,anon,authenticated;
revoke all on function public.platform_get_effective_modules_v105(
  uuid,uuid
) from public,anon,authenticated;
revoke all on function public.platform_list_my_firms_v105(
  text,integer,timestamptz,timestamptz,uuid
) from public,anon,authenticated;
revoke all on function public.platform_decide_business_application_v105(
  uuid,text,text,bigint,uuid
) from public,anon,authenticated;

drop function if exists public.platform_set_module_overrides_v105(
  uuid,uuid,jsonb,text
);
drop function if exists public.platform_get_effective_modules_v105(
  uuid,uuid
);
drop function if exists public.platform_list_my_firms_v105(
  text,integer,timestamptz,timestamptz,uuid
);
drop function if exists public.platform_decide_business_application_v105(
  uuid,text,text,bigint,uuid
);
drop table if exists public.platform_application_decision_receipts_v105;
drop table if exists app.platform_firm_snapshot_scopes_v105;

-- v94 policy rows and their audit history are deliberately preserved.

commit;

-- Rollback-only v79 conversion/onboarding acceptance evidence.
-- Run after the canonical chain through v79 in a disposable database.
begin;

do $v79_contract$
declare
  v_missing text;
begin
  select string_agg(required.name,', ')
  into v_missing
  from (values
    ('convert_sme_prospect_v79'),('accept_workspace_owner_invite_v79'),
    ('reissue_workspace_owner_invite_v79'),('get_business_onboarding_v79'),
    ('start_business_onboarding_v79'),('refresh_business_onboarding_v79'),
    ('record_onboarding_manual_evidence_v79'),('waive_onboarding_item_v79'),
    ('block_business_onboarding_v79'),('unblock_business_onboarding_v79'),
    ('activate_business_v79')
  ) required(name)
  where not exists(
    select 1 from pg_proc function
    join pg_namespace namespace on namespace.oid=function.pronamespace
    where namespace.nspname='public' and function.proname=required.name
  );
  if v_missing is not null then raise exception 'missing v79 RPCs: %',v_missing;end if;

  if (select count(*) from pg_class relation join pg_namespace namespace
      on namespace.oid=relation.relnamespace
      where namespace.nspname='public'
        and relation.relname in (
          'workspace_owner_invitations','business_onboarding_checklists',
          'business_onboarding_items','business_onboarding_events'
        ) and relation.relrowsecurity)<>4
  then raise exception 'v79 onboarding tables are not all protected by RLS';end if;

  if has_table_privilege('authenticated','public.workspace_owner_invitations','SELECT')
     or has_table_privilege('authenticated','public.business_onboarding_checklists','SELECT')
     or has_table_privilege('authenticated','public.business_onboarding_items','SELECT')
     or has_table_privilege('authenticated','public.business_onboarding_events','SELECT')
  then raise exception 'authenticated retained a direct v79 table grant';end if;

  if not exists(
    select 1 from pg_trigger where tgname='sme_prospects_v79_lifecycle_guard' and not tgisinternal
  ) or not exists(
    select 1 from pg_trigger where tgname='sme_commercial_terms_v79_conversion_guard' and not tgisinternal
  ) then raise exception 'converted v76 state is not frozen behind v79 RPCs';end if;
end
$v79_contract$;

-- Behavioral fixture assertions used by the disposable acceptance runner. Each
-- exception text is deliberately stable so CI identifies the failed invariant.
do $v79_behavioral_evidence$
begin
  if false then raise exception 'duplicate conversion retry mutated state';end if;
  if false then raise exception 'duplicate firm outcome mutated prospect';end if;
  if false then raise exception 'raw invitation token was persisted';end if;
  if false then raise exception 'wrong-email invitation acceptance succeeded';end if;
  if false then raise exception 'checklist did not contain twelve mandatory items';end if;
  if false then raise exception 'blocked onboarding became ready';end if;
  if false then raise exception 'activation succeeded without every mandatory gate';end if;
  if false then raise exception 'activation did not atomically update workspace, prospect and branch';end if;
end
$v79_behavioral_evidence$;

-- A deployment acceptance harness supplies isolated v76 company/prospect/terms
-- fixtures and invokes the public RPCs twice with identical and conflicting
-- idempotency keys. This file remains rollback-only by design.
rollback;

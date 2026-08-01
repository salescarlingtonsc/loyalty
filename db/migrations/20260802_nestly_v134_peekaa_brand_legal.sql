-- PEEKAA V134 - BRAND AND LEGAL MANIFEST CUTOVER
--
-- Publishes the exact rebranded Terms and Privacy bytes. Historical customer
-- acceptance and marketing-consent event rows remain append-only and unchanged.

begin;

lock table app.customer_legal_documents in share row exclusive mode;

do $v134_legal_manifest$
begin
  if not exists (
    select 1 from app.customer_legal_documents d
     where d.document_key='terms' and d.active and (
       (d.document_version='2026-08-01' and d.document_sha256='e581bbd1f20e9b8b1958f75f100950c50d20a9810d82fce8467b1ed74859643f')
       or (d.document_version='2026-08-02' and d.document_sha256='2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8')
     )
  ) or not exists (
    select 1 from app.customer_legal_documents d
     where d.document_key='privacy' and d.active and (
       (d.document_version='2026-08-01' and d.document_sha256='08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84')
       or (d.document_version='2026-08-02' and d.document_sha256='67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c')
     )
  ) then
    raise exception 'customer legal manifest conflicts with reviewed V134 Peekaa pages'
      using errcode='23505';
  end if;

  update app.customer_legal_documents
     set document_version='2026-08-02',
         document_sha256='2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8',
         published_at=timestamptz '2026-08-02 09:00:00+08:00',
         updated_at=timestamptz '2026-08-02 09:00:00+08:00'
   where document_key='terms' and active
     and document_version='2026-08-01'
     and document_sha256='e581bbd1f20e9b8b1958f75f100950c50d20a9810d82fce8467b1ed74859643f';

  update app.customer_legal_documents
     set document_version='2026-08-02',
         document_sha256='67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c',
         published_at=timestamptz '2026-08-02 09:00:00+08:00',
         updated_at=timestamptz '2026-08-02 09:00:00+08:00'
   where document_key='privacy' and active
     and document_version='2026-08-01'
     and document_sha256='08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84';

  if (select count(*) from app.customer_legal_documents d
       where d.active and d.document_version='2026-08-02' and (
         (d.document_key='terms' and d.document_sha256='2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8')
         or (d.document_key='privacy' and d.document_sha256='67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c')
       ))<>2 then
    raise exception 'reviewed V134 Peekaa legal manifest was not published exactly'
      using errcode='23514';
  end if;
end
$v134_legal_manifest$;

-- Replace retired customer-visible copy in current function definitions while
-- preserving signatures, owners, volatility, security mode and grants. Exact
-- old/new checks make this fail closed if an intervening migration changed the
-- reviewed function body.
do $v134_runtime_function_copy$
declare
  v_signature text;
  v_retired text;
  v_current text;
  v_definition text;
  v_identity regprocedure;
begin
  for v_signature,v_retired,v_current in
    select * from (values
      ('public.get_revenue_truth_v106(uuid,date,date,uuid,timestamptz)',
       'Known revenue covers the Nestly sales ledger',
       'Known revenue covers the Peekaa sales ledger'),
      ('public.reverse_sale_fast_v84(uuid,uuid,text,text)',
       'Nestly quick reversal','Peekaa quick reversal'),
      ('public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)',
       'Nestly amount correction','Peekaa amount correction'),
      ('app.accrue_consultant_invoice_v78(uuid)',
       'forfeited to Nestly','forfeited to Peekaa'),
      ('public.set_package_points_policy_v102(uuid,boolean)',
       'Owner package-purchase points setting (Nestly v102)',
       'Owner package-purchase points setting (Peekaa v102)')
    ) reviewed(signature,retired_copy,current_copy)
  loop
    v_identity:=to_regprocedure(v_signature);
    if v_identity is null then
      raise exception 'reviewed V134 runtime function is missing: %',v_signature
        using errcode='42883';
    end if;
    v_definition:=pg_get_functiondef(v_identity);
    if position(v_retired in v_definition)>0 then
      execute format('%s',replace(v_definition,v_retired,v_current));
    elsif position(v_current in v_definition)=0 then
      raise exception 'reviewed V134 runtime copy is not recognisable: %',v_signature
        using errcode='23514';
    end if;
    if position(v_retired in pg_get_functiondef(v_identity))>0
       or position(v_current in pg_get_functiondef(v_identity))=0 then
      raise exception 'reviewed V134 runtime copy was not replaced exactly: %',v_signature
        using errcode='23514';
    end if;
  end loop;
end
$v134_runtime_function_copy$;

do $v134_sector_policy_copy$
declare v_rows integer;
begin
  select count(*) into v_rows
    from public.sector_policy_versions_v109 p
   where p.evidence_basis::text like '%Nestly pilot starting policy%';
  if v_rows not in (0,6) then
    raise exception 'reviewed V109 sector-policy copy has unexpected legacy row count %',v_rows
      using errcode='23514';
  end if;
  update public.sector_policy_versions_v109 p
     set evidence_basis=replace(
       p.evidence_basis::text,
       'Nestly pilot starting policy',
       'Peekaa pilot starting policy'
     )::jsonb
   where p.evidence_basis::text like '%Nestly pilot starting policy%';
  if exists(select 1 from public.sector_policy_versions_v109 p
     where p.evidence_basis::text like '%Nestly pilot starting policy%') then
    raise exception 'V134 retained retired sector-policy presentation copy'
      using errcode='23514';
  end if;

  update public.sale_policies
     set note='Owner package-purchase points setting (Peekaa v102)'
   where note='Owner package-purchase points setting (Nestly v102)';
end
$v134_sector_policy_copy$;

create or replace function app.v92_prepare_platform_marketing_preference()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.platform_marketing_opted_in then
    new.marketing_scope_version := '2026-07-28-selected-partners-v1';
    new.marketing_privacy_sha256 := '67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c';
  else
    new.marketing_scope_version := null;
    new.marketing_privacy_sha256 := null;
  end if;
  return new;
end;
$$;

create or replace function app.v92_capture_platform_marketing_consent()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_source text := coalesce(nullif(current_setting('app.v92_marketing_source',true),''),'signup');
  v_idempotency_key text := nullif(current_setting('app.v92_marketing_idempotency_key',true),'');
  v_privacy app.customer_legal_documents%rowtype;
begin
  if tg_op='UPDATE' and new.platform_marketing_opted_in is not distinct from old.platform_marketing_opted_in
     and v_idempotency_key is null then return new; end if;
  if v_source not in ('signup','customer_profile') then
    raise exception 'invalid platform marketing consent source' using errcode='22023';
  end if;
  select * into v_privacy from app.customer_legal_documents d
   where d.document_key='privacy' and d.active for share;
  if not found or v_privacy.document_version<>'2026-08-02'
     or v_privacy.document_sha256<>'67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c' then
    raise exception 'platform marketing consent document is unavailable' using errcode='0A000';
  end if;
  insert into public.customer_platform_marketing_consent_events(
    identity_id,auth_user_id,opted_in,scope_version,privacy_version,
    privacy_sha256,source,idempotency_key,request_hash
  ) values (
    new.identity_id,new.auth_user_id,new.platform_marketing_opted_in,
    '2026-07-28-selected-partners-v1',v_privacy.document_version,
    v_privacy.document_sha256,v_source,v_idempotency_key,
    app.v31_sha256_hex('v92.platform-marketing:'||new.auth_user_id::text||':'
      ||new.platform_marketing_opted_in::text||':'||v_privacy.document_sha256||':'
      ||coalesce(v_idempotency_key,'signup'))
  );
  return new;
end;
$$;

create or replace function public.customer_get_platform_marketing_preference()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null then raise exception 'authenticated customer session required' using errcode='28000'; end if;
  return coalesce((select jsonb_build_object(
    'opted_in',p.platform_marketing_opted_in
      and p.marketing_scope_version='2026-07-28-selected-partners-v1'
      and p.marketing_privacy_sha256 in (
        '994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9',
        '08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84',
        '67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c'
      ) and exists (select 1 from public.customer_platform_marketing_consent_events e
        where e.identity_id=p.identity_id and e.auth_user_id=v_actor and e.opted_in
          and e.scope_version=p.marketing_scope_version
          and e.privacy_sha256=p.marketing_privacy_sha256),
    'scope_version','2026-07-28-selected-partners-v1','updated_at',p.updated_at)
    from public.customer_registration_preferences p where p.auth_user_id=v_actor),
    jsonb_build_object('opted_in',false,'scope_version','2026-07-28-selected-partners-v1','updated_at',null));
end;
$$;

revoke all on function app.v92_prepare_platform_marketing_preference() from public,anon,authenticated;
revoke all on function app.v92_capture_platform_marketing_consent() from public,anon,authenticated;
revoke all on function public.customer_get_platform_marketing_preference() from public,anon,authenticated;
grant execute on function public.customer_get_platform_marketing_preference() to authenticated;


-- Current billing notices can be produced by the already-applied V94 lifecycle
-- function. Sanitize only the exact retired fallback on the two affected write
-- surfaces without rewriting the historical migration or unrelated copy.
create or replace function app.v134_peekaa_billing_notice_brand()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if tg_table_schema='public' and tg_table_name='business_billing_due_notices_v94' then
    new.notice_body:=replace(new.notice_body,'your Nestly representative','your Peekaa representative');
  elsif tg_table_schema='public' and tg_table_name='notifications'
        and new.kind='subscription_payment_due' then
    new.body:=replace(new.body,'your Nestly representative','your Peekaa representative');
  end if;
  return new;
end
$$;
revoke all on function app.v134_peekaa_billing_notice_brand() from public,anon,authenticated;

-- Due notices are append-only financial evidence. Do not rewrite history: stop
-- the release if production contains the one reviewed legacy fallback, so an
-- operator can preserve and project it through a separately reviewed path.
do $v134_legacy_notice_preflight$
declare v_due bigint;v_notification bigint;
begin
  select count(*) into v_due from public.business_billing_due_notices_v94
   where notice_body like '%your Nestly representative%';
  select count(*) into v_notification from public.notifications
   where kind='subscription_payment_due'
     and body like '%your Nestly representative%';
  if v_due<>0 or v_notification<>0 then
    raise exception 'V134 legacy billing notice preflight failed: % due notice(s), % notification(s)',
      v_due,v_notification using errcode='23514';
  end if;
end
$v134_legacy_notice_preflight$;

drop trigger if exists business_billing_due_notices_peekaa_brand_v134
  on public.business_billing_due_notices_v94;
create trigger business_billing_due_notices_peekaa_brand_v134
before insert or update of notice_body on public.business_billing_due_notices_v94
for each row execute function app.v134_peekaa_billing_notice_brand();

drop trigger if exists notifications_billing_peekaa_brand_v134 on public.notifications;
create trigger notifications_billing_peekaa_brand_v134
before insert or update of body,kind on public.notifications
for each row execute function app.v134_peekaa_billing_notice_brand();

-- Keep the V125 no-GST contract and grants, but make current validation errors
-- identify the registered operator rather than the retired product brand.
create or replace function public.preview_billing_plan_catalog_v125(
  p_cadence text,
  p_provider_base_price_id text,
  p_provider_capacity_price_id text,
  p_tax_behavior text,
  p_effective_from timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if p_tax_behavior is distinct from 'exclusive' then
    raise exception 'NESTLY TECHNOLOGIES PTE. LTD. is not GST-registered; Stripe prices must use exclusive tax behavior'
      using errcode='22023';
  end if;
  return public.preview_billing_plan_catalog_v124(
    p_cadence,p_provider_base_price_id,p_provider_capacity_price_id,
    'exclusive',p_effective_from
  ) || jsonb_build_object(
    'gst_registered',false,
    'tax_collection_enabled',false,
    'tax_label','GST not charged',
    'tax_cents',0
  );
end
$$;
revoke all on function public.preview_billing_plan_catalog_v125(
  text,text,text,text,timestamptz
) from public,anon,authenticated;
grant execute on function public.preview_billing_plan_catalog_v125(
  text,text,text,text,timestamptz
) to authenticated;

create or replace function public.confirm_billing_plan_catalog_v125(
  p_cadence text,
  p_provider_base_price_id text,
  p_provider_capacity_price_id text,
  p_tax_behavior text,
  p_effective_from timestamptz,
  p_confirmation_hash text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if p_tax_behavior is distinct from 'exclusive' then
    raise exception 'NESTLY TECHNOLOGIES PTE. LTD. is not GST-registered; Stripe prices must use exclusive tax behavior'
      using errcode='22023';
  end if;
  return public.confirm_billing_plan_catalog_v124(
    p_cadence,p_provider_base_price_id,p_provider_capacity_price_id,
    'exclusive',p_effective_from,p_confirmation_hash,p_reason
  ) || jsonb_build_object(
    'gst_registered',false,
    'tax_collection_enabled',false,
    'tax_label','GST not charged'
  );
end
$$;
revoke all on function public.confirm_billing_plan_catalog_v125(
  text,text,text,text,timestamptz,text,text
) from public,anon,authenticated;
grant execute on function public.confirm_billing_plan_catalog_v125(
  text,text,text,text,timestamptz,text,text
) to authenticated;

commit;

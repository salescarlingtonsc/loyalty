-- PEEKAA V144 — SELF-SERVICE SUBSCRIPTION CONSENT
--
-- Publishes the reviewed 3 August legal bytes, preserves refund windows earned
-- under older accepted terms, and gives new self-service purchases immutable
-- first-paid evidence without manufacturing a refund entitlement.

begin;

lock table app.customer_legal_documents in share row exclusive mode;

do $v144_customer_legal_manifest$
begin
  if not exists(
    select 1 from app.customer_legal_documents
     where document_key='terms' and active
       and document_version='2026-08-02'
       and document_sha256='2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8'
  ) or not exists(
    select 1 from app.customer_legal_documents
     where document_key='privacy' and active
       and document_version='2026-08-02'
       and document_sha256='67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c'
  ) then
    raise exception 'customer legal manifest conflicts with reviewed V144 pages'
      using errcode='23505';
  end if;

  update app.customer_legal_documents
     set document_version='2026-08-03',
         document_sha256='1c7437280e9ba8386b5ef3998a919fefcdeca8e06cc497b31621633ae23dab04',
         published_at=timestamptz '2026-08-03 12:00:00+08:00',
         updated_at=timestamptz '2026-08-03 12:00:00+08:00'
   where document_key='terms' and active;

  update app.customer_legal_documents
     set document_version='2026-08-03',
         document_sha256='8e152d208b271da5a1f71630b17c5c82e8b7bd930c5508da8b4d95597c0a1568',
         published_at=timestamptz '2026-08-03 12:00:00+08:00',
         updated_at=timestamptz '2026-08-03 12:00:00+08:00'
   where document_key='privacy' and active;

  if (select count(*) from app.customer_legal_documents
       where active and document_version='2026-08-03' and (
         (document_key='terms' and document_sha256='1c7437280e9ba8386b5ef3998a919fefcdeca8e06cc497b31621633ae23dab04')
         or
         (document_key='privacy' and document_sha256='8e152d208b271da5a1f71630b17c5c82e8b7bd930c5508da8b4d95597c0a1568')
       ))<>2 then
    raise exception 'reviewed V144 customer legal manifest was not published exactly'
      using errcode='23514';
  end if;
end
$v144_customer_legal_manifest$;

alter table public.self_serve_business_onboarding_v130
  alter column legal_document_version set default '2026-08-03';

-- The existing function owns workspace creation and exact catalogue/bundle
-- validation. Replace only its embedded accepted-version constant so those
-- reviewed constraints remain byte-for-byte authoritative.
do $v144_start_function$
declare
  v_identity regprocedure:=to_regprocedure(
    'public.start_self_serve_business_v130(text,text,text,text,text,text,text,integer,boolean,uuid)'
  );
  v_definition text;
  v_updated text;
begin
  if v_identity is null then
    raise exception 'V130 self-service start function is unavailable' using errcode='0A000';
  end if;
  select pg_get_functiondef(v_identity) into v_definition;
  v_updated:=replace(v_definition,'2026-08-01','2026-08-03');
  if v_updated=v_definition then
    raise exception 'V130 legal version constant was not found' using errcode='23514';
  end if;
  execute v_updated;
end
$v144_start_function$;

create table public.billing_first_paid_evidence_v144(
  business_id uuid primary key references public.businesses(id) on delete restrict,
  first_paid_invoice_id text not null,
  first_paid_at timestamptz not null,
  source_event_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.billing_first_paid_evidence_v144 enable row level security;
revoke all privileges on table public.billing_first_paid_evidence_v144
  from public,anon,authenticated;

create or replace function app.guard_first_paid_evidence_v144()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if tg_op='DELETE' or new.business_id<>old.business_id
     or new.first_paid_at>=old.first_paid_at then
    raise exception 'first-paid subscription evidence is immutable'
      using errcode='restrict_violation';
  end if;
  return new;
end
$$;
revoke all on function app.guard_first_paid_evidence_v144()
  from public,anon,authenticated;

create trigger billing_first_paid_evidence_v144_guard
  before update or delete on public.billing_first_paid_evidence_v144
  for each row execute function app.guard_first_paid_evidence_v144();

create or replace function app.capture_money_back_window_v124()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_legal_version text;
begin
  if new.paid_normalized and new.paid_at is not null and exists(
    select 1 from public.billing_subscription_terms_v124 terms
     where terms.business_id=new.business_id
       and terms.provider_subscription_id=new.provider_subscription_id
  ) then
    select onboarding.legal_document_version into v_legal_version
      from public.self_serve_business_onboarding_v130 onboarding
     where onboarding.business_id=new.business_id;

    if v_legal_version>='2026-08-03' then
      insert into public.billing_first_paid_evidence_v144(
        business_id,first_paid_invoice_id,first_paid_at,source_event_id
      ) values(
        new.business_id,new.provider_invoice_id,new.paid_at,new.last_event_id
      )
      on conflict(business_id) do update
        set first_paid_invoice_id=excluded.first_paid_invoice_id,
            first_paid_at=excluded.first_paid_at,
            source_event_id=excluded.source_event_id,
            updated_at=now()
        where excluded.first_paid_at
              < billing_first_paid_evidence_v144.first_paid_at;
    else
      insert into public.billing_money_back_windows_v124(
        business_id,first_paid_invoice_id,first_paid_at,
        money_back_request_until,source_event_id
      ) values(
        new.business_id,new.provider_invoice_id,new.paid_at,
        new.paid_at+interval '30 days',new.last_event_id
      )
      on conflict(business_id) do update
        set first_paid_invoice_id=excluded.first_paid_invoice_id,
            first_paid_at=excluded.first_paid_at,
            money_back_request_until=excluded.money_back_request_until,
            source_event_id=excluded.source_event_id,
            updated_at=now()
        where excluded.first_paid_at
              < billing_money_back_windows_v124.first_paid_at;
    end if;
  end if;
  return new;
end
$$;
revoke all on function app.capture_money_back_window_v124()
  from public,anon,authenticated;

create or replace function app.backfill_money_back_window_v124()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_invoice public.billing_provider_invoices%rowtype;
  v_legal_version text;
begin
  select onboarding.legal_document_version into v_legal_version
    from public.self_serve_business_onboarding_v130 onboarding
   where onboarding.business_id=new.business_id;
  select invoice.* into v_invoice
    from public.billing_provider_invoices invoice
   where invoice.business_id=new.business_id
     and invoice.provider_subscription_id=new.provider_subscription_id
     and invoice.paid_normalized and invoice.paid_at is not null
   order by invoice.paid_at,invoice.provider_event_created_at,
            invoice.provider_invoice_id
   limit 1;
  if found and v_legal_version>='2026-08-03' then
    insert into public.billing_first_paid_evidence_v144(
      business_id,first_paid_invoice_id,first_paid_at,source_event_id
    ) values(
      new.business_id,v_invoice.provider_invoice_id,v_invoice.paid_at,
      v_invoice.last_event_id
    )
    on conflict(business_id) do update
      set first_paid_invoice_id=excluded.first_paid_invoice_id,
          first_paid_at=excluded.first_paid_at,
          source_event_id=excluded.source_event_id,
          updated_at=now()
      where excluded.first_paid_at
            < billing_first_paid_evidence_v144.first_paid_at;
  elsif found then
    insert into public.billing_money_back_windows_v124(
      business_id,first_paid_invoice_id,first_paid_at,
      money_back_request_until,source_event_id
    ) values(
      new.business_id,v_invoice.provider_invoice_id,v_invoice.paid_at,
      v_invoice.paid_at+interval '30 days',v_invoice.last_event_id
    )
    on conflict(business_id) do update
      set first_paid_invoice_id=excluded.first_paid_invoice_id,
          first_paid_at=excluded.first_paid_at,
          money_back_request_until=excluded.money_back_request_until,
          source_event_id=excluded.source_event_id,
          updated_at=now()
      where excluded.first_paid_at
            < billing_money_back_windows_v124.first_paid_at;
  end if;
  return null;
end
$$;
revoke all on function app.backfill_money_back_window_v124()
  from public,anon,authenticated;

create trigger billing_first_paid_self_serve_activate_v144
  after insert or update of first_paid_at
  on public.billing_first_paid_evidence_v144
  for each row execute function app.activate_self_serve_paid_v130();

-- Keep the historical getter shape while exposing the accepted policy. The
-- branch is server-owned; the browser cannot claim an earlier policy.
do $v144_checkout_function$
declare
  v_identity regprocedure:=to_regprocedure('public.get_self_serve_checkout_v130(uuid)');
  v_definition text;
  v_updated text;
begin
  if v_identity is null then
    raise exception 'V130 self-service checkout getter is unavailable' using errcode='0A000';
  end if;
  select pg_get_functiondef(v_identity) into v_definition;
  v_updated:=replace(v_definition,
    '''money_back_days'',30',
    '''money_back_days'',case when v_onboarding.business_id is not null and v_onboarding.legal_document_version<''2026-08-03'' then 30 else null end,''refund_policy'',case when v_onboarding.business_id is not null and v_onboarding.legal_document_version<''2026-08-03'' then ''legacy_30_day_request'' else ''non_refundable_after_payment'' end'
  );
  v_updated:=replace(v_updated,
    '''money_back_days'', 30',
    '''money_back_days'',case when v_onboarding.business_id is not null and v_onboarding.legal_document_version<''2026-08-03'' then 30 else null end,''refund_policy'',case when v_onboarding.business_id is not null and v_onboarding.legal_document_version<''2026-08-03'' then ''legacy_30_day_request'' else ''non_refundable_after_payment'' end'
  );
  if v_updated=v_definition then
    raise exception 'V130 money-back response field was not found' using errcode='23514';
  end if;
  execute v_updated;
end
$v144_checkout_function$;

-- V134 marketing consent records the current Privacy manifest. Carry that
-- exact binding forward without changing its append-only evidence contract.
do $v144_marketing_manifest_function$
declare
  v_identity regprocedure:=to_regprocedure('app.v92_capture_platform_marketing_consent()');
  v_definition text;
  v_updated text;
begin
  if v_identity is null then
    raise exception 'platform marketing consent capture is unavailable' using errcode='0A000';
  end if;
  select pg_get_functiondef(v_identity) into v_definition;
  v_updated:=replace(v_definition,'2026-08-02','2026-08-03');
  v_updated:=replace(v_updated,
    '67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c',
    '8e152d208b271da5a1f71630b17c5c82e8b7bd930c5508da8b4d95597c0a1568'
  );
  if v_updated=v_definition then
    raise exception 'V134 privacy manifest binding was not found' using errcode='23514';
  end if;
  execute v_updated;
end
$v144_marketing_manifest_function$;

comment on table public.billing_first_paid_evidence_v144 is
  'Immutable first-provider-paid evidence for prospectively non-refundable self-service subscriptions; activation authority, not refund entitlement.';

commit;

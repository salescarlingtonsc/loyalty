-- V144 rollback-only acceptance. Run after the canonical chain in a disposable
-- database. V130's acceptance suite proves provider-paid activation through
-- billing_first_paid_evidence_v144; this suite proves the legal and historical
-- evidence boundaries introduced by V144.
begin;
\ir fixtures/pristine_chain_fixture.psql

do $v144_test$
declare
  v_business_old uuid;
  v_business_new uuid;
  v_denied boolean:=false;
begin
  select id into v_business_old from public.businesses
   where name='Pristine chain fixture A';
  select id into v_business_new from public.businesses
   where name='Pristine chain fixture B';
  assert v_business_old is not null and v_business_new is not null,
    'V144 pristine businesses are unavailable';

  assert exists(
    select 1 from app.customer_legal_documents
     where document_key='terms' and active
       and document_version='2026-08-03'
       and document_sha256='1c7437280e9ba8386b5ef3998a919fefcdeca8e06cc497b31621633ae23dab04'
  ), 'V144 Terms manifest is not exact';
  assert exists(
    select 1 from app.customer_legal_documents
     where document_key='privacy' and active
       and document_version='2026-08-03'
       and document_sha256='8e152d208b271da5a1f71630b17c5c82e8b7bd930c5508da8b4d95597c0a1568'
  ), 'V144 Privacy manifest is not exact';

  assert (select pg_get_expr(adbin,adrelid)
            from pg_attrdef
           where adrelid='public.self_serve_business_onboarding_v130'::regclass
             and adnum=(select attnum from pg_attribute
                         where attrelid='public.self_serve_business_onboarding_v130'::regclass
                           and attname='legal_document_version')) like '%2026-08-03%',
    'new self-service records do not default to the V144 legal version';

  insert into public.billing_money_back_windows_v124(
    business_id,first_paid_invoice_id,first_paid_at,
    money_back_request_until,source_event_id
  ) values(
    v_business_old,'in_v144_legacy','2026-08-02 01:00:00+00',
    '2026-09-01 01:00:00+00','evt_v144_legacy'
  );
  assert exists(select 1 from public.billing_money_back_windows_v124
                 where business_id=v_business_old
                   and money_back_request_until='2026-09-01 01:00:00+00'),
    'previously earned refund-window evidence no longer persists';
  begin
    delete from public.billing_money_back_windows_v124
     where business_id=v_business_old;
  exception when sqlstate '23001' then
    v_denied:=true;
  end;
  assert v_denied, 'legacy refund-window evidence became deletable';

  insert into public.billing_first_paid_evidence_v144(
    business_id,first_paid_invoice_id,first_paid_at,source_event_id
  ) values(
    v_business_new,'in_v144_new','2026-08-03 01:00:00+00','evt_v144_new'
  );
  assert exists(select 1 from public.billing_first_paid_evidence_v144
                 where business_id=v_business_new
                   and first_paid_invoice_id='in_v144_new'),
    'new-policy first-paid evidence did not persist';
  assert not exists(select 1 from public.billing_money_back_windows_v124
                     where business_id=v_business_new),
    'new-policy evidence manufactured a refund window';
  v_denied:=false;
  begin
    delete from public.billing_first_paid_evidence_v144
     where business_id=v_business_new;
  exception when sqlstate '23001' then
    v_denied:=true;
  end;
  assert v_denied, 'new-policy first-paid evidence became deletable';

  assert (select relrowsecurity from pg_class
           where oid='public.billing_first_paid_evidence_v144'::regclass),
    'V144 first-paid evidence does not enforce RLS';
  assert not has_table_privilege('anon','public.billing_first_paid_evidence_v144','SELECT')
     and not has_table_privilege('authenticated','public.billing_first_paid_evidence_v144','SELECT'),
    'browser roles can read provider evidence directly';
end
$v144_test$;

rollback;

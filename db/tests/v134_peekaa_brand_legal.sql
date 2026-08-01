-- Rollback-only acceptance for Peekaa V134 legal and runtime brand cutover.
-- Run after the complete canonical chain on a disposable database.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v134_customer(p_uid uuid) returns void
language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_uid,'role','authenticated'
  )::text,true);
end
$$;
grant execute on function pg_temp.as_v134_customer(uuid) to public;

do $v134_manifest_acl$
begin
  if (select count(*) from app.customer_legal_documents d
       where d.active and d.document_version='2026-08-02' and (
         (d.document_key='terms' and d.document_sha256='2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8')
         or (d.document_key='privacy' and d.document_sha256='67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c')
       ))<>2 then
    raise exception 'V134 Peekaa legal manifest is not exact';
  end if;
  if has_table_privilege('anon','app.customer_legal_documents','select')
     or has_table_privilege('authenticated','app.customer_legal_documents','select')
     or has_table_privilege('anon','public.customer_platform_marketing_consent_events','select')
     or has_table_privilege('authenticated','public.customer_platform_marketing_consent_events','select')
     or has_table_privilege('authenticated','public.customer_platform_marketing_consent_events','insert')
     or has_table_privilege('authenticated','public.customer_platform_marketing_consent_events','update')
     or has_table_privilege('authenticated','public.customer_platform_marketing_consent_events','delete') then
    raise exception 'V134 widened private legal/consent evidence privileges';
  end if;
  if has_function_privilege('anon','public.customer_get_platform_marketing_preference()','execute')
     or has_function_privilege('anon','public.customer_set_platform_marketing_preference(boolean,text)','execute')
     or not has_function_privilege('authenticated','public.customer_get_platform_marketing_preference()','execute')
     or not has_function_privilege('authenticated','public.customer_set_platform_marketing_preference(boolean,text)','execute') then
    raise exception 'V134 marketing preference RPC ACLs are not exact';
  end if;
  if pg_get_functiondef('public.customer_get_platform_marketing_preference()'::regprocedure)
       not like '%994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9%'
     or pg_get_functiondef('public.customer_get_platform_marketing_preference()'::regprocedure)
       not like '%08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84%'
     or pg_get_functiondef('public.customer_get_platform_marketing_preference()'::regprocedure)
       not like '%67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c%' then
    raise exception 'V134 reader does not preserve prior consent hashes';
  end if;
  if pg_get_functiondef('public.preview_billing_plan_catalog_v125(text,text,text,text,timestamptz)'::regprocedure)
       like '%Nestly is not GST-registered%'
     or pg_get_functiondef('public.preview_billing_plan_catalog_v125(text,text,text,text,timestamptz)'::regprocedure)
       not like '%NESTLY TECHNOLOGIES PTE. LTD. is not GST-registered%' then
    raise exception 'V134 current no-GST validation identity is not exact';
  end if;
end
$v134_manifest_acl$;

do $v134_runtime_payloads$
declare
  v_signature text;
  v_retired text;
  v_current text;
  v_definition text;
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
    v_definition:=pg_get_functiondef(v_signature::regprocedure);
    if position(v_retired in v_definition)>0
       or position(v_current in v_definition)=0 then
      raise exception 'V134 runtime function copy is not final: %',v_signature;
    end if;
  end loop;

  if exists(select 1 from public.sector_policy_versions_v109 p
      where p.evidence_basis::text like '%Nestly pilot starting policy%')
     or (select count(*) from public.sector_policy_versions_v109 p
          where p.evidence_basis::text like '%Peekaa pilot starting policy%')<>6 then
    raise exception 'V134 sector-policy evidence copy is not exact';
  end if;
  if exists(select 1 from public.sale_policies p
      where p.note='Owner package-purchase points setting (Nestly v102)') then
    raise exception 'V134 retained retired package-policy presentation copy';
  end if;
  if exists(select 1 from public.business_billing_due_notices_v94 n
      where n.notice_body like '%your Nestly representative%')
     or exists(select 1 from public.notifications n
      where n.kind='subscription_payment_due'
        and n.body like '%your Nestly representative%') then
    raise exception 'V134 retained a pre-cutover billing fallback row';
  end if;
end
$v134_runtime_payloads$;

do $v134_historical_acceptance_immutable$
declare
  v_user uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_before jsonb;
  v_after jsonb;
  v_rows integer:=0;
  v_changed integer:=0;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_user,
    'authenticated','authenticated','v134-legal-'||v_user::text||'@example.test','',now(),now(),now()
  );
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity,v_user,'active','wallet_start');
  insert into public.customer_legal_acceptances(
    identity_id,auth_user_id,document_key,document_version,
    document_sha256,acceptance_hash,accepted_at,created_at
  ) values
    (v_identity,v_user,'terms','2026-08-01',
     'e581bbd1f20e9b8b1958f75f100950c50d20a9810d82fce8467b1ed74859643f',
     repeat('a',64),timestamptz '2026-08-01 10:00:00+08:00',timestamptz '2026-08-01 10:00:00+08:00'),
    (v_identity,v_user,'privacy','2026-08-01',
     '08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84',
     repeat('b',64),timestamptz '2026-08-01 10:00:01+08:00',timestamptz '2026-08-01 10:00:01+08:00');

  select jsonb_agg(to_jsonb(a) order by a.document_key) into v_before
    from public.customer_legal_acceptances a where a.identity_id=v_identity;

  -- Repeat the V134 legal-manifest writes against both current active rows.
  -- These are real same-value writes, not a zero-row predicate, and must remain
  -- scoped to the manifest without rewriting acceptance evidence.
  update app.customer_legal_documents
     set document_version='2026-08-02',
         document_sha256='2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8',
         published_at=timestamptz '2026-08-02 09:00:00+08:00',
         updated_at=timestamptz '2026-08-02 09:00:00+08:00'
   where document_key='terms' and active
     and document_version='2026-08-02'
     and document_sha256='2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8';
  get diagnostics v_changed=row_count;
  v_rows:=v_rows+v_changed;
  update app.customer_legal_documents
     set document_version='2026-08-02',
         document_sha256='67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c',
         published_at=timestamptz '2026-08-02 09:00:00+08:00',
         updated_at=timestamptz '2026-08-02 09:00:00+08:00'
   where document_key='privacy' and active
     and document_version='2026-08-02'
     and document_sha256='67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c';
  get diagnostics v_changed=row_count;
  v_rows:=v_rows+v_changed;

  if v_rows<>2 then
    raise exception 'V134 legal manifest replay did not write exactly two current rows';
  end if;

  select jsonb_agg(to_jsonb(a) order by a.document_key) into v_after
    from public.customer_legal_acceptances a where a.identity_id=v_identity;
  if v_after is distinct from v_before then
    raise exception 'V134 legal manifest changed historical legal acceptance bytes';
  end if;
end
$v134_historical_acceptance_immutable$;

set local role anon;
do $v134_anon_rpc_denial$
begin
  begin
    perform public.customer_get_platform_marketing_preference();
    raise exception 'anonymous preference reader was callable';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.customer_set_platform_marketing_preference(true,'v134-anon-denied');
    raise exception 'anonymous preference writer was callable';
  exception when insufficient_privilege then null;
  end;
end
$v134_anon_rpc_denial$;
reset role;

do $v134_authenticated_outsider$
declare
  v_user uuid:=gen_random_uuid();
  v_result jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_user,
    'authenticated','authenticated','v134-outsider-'||v_user::text||'@example.test','',now(),now(),now()
  );
  perform pg_temp.as_v134_customer(v_user);
  v_result:=public.customer_get_platform_marketing_preference();
  if v_result->>'opted_in'<>'false' then
    raise exception 'authenticated outsider preference reader was not fail-closed';
  end if;
  begin
    perform public.customer_set_platform_marketing_preference(true,'v134-outsider-denied');
    raise exception 'authenticated outsider preference writer was accepted';
  exception when insufficient_privilege then null;
  end;
  reset role;
end
$v134_authenticated_outsider$;

do $v134_consent_replay$
declare
  v_user uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_key text:='v134-consent-'||gen_random_uuid()::text;
  v_result jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_user,
    'authenticated','authenticated','v134-'||v_user::text||'@example.test','',now(),now(),now()
  );
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity,v_user,'active','wallet_start');
  insert into public.customer_registration_preferences(
    identity_id,auth_user_id,platform_marketing_opted_in
  ) values(v_identity,v_user,false);

  perform pg_temp.as_v134_customer(v_user);
  v_result:=public.customer_set_platform_marketing_preference(true,v_key);
  if v_result<>jsonb_build_object('outcome','updated','opted_in',true) then
    raise exception 'V134 consent write did not return the canonical response';
  end if;
  v_result:=public.customer_set_platform_marketing_preference(true,v_key);
  if v_result<>jsonb_build_object('outcome','updated','opted_in',true) then
    raise exception 'V134 exact consent replay was not stable';
  end if;
  if public.customer_get_platform_marketing_preference()->>'opted_in'<>'true' then
    raise exception 'V134 current consent is not readable';
  end if;
  begin
    perform public.customer_set_platform_marketing_preference(false,v_key);
    raise exception 'V134 changed-payload idempotency replay was accepted';
  exception when unique_violation then null;
  end;
  reset role;

  if (select count(*) from public.customer_platform_marketing_consent_events e
       where e.identity_id=v_identity and e.idempotency_key=v_key
         and e.opted_in and e.privacy_version='2026-08-02'
         and e.privacy_sha256='67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c')<>1 then
    raise exception 'V134 consent did not create exactly one current immutable event';
  end if;
end
$v134_consent_replay$;

do $v134_prior_consent_compatibility$
declare
  v_user uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_result jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_user,
    'authenticated','authenticated','v134-old-'||v_user::text||'@example.test','',now(),now(),now()
  );
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity,v_user,'active','wallet_start');
  insert into public.customer_registration_preferences(
    identity_id,auth_user_id,platform_marketing_opted_in
  ) values(v_identity,v_user,false);
  set local session_replication_role='replica';
  update public.customer_registration_preferences
     set platform_marketing_opted_in=true,
       marketing_scope_version='2026-07-28-selected-partners-v1',
       marketing_privacy_sha256='08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84'
   where identity_id=v_identity;
  insert into public.customer_platform_marketing_consent_events(
    identity_id,auth_user_id,opted_in,scope_version,privacy_version,
    privacy_sha256,source,idempotency_key,request_hash
  ) values(
    v_identity,v_user,true,'2026-07-28-selected-partners-v1','2026-08-01',
    '08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84',
    'customer_profile','v134-prior-'||v_identity::text,repeat('a',64)
  );
  set local session_replication_role='origin';
  perform pg_temp.as_v134_customer(v_user);
  v_result:=public.customer_get_platform_marketing_preference();
  reset role;
  if v_result->>'opted_in'<>'true' then
    raise exception 'V134 invalidated reviewed prior consent evidence';
  end if;
end
$v134_prior_consent_compatibility$;

do $v134_runtime_brand$
declare
  v_business uuid;
  v_notice uuid;
begin
  insert into public.businesses(name,slug,industry,enabled_modules)
  values('Glow Atelier V134','glow-v134-'||substr(gen_random_uuid()::text,1,8),'beauty',array['dashboard'])
  returning id into v_business;
  insert into public.business_billing_due_notices_v94(
    business_id,provider_invoice_id,due_date,due_day,notice_title,notice_body,hotline_phone
  ) values(
    v_business,'in_v134_brand',date '2026-08-01',14,'Workspace paused — payment overdue',
    'Payment is 14 day(s) overdue. Update billing or contact your Nestly representative at +65 6000 0000.',
    '+65 6000 0000'
  ) returning id into v_notice;
  if (select notice_body from public.business_billing_due_notices_v94 where id=v_notice)
       not like '%your Peekaa representative%'
     or (select notice_body from public.business_billing_due_notices_v94 where id=v_notice)
       like '%your Nestly representative%' then
    raise exception 'V134 durable billing notice retained the retired fallback';
  end if;
  insert into public.notifications(business_id,kind,title,body,ref_table,ref_id)
  values(
    v_business,'subscription_payment_due','Subscription payment is overdue',
    'Payment is overdue. Contact your Nestly representative at +65 6000 0000.',
    'business_billing_due_notices_v94',v_notice
  );
  if not exists(select 1 from public.notifications n
     where n.ref_id=v_notice and n.body like '%your Peekaa representative%'
       and n.body not like '%your Nestly representative%') then
    raise exception 'V134 notification projection retained the retired fallback';
  end if;
end
$v134_runtime_brand$;

rollback;

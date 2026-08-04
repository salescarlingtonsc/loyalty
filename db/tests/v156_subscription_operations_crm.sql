begin;

do $$
declare v_profile public.platform_billing_profiles_v156%rowtype;
begin
  select * into strict v_profile from public.platform_billing_profiles_v156 where version=1;
  if v_profile.brand_name<>'Peekaa' or v_profile.legal_name<>'NESTLY TECHNOLOGIES PTE. LTD.' then raise exception 'seller identity seed mismatch';end if;
  if v_profile.bank_code<>'9496' or v_profile.branch_code<>'001' or v_profile.swift_code<>'SCBLSG22' or v_profile.bank_account_number<>'7897246357' then raise exception 'bank seed mismatch';end if;
  if v_profile.uen<>'202634502E' or v_profile.registered_address is not null or v_profile.billing_email is not null or v_profile.gst_status<>'unconfigured' then raise exception 'seller configuration does not match confirmed truth';end if;
  if app.v156_profile_ready(v_profile) then raise exception 'incomplete seller profile must fail closed';end if;
end $$;

do $$
declare v_one text;v_two text;
begin
  v_one:=app.v156_next_document_number('quotation',date '2026-08-04');
  v_two:=app.v156_next_document_number('quotation',date '2026-08-04');
  if v_one!~'^QTN-2026-[0-9]{6}$' or v_two!~'^QTN-2026-[0-9]{6}$' or v_one=v_two then raise exception 'quotation numbering is not sequential and unique';end if;
end $$;

do $$
begin
  if has_table_privilege('authenticated','public.platform_subscription_documents_v156','select') then raise exception 'raw documents are exposed';end if;
  if has_table_privilege('anon','public.platform_billing_contacts_v156','select') then raise exception 'billing contacts are exposed';end if;
  if has_table_privilege('authenticated','public.platform_manual_payments_v156','update') then raise exception 'manual payments are directly mutable';end if;
  if not has_function_privilege('authenticated','public.platform_get_subscription_operations_v156(text,text,integer)','execute') then raise exception 'guarded subscription reader is unavailable';end if;
  if has_function_privilege('anon','public.platform_get_subscription_operations_v156(text,text,integer)','execute') then raise exception 'anonymous subscription access is exposed';end if;
end $$;

do $$
begin
  begin
    update public.platform_billing_profiles_v156 set brand_name='Changed' where version=1;
    raise exception 'profile history was mutable';
  exception when sqlstate '55000' then null;end;
end $$;

rollback;

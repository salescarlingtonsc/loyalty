-- FRENLY v47b — deterministic phone-sale overload dispatch.
-- Keep the retired legacy signature present but inaccessible so privilege
-- checks remain stable. Remove defaults from the hardened nine-argument
-- signature so PostgreSQL can resolve calls without ambiguity.

begin;

create or replace function public.record_sale_by_phone(
  p_business uuid,p_phone text,p_amount_cents integer,
  p_kind text default 'quick_sale',p_note text default null,
  p_staff uuid default null,p_idem text default null
)
returns json
language plpgsql
security invoker
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'Legacy phone-sale signature is retired; use the hardened nine-argument operation'
    using errcode='42501';
end
$$;

revoke all privileges on function public.record_sale_by_phone(
  uuid,text,integer,text,text,uuid,text
) from public, anon, authenticated;

drop function public.record_sale_by_phone(
  uuid,text,integer,text,text,uuid,text,uuid,text
);

create or replace function public.record_sale_by_phone(
  p_business uuid,p_phone text,p_amount_cents integer,
  p_kind text,p_note text,p_staff uuid,p_idem text,
  p_branch uuid,p_method text
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_norm text;
  v_actor_staff uuid;
  v_client public.clients%rowtype;
  v_financial jsonb;
  v_sale_id uuid;
  v_payment_id uuid;
  v_points_earned integer;
  v_points_after integer;
  v_note text;
begin
  if not app.has_perm(p_business,'create_sales')
     or not app.can_module_read(p_business,'clients') then
    raise exception 'clients read and create-sales authorization is required' using errcode='42501';
  end if;
  select staff.id into v_actor_staff from public.staff staff
   where staff.business_id=p_business and staff.user_id=auth.uid() and staff.active limit 1;
  if not found then raise exception 'an active staff identity is required' using errcode='42501'; end if;
  if p_staff is not null and p_staff is distinct from v_actor_staff then
    raise exception 'sale staff attribution must match the authenticated staff identity'
      using errcode='42501';
  end if;
  if p_idem is null or char_length(btrim(p_idem)) not between 8 and 200 then
    raise exception 'an idempotency key of 8 to 200 characters is required' using errcode='22023';
  end if;
  if p_amount_cents is null or p_amount_cents<=0 then
    raise exception 'Enter the amount paid.' using errcode='22023';
  end if;
  if p_kind is distinct from 'quick_sale' then
    raise exception 'Quick earn only accepts quick-sale purchases' using errcode='22023';
  end if;
  if p_branch is null then
    raise exception 'Choose the branch where payment was received' using errcode='22023';
  end if;
  if lower(coalesce(btrim(p_method),'')) not in ('cash','card','paynow','other') then
    raise exception 'Choose Cash, Card, PayNow or Other' using errcode='22023';
  end if;
  if p_note is not null and char_length(p_note)>1000 then
    raise exception 'sale note is too long' using errcode='22023';
  end if;
  v_norm:=app.norm_phone(p_phone);
  if v_norm is null then raise exception 'Enter a valid 8-digit mobile number.' using errcode='22023'; end if;
  select * into v_client from public.clients
   where business_id=p_business and phone_norm=v_norm;
  if not found then raise exception 'No customer with that number. Add them first.' using errcode='22023'; end if;
  v_note:=coalesce(p_note,'till: '||v_norm);
  v_financial:=public.record_quick_sale(
    p_business=>p_business,p_amount_cents=>p_amount_cents,
    p_method=>lower(btrim(p_method)),p_client=>v_client.id,p_staff=>v_actor_staff,
    p_branch=>p_branch,p_note=>v_note,p_idempotency_key=>btrim(p_idem),p_paid=>true
  )::jsonb;
  v_sale_id:=nullif(v_financial #>> '{sale,id}','')::uuid;
  v_payment_id:=nullif(v_financial->>'payment_id','')::uuid;
  if v_sale_id is null or v_payment_id is null then
    raise exception 'Quick earn did not produce exact sale and payment proof' using errcode='XX001';
  end if;
  select coalesce(sum(points),0) into v_points_earned from public.points_ledger
   where business_id=p_business and client_id=v_client.id and sale_id=v_sale_id;
  select coalesce(sum(points),0) into v_points_after from public.points_ledger
   where business_id=p_business and client_id=v_client.id;
  return json_build_object(
    'status',case when coalesce((v_financial->>'replayed')::boolean,false)
                  then 'duplicate_ignored' else 'ok' end,
    'sale_id',v_sale_id,'payment_id',v_payment_id,'client_id',v_client.id,
    'full_name',v_client.full_name,'amount_cents',p_amount_cents,'kind','quick_sale',
    'branch_id',p_branch,'payment_method',lower(btrim(p_method)),
    'points_earned',case when coalesce((v_financial->>'replayed')::boolean,false)
                         then 0 else v_points_earned end,
    'points',v_points_after
  );
end
$$;

revoke all privileges on function public.record_sale_by_phone(
  uuid,text,integer,text,text,uuid,text,uuid,text) from public, anon, authenticated;
grant execute on function public.record_sale_by_phone(
  uuid,text,integer,text,text,uuid,text,uuid,text) to authenticated;

commit;


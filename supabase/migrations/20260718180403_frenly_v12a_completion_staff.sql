-- FRENLY v12a — carry appointments.staff_id onto the sale at completion. Fixes Q9.
-- Body reproduced from the LIVE definition; only v_staff resolution, the same-tenant
-- guard, and staff_id in the INSERT are new. FEFO + idempotent insert unchanged.
create or replace function app.on_appointment_completed()
returns trigger language plpgsql security definer set search_path = public as $function$
declare
  v_amount integer;
  sp       record;
  b        record;
  v_need   integer;
  v_take   integer;
  v_staff  uuid;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    v_amount := coalesce(nullif(new.total_cents,0),
                         (select price_cents from services where id = new.service_id), 0);

    -- Q9 FIX. Resolve the performer through the SAME COMPOSITE PAIR that sales_staff_fk
    -- enforces (appointments' own FK is single-column and does NOT check tenant), so a
    -- cross-tenant staff_id fails closed with a named error instead of an opaque FK violation.
    if new.staff_id is not null then
      select st.id into v_staff
        from staff st
       where st.id = new.staff_id
         and st.business_id = new.business_id;
      if v_staff is null then
        raise exception 'appointment % references staff % which does not belong to business % '
                        '— refusing to attribute a sale across tenants',
                        new.id, new.staff_id, new.business_id
          using errcode = 'foreign_key_violation';
      end if;
    end if;

    -- Idempotent against the partial unique index one_sale_per_appointment.
    insert into sales (business_id, client_id, kind, amount_cents, appointment_id, staff_id, note)
    values (new.business_id, new.client_id, 'service', v_amount, new.id, v_staff, 'appointment completed')
    on conflict do nothing;

    -- FEFO stock consumption via service_products. UNCHANGED from the live definition.
    if new.service_id is not null then
      for sp in
        select product_id, qty from service_products where service_id = new.service_id
      loop
        v_need := sp.qty;
        for b in
          select id, qty from stock_batches
          where product_id = sp.product_id and qty > 0
          order by expires_on nulls last, received_on, id
        loop
          exit when v_need <= 0;
          v_take := least(b.qty, v_need);
          update stock_batches set qty = qty - v_take where id = b.id;
          v_need := v_need - v_take;
        end loop;
      end loop;
    end if;
  end if;
  return new;
end $function$;
-- NESTLY v636 — Phase A, M10 (A13): a catalog service can only be hard-deleted by the owner.
-- The Phase A audit expected the init-era any-member policy; production actually runs
-- v572's split policies, where DELETE is gated on is_salon_member + can_module_write —
-- i.e. any staff member holding the services module can still permanently destroy a
-- service. sale_items.ref_id has no FK, so deletion orphans every historical line and
-- the Phase C taxonomy mapping target. Soft retire (active=false) remains the everyday
-- path for everyone with module write; hard DELETE becomes owner-only.
begin;

drop policy services_delete_v572 on public.services;
create policy services_delete_v636 on public.services
  for delete to authenticated
  using (
    app.is_salon_member(business_id)
    and app.can_module_write(business_id, 'services')
    and exists (
      select 1 from public.staff s
       where s.business_id = services.business_id
         and s.user_id = auth.uid()
         and s.active
         and s.role = 'owner'
    )
  );

commit;

-- NESTLY v202b — creating a branch is a BILLABLE act, so it cannot be a plain table insert.
--
-- branches_write granted ALL to any owner, and app/app.js used it directly:
--   sb.from('branches').insert({...})
-- An owner could add unlimited branches for free, which made the whole v202 paid path
-- decorative. Splitting ALL into SELECT/UPDATE/DELETE leaves every existing screen working
-- (rename, activate, deactivate) while making business_add_branch_v202 — SECURITY DEFINER,
-- and the thing that mints the billing command — the ONLY way a branch comes into existence.
--
-- Same shape as the v14 fix that removed the businesses INSERT policy and left
-- create_business as the sole path.

begin;

drop policy if exists branches_write on public.branches;

create policy branches_read on public.branches
  for select to authenticated using (app.is_salon_owner(business_id));

create policy branches_update on public.branches
  for update to authenticated using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));

create policy branches_delete on public.branches
  for delete to authenticated using (app.is_salon_owner(business_id));

-- deliberately NO insert policy: see above.

commit;

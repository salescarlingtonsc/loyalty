-- Frenly v49b: align Reports RPC authorization with v41 read-only module permissions.
-- Forward-only catalog repair. Historical migrations remain immutable.

begin;

create or replace function app.reports_gift_card_liability_v49b(
  p_business uuid,
  p_branch uuid default null::uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_liability bigint;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales')
     or not app.can_module_read(p_business, 'reports') then
    raise exception 'active Reports read authorization is required'
      using errcode = '42501';
  end if;
  if p_branch is not null and not exists (
    select 1
      from public.branches branch
     where branch.id = p_branch
       and branch.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope'
      using errcode = '42501';
  end if;

  -- Gift cards have no branch attribution. After validating the requested branch,
  -- the scalar is intentionally business-wide and exposes no card/customer fields.
  select coalesce(sum(card.balance_cents) filter (where card.status = 'active'), 0)::bigint
    into v_liability
    from public.gift_cards card
   where card.business_id = p_business;
  return coalesce(v_liability, 0);
end
$$;

do $migration$
declare
  v_definition text;
  v_legacy text := '     or not app.can_module(p_business, ''reports'') then';
  v_read text := '     or not app.can_module_read(p_business, ''reports'') then';
  v_gift_card_legacy text := E'  select coalesce(sum(gc.balance_cents) filter (where gc.status = ''active''), 0)\n  into v_gift_card_liability\n  from public.gift_cards gc\n  where gc.business_id = p_business;';
  v_gift_card_helper text := '  v_gift_card_liability := app.reports_gift_card_liability_v49b(p_business, p_branch);';
  v_legacy_occurrences integer;
  v_read_occurrences integer;
  v_gift_card_legacy_occurrences integer;
  v_gift_card_helper_occurrences integer;
begin
  select pg_get_functiondef(
           'public.get_reports_summary(uuid,date,date,uuid)'::regprocedure
         )
    into strict v_definition;

  v_legacy_occurrences := (
    length(v_definition) - length(replace(v_definition, v_legacy, ''))
  ) / length(v_legacy);
  v_read_occurrences := (
    length(v_definition) - length(replace(v_definition, v_read, ''))
  ) / length(v_read);
  v_gift_card_legacy_occurrences := (
    length(v_definition) - length(replace(v_definition, v_gift_card_legacy, ''))
  ) / length(v_gift_card_legacy);
  v_gift_card_helper_occurrences := (
    length(v_definition) - length(replace(v_definition, v_gift_card_helper, ''))
  ) / length(v_gift_card_helper);

  if v_legacy_occurrences <> 1 or v_read_occurrences <> 0
     or v_gift_card_legacy_occurrences <> 1 or v_gift_card_helper_occurrences <> 0 then
    raise exception 'unexpected get_reports_summary predecessor authorization definition';
  end if;

  v_definition := replace(v_definition, v_legacy, v_read);
  execute replace(v_definition, v_gift_card_legacy, v_gift_card_helper);
end
$migration$;

-- PostgreSQL grants function execution to PUBLIC by default. Reassert the intended
-- browser surface after CREATE OR REPLACE: authenticated only, never anon/PUBLIC.
revoke all privileges on function app.reports_gift_card_liability_v49b(uuid,uuid)
  from public, anon, authenticated;
grant execute on function app.reports_gift_card_liability_v49b(uuid,uuid)
  to authenticated;
revoke all privileges on function public.get_reports_summary(uuid,date,date,uuid)
  from public, anon, authenticated;
grant execute on function public.get_reports_summary(uuid,date,date,uuid)
  to authenticated;

commit;

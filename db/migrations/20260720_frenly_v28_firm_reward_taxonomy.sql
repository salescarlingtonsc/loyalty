-- FRENLY v28 - PER-FIRM REWARD TAXONOMY
-- Local review candidate. Do not apply until the phase release gate is accepted.

begin;

create table public.firm_reward_taxonomy (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  label text not null check (char_length(btrim(label)) between 2 and 80),
  fulfillment_kind text not null
    check (fulfillment_kind in ('discount_pct','free_item','credit')),
  active boolean not null default true,
  sort integer not null default 0 check (sort between 0 and 10000),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint firm_reward_taxonomy_id_business_uk unique (id, business_id)
);
create unique index firm_reward_taxonomy_label_uk
  on public.firm_reward_taxonomy (business_id, lower(btrim(label)));

insert into public.firm_reward_taxonomy (
  business_id, label, fulfillment_kind, created_by
)
select distinct rp.business_id,
  case rp.reward_type
    when 'discount_pct' then 'Percentage discount'
    when 'free_item' then 'Free item or service'
    when 'credit' then 'Store credit'
  end,
  rp.reward_type,
  null::uuid
from public.retention_programs rp;

-- Every firm receives editable starter labels. They have no effect until an
-- owner selects one in a retention program.
insert into public.firm_reward_taxonomy (
  business_id, label, fulfillment_kind, created_by, sort
)
select b.id, seed.label, seed.kind, null::uuid, seed.sort
  from public.businesses b
 cross join (values
   ('Percentage discount','discount_pct',10),
   ('Free item or service','free_item',20),
   ('Store credit','credit',30)
 ) as seed(label,kind,sort)
 where not exists (
   select 1 from public.firm_reward_taxonomy t
    where t.business_id=b.id and t.fulfillment_kind=seed.kind
 );

alter table public.retention_programs add column reward_taxonomy_id uuid;
update public.retention_programs rp
   set reward_taxonomy_id = t.id
  from public.firm_reward_taxonomy t
 where t.business_id = rp.business_id
   and t.fulfillment_kind = rp.reward_type;
alter table public.retention_programs alter column reward_taxonomy_id set not null;
alter table public.retention_programs
  add constraint retention_programs_id_business_uk unique (id, business_id),
  add constraint retention_programs_taxonomy_business_fk
    foreign key (reward_taxonomy_id, business_id)
    references public.firm_reward_taxonomy(id, business_id) on delete restrict;
alter table public.retention_programs
  drop constraint if exists retention_programs_reward_type_check;
alter table public.retention_programs
  add constraint retention_programs_reward_type_projection_check
  check (reward_type in ('discount_pct','free_item','credit'));

alter table public.reward_grants
  add column reward_taxonomy_id uuid,
  add column reward_label text,
  add column fulfillment_kind text;
update public.reward_grants g
   set reward_taxonomy_id = rp.reward_taxonomy_id,
       reward_label = t.label,
       fulfillment_kind = t.fulfillment_kind
  from public.retention_programs rp
  join public.firm_reward_taxonomy t
    on t.id = rp.reward_taxonomy_id
   and t.business_id = rp.business_id
 where rp.id = g.program_id
   and rp.business_id = g.business_id;
alter table public.reward_grants
  alter column reward_taxonomy_id set not null,
  alter column reward_label set not null,
  alter column fulfillment_kind set not null,
  add constraint reward_grants_taxonomy_business_fk
    foreign key (reward_taxonomy_id, business_id)
    references public.firm_reward_taxonomy(id, business_id) on delete restrict,
  add constraint reward_grants_program_business_fk
    foreign key (program_id, business_id)
    references public.retention_programs(id, business_id) on delete cascade,
  add constraint reward_grants_fulfillment_kind_check
    check (fulfillment_kind in ('discount_pct','free_item','credit'));

alter table public.firm_reward_taxonomy enable row level security;
drop policy if exists firm_reward_taxonomy_read on public.firm_reward_taxonomy;
drop policy if exists firm_reward_taxonomy_write on public.firm_reward_taxonomy;
drop policy if exists firm_reward_taxonomy_sa_read on public.firm_reward_taxonomy;
create policy firm_reward_taxonomy_read on public.firm_reward_taxonomy
  for select to authenticated using (app.is_salon_member(business_id));
create policy firm_reward_taxonomy_write on public.firm_reward_taxonomy
  for all to authenticated using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
create policy firm_reward_taxonomy_sa_read on public.firm_reward_taxonomy
  for select to authenticated using (app.is_super_admin());
revoke all on public.firm_reward_taxonomy from public, anon;
grant select, insert, update, delete on public.firm_reward_taxonomy to authenticated;

create or replace function app.guard_reward_taxonomy_kind()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  new.label := btrim(new.label);
  if tg_op = 'UPDATE' and new.fulfillment_kind is distinct from old.fulfillment_kind then
    raise exception 'reward fulfillment behavior is immutable; create a new reward type'
      using errcode = 'restrict_violation';
  end if;
  new.updated_at := now();
  return new;
end $$;
revoke execute on function app.guard_reward_taxonomy_kind() from public, anon, authenticated;
create trigger trg_guard_reward_taxonomy_kind
  before insert or update on public.firm_reward_taxonomy
  for each row execute function app.guard_reward_taxonomy_kind();

create or replace function app.resolve_retention_reward_taxonomy()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_tax public.firm_reward_taxonomy%rowtype;
begin
  select * into v_tax
    from public.firm_reward_taxonomy
   where id = new.reward_taxonomy_id
     and business_id = new.business_id;
  if not found then
    raise exception 'reward type does not belong to this business'
      using errcode = 'foreign_key_violation';
  end if;
  if (tg_op = 'INSERT' or new.reward_taxonomy_id is distinct from old.reward_taxonomy_id)
     and not v_tax.active then
    raise exception 'retired reward types cannot be selected';
  end if;
  new.reward_type := v_tax.fulfillment_kind;
  if new.reward_type = 'discount_pct'
     and (new.reward_value <= 0 or new.reward_value > 100) then
    raise exception 'discount percentage must be greater than 0 and at most 100'
      using errcode = 'check_violation';
  elsif new.reward_type = 'credit'
     and (new.reward_value <= 0 or new.reward_value <> trunc(new.reward_value)) then
    raise exception 'store credit must be a positive whole number of cents'
      using errcode = 'check_violation';
  elsif new.reward_type = 'free_item'
     and char_length(btrim(coalesce(new.reward_item,''))) < 2 then
    raise exception 'free item or service description is required'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
revoke execute on function app.resolve_retention_reward_taxonomy() from public, anon, authenticated;
create trigger trg_resolve_retention_reward_taxonomy
  before insert or update on public.retention_programs
  for each row execute function app.resolve_retention_reward_taxonomy();

create or replace function app.snapshot_reward_grant_taxonomy()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_tax_id uuid; v_label text; v_kind text;
begin
  select rp.reward_taxonomy_id, t.label, t.fulfillment_kind
    into v_tax_id, v_label, v_kind
    from public.retention_programs rp
    join public.firm_reward_taxonomy t
      on t.id = rp.reward_taxonomy_id and t.business_id = rp.business_id
   where rp.id = new.program_id and rp.business_id = new.business_id;
  if not found then raise exception 'retention program taxonomy not found'; end if;
  if new.reward_taxonomy_id is not null and new.reward_taxonomy_id <> v_tax_id then
    raise exception 'reward grant taxonomy does not match its program'
      using errcode = 'check_violation';
  end if;
  new.reward_taxonomy_id := v_tax_id;
  new.reward_label := v_label;
  new.fulfillment_kind := v_kind;
  new.reward_type := v_kind;
  return new;
end $$;
revoke execute on function app.snapshot_reward_grant_taxonomy() from public, anon, authenticated;
create trigger trg_snapshot_reward_grant_taxonomy
  before insert on public.reward_grants
  for each row execute function app.snapshot_reward_grant_taxonomy();

commit;

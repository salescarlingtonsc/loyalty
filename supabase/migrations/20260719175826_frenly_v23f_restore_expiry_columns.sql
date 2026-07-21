alter table public.loyalty_programs
  add column if not exists expiry_mode text not null default 'none'
    check (expiry_mode in ('none','fixed','inactivity')),
  add column if not exists expiry_days integer;
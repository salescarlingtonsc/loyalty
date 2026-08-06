-- NESTLY v177 - CLIENT ERROR REPORTS
--
-- Production-readiness monitoring: the app previously had no client-side
-- error visibility at all. Adds a private append-only telemetry table and a
-- fire-and-forget intake RPC. Browser roles cannot read the table (RLS
-- enabled with zero policies and all table privileges revoked); the only
-- write path is report_client_error_v177, which caps every payload field,
-- drops everything beyond 300 reports/hour globally, dedupes identical
-- errors within a minute, and never raises to the caller.
begin;

create table public.client_error_reports (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid,
  surface text not null check (surface in ('customer','business','public')),
  message text not null check (char_length(message) between 1 and 500),
  stack text check (stack is null or char_length(stack) <= 2000),
  url text check (url is null or char_length(url) <= 300),
  build text check (build is null or char_length(build) <= 64),
  user_agent text check (user_agent is null or char_length(user_agent) <= 300),
  dedupe_hash text not null check (dedupe_hash ~ '^[0-9a-f]{64}$'),
  occurred_at timestamptz not null default now()
);
comment on table public.client_error_reports is
  'Append-only client-side error telemetry. No browser role may read; writes only through report_client_error_v177 with flood guard and dedupe.';
alter table public.client_error_reports enable row level security;
revoke all privileges on table public.client_error_reports from public, anon, authenticated;
create index client_error_reports_occurred_idx on public.client_error_reports (occurred_at desc);
create index client_error_reports_dedupe_idx on public.client_error_reports (dedupe_hash, occurred_at desc);

create or replace function public.report_client_error_v177(
  p_surface text, p_message text, p_stack text default null,
  p_url text default null, p_build text default null
) returns void
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_surface text;
  v_message text;
  v_hash text;
  v_recent integer;
begin
  v_surface := coalesce(nullif(btrim(p_surface),''),'public');
  if v_surface not in ('customer','business','public') then v_surface := 'public'; end if;
  v_message := left(coalesce(nullif(btrim(p_message),''),'unknown error'),500);
  v_hash := app.v31_sha256_hex(v_surface||':'||v_message||':'||coalesce(left(p_url,300),''));
  select count(*) into v_recent from public.client_error_reports
   where occurred_at > now() - interval '1 hour';
  if v_recent >= 300 then return; end if;
  if exists (
    select 1 from public.client_error_reports
     where dedupe_hash = v_hash and occurred_at > now() - interval '1 minute'
  ) then return; end if;
  insert into public.client_error_reports
    (auth_user_id, surface, message, stack, url, build, user_agent, dedupe_hash)
  values (
    auth.uid(), v_surface, v_message, left(p_stack,2000), left(p_url,300),
    left(p_build,64),
    left(coalesce(current_setting('request.headers',true),'{}')::jsonb->>'user-agent',300),
    v_hash
  );
exception when others then
  return;
end $$;
comment on function public.report_client_error_v177(text,text,text,text,text) is
  'Fire-and-forget client error intake: payload caps, 300/hour global flood guard, per-error one-minute dedupe. Never raises.';
revoke all on function public.report_client_error_v177(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.report_client_error_v177(text,text,text,text,text) to anon;
grant execute on function public.report_client_error_v177(text,text,text,text,text) to authenticated;

commit;

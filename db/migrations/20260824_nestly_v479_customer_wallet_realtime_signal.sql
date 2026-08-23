-- nestly_v479 — the customer hears about their stamps the way the business hears about bookings.
--
-- OWNER, 2026-08-24: "why we clicked record sale on business view but customer view will take so
-- long to receive the stamps? But customer can book appointment and business will receive the
-- appointment instantly?" — and, choosing the fix: it must be the proven mechanism other apps
-- use, give exact factual data, and not load the backend.
--
-- THE ASYMMETRY. The business app holds an open realtime channel on appointments /
-- booking_requests / notifications — tables staff are allowed to read — so a booking is PUSHED in
-- under a second. The customer app holds no channel at all and POLLS (20s cadence, 9-tick budget,
-- paused when hidden), because the table their stamps live in — points_ledger — is the sales
-- record, and customers deliberately hold no SELECT on it. Realtime respects RLS, so subscribing
-- them to the ledger would deliver nothing. The lag the owner sees is the poll budget running out.
--
-- THE FIX. A signal table the customer IS allowed to hear. One row per (business, customer),
-- carrying NOTHING but "your balance moved" — no amounts, no items, no other customers. A trigger
-- on points_ledger bumps it on every earn, redemption, adjustment and expiry (the ledger is the
-- one spine every balance change flows through). The row joins the same realtime publication
-- appointments already use; the customer app subscribes filtered to its own auth uid and, on the
-- ping, re-runs the SAME ledger-backed read it runs today. The push carries no figures, so the
-- number on screen is always the ledger's answer — exact and factual by construction.
--
-- BACKEND LOAD: one tiny upsert per ledger row, silence otherwise. This REPLACES load rather than
-- adding it: the alternative was every open customer app querying on a timer whether anything
-- happened or not.
--
-- THE NON-NEGOTIABLE RULE: a signal must never break a sale. The trigger function swallows every
-- exception and returns null. PROVED in the rolled-back dry run by the worst case imaginable —
-- the signals table dropped entirely mid-flight — after which a points_ledger insert still
-- succeeded. Also proved: the signal row is written for a verified customer link; the customer
-- reads their own row; a stranger reads nothing.
--
-- WHAT IS DELIBERATELY NOT DONE:
--   * The polling watcher is NOT removed. Sockets drop — on a train, in a lift — and when this
--     channel is connected the poll is redundant but harmless; when it is not, the poll is the
--     fallback that keeps the promise. Belt and braces, exactly like the business side.
--   * No RLS change on points_ledger. The ruling stands: customers never read the sales record.
--   * REPLICA IDENTITY FULL on a table this small is fine: one row per customer-business pair,
--     updated in place, never appended.

begin;

create table public.customer_wallet_signals_v479(
  business_id uuid not null references public.businesses(id) on delete cascade,
  auth_user_id uuid not null,
  client_id uuid,
  bumped_at timestamptz not null default now(),
  primary key (business_id, auth_user_id)
);

comment on table public.customer_wallet_signals_v479 is
  'nestly_v479. One row per (business, customer): "your balance moved", nothing else. Bumped by '
  'a trigger on points_ledger; the customer app subscribes via realtime and re-reads its normal '
  'RPCs on the ping. Carries no amounts by design — the push is a doorbell, not a statement.';

alter table public.customer_wallet_signals_v479 enable row level security;
alter table public.customer_wallet_signals_v479 replica identity full;

create policy customer_wallet_signals_v479_own_read on public.customer_wallet_signals_v479
  for select to authenticated using (auth_user_id = auth.uid());
-- No insert/update/delete policy for anyone: the SECURITY DEFINER trigger is the only writer.
revoke all on table public.customer_wallet_signals_v479 from public, anon, authenticated;
grant select on table public.customer_wallet_signals_v479 to authenticated;

create or replace function app.bump_customer_wallet_signal_v479()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
begin
  insert into public.customer_wallet_signals_v479(business_id, auth_user_id, client_id, bumped_at)
  select new.business_id, cl.auth_user_id, new.client_id, now()
    from public.customer_links cl
   where cl.business_id = new.business_id
     and cl.client_id   = new.client_id
     and cl.state = 'verified'
     and cl.auth_user_id is not null
  on conflict (business_id, auth_user_id)
  do update set bumped_at = now(), client_id = excluded.client_id;
  return null;
exception when others then
  -- A signal must NEVER break the ledger write. Proved in the dry run with the signals table
  -- dropped entirely: the ledger insert still succeeded. Do not "improve" this into a rethrow.
  return null;
end
$function$;

create trigger trg_points_ledger_signal_v479
  after insert on public.points_ledger
  for each row execute function app.bump_customer_wallet_signal_v479();

alter publication supabase_realtime add table public.customer_wallet_signals_v479;

commit;

-- NESTLY v757 - a reconciliation run carries its own provider label
--
-- public.billing_reconciliation_runs.provider defaults to 'stripe' and
-- public.start_billing_reconciliation_v77(p_run_mode, p_cursor_start) never set it, so every
-- run row says provider='stripe' even when it is a Razorpay reconciliation (the Razorpay
-- reconciler at supabase/functions/razorpay-billing-reconcile/index.ts calls it, and that run's
-- own summary jsonb says provider='razorpay') -- the row label contradicts its own summary.
-- v755 already relaxed billing_reconciliation_runs' provider check to
-- provider in ('stripe','razorpay'); this migration is the first writer to actually use that.
--
-- public.start_billing_reconciliation_v77 is left in place unmodified (dropping/replacing SQL
-- objects that other callers still reference breaks them silently); this migration adds a new,
-- explicitly provider-parameterised sibling and repoints the Razorpay reconciler at it.

begin;

create or replace function public.start_billing_reconciliation_v757(
  p_run_mode text,
  p_cursor_start text,
  p_provider text
)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_id uuid;
begin
  if p_run_mode not in ('dry_run','apply','scheduled') then
    raise exception 'invalid reconciliation mode' using errcode='22023';
  end if;
  if p_provider not in ('stripe','razorpay') then
    raise exception 'invalid reconciliation provider' using errcode='22023';
  end if;
  insert into public.billing_reconciliation_runs(run_mode,cursor_start,provider)
  values(p_run_mode,p_cursor_start,p_provider) returning id into v_id;
  return v_id;
end
$$;
revoke all on function public.start_billing_reconciliation_v757(text,text,text)
  from public,anon,authenticated;
grant execute on function public.start_billing_reconciliation_v757(text,text,text)
  to service_role;

-- ---------------------------------------------------------------------------
-- Backfill: existing rows the Razorpay reconciler already wrote through v77 (provider defaulted
-- to 'stripe') but whose own finish summary already says provider='razorpay'.
-- ---------------------------------------------------------------------------

do $v757_backfill$
declare
  v_count integer;
begin
  with corrected as (
    update public.billing_reconciliation_runs
       set provider = 'razorpay'
     where provider = 'stripe'
       and summary->>'provider' = 'razorpay'
    returning id
  )
  select count(*) into v_count from corrected;

  raise notice 'v757 relabelled % billing_reconciliation_runs row(s) stripe -> razorpay', v_count;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (
    null, null, 'RECONCILE_RUN_PROVIDER_BACKFILLED_V757', 'billing_reconciliation_runs', null,
    jsonb_build_object(
      'relabelled_count', v_count,
      'reason', 'provider defaulted to stripe on every run; rows whose own finish summary already named razorpay are corrected to match'
    )
  );
end
$v757_backfill$;

commit;

-- nestly_v760 — one Razorpay customer may span several businesses (2026-09-05).
--
-- LIVE TEST-MODE DEFECT. Razorpay keys a customer by contact details: the SAME `cust_...` id is
-- reused for every subscription created against a given phone/email. An owner who runs two
-- businesses on Peekaa therefore has ONE Razorpay customer id across both tenants. v77 modelled
-- the provider customer as globally unique (`provider_customer_id text not null unique`) and
-- apply_razorpay_billing_event_v755 enforced the same assumption in code, so the second
-- business's events all failed:
--
--   TY2VXwW6tgMOQQ (subscription.charged), TY2VYR2ZrWsqCC (subscription.activated),
--   TY2VYtsAzWEJCI (subscription.authenticated) for sub_TY2TBGS2P1WeKX, business Cafe2U,
--   livemode=false — every one rejected with 'Razorpay customer is already linked to another
--   business'. Nothing was mis-billed; the second tenant simply never became paid.
--
-- WHAT THIS MIGRATION DOES
--   1. Drops the GLOBAL unique constraint on billing_provider_customers.provider_customer_id
--      (found by shape in pg_constraint, not by a guessed name) and replaces it with a plain
--      lookup index on (provider, provider_customer_id). The `business_id` unique key stays: one
--      row per business is still the rule, and it is the row every reader addresses.
--   1b. Drops the SAME assumption where it is stated a second time: the partial unique index
--      public.subscriptions_provider_customer_uk on subscriptions.provider_customer_id, which
--      made two tenants on one Razorpay customer a duplicate-key error inside the applier even
--      after the projection table was freed. Replaced with a non-unique lookup index. The
--      subscription-level index (subscriptions_provider_subscription_uk) is KEPT: a Razorpay
--      subscription really does belong to exactly one business.
--   2. Patches public.apply_razorpay_billing_event_v755 IN PLACE by extract-and-diff, so that
--        (a) a customer id already used by ANOTHER business is allowed, and
--        (b) a business whose stored customer id differs from the incoming one is RELINKED to the
--            incoming id (Razorpay issues a fresh customer when contact details change), with an
--            audit_log row action 'PROVIDER_CUSTOMER_RELINKED_V760'.
--      The ON CONFLICT target moves from the dropped provider_customer_id key to business_id.
--   3. Adds public.redrive_razorpay_billing_events_v760 — the operator path that replays events
--      left in processing_status='failed' after a fix like this one. service_role only.
--
-- TENANT ISOLATION IS UNCHANGED. The guard that actually protects a tenant is the SUBSCRIPTION
-- guard immediately above the customer block ('Razorpay subscription is already linked to another
-- business'), and it is deliberately untouched: a subscription belongs to exactly one business,
-- and app.razorpay_business_v755 still derives the business from the event's own notes, never
-- from the customer id. A shared customer id was never used to authorise anything — it is a
-- contact record, not a tenant key. The Stripe applier keeps its own global-uniqueness guard;
-- Stripe does create one customer per checkout, so nothing there changes.
--
-- ESTATE SCAN (2026-09-05). Every function whose body mentions provider_customer_id was read.
-- Only two ever treated it as a KEY rather than a value:
--   * public.apply_stripe_billing_event_v94_base — its own 'Stripe customer is already linked to
--     another business' guard. Stripe-only; left in place deliberately.
--   * app.stripe_business_v77 — resolves a business FROM a Stripe customer id. Stripe-only, and
--     Stripe issues one customer per checkout, so it stays. No Razorpay path resolves a business
--     from a customer id: app.razorpay_business_v755 reads the event's own notes, then the
--     subscription mirrors, then the invoice mirrors — never the customer table.
-- The remaining readers (get_business_billing_v77, get_platform_billing_v77,
-- app.v89_platform_billing_rows, claim_billing_command_v77/_v124,
-- platform_get_subscription_operations_v156) only project the value into a response.
--
-- Rollback suite: db/tests/v760_shared_provider_customers.sql
-- Executed suite: db/tests/executed/v760_corpus_shared_provider_customers.sql
begin;

-- =============================================================================================
-- 1 · The provider customer id stops being globally unique.
-- =============================================================================================
do $v760_unique$
declare
  v_name text;
begin
  select con.conname into v_name
    from pg_catalog.pg_constraint con
   where con.conrelid = 'public.billing_provider_customers'::regclass
     and con.contype = 'u'
     and (
       select array_agg(att.attname::text order by att.attname::text)
         from unnest(con.conkey) as key(attnum)
         join pg_catalog.pg_attribute att
           on att.attrelid = con.conrelid and att.attnum = key.attnum
     ) = array['provider_customer_id'];

  if v_name is null then
    raise notice
      'v760: billing_provider_customers already has no global provider_customer_id unique key';
  else
    execute format(
      'alter table public.billing_provider_customers drop constraint %I', v_name
    );
  end if;
end
$v760_unique$;

/* Still one row per business — that key is what every reader and the new ON CONFLICT target use. */
do $v760_business_key$
begin
  if not exists (
    select 1
      from pg_catalog.pg_constraint con
     where con.conrelid = 'public.billing_provider_customers'::regclass
       and con.contype = 'u'
       and (
         select array_agg(att.attname::text order by att.attname::text)
           from unnest(con.conkey) as key(attnum)
           join pg_catalog.pg_attribute att
             on att.attrelid = con.conrelid and att.attnum = key.attnum
       ) = array['business_id']
  ) then
    raise exception
      'v760 requires the one-row-per-business unique key on billing_provider_customers'
      using errcode = '55000';
  end if;
end
$v760_business_key$;

create index if not exists billing_provider_customers_provider_customer_idx
  on public.billing_provider_customers (provider, provider_customer_id);

comment on index public.billing_provider_customers_provider_customer_idx is
  'v760: lookup only. Razorpay reuses one customer id per contact, so several businesses '
  'legitimately share one provider_customer_id; the tenant key is business_id.';

/* The same assumption, stated a second time on the tenant table itself (v77). The applier writes
   subscriptions.provider_customer_id, so leaving this index in place would move the failure from
   the projection table to a duplicate-key error one statement later. */
drop index if exists public.subscriptions_provider_customer_uk;

create index if not exists subscriptions_provider_customer_idx
  on public.subscriptions (provider_customer_id)
  where provider_customer_id is not null;

comment on index public.subscriptions_provider_customer_idx is
  'v760: lookup only — one Razorpay customer id may belong to several tenants. '
  'subscriptions_provider_subscription_uk still holds: a subscription has exactly one tenant.';

-- =============================================================================================
-- 2 · The applier stops treating a shared customer id as a tenant collision
--     (extract-and-diff against the LIVE body; name and signature preserved).
-- =============================================================================================
do $v760_applier$
declare
  v_definition text := pg_get_functiondef(
    'public.apply_razorpay_billing_event_v755(text)'::regprocedure
  );
  v_guard constant text :=
       E'        if exists(\n'
    || E'          select 1 from public.billing_provider_customers customer\n'
    || E'           where (customer.provider_customer_id=v_customer\n'
    || E'                  and customer.business_id<>v_business)\n'
    || E'              or (customer.business_id=v_business\n'
    || E'                  and customer.provider_customer_id<>v_customer)\n'
    || E'        ) then\n'
    || E'          raise exception ''Razorpay customer is already linked to another business'';\n'
    || E'        end if;\n';
  v_guard_replacement constant text :=
       E'        /* v760: Razorpay keys a customer by contact details, so one cust_... id is\n'
    || E'           reused across every business the same owner runs. A shared id is therefore\n'
    || E'           normal and is NOT a tenant collision — the subscription guard above is the\n'
    || E'           one that protects a tenant. What is worth recording is the other direction:\n'
    || E'           this business already had a DIFFERENT customer id and Razorpay has issued a\n'
    || E'           new one (contact details changed). We relink, and we say so. */\n'
    || E'        insert into public.audit_log(\n'
    || E'          business_id,actor,action,entity,entity_id,detail\n'
    || E'        )\n'
    || E'        select v_business,null,''PROVIDER_CUSTOMER_RELINKED_V760'',\n'
    || E'               ''billing_provider_customers'',customer.id,\n'
    || E'               jsonb_build_object(\n'
    || E'                 ''provider'',''razorpay'',\n'
    || E'                 ''previous_customer_id'',customer.provider_customer_id,\n'
    || E'                 ''customer_id'',v_customer,\n'
    || E'                 ''event_id'',v_event.event_id,\n'
    || E'                 ''event_type'',v_event.event_type\n'
    || E'               )\n'
    || E'          from public.billing_provider_customers customer\n'
    || E'         where customer.business_id=v_business\n'
    || E'           and customer.provider_customer_id<>v_customer\n'
    || E'           and (v_event.event_created_at,v_rank)\n'
    || E'               >= (customer.provider_event_created_at,customer.provider_event_rank);\n';
  v_conflict constant text :=
       E'        on conflict(provider_customer_id) do update\n'
    || E'          set currency=coalesce(excluded.currency,billing_provider_customers.currency),\n';
  v_conflict_replacement constant text :=
       E'        on conflict(business_id) do update\n'
    || E'          set provider_customer_id=excluded.provider_customer_id,\n'
    || E'              currency=coalesce(excluded.currency,billing_provider_customers.currency),\n';
  v_patched text;
  v_occurrences integer;
begin
  if position('PROVIDER_CUSTOMER_RELINKED_V760' in v_definition) > 0 then
    raise exception 'v760 applier patch has already been applied' using errcode = '55000';
  end if;

  v_occurrences := (length(v_definition) - length(replace(v_definition, v_guard, '')))
                   / length(v_guard);
  if v_occurrences <> 1 then
    raise exception
      'v760 expected exactly one shared-customer guard in apply_razorpay_billing_event_v755, found %',
      v_occurrences using errcode = '55000';
  end if;

  v_occurrences := (length(v_definition) - length(replace(v_definition, v_conflict, '')))
                   / length(v_conflict);
  if v_occurrences <> 1 then
    raise exception
      'v760 expected exactly one provider_customer_id conflict target in apply_razorpay_billing_event_v755, found %',
      v_occurrences using errcode = '55000';
  end if;

  v_patched := replace(v_definition, v_guard, v_guard_replacement);
  v_patched := replace(v_patched, v_conflict, v_conflict_replacement);
  execute v_patched;
end
$v760_applier$;

revoke all on function public.apply_razorpay_billing_event_v755(text)
  from public, anon, authenticated;
grant execute on function public.apply_razorpay_billing_event_v755(text) to service_role;

-- =============================================================================================
-- 3 · The operator path: replay the events a fix has just unblocked.
-- =============================================================================================
create or replace function public.redrive_razorpay_billing_events_v760(p_event_ids text[])
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_event_id text;
  v_row public.billing_provider_events%rowtype;
  v_apply jsonb;
  v_events jsonb := '[]'::jsonb;
  v_processed integer := 0;
  v_failed integer := 0;
  v_skipped integer := 0;
begin
  if p_event_ids is null or array_length(p_event_ids, 1) is null then
    raise exception 'at least one event id is required' using errcode = '22023';
  end if;
  if array_length(p_event_ids, 1) > 200 then
    raise exception 'redrive at most 200 events at a time' using errcode = '22023';
  end if;

  foreach v_event_id in array p_event_ids loop
    select * into v_row
      from public.billing_provider_events
     where provider = 'razorpay' and event_id = v_event_id;

    if not found then
      v_skipped := v_skipped + 1;
      v_events := v_events || jsonb_build_object('event_id', v_event_id, 'status', 'not_found');
    elsif v_row.processing_status <> 'failed' then
      /* Only a failed event is redriven. A processed or ignored one is left exactly as it is —
         this is a recovery tool, not a way to re-run billing side effects on demand. */
      v_skipped := v_skipped + 1;
      v_events := v_events || jsonb_build_object(
        'event_id', v_event_id, 'status', 'skipped',
        'processing_status', v_row.processing_status
      );
    else
      v_apply := public.apply_razorpay_billing_event_v755(v_event_id);
      if coalesce(v_apply->>'status', '') = 'failed' then
        v_failed := v_failed + 1;
      else
        v_processed := v_processed + 1;
      end if;
      v_events := v_events || jsonb_build_object(
        'event_id', v_event_id,
        'status', coalesce(v_apply->>'status', 'unknown'),
        'result', v_apply
      );
    end if;
  end loop;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (
    null, auth.uid(), 'RAZORPAY_EVENTS_REDRIVEN_V760', 'billing_provider_events', null,
    jsonb_build_object(
      'event_ids', to_jsonb(p_event_ids),
      'processed', v_processed, 'failed', v_failed, 'skipped', v_skipped
    )
  );

  return jsonb_build_object(
    'provider', 'razorpay',
    'requested', array_length(p_event_ids, 1),
    'processed', v_processed,
    'failed', v_failed,
    'skipped', v_skipped,
    'events', v_events
  );
end
$fn$;

comment on function public.redrive_razorpay_billing_events_v760(text[]) is
  'v760: operator replay of Razorpay billing events left in processing_status=failed. '
  'Service role only; never called by a browser.';

revoke all on function public.redrive_razorpay_billing_events_v760(text[])
  from public, anon, authenticated;
grant execute on function public.redrive_razorpay_billing_events_v760(text[]) to service_role;

commit;

-- NESTLY v81 — authenticated customer relationship synchronization and history.
--
-- This closes the direct-sign-in gap left by slug-led v31/C42 claims. A signed-in
-- customer may reconcile exact, confirmed Auth phone/email evidence across firms,
-- but only one unclaimed merchant client per firm is eligible. Ambiguous or
-- historically linked records remain untouched. Customer history stays scoped
-- through the verified v32 relationship resolver.

begin;

alter table public.customer_link_claim_attempts
  drop constraint customer_link_claim_attempts_operation_check,
  add constraint customer_link_claim_attempts_operation_check
    check (operation in (
      'email_claim', 'invitation_claim', 'phone_claim', 'relationship_sync'
    ));

alter table public.customer_link_audit_events
  drop constraint customer_link_audit_events_event_type_check,
  add constraint customer_link_audit_events_event_type_check check (event_type in (
    'email_claim_linked', 'email_claim_not_linked', 'email_claim_rate_limited',
    'phone_claim_linked', 'phone_claim_not_linked', 'phone_claim_rate_limited',
    'invitation_issued', 'invitation_claim_linked', 'invitation_claim_not_linked',
    'invitation_claim_rate_limited', 'link_unlinked', 'relationship_sync_linked'
  ));

create index if not exists clients_email_normalized_business_v81_idx
  on public.clients (lower(btrim(email)), business_id, id)
  where nullif(btrim(email), '') is not null;

create or replace function public.customer_sync_verified_relationships_v81(
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_auth_email text;
  v_email_confirmed_at timestamptz;
  v_auth_phone text;
  v_phone_confirmed_at timestamptz;
  v_phone_norm text;
  v_existing public.customer_link_claim_attempts%rowtype;
  v_match record;
  v_candidate_ids uuid[];
  v_candidate_count integer;
  v_client_id uuid;
  v_link_id uuid;
  v_method text;
  v_linked_count integer := 0;
  v_already_linked_count integer := 0;
  v_ambiguous_count integer := 0;
  v_request_hash text := app.v31_sha256_hex('v81.relationship-sync');
  v_response jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_claims') then
    raise exception 'customer access is unavailable' using errcode = '0A000';
  end if;
  v_identity := app.v31_current_identity();
  if p_idempotency_key is null
     or length(btrim(p_idempotency_key)) not between 8 and 160 then
    raise exception 'idempotency key must contain between 8 and 160 characters'
      using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);

  perform pg_advisory_xact_lock(hashtextextended(
    'v81:relationship-sync:' || v_identity::text || ':' || p_idempotency_key, 0
  ));
  select * into v_existing
    from public.customer_link_claim_attempts attempt
   where attempt.identity_id = v_identity
     and attempt.operation = 'relationship_sync'
     and attempt.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for another relationship sync'
        using errcode = '23505';
    end if;
    return v_existing.response;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v81:relationship-sync-rate:' || v_identity::text, 0
  ));
  if (
    select count(*)
      from public.customer_link_claim_attempts attempt
     where attempt.identity_id = v_identity
       and attempt.operation = 'relationship_sync'
       and attempt.outcome <> 'rate_limited'
       and attempt.created_at >= now() - interval '15 minutes'
  ) >= 20 then
    v_response := jsonb_build_object(
      'outcome', 'try_later',
      'linked_count', 0,
      'already_linked_count', 0,
      'ambiguous_count', 0,
      'matched_business_count', 0,
      'retry_after_seconds', 900
    );
    insert into public.customer_link_claim_attempts (
      identity_id, auth_user_id, operation, idempotency_key, request_hash,
      outcome, response
    ) values (
      v_identity, v_actor, 'relationship_sync', p_idempotency_key,
      v_request_hash, 'rate_limited', v_response
    );
    return v_response;
  end if;

  select
    lower(nullif(btrim(auth_user.email), '')),
    auth_user.email_confirmed_at,
    auth_user.phone,
    auth_user.phone_confirmed_at
    into v_auth_email, v_email_confirmed_at, v_auth_phone, v_phone_confirmed_at
    from auth.users auth_user
   where auth_user.id = v_actor
   for share;
  if not found then
    raise exception 'authenticated user no longer exists' using errcode = '28000';
  end if;
  if v_email_confirmed_at is null then
    v_auth_email := null;
  end if;
  if v_phone_confirmed_at is not null
     and app.platform_feature_enabled('customer_phone_claims')
     and app.platform_feature_enabled('customer_phone_registration') then
    v_phone_norm := app.norm_phone(v_auth_phone);
  end if;

  select count(*)::integer into v_already_linked_count
    from public.customer_links link
   where link.identity_id = v_identity
     and link.auth_user_id = v_actor
     and link.state = 'verified';

  for v_match in
    select matched.business_id
      from (
        select client.business_id
          from public.clients client
         where (
           (v_phone_norm is not null and client.phone_norm = v_phone_norm)
           or (
             v_auth_email is not null
             and nullif(btrim(client.email), '') is not null
             and lower(btrim(client.email)) = v_auth_email
           )
         )
           and not exists (
             select 1
               from public.customer_links prior
              where prior.client_id = client.id
           )
         group by client.business_id
      ) matched
     where not exists (
       select 1
         from public.customer_links current_link
        where current_link.business_id = matched.business_id
          and current_link.identity_id = v_identity
          and current_link.auth_user_id = v_actor
          and current_link.state = 'verified'
     )
     order by matched.business_id
  loop
    -- Serialize with both existing exact-email and exact-phone claim routes.
    perform pg_advisory_xact_lock(hashtextextended(
      'v31:business-link:' || v_match.business_id::text, 0
    ));
    perform pg_advisory_xact_lock(hashtextextended(
      'c42:phone-business-link:' || v_match.business_id::text, 0
    ));

    if exists (
      select 1
        from public.customer_links current_link
       where current_link.business_id = v_match.business_id
         and current_link.identity_id = v_identity
         and current_link.auth_user_id = v_actor
         and current_link.state = 'verified'
    ) then
      v_already_linked_count := v_already_linked_count + 1;
      continue;
    end if;

    select
      coalesce(array_agg(client.id order by client.id), '{}'::uuid[]),
      count(*)::integer
      into v_candidate_ids, v_candidate_count
      from public.clients client
     where client.business_id = v_match.business_id
       and (
         (v_phone_norm is not null and client.phone_norm = v_phone_norm)
         or (
           v_auth_email is not null
           and nullif(btrim(client.email), '') is not null
           and lower(btrim(client.email)) = v_auth_email
         )
       )
       and not exists (
         select 1
           from public.customer_links prior
          where prior.client_id = client.id
       );

    if v_candidate_count <> 1 then
      v_ambiguous_count := v_ambiguous_count + 1;
      continue;
    end if;

    v_client_id := v_candidate_ids[1];
    select case
      when v_phone_norm is not null and client.phone_norm = v_phone_norm
        then 'phone_claim'
      else 'email_claim'
    end
      into v_method
      from public.clients client
     where client.business_id = v_match.business_id
       and client.id = v_client_id;
    v_link_id := gen_random_uuid();

    begin
      perform set_config('app.customer_link_insert_id', v_link_id::text, true);
      insert into public.customer_links (
        id, business_id, identity_id, auth_user_id, client_id, state,
        verification_method, verified_at
      ) values (
        v_link_id, v_match.business_id, v_identity, v_actor, v_client_id,
        'verified', v_method, now()
      );
      perform set_config('app.customer_link_insert_id', '', true);

      insert into public.customer_link_audit_events (
        identity_id, actor_auth_user_id, business_id, client_id, link_id,
        event_type, idempotency_key, request_hash, response
      ) values (
        v_identity, v_actor, v_match.business_id, v_client_id, v_link_id,
        'relationship_sync_linked',
        p_idempotency_key || ':' || v_match.business_id::text,
        app.v31_sha256_hex(
          'v81.relationship-sync-link:' || v_match.business_id::text
        ),
        jsonb_build_object('outcome', 'linked')
      );
      v_linked_count := v_linked_count + 1;
    exception when unique_violation then
      perform set_config('app.customer_link_insert_id', '', true);
      if exists (
        select 1
          from public.customer_links current_link
         where current_link.business_id = v_match.business_id
           and current_link.identity_id = v_identity
           and current_link.auth_user_id = v_actor
           and current_link.state = 'verified'
      ) then
        v_already_linked_count := v_already_linked_count + 1;
      else
        v_ambiguous_count := v_ambiguous_count + 1;
      end if;
    end;
  end loop;

  v_response := jsonb_build_object(
    'outcome', 'synchronized',
    'linked_count', v_linked_count,
    'already_linked_count', v_already_linked_count,
    'ambiguous_count', v_ambiguous_count,
    'matched_business_count',
      v_linked_count + v_already_linked_count + v_ambiguous_count
  );
  insert into public.customer_link_claim_attempts (
    identity_id, auth_user_id, operation, idempotency_key, request_hash,
    outcome, response
  ) values (
    v_identity, v_actor, 'relationship_sync', p_idempotency_key, v_request_hash,
    case when v_linked_count + v_already_linked_count > 0
      then 'linked' else 'not_linked' end,
    v_response
  );
  return v_response;
end;
$$;

create or replace function public.customer_get_transaction_history_v81(
  p_business_slug text,
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_cursor jsonb := coalesce(p_cursor, '{}'::jsonb);
  v_limit integer := 20;
  v_before_at timestamptz;
  v_before_order integer;
  v_before_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if jsonb_typeof(v_cursor) <> 'object'
     or exists (
       select 1
         from jsonb_object_keys(v_cursor) as cursor_keys(key)
        where key not in ('limit', 'before_at', 'before_order', 'before_id')
     ) then
    raise exception 'invalid transaction history cursor' using errcode = '22023';
  end if;
  begin
    v_limit := least(greatest(coalesce((v_cursor->>'limit')::integer, 20), 1), 50);
    v_before_at := nullif(v_cursor->>'before_at', '')::timestamptz;
    v_before_order := nullif(v_cursor->>'before_order', '')::integer;
    v_before_id := nullif(v_cursor->>'before_id', '')::uuid;
  exception when others then
    raise exception 'invalid transaction history cursor' using errcode = '22023';
  end;
  if num_nonnulls(v_before_at, v_before_order, v_before_id) not in (0, 3)
     or (v_before_order is not null and v_before_order not in (1, 2)) then
    raise exception 'transaction history cursor is incomplete' using errcode = '22023';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  with sale_events as (
    select
      sale.id as source_id,
      sale.occurred_at as event_at,
      2 as event_order,
      'sale'::text as source_kind,
      case when sale.reversal_of is null then 'sale' else 'sale_reversal' end
        as event_type,
      case
        when sale.reversal_of is not null then 'reversal'
        when reversal.id is not null then 'reversed'
        else 'completed'
      end as status,
      branch.name as branch_name,
      sale.kind as sale_kind,
      sale.amount_cents::integer as gross_cents,
      case when sale.reversal_of is not null then 0
        else (sale.amount_cents + coalesce(reversal.amount_cents, 0))::integer
      end as net_cents,
      coalesce(points.points_earned, 0)::integer as points_earned,
      coalesce(points.points_redeemed, 0)::integer as points_redeemed,
      coalesce(points.points_removed, 0)::integer as points_removed,
      case when sale.reversal_of is not null then sale.reversal_of else reversal.id end
        as related_source_id,
      case sale.kind
        when 'quick_sale' then 'Purchase'
        when 'service' then 'Service purchase'
        when 'retail' then 'Retail purchase'
        when 'membership' then 'Membership purchase'
        else 'Purchase'
      end as description,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'item_id', item.id,
          'item_type', item.item_type,
          'description', item.description,
          'qty', item.qty,
          'unit_cents', item.unit_cents,
          'line_cents', item.line_cents
        ) order by item.created_at, item.id)
          from public.sale_items item
         where item.business_id = sale.business_id
           and item.sale_id = sale.id
      ), '[]'::jsonb) as line_items
      from public.sales sale
      left join public.branches branch
        on branch.business_id = sale.business_id
       and branch.id = sale.branch_id
      left join lateral (
        select reversal_sale.id, reversal_sale.amount_cents
          from public.sales reversal_sale
         where reversal_sale.business_id = sale.business_id
           and reversal_sale.reversal_of = sale.id
         order by reversal_sale.occurred_at desc, reversal_sale.id desc
         limit 1
      ) reversal on true
      left join lateral (
        select
          coalesce(sum(ledger.points) filter (where ledger.points > 0), 0)::integer
            as points_earned,
          abs(coalesce(sum(ledger.points) filter (
            where ledger.points < 0 and ledger.entry_type = 'redeem'
          ), 0))::integer as points_redeemed,
          abs(coalesce(sum(ledger.points) filter (
            where ledger.points < 0 and ledger.entry_type <> 'redeem'
          ), 0))::integer as points_removed
          from public.points_ledger ledger
         where ledger.business_id = sale.business_id
           and ledger.client_id = sale.client_id
           and ledger.sale_id = sale.id
      ) points on true
     where sale.business_id = v_context.business_id
       and sale.client_id = v_context.client_id
  ), standalone_point_events as (
    select
      ledger.id as source_id,
      ledger.created_at as event_at,
      1 as event_order,
      'points_ledger'::text as source_kind,
      'points_' || ledger.entry_type as event_type,
      'completed'::text as status,
      null::text as branch_name,
      null::text as sale_kind,
      null::integer as gross_cents,
      null::integer as net_cents,
      greatest(ledger.points, 0)::integer as points_earned,
      case when ledger.entry_type = 'redeem'
        then greatest(-ledger.points, 0) else 0 end::integer as points_redeemed,
      case when ledger.entry_type <> 'redeem'
        then greatest(-ledger.points, 0) else 0 end::integer as points_removed,
      null::uuid as related_source_id,
      case ledger.entry_type
        when 'earn' then 'Points earned'
        when 'redeem' then 'Points redeemed'
        when 'expire' then 'Points expired'
        when 'adjust' then 'Points adjustment'
        else 'Loyalty activity'
      end as description,
      '[]'::jsonb as line_items
      from public.points_ledger ledger
     where ledger.business_id = v_context.business_id
       and ledger.client_id = v_context.client_id
       and ledger.sale_id is null
  ), history as (
    select * from sale_events
    union all
    select * from standalone_point_events
  ), eligible as (
    select *
      from history
     where v_before_at is null
        or (event_at, event_order, source_id)
           < (v_before_at, v_before_order, v_before_id)
     order by event_at desc, event_order desc, source_id desc
     limit v_limit + 1
  ), visible as (
    select *
      from eligible
     order by event_at desc, event_order desc, source_id desc
     limit v_limit
  )
  select jsonb_build_object(
    'business', jsonb_build_object(
      'slug', v_context.business_slug,
      'name', v_context.business_name,
      'currency', v_context.business_currency
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'source_kind', source_kind,
        'source_id', source_id,
        'event_at', event_at,
        'event_type', event_type,
        'status', status,
        'branch_name', branch_name,
        'sale_kind', sale_kind,
        'gross_cents', gross_cents,
        'net_cents', net_cents,
        'points_earned', points_earned,
        'points_redeemed', points_redeemed,
        'points_removed', points_removed,
        'related_source_id', related_source_id,
        'description', description,
        'line_items', line_items
      ) order by event_at desc, event_order desc, source_id desc)
        from visible
    ), '[]'::jsonb),
    'next_cursor', case when (select count(*) from eligible) > v_limit then (
      select jsonb_build_object(
        'before_at', event_at,
        'before_order', event_order,
        'before_id', source_id,
        'limit', v_limit
      )
        from visible
       order by event_at, event_order, source_id
       limit 1
    ) else null end
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.customer_sync_verified_relationships_v81(text)
  from public, anon, authenticated;
revoke all on function public.customer_get_transaction_history_v81(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.customer_sync_verified_relationships_v81(text)
  to authenticated;
grant execute on function public.customer_get_transaction_history_v81(text, jsonb)
  to authenticated;

commit;

-- FRENLY v40 - BOUNDED STAFF REVERSAL WORKFLOW READ MODEL
-- Local review candidate. Mutations remain exclusively in v20/v34 reverse_sale and
-- reverse_loyalty_redemption. This RPC exposes only the evidence required to render a
-- permission- and branch-aware staff workflow; raw provenance tables remain closed.

begin;

-- v34 package reversals treated the user-visible reference as presentation text, not part
-- of the immutable request hash. Put a locked public boundary around the existing engine so
-- an exact retry succeeds but changing that explicit reference conflicts like v20 sales.
alter function public.reverse_sale(uuid,uuid,text,text,text,text)
  rename to reverse_sale_v34_base;
revoke all privileges on function public.reverse_sale_v34_base(uuid,uuid,text,text,text,text)
  from public, anon, authenticated;

create or replace function public.reverse_sale(
  p_business uuid,
  p_sale uuid,
  p_reason text,
  p_idempotency_key text,
  p_reference text default null,
  p_restock_policy text default 'none'
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_sale public.sales%rowtype;
  v_existing public.package_session_reversals%rowtype;
  v_reversal_note text;
  v_expected_note text;
begin
  if v_actor is null or not app.has_perm(p_business, 'refund_sales') then
    raise exception 'refund_sales permission required' using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'refund_sales' = any(app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end,
            s.created_at, s.id
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization required' using errcode = '42501';
  end if;
  select * into v_sale from public.sales
   where id = p_sale and business_id = p_business
   for update;
  if not found then raise exception 'sale not found in this business' using errcode = '42501'; end if;
  if not app.has_perm(p_business, 'refund_sales')
     or not app.can_see_branch(p_business, v_sale.branch_id) then
    raise exception 'sale reversal authorization changed while locking' using errcode = '42501';
  end if;

  if v_sale.amount_cents = 0 then
    select pr.* into v_existing
      from public.package_session_consumptions pc
      join public.package_session_reversals pr
        on pr.business_id = pc.business_id and pr.consumption_id = pc.id
      join public.sales r
        on r.business_id = pr.business_id and r.id = pr.reversal_sale_id
     where pc.business_id = p_business and pc.sale_id = p_sale;
    if found then
      select r.note into v_reversal_note
        from public.sales r
       where r.business_id = v_existing.business_id
         and r.id = v_existing.reversal_sale_id;
    end if;
    if v_existing.id is not null and v_existing.idempotency_key = btrim(p_idempotency_key) then
      v_expected_note := coalesce(nullif(btrim(p_reference), ''), 'package session reversal')
        || ': ' || left(btrim(p_reason), 200);
      if v_reversal_note is distinct from v_expected_note then
        raise exception 'package reversal idempotency key conflicts with a changed reference'
          using errcode = '23505';
      end if;
    end if;
  end if;
  return public.reverse_sale_v34_base(
    p_business,p_sale,p_reason,p_idempotency_key,p_reference,p_restock_policy
  );
end $$;

revoke all privileges on function public.reverse_sale(uuid,uuid,text,text,text,text)
  from public, anon, authenticated;
grant execute on function public.reverse_sale(uuid,uuid,text,text,text,text)
  to authenticated;

-- v34 proved exact compensation but did not bind the redemption's immutable selected
-- branch to the caller. Keep that implementation internal and put the missing branch
-- authorization at the public mutation boundary. A NULL selected branch is intentionally
-- admin-only under app.can_see_branch(), matching every other v20/v34 branch decision.
alter function public.reverse_loyalty_redemption(uuid,uuid,text,text)
  rename to reverse_loyalty_redemption_v34_base;
revoke all privileges on function public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)
  from public, anon, authenticated;

create or replace function public.reverse_loyalty_redemption(
  p_business uuid,
  p_redemption uuid,
  p_reason text,
  p_idempotency_key text
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_branch uuid;
  v_staff uuid;
  v_role text;
  v_redemption public.loyalty_redemptions%rowtype;
  v_existing public.loyalty_redemption_reversals%rowtype;
  v_provenance public.loyalty_redemption_provenance%rowtype;
  v_source_credit public.credit_ledger%rowtype;
begin
  if v_actor is null or not app.has_perm(p_business, 'refund_sales') then
    raise exception 'refund_sales permission required' using errcode = '42501';
  end if;
  select s.id,s.role into v_staff,v_role
    from public.staff s
     where s.business_id = p_business
       and s.user_id = v_actor
       and s.active
       and 'refund_sales' = any(app.role_perms(s.role))
     order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end,
              s.created_at, s.id
     limit 1
     for update;
  if not found then
    raise exception 'active staff authorization required' using errcode = '42501';
  end if;
  select nullif(lr.eligibility_snapshot #>> '{selected,branch_id}', '')::uuid
    into v_branch
    from public.loyalty_redemptions lr
   where lr.id = p_redemption and lr.business_id = p_business;
  if not found then
    raise exception 'loyalty redemption not found in this business' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'redemption branch scope is not permitted' using errcode = '42501';
  end if;

  -- Owner/admin roles are firm-wide. A future refund-authorized employee must retain the
  -- exact assignment through the final authorization check; locking the assignment after
  -- staff and before the economic rows matches the branch-management lock hierarchy.
  if app.role_class(v_role) not in ('owner','admin') then
    perform 1 from public.staff_branches sb
     where sb.business_id=p_business and sb.staff_id=v_staff and sb.branch_id=v_branch
     for share;
    if not found then
      raise exception 'redemption branch assignment is not permitted' using errcode='42501';
    end if;
  end if;

  -- Staff -> optional assignment -> redemption -> client is the stable order. The client
  -- row is the same balance-serialization point record_credit_tender locks before reading
  -- or appending credit_ledger, so a tender and this compensation cannot both win.
  select lr.* into v_redemption
    from public.loyalty_redemptions lr
   where lr.id = p_redemption and lr.business_id = p_business
   for update;
  v_branch:=nullif(v_redemption.eligibility_snapshot #>> '{selected,branch_id}', '')::uuid;
  if not found
     or not app.has_perm(p_business, 'refund_sales')
     or not app.can_see_branch(p_business, v_branch) then
    raise exception 'redemption reversal authorization changed while locking'
      using errcode = '42501';
  end if;
  perform 1 from public.clients c
   where c.id=v_redemption.client_id and c.business_id=p_business
   for update;
  if not found then
    raise exception 'redemption client does not belong to this business' using errcode='42501';
  end if;

  -- A completed compensation necessarily contains its own negative credit row. Hand an
  -- already-reversed request back to the immutable v34 replay/conflict decision before
  -- applying the pre-compensation spent-credit test.
  select * into v_existing from public.loyalty_redemption_reversals rr
   where rr.business_id=p_business and rr.redemption_id=p_redemption;
  if found then
    return public.reverse_loyalty_redemption_v34_base(
      p_business, p_redemption, p_reason, p_idempotency_key
    );
  end if;

  select * into v_provenance from public.loyalty_redemption_provenance p
   where p.business_id=p_business and p.redemption_id=p_redemption
     and p.client_id=v_redemption.client_id;
  if not found or v_provenance.config_version_id is distinct from v_redemption.config_version_id then
    raise exception 'redemption exact provenance is missing or inconsistent';
  end if;
  if v_redemption.credit_cents>0 then
    if v_provenance.credit_ledger_id is null then
      raise exception 'original loyalty credit provenance is missing';
    end if;
    select * into v_source_credit from public.credit_ledger cl
     where cl.id=v_provenance.credit_ledger_id
       and cl.business_id=p_business
       and cl.client_id=v_redemption.client_id
       and cl.entry_type='loyalty_earn'
       and cl.amount_cents=v_redemption.credit_cents
       and cl.config_version_id=v_redemption.config_version_id;
    if not found then
      raise exception 'original loyalty credit provenance does not match the redemption';
    end if;
    if exists (
      select 1 from public.credit_ledger spend
       where spend.business_id=p_business and spend.client_id=v_redemption.client_id
         and spend.amount_cents<0 and spend.created_at>=v_source_credit.created_at
    ) then
      raise exception 'reward credit may have been spent; exact source credit is no longer reversible';
    end if;
  end if;
  if not app.has_perm(p_business,'refund_sales')
     or not app.can_see_branch(p_business,v_branch) then
    raise exception 'redemption reversal authorization changed after balance lock'
      using errcode='42501';
  end if;
  return public.reverse_loyalty_redemption_v34_base(
    p_business, p_redemption, p_reason, p_idempotency_key
  );
end $$;

revoke all privileges on function public.reverse_loyalty_redemption(uuid,uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.reverse_loyalty_redemption(uuid,uuid,text,text)
  to authenticated;

create or replace function public.staff_get_reversal_workflows(
  p_business uuid,
  p_client uuid default null,
  p_limit integer default 50,
  p_mode text default 'all'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_role text;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_mode text := lower(coalesce(nullif(btrim(p_mode), ''), 'all'));
  v_sales_total bigint := 0;
  v_sales jsonb := '[]'::jsonb;
  v_redemptions jsonb := '[]'::jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if v_mode not in ('all','package') then
    raise exception 'unsupported reversal workflow mode %', p_mode using errcode = '22023';
  end if;
  if not app.has_perm(p_business, 'refund_sales') then
    raise exception 'refund_sales permission required' using errcode = '42501';
  end if;
  select s.id, s.role into v_staff, v_role
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'refund_sales' = any(app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end,
            s.created_at, s.id
   limit 1;
  if not found then
    raise exception 'active staff authorization required' using errcode = '42501';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients c
     where c.id = p_client and c.business_id = p_business
  ) then
    raise exception 'customer not found in this business' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(x.item order by x.occurred_at desc, x.id desc), '[]'::jsonb),
         coalesce(max(x.total_count), 0)
    into v_sales, v_sales_total
    from (
      select s.id, s.occurred_at, count(*) over() as total_count,
             jsonb_build_object(
               'id', s.id,
               'client_id', s.client_id,
               'customer_name', c.full_name,
               'branch_id', s.branch_id,
               'kind', s.kind,
               'amount_cents', s.amount_cents,
               'net_amount_cents', case
                 when s.reversal_of is null then s.amount_cents + coalesce(rev.amount_cents, 0)
                 else coalesce(original.amount_cents, 0) + s.amount_cents
               end,
               'occurred_at', s.occurred_at,
               'note', s.note,
               'is_reversal', s.reversal_of is not null,
               'original_sale_id', s.reversal_of,
               'reversal_sale_id', case when s.reversal_of is null then rev.id else s.id end,
               'reversal_reason', coalesce(rev.reversal_reason, s.reversal_reason),
               'reversed_at', coalesce(rev.occurred_at,
                 case when s.reversal_of is not null then s.occurred_at end),
               'is_package_session', pkg.consumption_id is not null,
               'no_money_refund', pkg.consumption_id is not null,
               'can_reverse', s.reversal_of is null and rev.id is null and (
                 (s.amount_cents > 0 and s.kind in ('service', 'retail', 'quick_sale'))
                 or (s.amount_cents = 0 and pkg.consumption_id is not null)
               ),
               'refusal_reason', case
                 when s.reversal_of is not null then 'This row is already a reversal.'
                 when rev.id is not null then 'This sale is already fully reversed.'
                 when s.amount_cents = 0 and pkg.consumption_id is null then 'This zero-value sale has no package-session provenance.'
                 when s.amount_cents <= 0 then 'This sale has no positive economic amount to reverse.'
                 when s.kind not in ('service', 'retail', 'quick_sale') then 'This sale type has no proven reversal path.'
                 else null
               end,
               'completed_result', coalesce(
                 fin.result,
                 case when pkg.reversal_sale_id is not null then jsonb_build_object(
                   'reversal_sale_id', pkg.reversal_sale_id,
                   'restored_sessions', 1,
                   'refunded_payment_cents', 0,
                   'no_money_refund', true,
                   'replayed', false
                 ) end
               )
             ) as item
        from public.sales s
        left join public.clients c
          on c.id = s.client_id and c.business_id = s.business_id
        left join public.sales original
          on original.id = s.reversal_of and original.business_id = s.business_id
        left join lateral (
          select r.id, r.amount_cents, r.occurred_at, r.reversal_reason
            from public.sales r
           where r.business_id = s.business_id and r.reversal_of = s.id
           order by r.occurred_at, r.id limit 1
        ) rev on true
        left join lateral (
          select jsonb_strip_nulls(jsonb_build_object(
            'reversal_sale_id',fo.result->'reversal_sale_id',
            'reversed_cents',fo.result->'reversed_cents',
            'refunded_payment_cents',fo.result->'refunded_payment_cents',
            'replayed',coalesce(fo.result->'replayed','false'::jsonb)
          )) as result
            from public.financial_operations fo
           where fo.business_id = s.business_id
             and fo.sale_id = s.id
             and fo.operation_type = 'sale_reversal'
             and fo.status = 'completed'
           order by fo.completed_at desc, fo.id desc limit 1
        ) fin on true
        left join lateral (
          select pc.id as consumption_id, pr.reversal_sale_id
            from public.package_session_consumptions pc
            left join public.package_session_reversals pr
              on pr.business_id = pc.business_id and pr.consumption_id = pc.id
           where pc.business_id = s.business_id
             and pc.sale_id = coalesce(s.reversal_of, s.id)
           limit 1
        ) pkg on true
       where s.business_id = p_business
         and (p_client is null or s.client_id = p_client)
         and app.can_see_branch(p_business, s.branch_id)
         and (v_mode = 'all' or pkg.consumption_id is not null)
       order by s.occurred_at desc, s.id desc
       limit v_limit
    ) x;

  select coalesce(jsonb_agg(x.item order by x.redeemed_at desc, x.id desc), '[]'::jsonb)
    into v_redemptions
    from (
      select lr.id, lr.redeemed_at,
             jsonb_build_object(
               'id', lr.id,
               'client_id', lr.client_id,
               'customer_name', c.full_name,
               'branch_id', scope.branch_id,
               'reward_name', lr.reward_name,
               'points_spent', lr.points_spent,
               'credit_cents', lr.credit_cents,
               'fulfillment_kind', lr.fulfillment_kind,
               'redeemed_at', lr.redeemed_at,
               'reversal_id', rr.id,
               'reversed_at', rr.created_at,
               'completed_result', rr.result,
               'has_exact_provenance', prov.id is not null
                 and prov.config_version_id is not distinct from lr.config_version_id
                 and coalesce(drains.drained_points, 0) = lr.points_spent
                 and points_ok.proven
                 and credit_state.proven,
               'credit_may_be_spent', coalesce(credit_state.may_be_spent, false),
               'can_reverse', rr.id is null
                 and prov.id is not null
                 and prov.config_version_id is not distinct from lr.config_version_id
                 and coalesce(drains.drained_points, 0) = lr.points_spent
                 and points_ok.proven
                 and credit_state.proven
                 and not coalesce(credit_state.may_be_spent, false),
               'refusal_reason', case
                 when rr.id is not null then 'This redemption is already reversed.'
                 when prov.id is null then 'Legacy or incomplete redemption provenance cannot be reversed safely.'
                 when prov.config_version_id is distinct from lr.config_version_id then 'Configuration provenance is inconsistent.'
                 when not coalesce(points_ok.proven, false) then 'Original points-ledger provenance is incomplete.'
                 when coalesce(drains.drained_points, 0) <> lr.points_spent then 'FEFO batch-drain provenance does not reconcile.'
                 when not coalesce(credit_state.proven, false) then 'Original loyalty credit provenance is missing or does not match.'
                 when coalesce(credit_state.may_be_spent, false) then 'Reward credit may have been spent; exact compensation is refused.'
                 else null
               end
             ) as item
        from public.loyalty_redemptions lr
        join public.clients c
          on c.id = lr.client_id and c.business_id = lr.business_id
        left join public.loyalty_redemption_provenance prov
          on prov.business_id = lr.business_id and prov.redemption_id = lr.id
        left join public.loyalty_redemption_reversals rr
          on rr.business_id = lr.business_id and rr.redemption_id = lr.id
        left join lateral (
          select nullif(lr.eligibility_snapshot #>> '{selected,branch_id}', '')::uuid as branch_id
        ) scope on true
        left join lateral (
          select coalesce(sum(d.drained_points), 0)::integer as drained_points
            from public.loyalty_redemption_batch_drains d
           where d.business_id = lr.business_id and d.redemption_id = lr.id
        ) drains on true
        left join lateral (
          select exists (
            select 1 from public.points_ledger pl
             where pl.id = prov.points_ledger_id
               and pl.business_id = lr.business_id
               and pl.client_id = lr.client_id
               and pl.points = -lr.points_spent
               and pl.config_version_id = lr.config_version_id
          ) as proven
        ) points_ok on true
        left join lateral (
          select
            case when lr.credit_cents<=0 then true else exists (
              select 1 from public.credit_ledger source
               where source.id=prov.credit_ledger_id
                 and source.business_id=lr.business_id
                 and source.client_id=lr.client_id
                 and source.entry_type='loyalty_earn'
                 and source.amount_cents=lr.credit_cents
                 and source.config_version_id=lr.config_version_id
            ) end as proven,
            case when lr.credit_cents<=0 then false else exists (
              select 1
                from public.credit_ledger source
                join public.credit_ledger spend
                  on spend.business_id=source.business_id
                 and spend.client_id=source.client_id
                 and spend.amount_cents<0
                 and spend.created_at>=source.created_at
                 and spend.id is distinct from rr.reversed_credit_ledger_id
               where source.id=prov.credit_ledger_id
                 and source.business_id=lr.business_id
                 and source.client_id=lr.client_id
                 and source.entry_type='loyalty_earn'
                 and source.amount_cents=lr.credit_cents
                 and source.config_version_id=lr.config_version_id
            ) end as may_be_spent
        ) credit_state on true
       where v_mode = 'all'
         and lr.business_id = p_business
         and (p_client is null or lr.client_id = p_client)
         and app.can_see_branch(p_business, scope.branch_id)
       order by lr.redeemed_at desc, lr.id desc
       limit v_limit
    ) x;

  return jsonb_build_object(
    'can_reverse', true,
    'actor_role', v_role,
    'mode', v_mode,
    'limit', v_limit,
    'bounded', true,
    'total_sales', v_sales_total,
    'may_have_more', v_sales_total > v_limit,
    'sales', v_sales,
    'redemptions', v_redemptions
  );
end $$;

revoke all privileges on function public.staff_get_reversal_workflows(uuid,uuid,integer,text)
  from public, anon;
grant execute on function public.staff_get_reversal_workflows(uuid,uuid,integer,text)
  to authenticated;

commit;

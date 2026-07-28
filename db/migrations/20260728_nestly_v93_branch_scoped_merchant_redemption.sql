-- NESTLY v93 — branch-scoped merchant QR redemption.
--
-- v89 introduced a safe pending-intent -> merchant-scan boundary, but its scan
-- contract did not carry the active till branch into the canonical reward
-- writer. Owners appeared to work because their visibility is firm-wide;
-- branch-scoped front-desk staff were correctly refused by redeem_reward_core.
-- This version makes the branch explicit and records it in the immutable
-- redemption eligibility snapshot.

begin;

create or replace function public.merchant_scan_redemption_qr_v93(
  p_business uuid,
  p_branch uuid,
  p_qr_token text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_intent public.customer_redemption_intents_v89%rowtype;
  v_result jsonb;
  v_redemption uuid;
  v_operation uuid;
  v_operation_type text;
  v_program public.loyalty_programs%rowtype;
  v_reward_version public.loyalty_reward_versions%rowtype;
  v_current_quote jsonb;
  v_customer_name text;
  v_reward_label text;
begin
  if p_idempotency_key is null or length(coalesce(p_qr_token,''))<32 then
    raise exception 'invalid redemption QR scan' using errcode='22023';
  end if;
  if not app.can_module_write(p_business,'loyalty')
     or not app.has_perm(p_business,'create_sales') then
    raise exception 'merchant loyalty redemption access is required'
      using errcode='42501';
  end if;
  if p_branch is null
     or not exists(
       select 1
       from public.branches branch
       where branch.id=p_branch
         and branch.business_id=p_business
         and branch.active
     ) then
    raise exception 'an active business branch is required'
      using errcode='22023';
  end if;
  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'redemption branch scope is not permitted'
      using errcode='42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v93:scan:'||p_business::text||':'||app.v89_sha256(p_qr_token),0));
  select *
    into v_intent
    from public.customer_redemption_intents_v89 intent
   where intent.business_id=p_business
     and intent.token_hash=app.v89_sha256(p_qr_token)
   for update;
  if not found then
    raise exception 'redemption QR is invalid' using errcode='22023';
  end if;

  if v_intent.status='completed' then
    insert into public.customer_redemption_events_v89(
      intent_id,business_id,actor,event_type,idempotency_key,detail
    ) values(
      v_intent.id,p_business,auth.uid(),'scan_replayed',p_idempotency_key,
      jsonb_build_object(
        'redemption_kind',v_intent.redemption_kind,
        'redemption_id',v_intent.redemption_id,
        'operation_id',v_intent.completion_operation_id,
        'branch_id',p_branch
      )
    )
    on conflict(intent_id,event_type,idempotency_key) do nothing;
    return v_intent.completion_result||jsonb_build_object('replayed',true);
  end if;
  if v_intent.status<>'pending' then
    raise exception 'redemption QR is no longer pending' using errcode='22023';
  end if;
  if v_intent.expires_at<=now() then
    perform set_config('app.v89_redemption_intent_id',v_intent.id::text,true);
    update public.customer_redemption_intents_v89
       set status='expired'
     where id=v_intent.id;
    perform set_config('app.v89_redemption_intent_id','',true);
    insert into public.customer_redemption_events_v89(
      intent_id,business_id,actor,event_type,idempotency_key,detail
    ) values(
      v_intent.id,p_business,auth.uid(),'intent_expired',p_idempotency_key,
      jsonb_build_object('expired_at',v_intent.expires_at,'branch_id',p_branch)
    );
    return jsonb_build_object(
      'intent_id',v_intent.id,
      'status','expired',
      'expires_at',v_intent.expires_at,
      'branch_id',p_branch,
      'replayed',false
    );
  end if;
  if not app.platform_feature_enabled('customer_qr_redemption')
     or not coalesce((
       select capability.redemption_enabled
         from public.business_customer_capabilities_v89 capability
        where capability.business_id=p_business
     ),false)
     or not app.v89_business_module_enabled(p_business,'loyalty') then
    raise exception 'customer redemption is disabled for this business'
      using errcode='42501';
  end if;

  select *
    into v_program
    from public.loyalty_programs program
   where program.id=v_intent.quoted_program_id
     and program.business_id=p_business
     and program.active
   for share;
  if not found then
    raise exception 'redemption configuration changed; create a new QR'
      using errcode='23514';
  end if;
  select client.full_name
    into v_customer_name
    from public.clients client
   where client.id=v_intent.client_id
     and client.business_id=p_business;

  if v_intent.redemption_kind='classic_points' then
    v_current_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_program.current_config_version_id,
      'loyalty_model',v_program.loyalty_model,
      'kind',v_program.kind,
      'points_spent',v_program.redeem_points,
      'credit_cents',v_program.reward_credit_cents
    );
    if v_current_quote is distinct from v_intent.quoted_terms then
      raise exception 'classic redemption terms changed; create a new QR'
        using errcode='23514';
    end if;
    v_reward_label:='Store credit';
    v_operation_type:='redeem_points';
    -- Classic redemption has no branch-aware economic writer. Branch
    -- authorization is therefore locked and proven above, and the selected
    -- branch is included in the immutable merchant workflow receipt/events.
    v_result:=public.redeem_points(
      p_business,v_intent.client_id,'v93:'||v_intent.id::text
    )::jsonb;
  else
    select reward_version.*
      into v_reward_version
      from public.loyalty_reward_versions reward_version
      join public.businesses business
        on business.id=reward_version.business_id
     where reward_version.id=v_intent.quoted_reward_version_id
       and reward_version.reward_id=v_intent.reward_id
       and reward_version.business_id=p_business
       and reward_version.config_version_id=business.active_config_version_id
       and reward_version.active
     for share;
    if not found
       or exists(
         select 1
           from public.loyalty_reward_services restriction
          where restriction.reward_version_id=v_intent.quoted_reward_version_id
       )
       or exists(
         select 1
           from public.loyalty_reward_products restriction
          where restriction.reward_version_id=v_intent.quoted_reward_version_id
       ) then
      raise exception 'catalog redemption terms changed; create a new QR'
        using errcode='23514';
    end if;
    if exists(
      select 1
        from public.loyalty_reward_branches restriction
       where restriction.reward_version_id=v_intent.quoted_reward_version_id
    ) and not exists(
      select 1
        from public.loyalty_reward_branches restriction
       where restriction.reward_version_id=v_intent.quoted_reward_version_id
         and restriction.branch_id=p_branch
    ) then
      raise exception 'reward is not eligible at this branch'
        using errcode='23514';
    end if;
    v_current_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_reward_version.config_version_id,
      'reward_version_id',v_reward_version.id,
      'reward_id',v_intent.reward_id,
      'points_spent',v_reward_version.cost_points,
      'credit_cents',v_reward_version.credit_cents,
      'fulfillment_kind',v_reward_version.fulfillment_kind,
      'claim_available_from',v_reward_version.claim_available_from,
      'claim_available_until',v_reward_version.claim_available_until,
      'usage_limit',v_reward_version.usage_limit,
      'active',v_reward_version.active
    );
    if v_current_quote is distinct from v_intent.quoted_terms then
      raise exception 'catalog redemption terms changed; create a new QR'
        using errcode='23514';
    end if;
    v_reward_label:=coalesce(v_reward_version.customer_name,'Reward');
    v_operation_type:='redeem_reward';
    v_result:=public.redeem_reward_at_context(
      p_business,
      v_intent.client_id,
      v_intent.reward_id,
      'v93:'||v_intent.id::text,
      p_branch,
      null,
      null
    )::jsonb;
  end if;

  select operation.id
    into v_operation
    from public.loyalty_operations operation
   where operation.business_id=p_business
     and operation.operation_type=v_operation_type
     and operation.idempotency_key='v93:'||v_intent.id::text
     and operation.status='completed';
  if not found then
    raise exception 'canonical redemption operation was not recorded'
      using errcode='40001';
  end if;
  if v_intent.redemption_kind='catalog_reward' then
    select provenance.redemption_id
      into v_redemption
      from public.loyalty_redemption_provenance provenance
     where provenance.business_id=p_business
       and provenance.operation_id=v_operation;
    if not found then
      raise exception 'canonical catalog redemption was not recorded'
        using errcode='40001';
    end if;
  end if;

  v_result:=jsonb_build_object(
    'intent_id',v_intent.id,
    'status','completed',
    'redemption_kind',v_intent.redemption_kind,
    'completed_at',now(),
    'branch_id',p_branch,
    'operation_id',v_operation,
    'redemption_id',v_redemption,
    'customer_name',v_customer_name,
    'reward_label',v_reward_label,
    'points_spent',v_intent.quoted_points_spent,
    'credit_cents',v_intent.quoted_credit_cents,
    'result',v_result,
    'replayed',false
  );
  perform set_config('app.v89_redemption_intent_id',v_intent.id::text,true);
  update public.customer_redemption_intents_v89
     set status='completed',
         completed_at=now(),
         completed_by=auth.uid(),
         completion_idempotency_key=p_idempotency_key,
         redemption_id=v_redemption,
         completion_operation_id=v_operation,
         completion_result=v_result
   where id=v_intent.id;
  perform set_config('app.v89_redemption_intent_id','',true);
  insert into public.customer_redemption_events_v89(
    intent_id,business_id,actor,event_type,idempotency_key,detail
  ) values(
    v_intent.id,p_business,auth.uid(),'scan_completed',p_idempotency_key,
    jsonb_build_object(
      'redemption_kind',v_intent.redemption_kind,
      'redemption_id',v_redemption,
      'operation_id',v_operation,
      'branch_id',p_branch
    )
  );
  return v_result;
end
$$;

comment on function public.merchant_scan_redemption_qr_v93(uuid,uuid,text,uuid)
  is 'Branch-scoped, replay-safe merchant completion of a customer QR redemption through canonical loyalty writers.';

-- v89 cannot remain callable by browser identities after v93 ships. Its
-- signature has no branch argument, so leaving the old grant in place would
-- let a caller downgrade to branchless fulfilment and omit branch provenance.
revoke execute on function public.merchant_scan_redemption_qr_v89(
  uuid,text,uuid
) from public,anon,authenticated;

revoke all on function public.merchant_scan_redemption_qr_v93(
  uuid,uuid,text,uuid
) from public,anon,authenticated;
grant execute on function public.merchant_scan_redemption_qr_v93(
  uuid,uuid,text,uuid
) to authenticated;

commit;

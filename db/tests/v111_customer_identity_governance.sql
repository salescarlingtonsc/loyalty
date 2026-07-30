-- Rollback-only v111 identity correction, proof, decision and reversal evidence.
-- Run after the canonical chain through v111 in a disposable PostgreSQL database.
begin;

do $contract$
declare
  v_table text;
begin
  if to_regprocedure(
    'public.propose_customer_identity_correction_v111(uuid,uuid,uuid,uuid,text,uuid)'
  ) is null or to_regprocedure(
    'public.attach_customer_identity_proof_v111(uuid,text,jsonb,uuid)'
  ) is null or to_regprocedure(
    'public.approve_customer_identity_correction_v111(uuid,uuid)'
  ) is null or to_regprocedure(
    'public.reject_customer_identity_correction_v111(uuid,text,uuid)'
  ) is null or to_regprocedure(
    'public.reverse_customer_identity_correction_v111(uuid,text,uuid)'
  ) is null or to_regprocedure(
    'public.get_customer_identity_proposal_v111(uuid)'
  ) is null or to_regprocedure(
    'public.get_customer_identity_coverage_v111(uuid,uuid)'
  ) is null then
    raise exception 'v111 public RPC contract is incomplete';
  end if;

  foreach v_table in array array[
    'customer_identity_proposals_v111',
    'customer_identity_proofs_v111',
    'customer_identity_decisions_v111',
    'customer_identity_attribution_events_v111',
    'customer_identity_request_ledger_v111'
  ] loop
    if not exists(
      select 1
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=v_table and c.relrowsecurity
    ) then
      raise exception 'v111 table % does not enforce RLS',v_table;
    end if;
    if has_table_privilege('authenticated','public.'||v_table,'INSERT')
       or has_table_privilege('authenticated','public.'||v_table,'UPDATE')
       or has_table_privilege('authenticated','public.'||v_table,'DELETE') then
      raise exception 'authenticated has a direct mutation grant on %',v_table;
    end if;
  end loop;

  if has_function_privilege(
       'anon',
       'public.approve_customer_identity_correction_v111(uuid,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.approve_customer_identity_correction_v111(uuid,uuid)',
       'EXECUTE'
     ) then
    raise exception 'v111 RPC grants are not fail-closed';
  end if;
end
$contract$;

create or replace function pg_temp.v111_actor(p_actor uuid)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub',p_actor,'role','authenticated')::text,
    true
  );
end
$$;

do $runtime$
declare
  v_owner uuid:=gen_random_uuid();
  v_staff_user uuid:=gen_random_uuid();
  v_other_owner uuid:=gen_random_uuid();
  v_target_user uuid:=gen_random_uuid();
  v_other_target_user uuid:=gen_random_uuid();
  v_chain_target_user uuid:=gen_random_uuid();
  v_cycle_target_user uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_other_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_other_branch uuid:=gen_random_uuid();
  v_owner_staff uuid:=gen_random_uuid();
  v_staff uuid:=gen_random_uuid();
  v_other_owner_staff uuid:=gen_random_uuid();
  v_source uuid:=gen_random_uuid();
  v_target uuid:=gen_random_uuid();
  v_reject_source uuid:=gen_random_uuid();
  v_invite_source uuid:=gen_random_uuid();
  v_disabled_source uuid:=gen_random_uuid();
  v_chain_source uuid:=gen_random_uuid();
  v_chain_target uuid:=gen_random_uuid();
  v_ambiguous_source uuid:=gen_random_uuid();
  v_ambiguous_extra uuid:=gen_random_uuid();
  v_other_source uuid:=gen_random_uuid();
  v_other_target uuid:=gen_random_uuid();
  v_target_identity uuid:=gen_random_uuid();
  v_other_target_identity uuid:=gen_random_uuid();
  v_chain_target_identity uuid:=gen_random_uuid();
  v_cycle_target_identity uuid:=gen_random_uuid();
  v_target_link uuid:=gen_random_uuid();
  v_other_target_link uuid:=gen_random_uuid();
  v_late_source_link uuid:=gen_random_uuid();
  v_chain_target_link uuid:=gen_random_uuid();
  v_cycle_target_link uuid:=gen_random_uuid();
  v_invitation uuid:=gen_random_uuid();
  v_disabled_invitation uuid:=gen_random_uuid();
  v_chain_invitation uuid:=gen_random_uuid();
  v_sale uuid:=gen_random_uuid();
  v_chain_source_sale uuid:=gen_random_uuid();
  v_chain_target_sale uuid:=gen_random_uuid();
  v_points uuid:=gen_random_uuid();
  v_propose_key uuid:=gen_random_uuid();
  v_proof_key uuid:=gen_random_uuid();
  v_approve_key uuid:=gen_random_uuid();
  v_approve_repeat_key uuid:=gen_random_uuid();
  v_reject_propose_key uuid:=gen_random_uuid();
  v_reject_key uuid:=gen_random_uuid();
  v_reject_repeat_key uuid:=gen_random_uuid();
  v_reverse_key uuid:=gen_random_uuid();
  v_reverse_repeat_key uuid:=gen_random_uuid();
  v_ambiguous_propose_key uuid:=gen_random_uuid();
  v_ambiguous_proof_key uuid:=gen_random_uuid();
  v_cross_key uuid:=gen_random_uuid();
  v_branch_key uuid:=gen_random_uuid();
  v_staff_terminal_key uuid:=gen_random_uuid();
  v_staff_reject_key uuid:=gen_random_uuid();
  v_staff_reverse_key uuid:=gen_random_uuid();
  v_invite_propose_key uuid:=gen_random_uuid();
  v_invite_proof_key uuid:=gen_random_uuid();
  v_invite_approve_key uuid:=gen_random_uuid();
  v_disabled_propose_key uuid:=gen_random_uuid();
  v_disabled_proof_key uuid:=gen_random_uuid();
  v_disabled_approve_key uuid:=gen_random_uuid();
  v_disabled_reject_key uuid:=gen_random_uuid();
  v_disabled_proposal_denied_key uuid:=gen_random_uuid();
  v_chain_propose_key uuid:=gen_random_uuid();
  v_chain_proof_key uuid:=gen_random_uuid();
  v_chain_approve_key uuid:=gen_random_uuid();
  v_chain_denied_key uuid:=gen_random_uuid();
  v_cycle_denied_key uuid:=gen_random_uuid();
  v_proposal uuid;
  v_reject_proposal uuid;
  v_ambiguous_proposal uuid;
  v_invite_proposal uuid;
  v_disabled_proposal uuid;
  v_chain_proposal uuid;
  v_proof uuid;
  v_decision uuid;
  v_receipt jsonb;
  v_replay jsonb;
  v_history jsonb;
  v_coverage jsonb;
  v_lifecycle_before jsonb;
  v_lifecycle_after jsonb;
  v_revenue_before jsonb;
  v_revenue_after jsonb;
  v_before_sales bigint;
  v_before_points bigint;
  v_before_grants bigint;
  v_before_redemptions bigint;
  v_count bigint;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values
  (
    '00000000-0000-0000-0000-000000000000',v_owner,'authenticated',
    'authenticated','v111-owner-'||v_owner||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_staff_user,'authenticated',
    'authenticated','v111-staff-'||v_staff_user||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_other_owner,'authenticated',
    'authenticated','v111-other-owner-'||v_other_owner||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_target_user,'authenticated',
    'authenticated','v111-target@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_other_target_user,'authenticated',
    'authenticated','v111-other-target@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_chain_target_user,'authenticated',
    'authenticated','v111-chain-target@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_cycle_target_user,'authenticated',
    'authenticated','v111-cycle-target@example.test','',now(),now(),now()
  );

  insert into public.businesses(
    id,name,slug,currency,industry,enabled_modules,is_synthetic
  ) values
  (
    v_business,'V111 Identity Evidence','v111-'||v_business,'SGD','facial',
    array['dashboard','clients','sales','loyalty'],true
  ),(
    v_other_business,'V111 Other Firm','v111-other-'||v_other_business,
    'SGD','retail',array['dashboard','clients','sales','loyalty'],true
  );
  insert into public.branches(id,business_id,name,timezone,is_default)
  values
    (v_branch,v_business,'V111 Assigned Branch','Asia/Singapore',true),
    (v_other_branch,v_business,'V111 Hidden Branch','Asia/Singapore',false);
  insert into public.staff(
    id,business_id,user_id,role,full_name,email,active
  ) values
    (v_owner_staff,v_business,v_owner,'owner','V111 Owner',
     'v111-owner-'||v_owner||'@example.test',true),
    (v_staff,v_business,v_staff_user,'frontdesk','V111 Front Desk',
     'v111-staff-'||v_staff_user||'@example.test',true),
    (v_other_owner_staff,v_other_business,v_other_owner,'owner','V111 Other Owner',
     'v111-other-owner-'||v_other_owner||'@example.test',true);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_staff,v_branch);

  insert into public.clients(id,business_id,full_name,email,is_synthetic)
  values
    (v_source,v_business,'V111 Source','v111-target@example.test',true),
    (v_target,v_business,'V111 Verified Target','v111-target@example.test',true),
    (v_reject_source,v_business,'V111 Rejection Source','reject@example.test',true),
    (v_invite_source,v_business,'V111 Invitation Source','invitation-source@example.test',true),
    (v_disabled_source,v_business,'V111 Disabled Target Source','disabled-source@example.test',true),
    (v_chain_source,v_business,'V111 Chain Source','chain-source@example.test',true),
    (v_chain_target,v_business,'V111 Chain Target','v111-chain-target@example.test',true),
    (v_other_source,v_other_business,'V111 Other Source',
     'v111-other-target@example.test',true),
    (v_other_target,v_other_business,'V111 Other Target',
     'v111-other-target@example.test',true);

  insert into public.customer_identities(
    id,auth_user_id,status,created_via
  ) values
    (v_target_identity,v_target_user,'active','phone_registration'),
    (v_other_target_identity,v_other_target_user,'active','phone_registration'),
    (v_chain_target_identity,v_chain_target_user,'active','phone_registration'),
    (v_cycle_target_identity,v_cycle_target_user,'active','phone_registration');
  perform set_config('app.customer_link_insert_id',v_target_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_target_link,v_business,v_target_identity,v_target_user,v_target,
    'verified','qr_join',statement_timestamp()
  );
  perform set_config('app.customer_link_insert_id',v_other_target_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_other_target_link,v_other_business,v_other_target_identity,
    v_other_target_user,v_other_target,'verified','qr_join',
    statement_timestamp()
  );
  perform set_config('app.customer_link_insert_id',v_chain_target_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_chain_target_link,v_business,v_chain_target_identity,
    v_chain_target_user,v_chain_target,'verified','qr_join',
    statement_timestamp()
  );
  perform set_config('app.customer_link_insert_id','',true);

  -- Source financial history must remain on its original business-owned client row.
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    branch_id,counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at
  ) values(
    v_sale,v_business,v_source,'quick_sale',3000,statement_timestamp(),
    statement_timestamp(),v_branch,true,true,false,statement_timestamp()
  );
  perform set_config('app.points_ledger_insert_id',v_points::text,true);
  perform set_config('app.points_ledger_write_scope','sale_trigger',true);
  insert into public.points_ledger(
    id,business_id,client_id,entry_type,points,sale_id,reference
  ) values(v_points,v_business,v_source,'earn',300,v_sale,'v111 source truth');
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  select count(*) into v_before_sales from public.sales
   where business_id=v_business and client_id=v_source;
  select coalesce(sum(points),0) into v_before_points from public.points_ledger
   where business_id=v_business and client_id=v_source;
  select count(*) into v_before_grants from public.reward_grants
   where business_id=v_business and client_id=v_source;
  select count(*) into v_before_redemptions from public.loyalty_redemptions
   where business_id=v_business and client_id=v_source;

  -- Branch-scoped proposal: assigned front desk may propose only in its branch.
  perform pg_temp.v111_actor(v_staff_user);
  v_receipt:=public.propose_customer_identity_correction_v111(
    v_business,v_branch,v_source,v_target,'Duplicate created before QR join',
    v_propose_key
  );
  v_replay:=public.propose_customer_identity_correction_v111(
    v_business,v_branch,v_source,v_target,'Duplicate created before QR join',
    v_propose_key
  );
  if v_replay is distinct from v_receipt then
    raise exception 'propose exact replay did not return the original receipt';
  end if;
  v_proposal:=(v_receipt->>'proposal_id')::uuid;
  begin
    perform public.propose_customer_identity_correction_v111(
      v_business,v_branch,v_source,v_target,'changed-payload idempotency conflict',
      v_propose_key
    );
    raise exception 'propose changed-payload idempotency conflict was accepted';
  exception when unique_violation then null;
  end;
  begin
    perform public.propose_customer_identity_correction_v111(
      v_business,v_other_branch,v_reject_source,v_target,'Wrong branch',
      v_branch_key
    );
    raise exception 'branch-scoped proposal escaped its assigned branch';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.propose_customer_identity_correction_v111(
      v_other_business,null,v_other_source,v_other_target,'Cross firm',
      v_cross_key
    );
    raise exception 'cross-business proposal was accepted';
  exception when insufficient_privilege then null;
  end;

  v_receipt:=public.attach_customer_identity_proof_v111(
    v_proposal,'verified_contact_pair',
    jsonb_build_object(
      'contact_type','EMAIL','contact_value',' V111-TARGET@EXAMPLE.TEST '
    ),
    v_proof_key
  );
  v_replay:=public.attach_customer_identity_proof_v111(
    v_proposal,'VERIFIED_CONTACT_PAIR',
    jsonb_build_object(
      'contact_type','email','contact_value','v111-target@example.test'
    ),
    v_proof_key
  );
  if v_replay is distinct from v_receipt then
    raise exception 'proof exact replay did not return the original receipt';
  end if;
  v_proof:=(v_receipt->>'proof_id')::uuid;
  begin
    perform public.attach_customer_identity_proof_v111(
      v_proposal,'verified_contact_pair',
      jsonb_build_object(
        'contact_type','email','contact_value','changed@example.test'
      ),
      v_proof_key
    );
    raise exception 'proof changed-payload idempotency conflict was accepted';
  exception when unique_violation then null;
  end;
  begin
    perform public.approve_customer_identity_correction_v111(
      v_proposal,v_staff_terminal_key
    );
    raise exception 'unauthorized terminal operation approved by branch staff';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.v111_actor(v_owner);
  v_receipt:=public.approve_customer_identity_correction_v111(
    v_proposal,v_approve_key
  );
  v_replay:=public.approve_customer_identity_correction_v111(
    v_proposal,v_approve_key
  );
  if v_replay is distinct from v_receipt then
    raise exception 'approve exact replay did not return the original receipt';
  end if;
  v_decision:=(v_receipt->>'decision_id')::uuid;
  perform public.approve_customer_identity_correction_v111(
    v_proposal,v_approve_repeat_key
  );
  select count(*) into v_count
  from public.customer_identity_decisions_v111
  where proposal_id=v_proposal and decision_type='approve';
  if v_count<>1 then
    raise exception 'repeated terminal operation created another approval';
  end if;
  if not exists(
    select 1 from public.customer_identity_current_attribution_v111
    where business_id=v_business and source_client_id=v_source
      and effective_client_id=v_target
  ) then
    raise exception 'approval did not publish exact source-to-target attribution';
  end if;
  v_coverage:=public.get_customer_identity_coverage_v111(v_business,v_branch);
  if coalesce((v_coverage->>'corrected_transaction_count')::bigint,0)<1 then
    raise exception 'approved correction was absent from identity coverage';
  end if;

  -- A second proposal provides changed-payload conflict and rejection evidence.
  perform pg_temp.v111_actor(v_staff_user);
  v_replay:=public.propose_customer_identity_correction_v111(
    v_business,v_branch,v_reject_source,v_chain_target,'Not the same person',
    v_reject_propose_key
  );
  v_reject_proposal:=(v_replay->>'proposal_id')::uuid;
  begin
    perform public.reject_customer_identity_correction_v111(
      v_reject_proposal,'Front desk cannot decide',v_staff_reject_key
    );
    raise exception 'unauthorized terminal operation rejected by branch staff';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.v111_actor(v_owner);
  begin
    perform public.approve_customer_identity_correction_v111(
      v_reject_proposal,v_approve_key
    );
    raise exception 'approve changed-payload idempotency conflict was accepted';
  exception when unique_violation then null;
  end;
  v_receipt:=public.reject_customer_identity_correction_v111(
    v_reject_proposal,'Owner verified these are different people',v_reject_key
  );
  v_replay:=public.reject_customer_identity_correction_v111(
    v_reject_proposal,'Owner verified these are different people',v_reject_key
  );
  if v_replay is distinct from v_receipt then
    raise exception 'reject exact replay did not return the original receipt';
  end if;
  perform public.reject_customer_identity_correction_v111(
    v_reject_proposal,'Owner verified these are different people',
    v_reject_repeat_key
  );
  select count(*) into v_count
  from public.customer_identity_decisions_v111
  where proposal_id=v_reject_proposal and decision_type='reject';
  if v_count<>1 then
    raise exception 'repeated terminal operation created another rejection';
  end if;
  begin
    perform public.reject_customer_identity_correction_v111(
      v_reject_proposal,'changed-payload idempotency conflict',v_reject_key
    );
    raise exception 'reject changed-payload idempotency conflict was accepted';
  exception when unique_violation then null;
  end;

  perform pg_temp.v111_actor(v_staff_user);
  begin
    perform public.reverse_customer_identity_correction_v111(
      v_proposal,'Front desk cannot reverse',v_staff_reverse_key
    );
    raise exception 'unauthorized terminal operation reversed by branch staff';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.v111_actor(v_owner);
  v_receipt:=public.reverse_customer_identity_correction_v111(
    v_proposal,'Correction was approved in error',v_reverse_key
  );
  v_replay:=public.reverse_customer_identity_correction_v111(
    v_proposal,'Correction was approved in error',v_reverse_key
  );
  if v_replay is distinct from v_receipt then
    raise exception 'reverse exact replay did not return the original receipt';
  end if;
  perform public.reverse_customer_identity_correction_v111(
    v_proposal,'Correction was approved in error',v_reverse_repeat_key
  );
  select count(*) into v_count
  from public.customer_identity_decisions_v111
  where proposal_id=v_proposal and decision_type='reverse';
  if v_count<>1 then
    raise exception 'repeated terminal operation created another reversal';
  end if;
  if not exists(
    select 1 from public.customer_identity_current_attribution_v111
    where business_id=v_business and source_client_id=v_source
      and effective_client_id=v_source and event_type='correction_reversed'
  ) then
    raise exception 'reversal did not restore exact prior attribution';
  end if;
  begin
    perform public.reverse_customer_identity_correction_v111(
      v_proposal,'changed-payload idempotency conflict',v_reverse_key
    );
    raise exception 'reverse changed-payload idempotency conflict was accepted';
  exception when unique_violation then null;
  end;

  if (select count(*) from public.sales
       where business_id=v_business and client_id=v_source)<>v_before_sales
     or (select coalesce(sum(points),0) from public.points_ledger
          where business_id=v_business and client_id=v_source)<>v_before_points
     or (select count(*) from public.reward_grants
          where business_id=v_business and client_id=v_source)<>v_before_grants
     or (select count(*) from public.loyalty_redemptions
          where business_id=v_business and client_id=v_source)<>v_before_redemptions then
    raise exception 'source financial history was rewritten by correction or reversal';
  end if;
  if not exists(
       select 1 from public.clients where id=v_source and business_id=v_business
     ) or exists(
       select 1 from public.customer_links
       where business_id=v_business and client_id=v_source and state='verified'
     ) then
    raise exception 'source record was destroyed or automatically linked';
  end if;

  -- Firm-invitation proof must fail closed when its source becomes verified
  -- after proof attachment but before the owner approval decision.
  insert into public.customer_link_invitations(
    id,business_id,client_id,issued_by_auth_user_id,token_hash,
    recipient_email_hash,expires_at
  ) values(
    v_invitation,v_business,v_invite_source,v_owner,
    app.v31_sha256_hex('v111-invitation-toctou-'||v_invitation),
    app.v31_sha256_hex('v31.invitation-email:v111-target@example.test'),
    statement_timestamp()+interval '1 day'
  );
  perform pg_temp.v111_actor(v_staff_user);
  v_receipt:=public.propose_customer_identity_correction_v111(
    v_business,v_branch,v_invite_source,v_target,
    'Invitation evidence before a later verified link',v_invite_propose_key
  );
  v_invite_proposal:=(v_receipt->>'proposal_id')::uuid;
  perform public.attach_customer_identity_proof_v111(
    v_invite_proposal,'firm_invitation',
    jsonb_build_object('invitation_id',v_invitation),
    v_invite_proof_key
  );
  perform set_config('app.customer_link_insert_id',v_late_source_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_late_source_link,v_business,v_other_target_identity,
    v_other_target_user,v_invite_source,'verified','firm_invitation',
    statement_timestamp()
  );
  perform set_config('app.customer_link_insert_id','',true);
  perform pg_temp.v111_actor(v_owner);
  begin
    perform public.approve_customer_identity_correction_v111(
      v_invite_proposal,v_invite_approve_key
    );
    raise exception 'firm_invitation source-link TOCTOU was approved';
  exception when insufficient_privilege then null;
  end;

  -- Disabled identities are not valid targets at proposal time or approval time.
  update public.customer_identities
     set status='disabled',updated_at=statement_timestamp()
   where id=v_chain_target_identity;
  perform pg_temp.v111_actor(v_staff_user);
  begin
    perform public.propose_customer_identity_correction_v111(
      v_business,v_branch,v_disabled_source,v_chain_target,
      'Disabled target proposal must fail',v_disabled_proposal_denied_key
    );
    raise exception 'disabled target identity was accepted at proposal';
  exception when insufficient_privilege then null;
  end;
  update public.customer_identities
     set status='active',updated_at=statement_timestamp()
   where id=v_chain_target_identity;
  insert into public.customer_link_invitations(
    id,business_id,client_id,issued_by_auth_user_id,token_hash,
    recipient_email_hash,expires_at
  ) values(
    v_disabled_invitation,v_business,v_disabled_source,v_owner,
    app.v31_sha256_hex('v111-disabled-approval-'||v_disabled_invitation),
    app.v31_sha256_hex('v31.invitation-email:v111-chain-target@example.test'),
    statement_timestamp()+interval '1 day'
  );
  v_receipt:=public.propose_customer_identity_correction_v111(
    v_business,v_branch,v_disabled_source,v_chain_target,
    'Target disabled after proof attachment',v_disabled_propose_key
  );
  v_disabled_proposal:=(v_receipt->>'proposal_id')::uuid;
  perform public.attach_customer_identity_proof_v111(
    v_disabled_proposal,'firm_invitation',
    jsonb_build_object('invitation_id',v_disabled_invitation),
    v_disabled_proof_key
  );
  update public.customer_identities
     set status='disabled',updated_at=statement_timestamp()
   where id=v_chain_target_identity;
  perform pg_temp.v111_actor(v_owner);
  begin
    perform public.approve_customer_identity_correction_v111(
      v_disabled_proposal,v_disabled_approve_key
    );
    raise exception 'target disabled after proof was approved';
  exception when insufficient_privilege then null;
  end;
  update public.customer_identities
     set status='active',updated_at=statement_timestamp()
   where id=v_chain_target_identity;
  perform public.reject_customer_identity_correction_v111(
    v_disabled_proposal,'Target identity was disabled before approval',
    v_disabled_reject_key
  );

  -- Full history is durable and returns approval + reversal without inference.
  perform pg_temp.v111_actor(v_staff_user);
  v_history:=public.get_customer_identity_proposal_v111(v_proposal);
  if jsonb_array_length(v_history->'proofs')<>1
     or jsonb_array_length(v_history->'decisions')<>2
     or jsonb_array_length(v_history->'attribution_history')<>2 then
    raise exception 'full proposal history omitted proof, decision, or reversal evidence';
  end if;

  -- Ambiguous proof: two unlinked business rows match the confirmed target contact.
  update auth.users
     set email='v111-ambiguous@example.test',
         email_confirmed_at=statement_timestamp(),
         updated_at=statement_timestamp()
   where id=v_target_user;
  insert into public.clients(id,business_id,full_name,email,is_synthetic)
  values
    (v_ambiguous_source,v_business,'V111 Ambiguous Source',
     'v111-ambiguous@example.test',true),
    (v_ambiguous_extra,v_business,'V111 Ambiguous Extra',
     'v111-ambiguous@example.test',true);
  v_receipt:=public.propose_customer_identity_correction_v111(
    v_business,v_branch,v_ambiguous_source,v_target,'Possible duplicate',
    v_ambiguous_propose_key
  );
  v_ambiguous_proposal:=(v_receipt->>'proposal_id')::uuid;
  begin
    perform public.attach_customer_identity_proof_v111(
      v_ambiguous_proposal,'verified_contact_pair',
      jsonb_build_object(
        'contact_type','email','contact_value','v111-ambiguous@example.test'
      ),
      v_ambiguous_proof_key
    );
    raise exception 'ambiguous proof was accepted';
  exception when sqlstate 'P0003' then null;
  end;

  -- A firm invitation is a valid owner-approved correction when its target
  -- remains active and its exact source remains unlinked.
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    branch_id,counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at
  ) values
  (
    v_chain_source_sale,v_business,v_chain_source,'quick_sale',2500,
    clock_timestamp(),clock_timestamp(),v_branch,true,true,false,
    clock_timestamp()
  ),(
    v_chain_target_sale,v_business,v_target,'quick_sale',3500,
    clock_timestamp(),clock_timestamp(),v_branch,true,true,false,
    clock_timestamp()
  );
  insert into public.customer_link_invitations(
    id,business_id,client_id,issued_by_auth_user_id,token_hash,
    recipient_email_hash,expires_at
  ) values(
    v_chain_invitation,v_business,v_chain_source,v_owner,
    app.v31_sha256_hex('v111-chain-happy-'||v_chain_invitation),
    app.v31_sha256_hex('v31.invitation-email:v111-ambiguous@example.test'),
    statement_timestamp()+interval '1 day'
  );
  perform pg_temp.v111_actor(v_staff_user);
  v_receipt:=public.propose_customer_identity_correction_v111(
    v_business,v_branch,v_chain_source,v_target,
    'Firm invitation exact-source happy path',v_chain_propose_key
  );
  v_chain_proposal:=(v_receipt->>'proposal_id')::uuid;
  perform public.attach_customer_identity_proof_v111(
    v_chain_proposal,'firm_invitation',
    jsonb_build_object('invitation_id',v_chain_invitation),
    v_chain_proof_key
  );
  perform pg_temp.v111_actor(v_owner);
  v_lifecycle_before:=public.get_customer_lifecycle_v107(
    v_business,current_date-2,current_date+2,v_branch,clock_timestamp()
  );
  v_revenue_before:=public.get_revenue_truth_v106(
    v_business,current_date-2,current_date+2,v_branch,clock_timestamp()
  );
  v_receipt:=public.approve_customer_identity_correction_v111(
    v_chain_proposal,v_chain_approve_key
  );
  if app.v111_effective_client_id(v_business,v_chain_source)
       is distinct from v_target then
    raise exception 'firm_invitation happy path did not publish effective attribution';
  end if;
  v_lifecycle_after:=public.get_customer_lifecycle_v107(
    v_business,current_date-2,current_date+2,v_branch,clock_timestamp()
  );
  v_revenue_after:=public.get_revenue_truth_v106(
    v_business,current_date-2,current_date+2,v_branch,clock_timestamp()
  );
  if (v_lifecycle_before #>> '{metrics,transacting_identified_customers}')::bigint
       <> (v_lifecycle_after #>> '{metrics,transacting_identified_customers}')::bigint + 1
  then
    raise exception
      'v107 lifecycle did not consume approved v111 attribution (before %, after %, raw_sales %, contracts %)',
      v_lifecycle_before #>> '{metrics,transacting_identified_customers}',
      v_lifecycle_after #>> '{metrics,transacting_identified_customers}',
      (select count(*) from public.sales s
        where s.business_id=v_business and s.branch_id=v_branch
          and s.counts_as_visit and s.amount_cents>0),
      (select count(*) from public.sales s
        cross join lateral app.v106_reporting_contract(
          s.business_id,s.branch_id,s.occurred_at
        ) c
        where s.business_id=v_business and s.branch_id=v_branch);
  end if;
  if v_revenue_before->'totals' is distinct from v_revenue_after->'totals'
     or v_revenue_after #>> '{formula_metadata,identity_attribution}' is distinct from
        'immutable sales.client_id is resolved through app.v111_effective_client_id for current synchronized reporting'
  then
    raise exception 'v106 current attribution changed revenue truth or omitted its resolver metadata';
  end if;
  if (select client_id from public.sales where id=v_chain_source_sale)
       is distinct from v_chain_source
     or (select client_id from public.sales where id=v_chain_target_sale)
       is distinct from v_target
  then
    raise exception 'v111 reporting integration rewrote immutable sales.client_id';
  end if;

  -- Once A→B is active, unlinking B cannot make B eligible as a new source.
  -- Both B→C (chain) and B→A (cycle) must fail while the resolver is one-hop.
  perform set_config('app.customer_link_transition_id',v_target_link::text,true);
  update public.customer_links
     set state='unlinked',unlinked_at=statement_timestamp(),
         unlinked_by_auth_user_id=v_target_user
   where id=v_target_link;
  perform set_config('app.customer_link_transition_id','',true);
  perform pg_temp.v111_actor(v_staff_user);
  begin
    perform public.propose_customer_identity_correction_v111(
      v_business,v_branch,v_target,v_chain_target,
      'B to C chain must fail',v_chain_denied_key
    );
    raise exception 'A to B then B to C active correction chain was accepted';
  exception when object_not_in_prerequisite_state then null;
  end;
  perform set_config('app.customer_link_insert_id',v_cycle_target_link::text,true);
  begin
    insert into public.customer_links(
      id,business_id,identity_id,auth_user_id,client_id,state,
      verification_method,verified_at
    ) values(
      v_cycle_target_link,v_business,v_cycle_target_identity,
      v_cycle_target_user,v_chain_source,'verified','firm_invitation',
      statement_timestamp()
    );
    raise exception
      'active-source verified link was accepted after attribution approval';
  exception when object_not_in_prerequisite_state then null;
  end;
  perform set_config('app.customer_link_insert_id','',true);
  begin
    perform public.propose_customer_identity_correction_v111(
      v_business,v_branch,v_target,v_chain_source,
      'B to A cycle must fail',v_cycle_denied_key
    );
    raise exception 'A to B then B to A active correction cycle was accepted';
  exception when insufficient_privilege then null;
  end;

  -- Append-only evidence, decision, event, request and proposal scope are immutable.
  begin
    update public.customer_identity_proofs_v111
       set evidence_metadata='{}'::jsonb where id=v_proof;
    raise exception 'append-only evidence was updated';
  exception when integrity_constraint_violation then null;
  end;
  begin
    delete from public.customer_identity_decisions_v111 where id=v_decision;
    raise exception 'append-only evidence decision was deleted';
  exception when integrity_constraint_violation then null;
  end;
  begin
    delete from public.customer_identity_attribution_events_v111
     where proposal_id=v_proposal;
    raise exception 'append-only evidence attribution was deleted';
  exception when integrity_constraint_violation then null;
  end;
  begin
    delete from public.customer_identity_request_ledger_v111
     where idempotency_key=v_approve_key;
    raise exception 'append-only evidence request receipt was deleted';
  exception when integrity_constraint_violation then null;
  end;
  begin
    update public.customer_identity_proposals_v111
       set source_client_id=v_target where id=v_proposal;
    raise exception 'append-only evidence proposal scope was rewritten';
  exception when integrity_constraint_violation then null;
  end;
end
$runtime$;

rollback;

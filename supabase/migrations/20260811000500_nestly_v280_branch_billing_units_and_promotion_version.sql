-- NESTLY v280 — two live-tenant defects from Bistro 999, one file.
--
-- (A) "why when add branch = pay for 2 branch? i only added 1 new branch - the older one is
--     manual payment". V202 bills a branch as another UNIT of the base plan, and computes the
--     Stripe quantity as 1 + paid branches. That constant 1 is the firm's own base unit, and it
--     belongs in the quantity only when Stripe is the thing collecting the base plan. Bistro 999
--     pays for the firm outside Stripe, so its branch checkout asked for two units: the firm a
--     second time, plus the branch they actually bought.
--
--     There is no reliable way to infer this after the fact — subscriptions.billing_provider is
--     'manual' for every business that has not yet paid through Stripe, and the V77 webhook
--     rewrites it to 'stripe' the moment ANY Stripe subscription confirms, including one that
--     only ever covered a branch. So the answer is recorded at the moment it is decided:
--     provider_covers_base_unit is true for every subscription that exists today (their
--     subscription, if any, was created by the Settings checkout, which does include the base),
--     and business_add_branch_v202 sets it false when the checkout it mints exists only to pay
--     for a branch.
--
-- (B) "promotions loading forever - cannot publish". The first publish of a NEWLY created
--     promotion could never succeed. business_create_promotion_draft_v155 returns the v104
--     receipt — content_version 1 — and only then calls app.save_promotion_scope_v155, which
--     writes the branch scope onto the same row and bumps its version to 2. The editor finalized
--     with the version it was handed, and Postgres answered promotion_version_conflict every
--     time. Verified against production: the owner's offer row sits at version 2 with a
--     branch_scope, its create receipt reports content_version 1, the 2.1 MB photo is in storage
--     and there is no finalize receipt and no media row.
--
--     The fix is not to stop bumping the version — the scope write really does change the row,
--     and the version is what protects a concurrent editor. The fix is that a wrapper must report
--     the version it actually LEFT BEHIND, in what it returns and in the receipt a replay reads.
--
-- Nothing here changes a price, a policy or who may call what. Both function bodies are the
-- shipped ones with the stated addition.

begin;

-- ------------------------------------------------------------------ (A) who pays the base unit
alter table public.subscriptions
  add column if not exists provider_covers_base_unit boolean not null default true;

comment on column public.subscriptions.provider_covers_base_unit is
  'true = the Stripe subscription''s base-price quantity includes this firm''s own base unit '
  '(the company and its main branch). false = the Stripe subscription exists only to pay for '
  'extra branches, because the base plan is collected elsewhere. Read by the billing command '
  'edge function to decide the quantity; never a price.';

-- ------------------------------------------------------------------------- (A) add a branch
-- Byte-identical to the V202 body apart from the marked V280 block.
create or replace function public.business_add_branch_v202(
  p_business uuid,
  p_name text,
  p_address text default null,
  p_phone text default null,
  p_email text default null,
  p_copy_from uuid default null,
  p_idempotency_key uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_branch public.branches%rowtype;
  v_existing public.billing_commands%rowtype;
  v_cadence text;
  v_capacity integer;
  v_subscription text;
  v_command_type text;
  v_command jsonb;
  v_copied jsonb := null;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
begin
  if v_actor is null or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner access is required' using errcode='42501';
  end if;
  if v_name is null then
    raise exception 'a branch name is required' using errcode='22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'an idempotency key is required' using errcode='22023';
  end if;

  select * into v_existing from public.billing_commands
   where business_id=p_business and idempotency_key=p_idempotency_key;
  if found then
    select * into v_branch from public.branches where id=v_existing.requested_branch_id;
    return jsonb_build_object(
      'status','replayed','branch_id',v_existing.requested_branch_id,
      'branch_name',v_branch.name,'billing_state',v_branch.billing_state,
      'command_id',v_existing.id,'command_status',v_existing.status,
      'redirect_url',v_existing.redirect_url);
  end if;

  select s.billing_cadence, s.provider_subscription_id, t.customer_capacity
    into v_cadence, v_subscription, v_capacity
    from public.subscriptions s
    left join public.billing_subscription_terms_v124 t on t.business_id=s.business_id
   where s.business_id=p_business;

  v_cadence := coalesce(nullif(v_cadence,''),'annual');
  if v_capacity is null then
    select greatest(1000, ceil(count(*)::numeric/1000)::integer*1000)
      into v_capacity from public.clients where business_id=p_business;
  end if;
  v_command_type := case when nullif(v_subscription,'') is not null
                         then 'change_branches' else 'create_checkout' end;

  insert into public.branches(business_id,name,address,phone,email,active,is_default,billing_state)
  values (p_business,v_name,nullif(btrim(coalesce(p_address,'')),''),
          nullif(btrim(coalesce(p_phone,'')),''),nullif(btrim(coalesce(p_email,'')),''),
          false,false,'pending_payment')
  returning * into v_branch;

  if p_copy_from is not null then
    v_copied := public.business_copy_branch_settings_v202(p_business,p_copy_from,v_branch.id);
  end if;

  -- V280: this branch of the code runs only when the firm has NO Stripe subscription, so the
  -- checkout being minted here is being minted to pay for a BRANCH. Whatever is collecting the
  -- firm's own base plan today — a manual invoice, or nothing yet because the trial is running —
  -- it is not this subscription, and charging the base a second time inside a branch purchase is
  -- what the owner saw as "pay for 2 branch". Recorded before the command is handed out, so the
  -- edge function reads a decision rather than guessing one.
  if v_command_type = 'create_checkout' then
    update public.subscriptions
       set provider_covers_base_unit = false, updated_at = now()
     where business_id = p_business;
  end if;

  v_command := public.request_billing_command_v124(
    p_business,v_command_type,v_cadence,v_capacity,p_idempotency_key);

  update public.billing_commands
     set requested_branch_id=v_branch.id
   where id=(v_command->>'command_id')::uuid;

  return jsonb_build_object(
    'status','ok','branch_id',v_branch.id,'branch_name',v_branch.name,
    'billing_state',v_branch.billing_state,'copied',v_copied,
    'command_type',v_command_type,'cadence',v_cadence,
    'covers_base_unit',v_command_type<>'create_checkout',
    'command_id',v_command->>'command_id','command_status',v_command->>'status');
end
$$;

revoke all on function public.business_add_branch_v202(uuid,text,text,text,text,uuid,uuid) from public, anon;
grant execute on function public.business_add_branch_v202(uuid,text,text,text,text,uuid,uuid) to authenticated;

-- --------------------------------------------------- (A) what the owner is allowed to be told
-- The Branches screen already reads public.branches directly under RLS, so this exists for the
-- billing surface and for support: the same three numbers, from one place, with no price in them.
create or replace function public.business_branch_billing_units_v280(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_total integer; v_included integer; v_billable integer; v_lapsed integer;
  v_covers boolean;
begin
  if auth.uid() is null or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner access is required' using errcode='42501';
  end if;
  select count(*)::integer,
         count(*) filter (where billing_state='included')::integer,
         count(*) filter (where billing_state in ('pending_payment','active'))::integer,
         count(*) filter (where billing_state='suspended')::integer
    into v_total, v_included, v_billable, v_lapsed
    from public.branches where business_id=p_business;
  select coalesce(provider_covers_base_unit,true) into v_covers
    from public.subscriptions where business_id=p_business;
  return jsonb_build_object(
    'status','ok','total_branches',v_total,'included_branches',v_included,
    'billable_branches',v_billable,'lapsed_branches',v_lapsed,
    'base_unit_billed_by_provider',coalesce(v_covers,true),
    'plan_units',greatest(1,(case when coalesce(v_covers,true) then 1 else 0 end)+v_billable));
end
$$;

revoke all on function public.business_branch_billing_units_v280(uuid) from public, anon;
grant execute on function public.business_branch_billing_units_v280(uuid) to authenticated;

-- ------------------------------------------------ (B) report the version actually left behind
create or replace function app.promotion_version_sync_v280(
  p_business uuid, p_promotion uuid, p_attempt_key uuid, p_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_version bigint;
  v_payload jsonb := coalesce(p_payload,'{}'::jsonb);
begin
  select content.version into v_version
    from public.business_customer_content_v95 content
   where content.id = p_promotion and content.business_id = p_business;
  if v_version is null then
    return v_payload;
  end if;
  v_payload := v_payload || jsonb_build_object('content_version',v_version);
  if v_payload ? 'item' then
    v_payload := jsonb_set(v_payload,'{item,content_version}',to_jsonb(v_version),true);
  end if;
  -- A replay reads the receipt, not this return value. Leaving the pre-scope version in the
  -- receipt would hand the same stale number straight back to the client that is retrying.
  update public.business_promotion_attempt_receipts_v104 receipt
     set response_payload = case
           when receipt.response_payload ? 'item'
             then jsonb_set(
                    receipt.response_payload||jsonb_build_object('content_version',v_version),
                    '{item,content_version}',to_jsonb(v_version),true)
           else receipt.response_payload||jsonb_build_object('content_version',v_version)
         end
   where receipt.business_id = p_business
     and receipt.attempt_key = p_attempt_key;
  return v_payload;
end
$$;

revoke all on function app.promotion_version_sync_v280(uuid,uuid,uuid,jsonb) from public, anon, authenticated;

create or replace function public.business_create_promotion_draft_v155(
  p_business uuid, p_promotion_id uuid, p_attempt_key uuid, p_scope_mode text,
  p_branch_ids uuid[], p_operational_branch uuid, p_name text, p_tagline text,
  p_description text, p_terms text, p_starts_at timestamptz, p_ends_at timestamptz,
  p_display_order integer, p_cta_kind text, p_cta_label text, p_offer_facts text,
  p_occasion text
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result jsonb;
  v_scope jsonb;
begin
  v_result := public.business_create_promotion_draft_v104(
    p_business,p_promotion_id,p_attempt_key,null,p_name,p_tagline,
    p_description,p_terms,p_starts_at,p_ends_at,p_display_order,p_cta_kind,
    p_cta_label,p_offer_facts,p_occasion
  );
  v_scope := app.save_promotion_scope_v155(
    p_business,p_promotion_id,p_scope_mode,p_branch_ids,p_operational_branch
  );
  -- V280: save_promotion_scope_v155 bumped the row's version AFTER v104 built this payload, so
  -- what was returned here described a row that no longer existed. The client then finalized
  -- with a version one behind and was refused, every time, for every new promotion.
  v_result := app.promotion_version_sync_v280(p_business,p_promotion_id,p_attempt_key,v_result);
  return v_result || jsonb_build_object('branch_scope',v_scope);
end
$function$;

revoke all on function public.business_create_promotion_draft_v155(
  uuid,uuid,uuid,text,uuid[],uuid,text,text,text,text,timestamptz,timestamptz,
  integer,text,text,text,text) from public, anon;
grant execute on function public.business_create_promotion_draft_v155(
  uuid,uuid,uuid,text,uuid[],uuid,text,text,text,text,timestamptz,timestamptz,
  integer,text,text,text,text) to authenticated;

create or replace function public.business_finalize_promotion_v155(
  p_business uuid, p_promotion_id uuid, p_scope_mode text, p_branch_ids uuid[],
  p_operational_branch uuid, p_name text, p_tagline text, p_description text,
  p_terms text, p_starts_at timestamptz, p_ends_at timestamptz, p_display_order integer,
  p_cta_kind text, p_cta_label text, p_offer_facts text, p_occasion text,
  p_publish boolean, p_object_path text, p_mime_type text, p_width_px integer,
  p_height_px integer, p_alt_en text, p_expected_content_version bigint,
  p_expected_copy_version bigint, p_expected_target_media_version bigint,
  p_attempt_key uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result jsonb;
  v_scope jsonb;
begin
  v_result := public.business_finalize_promotion_v104(
    p_business,p_promotion_id,null,p_name,p_tagline,p_description,p_terms,
    p_starts_at,p_ends_at,p_display_order,p_cta_kind,p_cta_label,
    p_offer_facts,p_occasion,p_publish,p_object_path,p_mime_type,
    p_width_px,p_height_px,p_alt_en,p_expected_content_version,
    p_expected_copy_version,p_expected_target_media_version,p_attempt_key
  );
  v_scope := app.save_promotion_scope_v155(
    p_business,p_promotion_id,p_scope_mode,p_branch_ids,p_operational_branch
  );
  -- V280: same correction on the finalize path. Publishing twice in a row without leaving the
  -- editor used to hit the identical stale-version refusal.
  v_result := app.promotion_version_sync_v280(p_business,p_promotion_id,p_attempt_key,v_result);
  return v_result || jsonb_build_object('branch_scope',v_scope);
end
$function$;

revoke all on function public.business_finalize_promotion_v155(
  uuid,uuid,text,uuid[],uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text,boolean,text,text,integer,integer,text,bigint,bigint,bigint,uuid)
  from public, anon;
grant execute on function public.business_finalize_promotion_v155(
  uuid,uuid,text,uuid[],uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text,boolean,text,text,integer,integer,text,bigint,bigint,bigint,uuid)
  to authenticated;

commit;

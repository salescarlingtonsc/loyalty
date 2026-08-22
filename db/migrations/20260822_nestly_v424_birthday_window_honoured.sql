-- nestly_v424 — the birthday window a customer is promised is the birthday window they get.
--
-- P0-3, go-live blocker. Two halves of the same feature disagreed about what a "birthday" is.
--
--   * The READ path, app.c45_customer_birthday_benefit_for_context, calls the FIVE-argument
--     app.c45_birthday_window and passes v_program.window_mode. In 'month' mode that resolves to
--     the whole Singapore calendar month, so the customer's card says "ready to activate" for
--     every day of their birthday month.
--   * The WRITE path, public.customer_activate_birthday_benefit, called the FOUR-argument
--     overload. That overload has no window_mode; it always applies window_days_before /
--     window_days_after. Every live birthday programme in production is window_mode='month' with
--     0/0 days, so the enforcement side collapsed the promised month to the single birthday date.
--
-- What that meant for a real customer: on any day of their birthday month except the birthday
-- itself, the card offered a button that answered 42501 "birthday benefits are unavailable". On
-- the birthday itself activation succeeded but wrote an entitlement whose valid_from/valid_until
-- span ONE day rather than the promised month — and that entitlement is immutable, so the wrong
-- promise would have been frozen into the customer's wallet for the year.
--
-- Owner ruling: the promise and the enforcement are identical. Month mode is accepted through the
-- whole Singapore birthday month; day-window mode honours before/after exactly as it always has.
--
-- Production state checked before writing this (2026-08-22): public.customer_birthday_entitlements
-- holds ZERO rows — nobody has ever completed an activation, which is itself corroboration of the
-- defect — so no entitlement backfill is needed and none is performed. One active birthday
-- programme is live on an active config version (business 8492e8d6…, window_mode='month', 0/0).
--
-- Callers of the 4-argument overload, swept across every SQL/PLPGSQL function in production:
--   1. public.customer_activate_birthday_benefit  — HAS window_mode in scope and drops it. Fixed
--                                                   here. This was the only defective caller.
--   2. app.c45_customer_birthday_benefit_for_context — already on the 5-argument overload in
--                                                   production; see section 2.
-- No redemption or staff path calls it: public.redeem_customer_birthday_benefit and
-- public.staff_get_customer_birthday_benefit work from the already-written entitlement's
-- valid_from/valid_until, so fixing the entitlement fixes them. The 4-argument overload is NOT
-- dropped — it is still the correct function for a caller that has no mode, and dropping a
-- resolvable name is how PL/pgSQL callers break silently at run time.

begin;

-- ============================================================================================
-- 1. ACTIVATION HONOURS THE MODE
-- ============================================================================================
-- Extracted from production with pg_get_functiondef and patched programmatically: exactly one
-- line differs from the live definition, the app.c45_birthday_window call, which gains
-- v_program.window_mode as its fifth argument. Everything else — the idempotency replay, the
-- participation gate, the `for update of bpv` programme lock, the unique_violation backstop —
-- is character for character what production runs today.
CREATE OR REPLACE FUNCTION public.customer_activate_birthday_benefit(p_business_slug text, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record; v_as_of timestamptz:=statement_timestamp(); v_program public.birthday_program_versions%rowtype;
  v_window record; v_entitlement public.customer_birthday_entitlements%rowtype;
  v_op public.customer_birthday_activation_operations%rowtype; v_request_hash text;
begin
  select * into v_context from app.c45_customer_birthday_context(p_business_slug) limit 1;
  if p_idempotency_key is null then raise exception 'birthday benefits are unavailable' using errcode='22023'; end if;
  v_request_hash:=app.c45_hash(jsonb_build_object('business_slug',lower(btrim(p_business_slug)))::text);
  select * into v_op from public.customer_birthday_activation_operations
   where identity_id=v_context.identity_id and business_id=v_context.business_id and idempotency_key=p_idempotency_key for share;
  if found then
    if v_op.request_hash is distinct from v_request_hash then raise exception 'birthday activation conflicts with an existing operation' using errcode='40001'; end if;
    select * into v_entitlement from public.customer_birthday_entitlements where id=v_op.entitlement_id;
    return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
  end if;
  if not exists(select 1 from public.customer_birthday_participation p where p.identity_id=v_context.identity_id and p.auth_user_id=auth.uid() and p.opted_in) then
    raise exception 'birthday benefits are unavailable' using errcode='42501';
  end if;
  select bpv.* into v_program from public.businesses b
   join public.loyalty_program_versions lpv on lpv.config_version_id=b.active_config_version_id and lpv.business_id=b.id and lpv.active
   join public.birthday_program_versions bpv on bpv.config_version_id=b.active_config_version_id and bpv.business_id=b.id and bpv.active
   where b.id=v_context.business_id and 'loyalty'=any(coalesce(b.enabled_modules,'{}'::text[]))
   order by bpv.sort,bpv.program_id limit 1 for update of bpv;
  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  -- nestly_v424: the fifth argument. Without it this call is the 4-argument overload, which knows
  -- only about window_days_before/after, and a month-mode programme silently enforced one day.
  select * into v_window from app.c45_birthday_window(v_context.birth_date,v_program.window_days_before,v_program.window_days_after,v_as_of,v_program.window_mode);
  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=v_context.business_id and client_id=v_context.client_id and birthday_year=v_window.birthday_year for update;
  if found then
    insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
    values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id);
    return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
  end if;
  insert into public.customer_birthday_entitlements(
    business_id,client_id,identity_id,config_version_id,birthday_program_version_id,birthday_year,
    status,valid_from,valid_until,benefit_snapshot
  ) values(
    v_context.business_id,v_context.client_id,v_context.identity_id,v_program.config_version_id,v_program.id,v_window.birthday_year,
    'available',v_window.valid_from,v_window.valid_until,app.c45_benefit_snapshot(v_program)
  ) returning * into v_entitlement;
  insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
  values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_context.business_id,auth.uid(),'ACTIVATE_BIRTHDAY_BENEFIT','customer_birthday_entitlements',v_entitlement.id,jsonb_build_object('status','available'));
  return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
exception when unique_violation then
  -- The per-customer/year uniqueness is the re-publish and concurrent-activate
  -- backstop. A caller retries through the same idempotency key for the exact
  -- immutable promise; changed inputs fail through the hash check above.
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=v_context.business_id and client_id=v_context.client_id and birthday_year=v_window.birthday_year;
  if v_entitlement.id is null then raise; end if;
  insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
  values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id)
  on conflict (identity_id,business_id,idempotency_key) do nothing;
  return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
end $function$;

revoke all on function public.customer_activate_birthday_benefit(text,uuid) from public, anon;
grant execute on function public.customer_activate_birthday_benefit(text,uuid) to authenticated, service_role;

-- ============================================================================================
-- 2. THE PROMISE SIDE, RE-ASSERTED (a no-op on production, a repair on any rebuilt database)
-- ============================================================================================
-- This is byte-identical to what production runs today: md5(pg_get_functiondef(...)) =
-- d3ec8f548d4182fc76ae25554b05898e both before and after. It is restated because v182's mode
-- patch to this function was applied straight to production and never committed as a migration —
-- a fresh replay of the repo's canonical chain produces the 4-argument version (md5
-- f556676959e1ca3df2734eb31de8f962), i.e. a rebuilt database would read the promise one day wide
-- while section 1 enforces a month. The two halves of a promise must not be able to drift apart
-- by which database you happened to build.
--
-- FOUR MORE functions carry the same undeposited v182 patch and are deliberately NOT touched
-- here — they are not this P0 and they belong in their own migration:
--   app.c45_clone_birthday_programs_on_draft, public.get_birthday_program_draft,
--   public.get_active_birthday_program, public.ensure_published_birthday_in_draft_v138.
CREATE OR REPLACE FUNCTION app.c45_customer_birthday_benefit_for_context(p_business_id uuid, p_client_id uuid, p_identity_id uuid, p_birth_date date, p_as_of timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_entitlement public.customer_birthday_entitlements%rowtype;
  v_program public.birthday_program_versions%rowtype;
  v_window record;
  v_opted_in boolean := false;
begin
  -- A current immutable promise wins even if the active programme has since
  -- changed. Its effective state is derived from the half-open validity range.
  select * into v_entitlement
    from public.customer_birthday_entitlements e
   where e.business_id = p_business_id and e.client_id = p_client_id
     and e.identity_id = p_identity_id and e.valid_until > p_as_of
   order by e.valid_until desc, e.activated_at desc
   limit 1;
  if found then
    -- An existing promise remains visible after opt-out until it expires or is
    -- reversed; participation only gates NEW activation.
    return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of);
  end if;
  select coalesce(p.opted_in, false) into v_opted_in
    from (select 1) one
    left join public.customer_birthday_participation p on p.identity_id = p_identity_id;
  select bpv.* into v_program
    from public.businesses b
    join public.loyalty_program_versions lpv
      on lpv.config_version_id = b.active_config_version_id
     and lpv.business_id = b.id and lpv.active
    join public.birthday_program_versions bpv
      on bpv.config_version_id = b.active_config_version_id
     and bpv.business_id = b.id and bpv.active
   where b.id = p_business_id
     and 'loyalty' = any(coalesce(b.enabled_modules, '{}'::text[]))
   order by bpv.sort, bpv.program_id
   limit 1;
  if found then
    select * into v_window
      from app.c45_birthday_window(p_birth_date, v_program.window_days_before,
        v_program.window_days_after, p_as_of, v_program.window_mode);
    if found then
      -- Once the current SG birthday window is known, the matching immutable
      -- promise must be projected even when its end instant has elapsed. This
      -- produces effective `expired` without a write inside a failing action.
      select * into v_entitlement
        from public.customer_birthday_entitlements e
       where e.business_id = p_business_id and e.client_id = p_client_id
         and e.identity_id = p_identity_id and e.birthday_year = v_window.birthday_year
       order by e.activated_at desc
       limit 1;
      if found then return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of); end if;
      if coalesce(v_opted_in, false) then
        return jsonb_build_object(
          'label', v_program.customer_label,
          'description', v_program.customer_description,
          'terms', v_program.customer_terms,
          'kind', v_program.fulfillment_kind,
          'display', case when v_program.fulfillment_kind = 'discount_pct'
            then trim(to_char(v_program.discount_percent, 'FM990D00')) || '% off'
            else v_program.manual_item end,
          'status', 'ready_to_activate',
          'validity', jsonb_build_object('available_from', v_window.valid_from, 'available_until', v_window.valid_until),
          'cta', 'activate'
        );
      end if;
    end if;
  end if;
  -- Outside the current birthday window, retain the most recent immutable
  -- promise as customer history. `c45_safe_birthday_entitlement` derives an
  -- effective expired state from valid_until; no failed redemption writes it.
  select * into v_entitlement
    from public.customer_birthday_entitlements e
   where e.business_id = p_business_id and e.client_id = p_client_id
     and e.identity_id = p_identity_id
   order by e.birthday_year desc, e.valid_until desc, e.activated_at desc
   limit 1;
  if found then return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of); end if;
  return null;
end $function$;

revoke all on function app.c45_customer_birthday_benefit_for_context(uuid,uuid,uuid,date,timestamptz)
  from public, anon, authenticated;

-- ============================================================================================
-- 3. SAVING A BIRTHDAY PROGRAMME IS ONE TRANSACTION, NOT THREE ROUND TRIPS
-- ============================================================================================
-- P1, owner-locked. The birthday editor saves through three separate RPCs —
-- create_loyalty_config_draft -> save_birthday_program_draft -> publish_loyalty_config. A tab
-- closed, a dropped connection or a 500 between the second and the third leaves a draft config
-- version holding the owner's edit and an active config version that still holds the old one:
-- the owner is looking at what they saved and every customer is being served something else.
--
-- The three functions are all plpgsql SECURITY DEFINER with no COMMIT / no transaction control
-- (verified against the live bodies), so they compose inside one transaction unchanged. Nothing
-- is reimplemented here — reimplementing publish would be a second copy of the stamp-card,
-- taxonomy, program-rule and tier-carry rules it enforces, which is exactly how two copies of a
-- rule drift apart.

create table if not exists public.birthday_program_save_operations_v424 (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references public.businesses(id) on delete cascade,
  actor              uuid,
  idempotency_key    text not null,
  request_hash       text not null,
  program_id         uuid not null,
  config_version_id  uuid,
  result             jsonb,
  created_at         timestamptz not null default now(),
  unique (business_id, idempotency_key)
);

-- Closed exactly like every other birthday table (customer_birthday_entitlements,
-- birthday_program_draft_operations, customer_birthday_activation_operations): RLS on, no
-- policy, no grant. The SECURITY DEFINER function below is the only reader and the only writer;
-- a browser holding an authenticated JWT cannot see or forge an operation receipt.
alter table public.birthday_program_save_operations_v424 enable row level security;
revoke all privileges on table public.birthday_program_save_operations_v424
  from public, anon, authenticated;

comment on table public.birthday_program_save_operations_v424 is
  'v424: idempotency receipts for public.business_save_birthday_program_v424. One row per '
  '(business, idempotency key); a retry of the same key returns the stored result instead of '
  'publishing a second identical config version.';

create or replace function public.business_save_birthday_program_v424(
  p_business uuid, p_payload jsonb, p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor       uuid := auth.uid();
  v_key         text := btrim(coalesce(p_idempotency_key,''));
  v_program     jsonb;
  v_program_id  uuid;
  v_request     text;
  v_replay      public.birthday_program_save_operations_v424%rowtype;
  v_version     uuid;
  v_hash        text;
  v_result      jsonb;
begin
  if p_business is null or p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or length(v_key) not between 8 and 200 then
    raise exception 'birthday save request is invalid' using errcode = '22023';
  end if;
  -- The same gate save_birthday_program_draft and publish_loyalty_config apply, applied once and
  -- up front so an unauthorised caller never reaches the point of creating a draft version.
  if v_actor is null or not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;

  -- program_id travels BESIDE the programme fields, never inside them: save_birthday_program_draft
  -- rejects any key outside its own whitelist, and that whitelist is the contract this payload
  -- must match exactly. Everything else is forwarded untouched and validated by that function.
  v_program := p_payload - 'program_id';
  if exists (select 1 from jsonb_object_keys(v_program) k where k not in (
    'active','customer_label','customer_description','customer_terms','fulfillment_kind',
    'discount_percent','manual_item','window_days_before','window_days_after','sort','window_mode'
  )) then
    raise exception 'birthday program contains unsupported fields' using errcode = '22023';
  end if;

  -- Serialise concurrent saves for this firm before reading the receipt, so the second caller
  -- takes a fresh snapshot after the first has committed and replays instead of publishing twice.
  -- publish_loyalty_config takes the same lock; re-taking it inside one transaction is free.
  perform 1 from public.businesses where id = p_business for update;

  v_request := app.c45_hash(jsonb_build_object('business',p_business,'payload',p_payload)::text);
  select * into v_replay from public.birthday_program_save_operations_v424
   where business_id = p_business and idempotency_key = v_key;
  if found then
    -- Same key, different edit: the caller reused a key it must not reuse. Refusing is the only
    -- honest answer — publishing would silently discard one of the two edits.
    if v_replay.request_hash is distinct from v_request then
      raise exception 'birthday save conflicts with an existing operation' using errcode = '40001';
    end if;
    return coalesce(v_replay.result,'{}'::jsonb) || jsonb_build_object('replayed', true);
  end if;

  -- Which programme is being edited. A caller may name it; otherwise the firm's live birthday
  -- programme is resolved server-side, and only a firm that has never had one gets a new id.
  -- The browser inventing a uuid on every save is how a second birthday programme gets created.
  v_program_id := coalesce(
    nullif(p_payload->>'program_id','')::uuid,
    (select bpv.program_id
       from public.birthday_program_versions bpv
       join public.businesses b
         on b.id = bpv.business_id and b.active_config_version_id = bpv.config_version_id
      where bpv.business_id = p_business
      order by bpv.sort, bpv.program_id
      limit 1),
    (select bp.id from public.birthday_programs bp
      where bp.business_id = p_business order by bp.created_at, bp.id limit 1),
    gen_random_uuid());

  v_version := (public.create_loyalty_config_draft(
    p_business, null, 'birthday_editor_v424')::jsonb->>'version_id')::uuid;
  if v_version is null then
    raise exception 'birthday save could not open a draft' using errcode = '55000';
  end if;
  -- Read the hash back rather than assuming one: create_loyalty_config_draft writes a hash and
  -- then app.refresh_loyalty_config_snapshot rewrites it, so no value known before this is current.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_version;
  perform public.save_birthday_program_draft(v_version, v_program_id, v_program, v_hash);
  perform public.publish_loyalty_config(v_version);

  v_result := jsonb_build_object(
    'status','published','version_id',v_version,'program_id',v_program_id);
  insert into public.birthday_program_save_operations_v424(
    business_id,actor,idempotency_key,request_hash,program_id,config_version_id,result)
  values (p_business,v_actor,v_key,v_request,v_program_id,v_version,v_result);
  return v_result || jsonb_build_object('replayed', false);
end $$;

comment on function public.business_save_birthday_program_v424(uuid,jsonb,text) is
  'v424: saves AND publishes a birthday programme in one transaction. p_payload carries exactly '
  'the keys save_birthday_program_draft accepts (active, customer_label, customer_description, '
  'customer_terms, fulfillment_kind, discount_percent, manual_item, window_days_before, '
  'window_days_after, sort, window_mode) plus an optional program_id. Returns '
  '{status, version_id, program_id, replayed}.';

revoke all on function public.business_save_birthday_program_v424(uuid,jsonb,text) from public, anon;
grant execute on function public.business_save_birthday_program_v424(uuid,jsonb,text) to authenticated;

commit;

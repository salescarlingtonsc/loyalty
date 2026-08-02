-- PEEKAA V138 — exact reward edit continuity
--
-- A published reward can be newer than an already-open draft. This function
-- copies only the selected reward and its eligibility into that draft so the
-- owner can edit the row they clicked without discarding unrelated draft work.
-- It never publishes and is safe to replay.

begin;

-- Google OAuth uses the same provider endpoint for sign-in and signup. A
-- consent-free sign-in must not silently become a new business account, while
-- signup must preserve durable proof of the exact legal documents accepted
-- before the browser leaves for Google. Attempts contain no PII, expire after
-- 30 minutes and are consumed once by the resulting authenticated Google user.
create table app.business_google_oauth_attempts_v138(
  token_sha256 text primary key check(token_sha256~'^[0-9a-f]{64}$'),
  idempotency_key uuid not null unique,
  request_sha256 text not null check(request_sha256~'^[0-9a-f]{64}$'),
  terms_version text not null,
  terms_sha256 text not null check(terms_sha256~'^[0-9a-f]{64}$'),
  privacy_version text not null,
  privacy_sha256 text not null check(privacy_sha256~'^[0-9a-f]{64}$'),
  accepted_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '30 minutes',
  consumed_by uuid,
  consumed_at timestamptz,
  constraint business_google_oauth_attempts_v138_expiry
    check(expires_at>accepted_at and expires_at<=accepted_at+interval '30 minutes'),
  constraint business_google_oauth_attempts_v138_consumption
    check((consumed_by is null and consumed_at is null)
       or (consumed_by is not null and consumed_at is not null))
);
alter table app.business_google_oauth_attempts_v138 enable row level security;
revoke all privileges on table app.business_google_oauth_attempts_v138
  from public,anon,authenticated;

create table app.business_account_legal_acceptances_v138(
  id bigint generated always as identity primary key,
  auth_user_id uuid not null,
  source text not null check(source in ('google_oauth_signup')),
  terms_version text not null,
  terms_sha256 text not null check(terms_sha256~'^[0-9a-f]{64}$'),
  privacy_version text not null,
  privacy_sha256 text not null check(privacy_sha256~'^[0-9a-f]{64}$'),
  accepted_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  idempotency_key uuid not null,
  request_sha256 text not null check(request_sha256~'^[0-9a-f]{64}$'),
  unique(source,idempotency_key),
  unique(source,auth_user_id,idempotency_key)
);
alter table app.business_account_legal_acceptances_v138 enable row level security;
revoke all privileges on table app.business_account_legal_acceptances_v138
  from public,anon,authenticated;

create or replace function public.begin_business_google_oauth_signup_v138(
  p_attempt_token text,
  p_idempotency_key uuid,
  p_terms_version text,
  p_terms_sha256 text,
  p_privacy_version text,
  p_privacy_sha256 text,
  p_accepted boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_token text:=lower(btrim(coalesce(p_attempt_token,'')));
  v_token_hash text;
  v_request_hash text;
  v_existing app.business_google_oauth_attempts_v138%rowtype;
  v_terms app.customer_legal_documents%rowtype;
  v_privacy app.customer_legal_documents%rowtype;
begin
  if auth.uid() is not null or p_accepted is distinct from true
     or p_idempotency_key is null
     or v_token!~'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'valid consented Google signup attempt required' using errcode='22023';
  end if;
  select * into v_terms from app.customer_legal_documents
   where document_key='terms' and active for share;
  select * into v_privacy from app.customer_legal_documents
   where document_key='privacy' and active for share;
  if v_terms.document_version is distinct from p_terms_version
     or v_terms.document_sha256 is distinct from lower(p_terms_sha256)
     or v_privacy.document_version is distinct from p_privacy_version
     or v_privacy.document_sha256 is distinct from lower(p_privacy_sha256) then
    raise exception 'current Terms and Privacy Policy must be accepted' using errcode='22023';
  end if;
  v_token_hash:=app.v31_sha256_hex(v_token);
  v_request_hash:=app.v31_sha256_hex(
    'v138.google-oauth-signup:'||v_token_hash||':'||p_terms_version||':'
    ||lower(p_terms_sha256)||':'||p_privacy_version||':'||lower(p_privacy_sha256)
  );
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,138));
  select * into v_existing from app.business_google_oauth_attempts_v138
   where idempotency_key=p_idempotency_key for update;
  if found then
    if v_existing.request_sha256<>v_request_hash then
      raise exception 'Google signup attempt key was reused for different consent'
        using errcode='22023';
    end if;
    return jsonb_build_object('accepted',true,'expires_at',v_existing.expires_at,
      'replayed',true,'published',false);
  end if;
  if exists(select 1 from app.business_google_oauth_attempts_v138
      where token_sha256=v_token_hash) then
    raise exception 'Google signup attempt token is already in use' using errcode='23505';
  end if;
  insert into app.business_google_oauth_attempts_v138(
    token_sha256,idempotency_key,request_sha256,
    terms_version,terms_sha256,privacy_version,privacy_sha256
  ) values(
    v_token_hash,p_idempotency_key,v_request_hash,
    v_terms.document_version,v_terms.document_sha256,
    v_privacy.document_version,v_privacy.document_sha256
  ) returning * into v_existing;
  return jsonb_build_object('accepted',true,'expires_at',v_existing.expires_at,
    'replayed',false,'published',false);
end
$$;

create or replace function public.complete_business_google_oauth_v138(
  p_intent text,
  p_attempt_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_token_hash text;
  v_attempt app.business_google_oauth_attempts_v138%rowtype;
begin
  if v_actor is null or p_intent not in ('signin','signup') then
    raise exception 'authenticated Google OAuth admission required' using errcode='28000';
  end if;
  if not exists(select 1 from auth.identities identity_row
      where identity_row.user_id=v_actor and identity_row.provider='google') then
    raise exception 'Google identity required' using errcode='42501';
  end if;
  if p_intent='signin' then
    if not exists(select 1 from public.staff staff_row
        where staff_row.user_id=v_actor and staff_row.active) then
      raise exception 'existing active business account required; use signup first'
        using errcode='42501';
    end if;
    return jsonb_build_object('admitted',true,'intent','signin',
      'legal_recorded',false,'replayed',false);
  end if;
  if lower(btrim(coalesce(p_attempt_token,'')))
       !~'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'server-recorded Google signup consent required' using errcode='42501';
  end if;
  v_token_hash:=app.v31_sha256_hex(lower(btrim(p_attempt_token)));
  select * into v_attempt from app.business_google_oauth_attempts_v138
   where token_sha256=v_token_hash for update;
  if not found then
    raise exception 'server-recorded Google signup consent required' using errcode='42501';
  end if;
  if v_attempt.consumed_by is not null then
    if v_attempt.consumed_by<>v_actor or not exists(
      select 1 from app.business_account_legal_acceptances_v138 acceptance
       where acceptance.source='google_oauth_signup'
         and acceptance.auth_user_id=v_actor
         and acceptance.idempotency_key=v_attempt.idempotency_key
         and acceptance.request_sha256=v_attempt.request_sha256
    ) then
      raise exception 'Google signup consent attempt was already consumed'
        using errcode='42501';
    end if;
    return jsonb_build_object('admitted',true,'intent','signup',
      'legal_recorded',true,'replayed',true);
  end if;
  if v_attempt.expires_at<=now() then
    raise exception 'Google signup consent attempt expired' using errcode='42501';
  end if;
  if not exists(select 1 from app.customer_legal_documents document
      where document.document_key='terms' and document.active
        and document.document_version=v_attempt.terms_version
        and document.document_sha256=v_attempt.terms_sha256)
     or not exists(select 1 from app.customer_legal_documents document
      where document.document_key='privacy' and document.active
        and document.document_version=v_attempt.privacy_version
        and document.document_sha256=v_attempt.privacy_sha256) then
    raise exception 'accepted legal documents are no longer current' using errcode='42501';
  end if;
  update app.business_google_oauth_attempts_v138
     set consumed_by=v_actor,consumed_at=now()
   where token_sha256=v_token_hash and consumed_by is null;
  if not found then
    raise exception 'Google signup consent attempt could not be consumed'
      using errcode='40001';
  end if;
  insert into app.business_account_legal_acceptances_v138(
    auth_user_id,source,terms_version,terms_sha256,
    privacy_version,privacy_sha256,accepted_at,idempotency_key,request_sha256
  ) values(
    v_actor,'google_oauth_signup',v_attempt.terms_version,v_attempt.terms_sha256,
    v_attempt.privacy_version,v_attempt.privacy_sha256,v_attempt.accepted_at,
    v_attempt.idempotency_key,v_attempt.request_sha256
  );
  return jsonb_build_object('admitted',true,'intent','signup',
    'legal_recorded',true,'replayed',false);
end
$$;

-- The legacy Loyalty row guard predates the consolidated Grow workspace. Keep
-- its default fail-closed rule, with one narrowly scoped exception for the
-- shared-draft function below: it may clone the unchanged published Loyalty
-- row while a retention-authorized owner creates the version container.
create or replace function app.c45_loyalty_program_version_write_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid:=case when tg_op='DELETE' then old.business_id else new.business_id end;
  v_config uuid:=case when tg_op='DELETE' then old.config_version_id else new.config_version_id end;
  v_status text;
  v_shared_clone boolean:=false;
begin
  select status into v_status from public.firm_config_versions where id=v_config;
  v_shared_clone:=
    nullif(current_setting('app.v138_grow_draft_id',true),'')=v_config::text
    and nullif(current_setting('app.v138_grow_draft_actor',true),'')=coalesce(auth.uid()::text,'')
    and app.is_salon_owner(v_business)
    and app.can_module_write(v_business,'retention');
  if v_status='draft' and not app.c45_owner_loyalty_write(v_business)
     and not v_shared_clone then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create or replace function public.create_grow_config_draft_v138(
  p_business uuid,
  p_based_on uuid default null,
  p_source text default 'grow_shared_edit'
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_base uuid;
  v_existing public.firm_config_versions%rowtype;
  v_typed public.loyalty_program_versions%rowtype;
  v_id uuid;
  v_no integer;
  v_snapshot_hash text;
begin
  if v_actor is null or not app.is_salon_owner(p_business)
     or not (
       app.can_module_write(p_business,'loyalty')
       or app.can_module_write(p_business,'retention')
     ) then
    raise exception 'owner Grow configuration access required' using errcode='42501';
  end if;
  if p_source not in ('grow_shared_edit','grow_retention_edit','grow_reward_edit') then
    raise exception 'invalid Grow draft source' using errcode='22023';
  end if;

  perform 1 from public.businesses where id=p_business for update;
  if not found then
    raise exception 'business is unavailable' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('v138:grow-draft:'||p_business::text,0));
  v_base:=coalesce(
    p_based_on,
    app.active_config_version(p_business),
    (select current_config_version_id from public.loyalty_programs where business_id=p_business)
  );
  if v_base is null or not exists(
    select 1 from public.firm_config_versions
     where id=v_base and business_id=p_business and status='published'
  ) then
    raise exception 'published base configuration not found' using errcode='22023';
  end if;

  select * into v_existing from public.firm_config_versions
   where business_id=p_business and based_on_version_id=v_base and status='draft'
   order by version_no desc limit 1 for update;
  if found then
    return jsonb_build_object(
      'version_id',v_existing.id,'version_no',v_existing.version_no,
      'status','draft','snapshot_hash',v_existing.snapshot_hash,
      'replayed',true,'published',false
    );
  end if;

  select * into v_typed from public.loyalty_program_versions
   where config_version_id=v_base and business_id=p_business;
  if not found then
    raise exception 'base Loyalty configuration not found' using errcode='22023';
  end if;
  select coalesce(max(version_no),0)+1 into v_no
    from public.firm_config_versions where business_id=p_business;
  v_id:=gen_random_uuid();
  insert into public.firm_config_versions(
    id,business_id,version_no,status,based_on_version_id,source,snapshot_hash,created_by
  ) values(
    v_id,p_business,v_no,'draft',v_base,p_source,
    md5((to_jsonb(v_typed)-'config_version_id')::text),v_actor
  );
  perform set_config('app.v138_grow_draft_id',v_id::text,true);
  perform set_config('app.v138_grow_draft_actor',v_actor::text,true);
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,
    stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days
  ) select
    v_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,
    stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days
  from public.loyalty_program_versions
  where config_version_id=v_base and business_id=p_business;
  perform set_config('app.v138_grow_draft_id','',true);
  perform set_config('app.v138_grow_draft_actor','',true);
  insert into public.loyalty_tier_versions(
    tier_id,config_version_id,business_id,name,threshold,
    points_multiplier,perk_note,sort,active
  ) select
    tier_id,v_id,business_id,name,threshold,
    points_multiplier,perk_note,sort,active
  from public.loyalty_tier_versions
  where config_version_id=v_base and business_id=p_business;
  perform app.refresh_loyalty_config_snapshot(v_id);
  select snapshot_hash into v_snapshot_hash
    from public.firm_config_versions where id=v_id;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'CREATE_GROW_DRAFT','firm_config_versions',v_id,
    jsonb_build_object('based_on_version_id',v_base,'source',p_source,'published',false));
  return jsonb_build_object(
    'version_id',v_id,'version_no',v_no,'status','draft',
    'snapshot_hash',v_snapshot_hash,'replayed',false,'published',false
  );
end $$;

create or replace function public.ensure_published_reward_in_draft_v138(
  p_config_version uuid,
  p_reward uuid,
  p_expected_snapshot_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_draft public.firm_config_versions%rowtype;
  v_source public.loyalty_reward_versions%rowtype;
  v_active_config uuid;
  v_new_reward_version uuid;
  v_snapshot_hash text;
  v_replayed boolean := false;
begin
  select *
    into v_draft
    from public.firm_config_versions
   where id = p_config_version
   for update;

  if not found or not app.c45_owner_loyalty_write(v_draft.business_id) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;
  if v_draft.status <> 'draft' then
    raise exception 'only a draft may receive an editable reward' using errcode = '22023';
  end if;
  select id
    into v_new_reward_version
    from public.loyalty_reward_versions
   where config_version_id = p_config_version
     and business_id = v_draft.business_id
     and reward_id = p_reward;

  if found then
    return jsonb_build_object(
      'reward_id', p_reward,
      'reward_version_id', v_new_reward_version,
      'config_version_id', p_config_version,
      'snapshot_hash', v_draft.snapshot_hash,
      'replayed', true,
      'published', false
    );
  end if;

  -- Replay is resolved before the optimistic-hash check. If the first call
  -- committed but its HTTP response was lost, the browser necessarily retries
  -- with the old hash; the already materialized exact row is the durable proof.
  if p_expected_snapshot_hash is not null
     and v_draft.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before editing this reward'
      using errcode = '40001';
  end if;

  select active_config_version_id
    into v_active_config
    from public.businesses
   where id = v_draft.business_id
   for share;

  select *
    into v_source
    from public.loyalty_reward_versions
   where config_version_id = v_active_config
     and business_id = v_draft.business_id
     and reward_id = p_reward;

  if not found then
    raise exception 'published reward is unavailable' using errcode = '22023';
  end if;

  insert into public.loyalty_reward_versions (
    reward_id, business_id, config_version_id, internal_name, customer_name,
    description, fulfillment_kind, taxonomy_label, cost_points, credit_cents,
    estimated_cost_cents, active, sort, claim_available_from, claim_available_until,
    entitlement_expiry_days, instructions, terms, image_ref, usage_limit
  )
  values (
    v_source.reward_id, v_source.business_id, p_config_version, v_source.internal_name,
    v_source.customer_name, v_source.description, v_source.fulfillment_kind,
    v_source.taxonomy_label, v_source.cost_points, v_source.credit_cents,
    v_source.estimated_cost_cents, v_source.active, v_source.sort,
    v_source.claim_available_from, v_source.claim_available_until,
    v_source.entitlement_expiry_days, v_source.instructions, v_source.terms,
    v_source.image_ref, v_source.usage_limit
  )
  on conflict (reward_id, config_version_id) do nothing
  returning id into v_new_reward_version;

  if v_new_reward_version is null then
    select id
      into v_new_reward_version
      from public.loyalty_reward_versions
     where config_version_id = p_config_version
       and business_id = v_draft.business_id
       and reward_id = p_reward;
    v_replayed := true;
  end if;

  insert into public.loyalty_reward_branches
    (reward_version_id, reward_id, business_id, branch_id)
  select v_new_reward_version, p_reward, v_draft.business_id, source.branch_id
    from public.loyalty_reward_branches source
   where source.reward_version_id = v_source.id
  on conflict do nothing;

  insert into public.loyalty_reward_services
    (reward_version_id, reward_id, business_id, service_id)
  select v_new_reward_version, p_reward, v_draft.business_id, source.service_id
    from public.loyalty_reward_services source
   where source.reward_version_id = v_source.id
  on conflict do nothing;

  insert into public.loyalty_reward_products
    (reward_version_id, reward_id, business_id, product_id)
  select v_new_reward_version, p_reward, v_draft.business_id, source.product_id
    from public.loyalty_reward_products source
   where source.reward_version_id = v_source.id
  on conflict do nothing;

  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash
    into v_snapshot_hash
    from public.firm_config_versions
   where id = p_config_version;

  insert into public.audit_log
    (business_id, actor, action, entity, entity_id, detail)
  values (
    v_draft.business_id, auth.uid(), 'MATERIALIZE_REWARD_DRAFT',
    'loyalty_reward_versions', p_reward,
    jsonb_build_object(
      'draft_config_version_id', p_config_version,
      'source_config_version_id', v_active_config,
      'reward_version_id', v_new_reward_version,
      'published', false
    )
  );

  return jsonb_build_object(
    'reward_id', p_reward,
    'reward_version_id', v_new_reward_version,
    'config_version_id', p_config_version,
    'snapshot_hash', v_snapshot_hash,
    'replayed', v_replayed,
    'published', false
  );
end $$;

create or replace function public.ensure_published_retention_in_draft_v138(
  p_config_version uuid,
  p_program uuid,
  p_expected_snapshot_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_draft public.firm_config_versions%rowtype;
  v_source public.retention_program_versions%rowtype;
  v_active_config uuid;
  v_new_version uuid;
  v_snapshot_hash text;
begin
  select * into v_draft from public.firm_config_versions
   where id=p_config_version for update;
  if not found or not app.is_salon_owner(v_draft.business_id)
     or not app.can_module_write(v_draft.business_id,'retention') then
    raise exception 'owner retention configuration access required' using errcode='42501';
  end if;
  if v_draft.status<>'draft' then
    raise exception 'only a draft may receive an editable bring-back rule' using errcode='22023';
  end if;
  select id into v_new_version from public.retention_program_versions
   where config_version_id=p_config_version and business_id=v_draft.business_id
     and program_id=p_program;
  if found then
    return jsonb_build_object('program_id',p_program,
      'retention_program_version_id',v_new_version,
      'config_version_id',p_config_version,'snapshot_hash',v_draft.snapshot_hash,
      'replayed',true,'published',false);
  end if;
  if p_expected_snapshot_hash is not null
     and v_draft.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before editing this bring-back rule'
      using errcode='40001';
  end if;
  select active_config_version_id into v_active_config
    from public.businesses where id=v_draft.business_id for share;
  select * into v_source from public.retention_program_versions
   where config_version_id=v_active_config and business_id=v_draft.business_id
     and program_id=p_program;
  if not found then
    raise exception 'published bring-back rule is unavailable' using errcode='22023';
  end if;
  insert into public.retention_program_versions(
    program_id,config_version_id,business_id,name,active,goal_visits,period_days,
    starts_on,reward_taxonomy_id,fulfillment_kind,discount_percent,credit_cents,
    manual_item,sort,customer_description,staff_description
  ) values(
    v_source.program_id,p_config_version,v_source.business_id,v_source.name,
    v_source.active,v_source.goal_visits,v_source.period_days,v_source.starts_on,
    v_source.reward_taxonomy_id,v_source.fulfillment_kind,v_source.discount_percent,
    v_source.credit_cents,v_source.manual_item,v_source.sort,
    v_source.customer_description,v_source.staff_description
  ) on conflict(program_id,config_version_id) do nothing returning id into v_new_version;
  if v_new_version is null then
    select id into v_new_version from public.retention_program_versions
     where config_version_id=p_config_version and business_id=v_draft.business_id
       and program_id=p_program;
  end if;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_snapshot_hash from public.firm_config_versions
   where id=p_config_version;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_draft.business_id,auth.uid(),'MATERIALIZE_RETENTION_DRAFT',
    'retention_program_versions',p_program,jsonb_build_object(
      'draft_config_version_id',p_config_version,
      'source_config_version_id',v_active_config,
      'retention_program_version_id',v_new_version,'published',false));
  return jsonb_build_object('program_id',p_program,
    'retention_program_version_id',v_new_version,
    'config_version_id',p_config_version,'snapshot_hash',v_snapshot_hash,
    'replayed',false,'published',false);
end $$;

create or replace function public.ensure_published_birthday_in_draft_v138(
  p_config_version uuid,
  p_program uuid,
  p_expected_snapshot_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_draft public.firm_config_versions%rowtype;
  v_source public.birthday_program_versions%rowtype;
  v_active_config uuid;
  v_new_version uuid;
  v_snapshot_hash text;
begin
  select * into v_draft from public.firm_config_versions
   where id=p_config_version for update;
  if not found or not app.c45_owner_loyalty_write(v_draft.business_id) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_draft.status<>'draft' then
    raise exception 'only a draft may receive an editable birthday benefit' using errcode='22023';
  end if;
  select id into v_new_version from public.birthday_program_versions
   where config_version_id=p_config_version and business_id=v_draft.business_id
     and program_id=p_program;
  if found then
    return jsonb_build_object('program_id',p_program,
      'birthday_program_version_id',v_new_version,
      'config_version_id',p_config_version,'snapshot_hash',v_draft.snapshot_hash,
      'replayed',true,'published',false);
  end if;
  if p_expected_snapshot_hash is not null
     and v_draft.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before editing this birthday benefit'
      using errcode='40001';
  end if;
  select active_config_version_id into v_active_config
    from public.businesses where id=v_draft.business_id for share;
  select * into v_source from public.birthday_program_versions
   where config_version_id=v_active_config and business_id=v_draft.business_id
     and program_id=p_program;
  if not found then
    raise exception 'published birthday benefit is unavailable' using errcode='22023';
  end if;
  if exists(select 1 from public.birthday_program_versions
      where config_version_id=p_config_version and business_id=v_draft.business_id) then
    raise exception 'the draft already contains another birthday benefit' using errcode='40001';
  end if;
  insert into public.birthday_program_versions(
    program_id,config_version_id,business_id,active,customer_label,
    customer_description,customer_terms,fulfillment_kind,discount_percent,
    manual_item,window_days_before,window_days_after,sort
  ) values(
    v_source.program_id,p_config_version,v_source.business_id,v_source.active,
    v_source.customer_label,v_source.customer_description,v_source.customer_terms,
    v_source.fulfillment_kind,v_source.discount_percent,v_source.manual_item,
    v_source.window_days_before,v_source.window_days_after,v_source.sort
  ) on conflict(program_id,config_version_id) do nothing returning id into v_new_version;
  if v_new_version is null then
    select id into v_new_version from public.birthday_program_versions
     where config_version_id=p_config_version and business_id=v_draft.business_id
       and program_id=p_program;
  end if;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_snapshot_hash from public.firm_config_versions
   where id=p_config_version;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_draft.business_id,auth.uid(),'MATERIALIZE_BIRTHDAY_DRAFT',
    'birthday_program_versions',p_program,jsonb_build_object(
      'draft_config_version_id',p_config_version,
      'source_config_version_id',v_active_config,
      'birthday_program_version_id',v_new_version,'published',false));
  return jsonb_build_object('program_id',p_program,
    'birthday_program_version_id',v_new_version,
    'config_version_id',p_config_version,'snapshot_hash',v_snapshot_hash,
    'replayed',false,'published',false);
end $$;

revoke all on function public.ensure_published_reward_in_draft_v138(uuid,uuid,text)
  from public, anon;
grant execute on function public.ensure_published_reward_in_draft_v138(uuid,uuid,text)
  to authenticated;
revoke all on function public.ensure_published_retention_in_draft_v138(uuid,uuid,text)
  from public, anon;
grant execute on function public.ensure_published_retention_in_draft_v138(uuid,uuid,text)
  to authenticated;
revoke all on function public.ensure_published_birthday_in_draft_v138(uuid,uuid,text)
  from public, anon;
grant execute on function public.ensure_published_birthday_in_draft_v138(uuid,uuid,text)
  to authenticated;
revoke all on function public.create_grow_config_draft_v138(uuid,uuid,text)
  from public, anon;
grant execute on function public.create_grow_config_draft_v138(uuid,uuid,text)
  to authenticated;
revoke all on function public.begin_business_google_oauth_signup_v138(
  text,uuid,text,text,text,text,boolean
) from public,authenticated;
grant execute on function public.begin_business_google_oauth_signup_v138(
  text,uuid,text,text,text,text,boolean
) to anon;
revoke all on function public.complete_business_google_oauth_v138(text,text)
  from public,anon;
grant execute on function public.complete_business_google_oauth_v138(text,text)
  to authenticated;

comment on function public.ensure_published_reward_in_draft_v138(uuid,uuid,text) is
  'Owner-only V138 continuity: idempotently copies one currently published reward and eligibility into a stale editable draft; never publishes.';
comment on function public.ensure_published_retention_in_draft_v138(uuid,uuid,text) is
  'Owner-only V138 continuity: idempotently copies one currently published Bring-back rule into a stale editable draft; never publishes.';
comment on function public.ensure_published_birthday_in_draft_v138(uuid,uuid,text) is
  'Owner-only V138 continuity: idempotently copies the currently published birthday benefit into a stale editable draft; never publishes.';
comment on function public.create_grow_config_draft_v138(uuid,uuid,text) is
  'Owner-only V138 shared Grow draft creation for Loyalty or retention writers; exact replay returns the existing draft and never publishes.';
comment on function public.begin_business_google_oauth_signup_v138(
  text,uuid,text,text,text,text,boolean
) is 'Anonymous no-PII V138 pre-OAuth consent attempt pinned to the active Terms and Privacy hashes; expires after 30 minutes.';
comment on function public.complete_business_google_oauth_v138(text,text) is
  'Authenticated Google-only V138 admission: existing active staff may sign in without consent; signup consumes one server-recorded legal acceptance.';

commit;

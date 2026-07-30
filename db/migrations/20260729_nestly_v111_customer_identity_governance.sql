-- NESTLY v111 — CUSTOMER IDENTITY GOVERNANCE
--
-- Local-only forward migration. This adds an owner-governed, append-only
-- correction workflow over business-owned customer records. It never deletes
-- or rewrites clients, sales, points, rewards, redemptions, or verified links.
-- Current attribution is resolved from append-only approval/reversal events.

begin;

create table public.customer_identity_proposals_v111 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  branch_id uuid,
  source_client_id uuid not null,
  target_client_id uuid not null,
  source_identity_id uuid references public.customer_identities(id) on delete restrict,
  target_identity_id uuid not null references public.customer_identities(id) on delete restrict,
  target_link_id uuid not null references public.customer_links(id) on delete restrict,
  reason text not null check (length(btrim(reason)) between 3 and 500),
  status text not null default 'proposed'
    check (status in ('proposed','proof_attached','approved','rejected','reversed')),
  proposed_by uuid not null references auth.users(id) on delete restrict,
  proposed_at timestamptz not null default statement_timestamp(),
  proof_attached_at timestamptz,
  decided_at timestamptz,
  reversed_at timestamptz,
  updated_at timestamptz not null default statement_timestamp(),
  constraint customer_identity_proposals_v111_source_business_fk
    foreign key (source_client_id,business_id)
    references public.clients(id,business_id) on delete restrict,
  constraint customer_identity_proposals_v111_target_business_fk
    foreign key (target_client_id,business_id)
    references public.clients(id,business_id) on delete restrict,
  constraint customer_identity_proposals_v111_target_link_client_fk
    foreign key (target_link_id,business_id,target_client_id)
    references public.customer_links(id,business_id,client_id) on delete restrict,
  constraint customer_identity_proposals_v111_target_link_identity_fk
    foreign key (target_link_id,business_id,target_identity_id)
    references public.customer_links(id,business_id,identity_id) on delete restrict,
  constraint customer_identity_proposals_v111_branch_business_fk
    foreign key (branch_id,business_id)
    references public.branches(id,business_id) on delete restrict,
  constraint customer_identity_proposals_v111_id_business_uk
    unique (id,business_id),
  constraint customer_identity_proposals_v111_distinct_clients_check
    check (source_client_id <> target_client_id),
  constraint customer_identity_proposals_v111_state_time_check check (
    (status='proposed' and proof_attached_at is null and decided_at is null and reversed_at is null)
    or (status='proof_attached' and proof_attached_at is not null and decided_at is null and reversed_at is null)
    or (status in ('approved','rejected') and decided_at is not null and reversed_at is null)
    or (status='reversed' and decided_at is not null and reversed_at is not null)
  )
);

create index customer_identity_proposals_v111_business_status_idx
  on public.customer_identity_proposals_v111(business_id,status,proposed_at desc);
create index customer_identity_proposals_v111_source_idx
  on public.customer_identity_proposals_v111(business_id,source_client_id,proposed_at desc);

create table public.customer_identity_proofs_v111 (
  id uuid primary key default gen_random_uuid(),
  proposal_id uuid not null references public.customer_identity_proposals_v111(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  proof_kind text not null check (proof_kind in ('verified_contact_pair','firm_invitation')),
  evidence_subject text not null check (length(evidence_subject) between 1 and 320),
  evidence_subject_hash text not null check (evidence_subject_hash ~ '^[0-9a-f]{64}$'),
  evidence_metadata jsonb not null check (jsonb_typeof(evidence_metadata)='object'),
  proof_fingerprint text not null check (proof_fingerprint ~ '^[0-9a-f]{64}$'),
  validated_by uuid not null references auth.users(id) on delete restrict,
  validated_at timestamptz not null default statement_timestamp(),
  constraint customer_identity_proofs_v111_proposal_business_uk
    unique(proposal_id,business_id,proof_fingerprint),
  constraint customer_identity_proofs_v111_id_proposal_business_uk
    unique(id,proposal_id,business_id),
  constraint customer_identity_proofs_v111_proposal_business_fk
    foreign key (proposal_id,business_id)
    references public.customer_identity_proposals_v111(id,business_id)
    on delete restrict
);

create table public.customer_identity_decisions_v111 (
  id uuid primary key default gen_random_uuid(),
  proposal_id uuid not null references public.customer_identity_proposals_v111(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  decision_type text not null check (decision_type in ('approve','reject','reverse')),
  proof_id uuid references public.customer_identity_proofs_v111(id) on delete restrict,
  prior_decision_id uuid references public.customer_identity_decisions_v111(id) on delete restrict,
  before_client_id uuid not null,
  after_client_id uuid not null,
  before_attribution jsonb not null check (jsonb_typeof(before_attribution)='object'),
  after_attribution jsonb not null check (jsonb_typeof(after_attribution)='object'),
  reason text,
  decided_by uuid not null references auth.users(id) on delete restrict,
  decided_at timestamptz not null default statement_timestamp(),
  constraint customer_identity_decisions_v111_before_business_fk
    foreign key (before_client_id,business_id)
    references public.clients(id,business_id) on delete restrict,
  constraint customer_identity_decisions_v111_after_business_fk
    foreign key (after_client_id,business_id)
    references public.clients(id,business_id) on delete restrict,
  constraint customer_identity_decisions_v111_id_proposal_business_uk
    unique(id,proposal_id,business_id),
  constraint customer_identity_decisions_v111_proposal_business_fk
    foreign key (proposal_id,business_id)
    references public.customer_identity_proposals_v111(id,business_id)
    on delete restrict,
  constraint customer_identity_decisions_v111_proof_scope_fk
    foreign key (proof_id,proposal_id,business_id)
    references public.customer_identity_proofs_v111(id,proposal_id,business_id)
    on delete restrict,
  constraint customer_identity_decisions_v111_prior_scope_fk
    foreign key (prior_decision_id,proposal_id,business_id)
    references public.customer_identity_decisions_v111(id,proposal_id,business_id)
    on delete restrict
);

create unique index customer_identity_decisions_v111_one_approval_idx
  on public.customer_identity_decisions_v111(proposal_id)
  where decision_type='approve';
create unique index customer_identity_decisions_v111_one_rejection_idx
  on public.customer_identity_decisions_v111(proposal_id)
  where decision_type='reject';
create unique index customer_identity_decisions_v111_one_reversal_idx
  on public.customer_identity_decisions_v111(proposal_id)
  where decision_type='reverse';

create table public.customer_identity_attribution_events_v111 (
  id uuid primary key default gen_random_uuid(),
  event_sequence bigint generated always as identity unique,
  proposal_id uuid not null references public.customer_identity_proposals_v111(id) on delete restrict,
  decision_id uuid not null unique references public.customer_identity_decisions_v111(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  source_client_id uuid not null,
  before_client_id uuid not null,
  after_client_id uuid not null,
  event_type text not null check (event_type in ('correction_approved','correction_reversed')),
  actor_auth_user_id uuid not null references auth.users(id) on delete restrict,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint customer_identity_attribution_events_v111_source_business_fk
    foreign key (source_client_id,business_id)
    references public.clients(id,business_id) on delete restrict,
  constraint customer_identity_attribution_events_v111_before_business_fk
    foreign key (before_client_id,business_id)
    references public.clients(id,business_id) on delete restrict,
  constraint customer_identity_attribution_events_v111_after_business_fk
    foreign key (after_client_id,business_id)
    references public.clients(id,business_id) on delete restrict,
  constraint customer_identity_attribution_events_v111_proposal_business_fk
    foreign key (proposal_id,business_id)
    references public.customer_identity_proposals_v111(id,business_id)
    on delete restrict,
  constraint customer_identity_attribution_events_v111_decision_scope_fk
    foreign key (decision_id,proposal_id,business_id)
    references public.customer_identity_decisions_v111(id,proposal_id,business_id)
    on delete restrict
);

create index customer_identity_attribution_events_v111_current_idx
  on public.customer_identity_attribution_events_v111(
    business_id,source_client_id,occurred_at desc,id desc
  );

create table public.customer_identity_request_ledger_v111 (
  id uuid primary key default gen_random_uuid(),
  actor_auth_user_id uuid not null references auth.users(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  operation text not null check (operation in (
    'propose','attach_proof','approve','reject','reverse'
  )),
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  receipt jsonb not null check (jsonb_typeof(receipt)='object'),
  created_at timestamptz not null default statement_timestamp(),
  constraint customer_identity_request_ledger_v111_actor_key_uk
    unique(actor_auth_user_id,idempotency_key)
);

alter table public.customer_identity_proposals_v111 enable row level security;
alter table public.customer_identity_proofs_v111 enable row level security;
alter table public.customer_identity_decisions_v111 enable row level security;
alter table public.customer_identity_attribution_events_v111 enable row level security;
alter table public.customer_identity_request_ledger_v111 enable row level security;

revoke all privileges on table
  public.customer_identity_proposals_v111,
  public.customer_identity_proofs_v111,
  public.customer_identity_decisions_v111,
  public.customer_identity_attribution_events_v111,
  public.customer_identity_request_ledger_v111
from public,anon,authenticated;

create or replace function app.v111_append_only_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  raise exception '% is append-only identity evidence',tg_table_name
    using errcode='23000';
end
$$;

create trigger customer_identity_proofs_v111_append_only
  before update or delete on public.customer_identity_proofs_v111
  for each row execute function app.v111_append_only_guard();
create trigger customer_identity_decisions_v111_append_only
  before update or delete on public.customer_identity_decisions_v111
  for each row execute function app.v111_append_only_guard();
create trigger customer_identity_attribution_events_v111_append_only
  before update or delete on public.customer_identity_attribution_events_v111
  for each row execute function app.v111_append_only_guard();
create trigger customer_identity_request_ledger_v111_append_only
  before update or delete on public.customer_identity_request_ledger_v111
  for each row execute function app.v111_append_only_guard();

create or replace function app.v111_proposal_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if tg_op='DELETE' then
    raise exception 'identity proposals are retained as audit evidence'
      using errcode='23000';
  end if;
  if (new.id,new.business_id,new.branch_id,new.source_client_id,new.target_client_id,
      new.source_identity_id,new.target_identity_id,new.target_link_id,new.reason,
      new.proposed_by,new.proposed_at)
     is distinct from
     (old.id,old.business_id,old.branch_id,old.source_client_id,old.target_client_id,
      old.source_identity_id,old.target_identity_id,old.target_link_id,old.reason,
      old.proposed_by,old.proposed_at) then
    raise exception 'identity proposal scope and evidence are immutable'
      using errcode='23000';
  end if;
  return new;
end
$$;

create trigger customer_identity_proposals_v111_guard
  before update or delete on public.customer_identity_proposals_v111
  for each row execute function app.v111_proposal_guard();

revoke all on function app.v111_append_only_guard() from public,anon,authenticated;
revoke all on function app.v111_proposal_guard() from public,anon,authenticated;

create or replace function app.v111_request_hash(p_payload jsonb)
returns text
language sql
immutable
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.v31_sha256_hex($1::text)
$$;

create or replace function app.v111_can_propose(
  p_business uuid,p_branch uuid
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select auth.uid() is not null
     and (
       app.is_super_admin()
       or (
         app.has_perm($1,'view_sales')
         and app.can_see_branch($1,$2)
       )
     )
$$;

create or replace function app.v111_can_decide(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select auth.uid() is not null
     and (app.is_super_admin() or app.is_salon_owner($1))
$$;

create or replace function app.v111_normalize_contact(
  p_type text,p_value text
)
returns text
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result text;
begin
  if p_type='email' then
    v_result:=lower(nullif(btrim(p_value),''));
    if v_result is null or position('@' in v_result)<=1 then
      raise exception 'a valid email evidence subject is required'
        using errcode='22023';
    end if;
  elsif p_type='phone' then
    v_result:=app.norm_phone(p_value);
    if v_result is null then
      raise exception 'a valid Singapore phone evidence subject is required'
        using errcode='22023';
    end if;
  else
    raise exception 'unsupported proof contact type' using errcode='22023';
  end if;
  return v_result;
end
$$;

create or replace function app.v111_validate_contact_pair(
  p_proposal uuid,p_type text,p_subject text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_proposal public.customer_identity_proposals_v111%rowtype;
  v_subject text:=app.v111_normalize_contact(p_type,p_subject);
  v_target_user uuid;
  v_target_identity uuid;
  v_candidate_count integer;
  v_candidate uuid;
  v_target_contact text;
begin
  select * into strict v_proposal
    from public.customer_identity_proposals_v111
   where id=p_proposal;

  select link.auth_user_id,link.identity_id
    into v_target_user,v_target_identity
    from public.customer_links link
   where link.id=v_proposal.target_link_id
     and link.business_id=v_proposal.business_id
     and link.client_id=v_proposal.target_client_id
     and link.identity_id=v_proposal.target_identity_id
     and link.state='verified'
     and exists (
       select 1
         from public.customer_identities identity_row
        where identity_row.id=link.identity_id
          and identity_row.status='active'
     );
  if not found then
    raise exception 'target no longer has an active verified business identity'
      using errcode='42501';
  end if;

  if p_type='email' then
    select lower(nullif(btrim(u.email),'')) into v_target_contact
      from auth.users u
     where u.id=v_target_user and u.email_confirmed_at is not null;
  else
    select app.norm_phone(u.phone) into v_target_contact
      from auth.users u
     where u.id=v_target_user and u.phone_confirmed_at is not null;
  end if;
  if v_target_contact is distinct from v_subject then
    raise exception 'evidence does not match the target verified identity'
      using errcode='42501';
  end if;

  select count(*)::integer,(array_agg(c.id order by c.id))[1]
    into v_candidate_count,v_candidate
    from public.clients c
   where c.business_id=v_proposal.business_id
     and c.id<>v_proposal.target_client_id
     and (
       (p_type='email' and lower(nullif(btrim(c.email),''))=v_subject)
       or (p_type='phone' and c.phone_norm=v_subject)
     )
     and not exists (
       select 1 from public.customer_links linked
        where linked.business_id=c.business_id
          and linked.client_id=c.id
          and linked.state='verified'
     );
  if v_candidate_count<>1 or v_candidate is distinct from v_proposal.source_client_id then
    raise exception 'proof is ambiguous or matches multiple candidate customer records'
      using errcode='P0003';
  end if;

  return jsonb_build_object(
    'proof_kind','verified_contact_pair',
    'contact_type',p_type,
    'target_identity_id',v_target_identity,
    'candidate_count',v_candidate_count,
    'source_client_id',v_proposal.source_client_id,
    'target_client_id',v_proposal.target_client_id
  );
end
$$;

create or replace function app.v111_validate_invitation(
  p_proposal uuid,p_invitation uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_proposal public.customer_identity_proposals_v111%rowtype;
  v_invite public.customer_link_invitations%rowtype;
  v_email text;
  v_target_user uuid;
begin
  select * into strict v_proposal
    from public.customer_identity_proposals_v111 where id=p_proposal;
  if exists (
    select 1
      from public.customer_links source_link
     where source_link.business_id=v_proposal.business_id
       and source_link.client_id=v_proposal.source_client_id
       and source_link.state='verified'
  ) then
    raise exception 'source customer already has a verified identity; invitation proof is no longer unambiguous'
      using errcode='42501';
  end if;
  select * into v_invite
    from public.customer_link_invitations invitation
   where invitation.id=p_invitation
     and invitation.business_id=v_proposal.business_id
     and invitation.client_id=v_proposal.source_client_id
     and invitation.state='issued'
     and invitation.expires_at>statement_timestamp();
  if not found then
    raise exception 'firm invitation evidence is invalid, expired, or cross-business'
      using errcode='42501';
  end if;
  select link.auth_user_id into v_target_user
    from public.customer_links link
   where link.id=v_proposal.target_link_id
     and link.business_id=v_proposal.business_id
     and link.client_id=v_proposal.target_client_id
     and link.identity_id=v_proposal.target_identity_id
     and link.state='verified'
     and exists (
       select 1
         from public.customer_identities identity_row
        where identity_row.id=link.identity_id
          and identity_row.status='active'
     );
  select lower(nullif(btrim(u.email),'')) into v_email
    from auth.users u
   where u.id=v_target_user and u.email_confirmed_at is not null;
  if v_email is null
     or v_invite.recipient_email_hash is distinct from
        app.v31_sha256_hex('v31.invitation-email:'||v_email) then
    raise exception 'invitation recipient does not match the target verified identity'
      using errcode='42501';
  end if;
  return jsonb_build_object(
    'proof_kind','firm_invitation',
    'invitation_id',v_invite.id,
    'source_client_id',v_proposal.source_client_id,
    'target_client_id',v_proposal.target_client_id
  );
end
$$;

revoke all on function app.v111_request_hash(jsonb) from public,anon,authenticated;
revoke all on function app.v111_can_propose(uuid,uuid) from public,anon,authenticated;
revoke all on function app.v111_can_decide(uuid) from public,anon,authenticated;
revoke all on function app.v111_normalize_contact(text,text) from public,anon,authenticated;
revoke all on function app.v111_validate_contact_pair(uuid,text,text) from public,anon,authenticated;
revoke all on function app.v111_validate_invitation(uuid,uuid) from public,anon,authenticated;

create or replace view public.customer_identity_current_attribution_v111
with (security_invoker=true)
as
select distinct on (event.business_id,event.source_client_id)
  event.business_id,event.source_client_id,event.after_client_id as effective_client_id,
  event.proposal_id,event.decision_id,event.event_type,event.occurred_at
from public.customer_identity_attribution_events_v111 event
order by event.business_id,event.source_client_id,event.event_sequence desc;

create or replace function app.v111_effective_client_id(
  p_business uuid,p_client uuid
)
returns uuid
language sql
stable
security definer
returns null on null input
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce((
    select current.effective_client_id
      from public.customer_identity_current_attribution_v111 current
     where current.business_id=p_business
       and current.source_client_id=p_client
  ),p_client)
$$;

revoke all on function app.v111_effective_client_id(uuid,uuid)
  from public,anon,authenticated;

revoke all privileges on table public.customer_identity_current_attribution_v111
  from public,anon,authenticated;

create or replace function app.v111_guard_verified_customer_link()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.state<>'verified' then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:client:'||new.business_id||':'||new.client_id::text,0
  ));
  if exists (
    select 1
      from public.customer_identity_current_attribution_v111 current
     where current.business_id=new.business_id
       and current.source_client_id=new.client_id
       and current.effective_client_id<>current.source_client_id
  ) then
    raise exception
      'verified link cannot be created for a customer with an active identity correction'
      using errcode='55000';
  end if;
  return new;
end
$$;

revoke all on function app.v111_guard_verified_customer_link()
  from public,anon,authenticated;

create trigger customer_links_v111_verified_source_guard
before insert or update of state on public.customer_links
for each row execute function app.v111_guard_verified_customer_link();

create or replace function public.propose_customer_identity_correction_v111(
  p_business uuid,
  p_branch uuid,
  p_source_client uuid,
  p_target_client uuid,
  p_reason text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_payload jsonb;
  v_hash text;
  v_existing public.customer_identity_request_ledger_v111%rowtype;
  v_proposal uuid:=gen_random_uuid();
  v_target_link public.customer_links%rowtype;
  v_source_identity uuid;
  v_receipt jsonb;
begin
  if v_actor is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  if not app.v111_can_propose(p_business,p_branch) then
    raise exception 'identity proposal is outside actor business or branch scope'
      using errcode='42501';
  end if;
  p_reason:=nullif(btrim(p_reason),'');
  v_payload:=jsonb_build_object(
    'operation','propose','business_id',p_business,'branch_id',p_branch,
    'source_client_id',p_source_client,'target_client_id',p_target_client,
    'reason',p_reason
  );
  v_hash:=app.v111_request_hash(v_payload);
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:request:'||v_actor||':'||p_idempotency_key,0
  ));
  select * into v_existing from public.customer_identity_request_ledger_v111
   where actor_auth_user_id=v_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.operation<>'propose' or v_existing.request_hash<>v_hash then
      raise exception 'idempotency key was already used for a different identity mutation'
        using errcode='23505';
    end if;
    return v_existing.receipt;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:client:'||p_business||':'||least(p_source_client::text,p_target_client::text),0
  ));
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:client:'||p_business||':'||greatest(p_source_client::text,p_target_client::text),0
  ));
  if p_source_client=p_target_client or p_reason is null
     or length(p_reason) not between 3 and 500 then
    raise exception 'distinct customers and a concise reason are required'
      using errcode='22023';
  end if;
  perform 1 from public.clients c
   where c.id=p_source_client and c.business_id=p_business;
  if not found then raise exception 'source customer is cross-business or missing' using errcode='42501'; end if;
  select * into v_target_link from public.customer_links link
   where link.business_id=p_business and link.client_id=p_target_client
     and link.state='verified'
     and exists (
       select 1
         from public.customer_identities identity_row
        where identity_row.id=link.identity_id
          and identity_row.status='active'
     );
  if not found then
    raise exception 'target customer needs one active verified business identity'
      using errcode='42501';
  end if;
  if exists (
    select 1 from public.customer_links link
     where link.business_id=p_business and link.client_id=p_source_client
       and link.state='verified'
  ) then
    raise exception 'source customer already has a verified identity; no automatic merge is allowed'
      using errcode='42501';
  end if;
  select link.identity_id into v_source_identity
    from public.customer_links link
   where link.business_id=p_business and link.client_id=p_source_client
   order by link.created_at desc limit 1;
  if exists (
    select 1 from public.customer_identity_current_attribution_v111 current
     where current.business_id=p_business
       and current.effective_client_id<>current.source_client_id
       and (
         current.source_client_id in (p_source_client,p_target_client)
         or current.effective_client_id in (p_source_client,p_target_client)
       )
  ) then
    raise exception 'source or target already participates in an active identity correction'
      using errcode='55000';
  end if;
  insert into public.customer_identity_proposals_v111(
    id,business_id,branch_id,source_client_id,target_client_id,
    source_identity_id,target_identity_id,target_link_id,reason,proposed_by
  ) values (
    v_proposal,p_business,p_branch,p_source_client,p_target_client,
    v_source_identity,v_target_link.identity_id,v_target_link.id,p_reason,v_actor
  );
  v_receipt:=jsonb_build_object(
    'status','proposed','proposal_id',v_proposal,'business_id',p_business,
    'source_client_id',p_source_client,'target_client_id',p_target_client
  );
  insert into public.customer_identity_request_ledger_v111(
    actor_auth_user_id,business_id,operation,idempotency_key,request_hash,receipt
  ) values(v_actor,p_business,'propose',p_idempotency_key,v_hash,v_receipt);
  return v_receipt;
end
$$;

create or replace function public.attach_customer_identity_proof_v111(
  p_proposal uuid,
  p_proof_kind text,
  p_evidence jsonb,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_proposal public.customer_identity_proposals_v111%rowtype;
  v_payload jsonb;
  v_hash text;
  v_existing public.customer_identity_request_ledger_v111%rowtype;
  v_metadata jsonb;
  v_subject text;
  v_contact_type text;
  v_fingerprint text;
  v_proof uuid;
  v_receipt jsonb;
begin
  if v_actor is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  select * into v_proposal from public.customer_identity_proposals_v111
   where id=p_proposal;
  if not found then raise exception 'identity proposal not found' using errcode='23503'; end if;
  if not app.v111_can_propose(v_proposal.business_id,v_proposal.branch_id) then
    raise exception 'proof is outside actor business or branch scope' using errcode='42501';
  end if;
  p_proof_kind:=lower(nullif(btrim(p_proof_kind),''));
  if p_proof_kind='verified_contact_pair' then
    v_contact_type:=lower(nullif(btrim(p_evidence->>'contact_type'),''));
    v_subject:=app.v111_normalize_contact(
      v_contact_type,p_evidence->>'contact_value'
    );
    v_payload:=jsonb_build_object(
      'operation','attach_proof','proposal_id',p_proposal,
      'proof_kind',p_proof_kind,'contact_type',v_contact_type,
      'contact_value',v_subject
    );
  elsif p_proof_kind='firm_invitation' then
    v_subject:=nullif(p_evidence->>'invitation_id','');
    if v_subject is null then raise exception 'invitation_id is required' using errcode='22023'; end if;
    v_payload:=jsonb_build_object(
      'operation','attach_proof','proposal_id',p_proposal,
      'proof_kind',p_proof_kind,'invitation_id',v_subject
    );
  else
    raise exception 'unsupported proof kind' using errcode='22023';
  end if;
  v_hash:=app.v111_request_hash(v_payload);
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:request:'||v_actor||':'||p_idempotency_key,0
  ));
  select * into v_existing from public.customer_identity_request_ledger_v111
   where actor_auth_user_id=v_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.operation<>'attach_proof' or v_existing.request_hash<>v_hash then
      raise exception 'idempotency key was already used for a different identity mutation'
        using errcode='23505';
    end if;
    return v_existing.receipt;
  end if;
  select * into v_proposal from public.customer_identity_proposals_v111
   where id=p_proposal for update;
  if not found then raise exception 'identity proposal not found' using errcode='23503'; end if;
  if v_proposal.status not in ('proposed','proof_attached') then
    raise exception 'proof cannot be attached after a terminal decision' using errcode='55000';
  end if;
  if p_proof_kind='verified_contact_pair' then
    v_metadata:=app.v111_validate_contact_pair(
      p_proposal,v_contact_type,v_subject
    );
  else
    v_metadata:=app.v111_validate_invitation(p_proposal,v_subject::uuid);
  end if;
  v_fingerprint:=app.v111_request_hash(jsonb_build_object(
    'proposal_id',p_proposal,'proof_kind',p_proof_kind,'subject',v_subject
  ));
  select proof.id into v_proof from public.customer_identity_proofs_v111 proof
   where proof.proposal_id=p_proposal and proof.business_id=v_proposal.business_id
     and proof.proof_fingerprint=v_fingerprint;
  if v_proof is null then
    v_proof:=gen_random_uuid();
    insert into public.customer_identity_proofs_v111(
      id,proposal_id,business_id,proof_kind,evidence_subject,
      evidence_subject_hash,evidence_metadata,proof_fingerprint,validated_by
    ) values (
      v_proof,p_proposal,v_proposal.business_id,p_proof_kind,v_subject,
      app.v111_request_hash(jsonb_build_object('subject',v_subject)),
      v_metadata,v_fingerprint,v_actor
    );
  end if;
  if v_proposal.status='proposed' then
    update public.customer_identity_proposals_v111
       set status='proof_attached',proof_attached_at=statement_timestamp(),
           updated_at=statement_timestamp()
     where id=p_proposal;
  end if;
  v_receipt:=jsonb_build_object(
    'status','proof_attached','proposal_id',p_proposal,'proof_id',v_proof,
    'proof_kind',p_proof_kind
  );
  insert into public.customer_identity_request_ledger_v111(
    actor_auth_user_id,business_id,operation,idempotency_key,request_hash,receipt
  ) values(v_actor,v_proposal.business_id,'attach_proof',p_idempotency_key,v_hash,v_receipt);
  return v_receipt;
end
$$;

create or replace function app.v111_attribution_snapshot(
  p_business uuid,p_source uuid,p_target uuid,p_effective uuid
)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select jsonb_build_object(
    'source_client_id',$2,
    'target_client_id',$3,
    'effective_client_id',$4,
    'source_sales',(
      select count(*) from public.sales s
       where s.business_id=$1 and s.client_id=$2
    ),
    'source_points',(
      select coalesce(sum(points),0) from public.points_ledger p
       where p.business_id=$1 and p.client_id=$2
    ),
    'source_reward_grants',(
      select count(*) from public.reward_grants g
       where g.business_id=$1 and g.client_id=$2
    ),
    'source_redemptions',(
      select count(*) from public.loyalty_redemptions r
       where r.business_id=$1 and r.client_id=$2
    ),
    'target_sales',(
      select count(*) from public.sales s
       where s.business_id=$1 and s.client_id=$3
    ),
    'target_points',(
      select coalesce(sum(points),0) from public.points_ledger p
       where p.business_id=$1 and p.client_id=$3
    ),
    'target_reward_grants',(
      select count(*) from public.reward_grants g
       where g.business_id=$1 and g.client_id=$3
    ),
    'target_redemptions',(
      select count(*) from public.loyalty_redemptions r
       where r.business_id=$1 and r.client_id=$3
    )
  )
$$;

revoke all on function app.v111_attribution_snapshot(uuid,uuid,uuid,uuid)
  from public,anon,authenticated;

create or replace function public.approve_customer_identity_correction_v111(
  p_proposal uuid,p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_proposal public.customer_identity_proposals_v111%rowtype;
  v_proof public.customer_identity_proofs_v111%rowtype;
  v_payload jsonb:=jsonb_build_object('operation','approve','proposal_id',p_proposal);
  v_hash text:=app.v111_request_hash(v_payload);
  v_existing public.customer_identity_request_ledger_v111%rowtype;
  v_decision uuid;
  v_event uuid;
  v_before jsonb;
  v_after jsonb;
  v_receipt jsonb;
begin
  if v_actor is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  select * into v_proposal from public.customer_identity_proposals_v111
   where id=p_proposal;
  if not found then raise exception 'identity proposal not found' using errcode='23503'; end if;
  if not app.v111_can_decide(v_proposal.business_id) then
    raise exception 'owner or global business authority is required to approve'
      using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:request:'||v_actor||':'||p_idempotency_key,0
  ));
  select * into v_existing from public.customer_identity_request_ledger_v111
   where actor_auth_user_id=v_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.operation<>'approve' or v_existing.request_hash<>v_hash then
      raise exception 'idempotency key was already used for a different identity mutation'
        using errcode='23505';
    end if;
    return v_existing.receipt;
  end if;
  select * into v_proposal from public.customer_identity_proposals_v111
   where id=p_proposal for update;
  if not found then raise exception 'identity proposal not found' using errcode='23503'; end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:client:'||v_proposal.business_id||':'||
    least(v_proposal.source_client_id::text,v_proposal.target_client_id::text),0
  ));
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:client:'||v_proposal.business_id||':'||
    greatest(v_proposal.source_client_id::text,v_proposal.target_client_id::text),0
  ));
  if v_proposal.status='approved' then
    select id into v_decision from public.customer_identity_decisions_v111
     where proposal_id=p_proposal and decision_type='approve';
    v_receipt:=jsonb_build_object('status','approved','proposal_id',p_proposal,'decision_id',v_decision);
  elsif v_proposal.status in ('rejected','reversed') then
    raise exception 'identity proposal already has a conflicting terminal decision'
      using errcode='55000';
  else
    select * into v_proof from public.customer_identity_proofs_v111 proof
     where proof.proposal_id=p_proposal and proof.business_id=v_proposal.business_id
     order by proof.validated_at desc,proof.id desc limit 1;
    if not found then raise exception 'validated proof is required before approval' using errcode='42501'; end if;
    if exists (
      select 1
        from public.customer_links source_link
       where source_link.business_id=v_proposal.business_id
         and source_link.client_id=v_proposal.source_client_id
         and source_link.state='verified'
    ) then
      raise exception 'source customer gained a verified identity after proof; approval requires fresh unambiguous evidence'
        using errcode='42501';
    end if;
    if v_proof.proof_kind='verified_contact_pair' then
      perform app.v111_validate_contact_pair(
        p_proposal,v_proof.evidence_metadata->>'contact_type',v_proof.evidence_subject
      );
    else
      perform app.v111_validate_invitation(p_proposal,(v_proof.evidence_metadata->>'invitation_id')::uuid);
    end if;
    if exists (
      select 1 from public.customer_identity_current_attribution_v111 current
       where current.business_id=v_proposal.business_id
         and current.effective_client_id<>current.source_client_id
         and (
           current.source_client_id in (
             v_proposal.source_client_id,v_proposal.target_client_id
           )
           or current.effective_client_id in (
             v_proposal.source_client_id,v_proposal.target_client_id
           )
         )
    ) then
      raise exception 'source or target already participates in an active identity correction'
        using errcode='55000';
    end if;
    v_before:=app.v111_attribution_snapshot(
      v_proposal.business_id,v_proposal.source_client_id,
      v_proposal.target_client_id,v_proposal.source_client_id
    );
    v_after:=app.v111_attribution_snapshot(
      v_proposal.business_id,v_proposal.source_client_id,
      v_proposal.target_client_id,v_proposal.target_client_id
    );
    v_decision:=gen_random_uuid();
    insert into public.customer_identity_decisions_v111(
      id,proposal_id,business_id,decision_type,proof_id,
      before_client_id,after_client_id,before_attribution,after_attribution,
      decided_by
    ) values (
      v_decision,p_proposal,v_proposal.business_id,'approve',v_proof.id,
      v_proposal.source_client_id,v_proposal.target_client_id,v_before,v_after,
      v_actor
    );
    v_event:=gen_random_uuid();
    insert into public.customer_identity_attribution_events_v111(
      id,proposal_id,decision_id,business_id,source_client_id,
      before_client_id,after_client_id,event_type,actor_auth_user_id
    ) values (
      v_event,p_proposal,v_decision,v_proposal.business_id,
      v_proposal.source_client_id,v_proposal.source_client_id,
      v_proposal.target_client_id,'correction_approved',v_actor
    );
    update public.customer_identity_proposals_v111
       set status='approved',decided_at=statement_timestamp(),
           updated_at=statement_timestamp()
     where id=p_proposal;
    v_receipt:=jsonb_build_object(
      'status','approved','proposal_id',p_proposal,'decision_id',v_decision,
      'attribution_event_id',v_event,'source_client_id',v_proposal.source_client_id,
      'effective_client_id',v_proposal.target_client_id
    );
  end if;
  insert into public.customer_identity_request_ledger_v111(
    actor_auth_user_id,business_id,operation,idempotency_key,request_hash,receipt
  ) values(v_actor,v_proposal.business_id,'approve',p_idempotency_key,v_hash,v_receipt);
  return v_receipt;
end
$$;

create or replace function public.reject_customer_identity_correction_v111(
  p_proposal uuid,p_reason text,p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_proposal public.customer_identity_proposals_v111%rowtype;
  v_payload jsonb;
  v_hash text;
  v_existing public.customer_identity_request_ledger_v111%rowtype;
  v_decision uuid;
  v_snapshot jsonb;
  v_receipt jsonb;
begin
  if v_actor is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  select * into v_proposal from public.customer_identity_proposals_v111
   where id=p_proposal;
  if not found then raise exception 'identity proposal not found' using errcode='23503'; end if;
  if not app.v111_can_decide(v_proposal.business_id) then
    raise exception 'owner or global business authority is required to reject'
      using errcode='42501';
  end if;
  p_reason:=nullif(btrim(p_reason),'');
  if p_reason is null or length(p_reason)>500 then
    raise exception 'rejection reason is required' using errcode='22023';
  end if;
  v_payload:=jsonb_build_object('operation','reject','proposal_id',p_proposal,'reason',p_reason);
  v_hash:=app.v111_request_hash(v_payload);
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:request:'||v_actor||':'||p_idempotency_key,0
  ));
  select * into v_existing from public.customer_identity_request_ledger_v111
   where actor_auth_user_id=v_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.operation<>'reject' or v_existing.request_hash<>v_hash then
      raise exception 'idempotency key was already used for a different identity mutation'
        using errcode='23505';
    end if;
    return v_existing.receipt;
  end if;
  select * into v_proposal from public.customer_identity_proposals_v111
   where id=p_proposal for update;
  if not found then raise exception 'identity proposal not found' using errcode='23503'; end if;
  if v_proposal.status='rejected' then
    select id into v_decision from public.customer_identity_decisions_v111
     where proposal_id=p_proposal and decision_type='reject';
  elsif v_proposal.status in ('approved','reversed') then
    raise exception 'identity proposal already has a conflicting terminal decision'
      using errcode='55000';
  else
    v_snapshot:=app.v111_attribution_snapshot(
      v_proposal.business_id,v_proposal.source_client_id,
      v_proposal.target_client_id,v_proposal.source_client_id
    );
    v_decision:=gen_random_uuid();
    insert into public.customer_identity_decisions_v111(
      id,proposal_id,business_id,decision_type,before_client_id,after_client_id,
      before_attribution,after_attribution,reason,decided_by
    ) values (
      v_decision,p_proposal,v_proposal.business_id,'reject',
      v_proposal.source_client_id,v_proposal.source_client_id,
      v_snapshot,v_snapshot,p_reason,v_actor
    );
    update public.customer_identity_proposals_v111
       set status='rejected',decided_at=statement_timestamp(),
           updated_at=statement_timestamp()
     where id=p_proposal;
  end if;
  v_receipt:=jsonb_build_object(
    'status','rejected','proposal_id',p_proposal,'decision_id',v_decision
  );
  insert into public.customer_identity_request_ledger_v111(
    actor_auth_user_id,business_id,operation,idempotency_key,request_hash,receipt
  ) values(v_actor,v_proposal.business_id,'reject',p_idempotency_key,v_hash,v_receipt);
  return v_receipt;
end
$$;

create or replace function public.reverse_customer_identity_correction_v111(
  p_proposal uuid,p_reason text,p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_proposal public.customer_identity_proposals_v111%rowtype;
  v_payload jsonb;
  v_hash text;
  v_existing public.customer_identity_request_ledger_v111%rowtype;
  v_approval uuid;
  v_decision uuid;
  v_event uuid;
  v_before jsonb;
  v_after jsonb;
  v_receipt jsonb;
begin
  if v_actor is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  select * into v_proposal from public.customer_identity_proposals_v111
   where id=p_proposal;
  if not found then raise exception 'identity proposal not found' using errcode='23503'; end if;
  if not app.v111_can_decide(v_proposal.business_id) then
    raise exception 'owner or global business authority is required to reverse'
      using errcode='42501';
  end if;
  p_reason:=nullif(btrim(p_reason),'');
  if p_reason is null or length(p_reason)>500 then
    raise exception 'reversal reason is required' using errcode='22023';
  end if;
  v_payload:=jsonb_build_object('operation','reverse','proposal_id',p_proposal,'reason',p_reason);
  v_hash:=app.v111_request_hash(v_payload);
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:request:'||v_actor||':'||p_idempotency_key,0
  ));
  select * into v_existing from public.customer_identity_request_ledger_v111
   where actor_auth_user_id=v_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.operation<>'reverse' or v_existing.request_hash<>v_hash then
      raise exception 'idempotency key was already used for a different identity mutation'
        using errcode='23505';
    end if;
    return v_existing.receipt;
  end if;
  select * into v_proposal from public.customer_identity_proposals_v111
   where id=p_proposal for update;
  if not found then raise exception 'identity proposal not found' using errcode='23503'; end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v111:source:'||v_proposal.business_id||':'||v_proposal.source_client_id,0
  ));
  if v_proposal.status='reversed' then
    select id into v_decision from public.customer_identity_decisions_v111
     where proposal_id=p_proposal and decision_type='reverse';
    select id into v_event from public.customer_identity_attribution_events_v111
     where decision_id=v_decision;
  elsif v_proposal.status<>'approved' then
    raise exception 'only an approved identity correction may be reversed'
      using errcode='55000';
  else
    select id into strict v_approval from public.customer_identity_decisions_v111
     where proposal_id=p_proposal and decision_type='approve';
    if not exists (
      select 1 from public.customer_identity_current_attribution_v111 current
       where current.business_id=v_proposal.business_id
         and current.source_client_id=v_proposal.source_client_id
         and current.proposal_id=p_proposal
         and current.effective_client_id=v_proposal.target_client_id
    ) then
      raise exception 'approved attribution is no longer the current correction'
        using errcode='55000';
    end if;
    v_before:=app.v111_attribution_snapshot(
      v_proposal.business_id,v_proposal.source_client_id,
      v_proposal.target_client_id,v_proposal.target_client_id
    );
    v_after:=app.v111_attribution_snapshot(
      v_proposal.business_id,v_proposal.source_client_id,
      v_proposal.target_client_id,v_proposal.source_client_id
    );
    v_decision:=gen_random_uuid();
    insert into public.customer_identity_decisions_v111(
      id,proposal_id,business_id,decision_type,prior_decision_id,
      before_client_id,after_client_id,before_attribution,after_attribution,
      reason,decided_by
    ) values (
      v_decision,p_proposal,v_proposal.business_id,'reverse',v_approval,
      v_proposal.target_client_id,v_proposal.source_client_id,
      v_before,v_after,p_reason,v_actor
    );
    v_event:=gen_random_uuid();
    insert into public.customer_identity_attribution_events_v111(
      id,proposal_id,decision_id,business_id,source_client_id,
      before_client_id,after_client_id,event_type,actor_auth_user_id
    ) values (
      v_event,p_proposal,v_decision,v_proposal.business_id,
      v_proposal.source_client_id,v_proposal.target_client_id,
      v_proposal.source_client_id,'correction_reversed',v_actor
    );
    update public.customer_identity_proposals_v111
       set status='reversed',reversed_at=statement_timestamp(),
           updated_at=statement_timestamp()
     where id=p_proposal;
  end if;
  v_receipt:=jsonb_build_object(
    'status','reversed','proposal_id',p_proposal,'decision_id',v_decision,
    'attribution_event_id',v_event,'source_client_id',v_proposal.source_client_id,
    'effective_client_id',v_proposal.source_client_id
  );
  insert into public.customer_identity_request_ledger_v111(
    actor_auth_user_id,business_id,operation,idempotency_key,request_hash,receipt
  ) values(v_actor,v_proposal.business_id,'reverse',p_idempotency_key,v_hash,v_receipt);
  return v_receipt;
end
$$;

create or replace function public.get_customer_identity_proposal_v111(
  p_proposal uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_proposal public.customer_identity_proposals_v111%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode='42501'; end if;
  select * into v_proposal from public.customer_identity_proposals_v111 where id=p_proposal;
  if not found then raise exception 'identity proposal not found' using errcode='23503'; end if;
  if not app.v111_can_propose(v_proposal.business_id,v_proposal.branch_id) then
    raise exception 'identity proposal is outside actor scope' using errcode='42501';
  end if;
  return jsonb_build_object(
    'proposal',to_jsonb(v_proposal),
    'proofs',coalesce((
      select jsonb_agg(to_jsonb(proof) order by proof.validated_at,proof.id)
      from public.customer_identity_proofs_v111 proof
      where proof.proposal_id=p_proposal
    ),'[]'::jsonb),
    'decisions',coalesce((
      select jsonb_agg(to_jsonb(decision) order by decision.decided_at,decision.id)
      from public.customer_identity_decisions_v111 decision
      where decision.proposal_id=p_proposal
    ),'[]'::jsonb),
    'attribution_history',coalesce((
      select jsonb_agg(to_jsonb(event) order by event.occurred_at,event.id)
      from public.customer_identity_attribution_events_v111 event
      where event.proposal_id=p_proposal
    ),'[]'::jsonb)
  );
end
$$;

create or replace function public.get_customer_identity_coverage_v111(
  p_business uuid,p_branch uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_total bigint;
  v_identified bigint;
  v_corrected bigint;
  v_raw_customers bigint;
  v_canonical_customers bigint;
begin
  if auth.uid() is null
     or not app.v111_can_propose(p_business,p_branch) then
    raise exception 'identity coverage is outside actor scope' using errcode='42501';
  end if;
  select
    count(*)::bigint,
    count(*) filter(where s.client_id is not null)::bigint,
    count(*) filter(where current.effective_client_id is distinct from s.client_id)::bigint,
    count(distinct s.client_id) filter(where s.client_id is not null)::bigint,
    count(distinct coalesce(current.effective_client_id,s.client_id))
      filter(where s.client_id is not null)::bigint
  into v_total,v_identified,v_corrected,v_raw_customers,v_canonical_customers
  from public.sales s
  left join public.customer_identity_current_attribution_v111 current
    on current.business_id=s.business_id and current.source_client_id=s.client_id
  where s.business_id=p_business
    and (p_branch is null or s.branch_id=p_branch)
    and s.amount_cents>=0
    and s.counts_as_revenue
    and s.reversal_of is null
    and not exists(
      select 1 from public.sales reversal
      where reversal.business_id=s.business_id
        and reversal.reversal_of=s.id
    );
  return jsonb_build_object(
    'business_id',p_business,'branch_id',p_branch,
    'eligible_transaction_count',v_total,
    'identified_transaction_count',v_identified,
    'corrected_transaction_count',v_corrected,
    'raw_identified_customer_count',v_raw_customers,
    'canonical_identified_customer_count',v_canonical_customers,
    'identified_transaction_coverage',
      case when v_total=0 then null else round(v_identified::numeric/v_total,6) end
  );
end
$$;

revoke all on function
  public.propose_customer_identity_correction_v111(uuid,uuid,uuid,uuid,text,uuid)
from public,anon,authenticated;
revoke all on function
  public.attach_customer_identity_proof_v111(uuid,text,jsonb,uuid)
from public,anon,authenticated;
revoke all on function
  public.approve_customer_identity_correction_v111(uuid,uuid)
from public,anon,authenticated;
revoke all on function
  public.reject_customer_identity_correction_v111(uuid,text,uuid)
from public,anon,authenticated;
revoke all on function
  public.reverse_customer_identity_correction_v111(uuid,text,uuid)
from public,anon,authenticated;
revoke all on function
  public.get_customer_identity_proposal_v111(uuid)
from public,anon,authenticated;
revoke all on function
  public.get_customer_identity_coverage_v111(uuid,uuid)
from public,anon,authenticated;

grant execute on function
  public.propose_customer_identity_correction_v111(uuid,uuid,uuid,uuid,text,uuid),
  public.attach_customer_identity_proof_v111(uuid,text,jsonb,uuid),
  public.approve_customer_identity_correction_v111(uuid,uuid),
  public.reject_customer_identity_correction_v111(uuid,text,uuid),
  public.reverse_customer_identity_correction_v111(uuid,text,uuid),
  public.get_customer_identity_proposal_v111(uuid),
  public.get_customer_identity_coverage_v111(uuid,uuid)
to authenticated;

commit;

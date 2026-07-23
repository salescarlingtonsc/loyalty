-- FRENLY v53 - VISIT FEEDBACK & SERVICE-RECOVERY FOUNDATION
--
-- Forward-only. Post-visit feedback from customers, PRIVATE BY DEFAULT. Negative
-- feedback (rating <= 3) opens a staff service-recovery case; positive feedback
-- (rating >= 4) is auto-closed and never enters the queue. There is NO messaging
-- provider, so the ONLY collection entry point is the authenticated customer wallet
-- (C42-C46): every customer RPC re-derives the (identity, verified link, business,
-- client) tuple from auth.uid() exactly as app.c46_customer_inbox_context does, and
-- attaches feedback only to a sale that belongs to that customer's own linked client.
--
-- ANTI-REVIEW-GATING (audit warning, honored): businesses.review_url is a plain
-- link-out field. The database NEVER suppresses negative feedback from any platform
-- and stores no logic that would. A UI may show the link more prominently on high
-- ratings, but must show a path to the public platforms regardless of rating; that is
-- a UI concern and is documented here so the invariant is not lost.
--
-- IDENTITY LINKAGE (studied, mirrored): a verified public.customer_links row
-- (state='verified', auth_user_id=auth.uid()) ties a platform customer_identities row
-- to one business-owned client per firm. Feedback is pinned to that link via two
-- tenant-safe composite FKs (link_id,business_id,identity_id) and (link_id,business_id,
-- client_id), so identity, client and business can never drift apart.
--
-- GATES (justified below at each RPC): customer RPCs = verified wallet link (customer
-- identity, not staff). staff_list = can_module_read('clients'). staff_resolve =
-- can_module_write('clients') AND has_perm('refund_sales').

begin;

-- ---------------------------------------------------------------------------
-- 1. SECURITY DEFINER helper used by the customer-read RLS policy (so the browser
--    role never needs direct SELECT on customer_links / customer_identities).
-- ---------------------------------------------------------------------------
create or replace function app.v53_feedback_link_visible(p_link_id uuid, p_business uuid)
returns boolean
language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1
      from public.customer_links cl
      join public.customer_identities ci
        on ci.id = cl.identity_id and ci.auth_user_id = cl.auth_user_id
     where cl.id = p_link_id
       and cl.business_id = p_business
       and cl.auth_user_id = auth.uid()
       and cl.state = 'verified'
       and ci.auth_user_id = auth.uid()
       and ci.status = 'active'
  )
$$;
revoke all privileges on function app.v53_feedback_link_visible(uuid, uuid)
  from public, anon, authenticated;
grant execute on function app.v53_feedback_link_visible(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Customer wallet context resolver (mirrors app.c46_customer_inbox_context,
--    minus the inbox feature flag: the effective gate is a verified link).
-- ---------------------------------------------------------------------------
create or replace function app.v53_customer_feedback_context(p_business_slug text)
returns table (
  identity_id uuid,
  auth_user_id uuid,
  link_id uuid,
  business_id uuid,
  client_id uuid,
  business_slug text
)
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_slug text := lower(btrim(coalesce(p_business_slug, '')));
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if length(v_slug) not between 2 and 160 then
    raise exception 'invalid business link' using errcode = '22023';
  end if;
  return query
    select ci.id, v_actor, cl.id, cl.business_id, cl.client_id, b.slug
      from public.customer_identities ci
      join public.customer_links cl
        on cl.identity_id = ci.id and cl.auth_user_id = v_actor and cl.state = 'verified'
      join public.businesses b on b.id = cl.business_id
     where ci.auth_user_id = v_actor and ci.status = 'active' and b.slug = v_slug
     order by cl.id
     limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
end;
$$;
revoke all privileges on function app.v53_customer_feedback_context(text)
  from public, anon, authenticated;
grant execute on function app.v53_customer_feedback_context(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. visit_feedback: append-only for the customer; staff mutate ONLY the recovery
--    lifecycle via the guarded RPC.
-- ---------------------------------------------------------------------------
create table public.visit_feedback (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  identity_id uuid not null,
  link_id uuid not null,
  client_id uuid not null,
  auth_user_id uuid not null,
  sale_id uuid,
  rating smallint not null check (rating between 1 and 5),
  comment text check (comment is null or length(comment) <= 2000),
  idempotency_key uuid not null,
  recovery_status text not null
    check (recovery_status in ('open', 'acknowledged', 'resolved', 'closed')),
  resolved_by uuid,
  resolved_at timestamptz,
  resolution_note text check (resolution_note is null or length(resolution_note) <= 2000),
  created_at timestamptz not null default now(),
  constraint visit_feedback_business_fk
    foreign key (business_id) references public.businesses(id) on delete cascade,
  -- Two tenant/identity-safe link FKs pin (identity, client) to the same verified link.
  constraint visit_feedback_link_identity_fk
    foreign key (link_id, business_id, identity_id)
    references public.customer_links(id, business_id, identity_id) on delete restrict,
  constraint visit_feedback_link_client_fk
    foreign key (link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  constraint visit_feedback_sale_fk
    foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint visit_feedback_resolver_fk
    foreign key (resolved_by, business_id)
    references public.staff(id, business_id) on delete restrict,
  -- Positive feedback is auto-closed and out of the recovery queue; negative feedback
  -- rides the open -> acknowledged -> resolved lifecycle. This CHECK holds across every
  -- legal transition (see the guard trigger).
  constraint visit_feedback_recovery_gate_check check (
    (rating <= 3 and recovery_status in ('open', 'acknowledged', 'resolved'))
    or (rating >= 4 and recovery_status = 'closed')
  ),
  constraint visit_feedback_resolution_check check (
    (recovery_status = 'resolved' and resolved_by is not null and resolved_at is not null)
    or (recovery_status <> 'resolved')
  ),
  constraint visit_feedback_identity_idempotency_uk unique (identity_id, idempotency_key)
);
-- One feedback per (identity, visit); and a sane no-visit rule: one standing general
-- feedback per (identity, business) so the recovery queue cannot be flooded.
create unique index visit_feedback_one_per_visit_uk
  on public.visit_feedback (identity_id, sale_id) where sale_id is not null;
create unique index visit_feedback_one_general_per_business_uk
  on public.visit_feedback (identity_id, business_id) where sale_id is null;
create index visit_feedback_recovery_queue_idx
  on public.visit_feedback (business_id, recovery_status, created_at desc);
create index visit_feedback_client_idx
  on public.visit_feedback (business_id, client_id, created_at desc);

alter table public.visit_feedback enable row level security;
revoke all privileges on table public.visit_feedback from public, anon, authenticated;
grant select on public.visit_feedback to authenticated;
-- Customer sees only their own rows (via the SECURITY DEFINER link check); staff see
-- their tenant's rows through the clients module gate; super admin reads all.
create policy visit_feedback_customer_read on public.visit_feedback
  for select to authenticated using (app.v53_feedback_link_visible(link_id, business_id));
create policy visit_feedback_staff_read on public.visit_feedback
  for select to authenticated using (app.can_module_read(business_id, 'clients'));
create policy visit_feedback_sa_read on public.visit_feedback
  for select to authenticated using (app.is_super_admin());
-- No insert/update/delete policy: every write goes through the SECURITY DEFINER RPCs
-- below (which run as owner and bypass RLS). The guard trigger governs update/delete.

create or replace function app.visit_feedback_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_token text;
begin
  if tg_op = 'DELETE' then
    raise exception 'visit_feedback is append-only: DELETE is not permitted'
      using errcode = 'restrict_violation';
  end if;
  if tg_op = 'INSERT' then
    return new;
  end if;
  -- UPDATE: only staff_resolve_feedback may move the recovery lifecycle, and only that.
  v_token := nullif(current_setting('app.visit_feedback_resolve_id', true), '');
  if v_token is distinct from old.id::text then
    raise exception 'visit feedback recovery may only be updated by staff_resolve_feedback'
      using errcode = '42501';
  end if;
  if (new.id, new.business_id, new.identity_id, new.link_id, new.client_id, new.auth_user_id,
      new.sale_id, new.rating, new.comment, new.idempotency_key, new.created_at)
     is distinct from
     (old.id, old.business_id, old.identity_id, old.link_id, old.client_id, old.auth_user_id,
      old.sale_id, old.rating, old.comment, old.idempotency_key, old.created_at) then
    raise exception 'only the service-recovery lifecycle of a feedback row may change'
      using errcode = 'restrict_violation';
  end if;
  if not (
       (old.recovery_status = 'open' and new.recovery_status in ('acknowledged', 'resolved'))
    or (old.recovery_status = 'acknowledged' and new.recovery_status = 'resolved')
    or (old.recovery_status = new.recovery_status)
  ) then
    raise exception 'illegal service-recovery transition % -> %',
      old.recovery_status, new.recovery_status
      using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all privileges on function app.visit_feedback_guard() from public, anon, authenticated;
create trigger trg_visit_feedback_guard
  before insert or update or delete on public.visit_feedback
  for each row execute function app.visit_feedback_guard();

-- Row -> JSON projections (defined before their RPC callers). The customer projection
-- hides staff-only recovery internals (resolver, resolution note); the staff projection
-- includes them.
create or replace function app.v53_feedback_json(p_row public.visit_feedback)
returns jsonb language sql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'id', p_row.id,
    'business_id', p_row.business_id,
    'sale_id', p_row.sale_id,
    'rating', p_row.rating,
    'comment', p_row.comment,
    'recovery_status', p_row.recovery_status,
    'created_at', p_row.created_at
  )
$$;
revoke all privileges on function app.v53_feedback_json(public.visit_feedback)
  from public, anon, authenticated;
grant execute on function app.v53_feedback_json(public.visit_feedback) to authenticated;

create or replace function app.v53_feedback_staff_json(p_row public.visit_feedback)
returns jsonb language sql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'id', p_row.id,
    'client_id', p_row.client_id,
    'sale_id', p_row.sale_id,
    'rating', p_row.rating,
    'comment', p_row.comment,
    'recovery_status', p_row.recovery_status,
    'resolved_by', p_row.resolved_by,
    'resolved_at', p_row.resolved_at,
    'resolution_note', p_row.resolution_note,
    'created_at', p_row.created_at
  )
$$;
revoke all privileges on function app.v53_feedback_staff_json(public.visit_feedback)
  from public, anon, authenticated;
grant execute on function app.v53_feedback_staff_json(public.visit_feedback) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Review link-out (owner-settable via the existing salons_update RLS policy;
--    the businesses modules guard fires only on enabled_modules, so this is a plain
--    owner UPDATE with no new RPC). https-only, bounded.
-- ---------------------------------------------------------------------------
alter table public.businesses
  add column review_url text
  check (review_url is null or (length(review_url) <= 500 and review_url ~ '^https://'));

-- ---------------------------------------------------------------------------
-- 5. Customer RPC: submit feedback for one of my own visits (or a general note).
-- ---------------------------------------------------------------------------
create or replace function public.customer_submit_visit_feedback(
  p_business_slug text,
  p_sale uuid,
  p_rating integer,
  p_comment text,
  p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_ctx record;
  v_comment text := nullif(btrim(p_comment), '');
  v_status text;
  v_row public.visit_feedback%rowtype;
  v_existing public.visit_feedback%rowtype;
begin
  select * into v_ctx from app.v53_customer_feedback_context(p_business_slug);
  if p_idempotency_key is null then
    raise exception 'an idempotency key is required' using errcode = '22023';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'rating must be between 1 and 5' using errcode = '22023';
  end if;
  if v_comment is not null and length(v_comment) > 2000 then
    raise exception 'comment is too long' using errcode = '22023';
  end if;
  if p_sale is not null and not exists (
    select 1 from public.sales s
     where s.id = p_sale
       and s.business_id = v_ctx.business_id
       and s.client_id = v_ctx.client_id
       and s.reversal_of is null
  ) then
    raise exception 'that visit is not on your account' using errcode = '42501';
  end if;

  v_status := case when p_rating <= 3 then 'open' else 'closed' end;

  perform pg_advisory_xact_lock(hashtextextended(
    'v53:feedback:' || v_ctx.identity_id::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.visit_feedback f
   where f.identity_id = v_ctx.identity_id and f.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.rating <> p_rating
       or v_existing.comment is distinct from v_comment
       or v_existing.sale_id is distinct from p_sale then
      raise exception 'idempotency key conflicts with a different feedback submission'
        using errcode = '40001';
    end if;
    return app.v53_feedback_json(v_existing);
  end if;

  begin
    insert into public.visit_feedback(
      business_id, identity_id, link_id, client_id, auth_user_id,
      sale_id, rating, comment, idempotency_key, recovery_status)
    values (
      v_ctx.business_id, v_ctx.identity_id, v_ctx.link_id, v_ctx.client_id, v_ctx.auth_user_id,
      p_sale, p_rating::smallint, v_comment, p_idempotency_key, v_status)
    returning * into v_row;
  exception when unique_violation then
    -- A concurrent same-key winner replays; a different key for the same visit/general
    -- slot is a genuine duplicate.
    select * into v_existing from public.visit_feedback f
     where f.identity_id = v_ctx.identity_id and f.idempotency_key = p_idempotency_key;
    if found then
      return app.v53_feedback_json(v_existing);
    end if;
    raise exception 'you have already left feedback for this visit'
      using errcode = '23505';
  end;

  return app.v53_feedback_json(v_row);
end $$;
revoke all privileges on function public.customer_submit_visit_feedback(text, uuid, integer, text, uuid)
  from public, anon, authenticated;
grant execute on function public.customer_submit_visit_feedback(text, uuid, integer, text, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Customer RPC: list my own feedback (optionally scoped to one business).
-- ---------------------------------------------------------------------------
create or replace function public.customer_list_my_feedback(
  p_business_slug text default null,
  p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_business uuid;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_business_slug is not null then
    select identity_id, business_id into v_identity, v_business
      from app.v53_customer_feedback_context(p_business_slug);
  else
    select ci.id into v_identity
      from public.customer_identities ci
     where ci.auth_user_id = v_actor and ci.status = 'active'
     limit 1;
    if v_identity is null or not exists (
      select 1 from public.customer_links cl
       where cl.identity_id = v_identity and cl.auth_user_id = v_actor and cl.state = 'verified'
    ) then
      raise exception 'verified customer link required' using errcode = '42501';
    end if;
  end if;

  select coalesce(jsonb_agg(app.v53_feedback_json(f) order by f.created_at desc, f.id desc), '[]'::jsonb)
    into v_result
    from (
      select * from public.visit_feedback f
       where f.identity_id = v_identity
         and (v_business is null or f.business_id = v_business)
       order by f.created_at desc, f.id desc
       limit v_limit
    ) f;
  return jsonb_build_object('status', 'ok', 'feedback', v_result);
end $$;
revoke all privileges on function public.customer_list_my_feedback(text, integer)
  from public, anon, authenticated;
grant execute on function public.customer_list_my_feedback(text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Staff RPC: list the tenant's feedback / recovery queue.
--    GATE: can_module_read('clients') + active staff. Feedback is customer-context
--    data shown on the Customer-360 / service-recovery surface (clients module) — the
--    same module gate as every other staff customer read (e.g. staff_list_gift_cards
--    uses can_module_read('giftcards')). Customer name is the only PII, already on the
--    customers page.
-- ---------------------------------------------------------------------------
create or replace function public.staff_list_visit_feedback(
  p_business uuid,
  p_status text default null,
  p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_status text := nullif(btrim(lower(coalesce(p_status, ''))), '');
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if not app.can_module_read(p_business, 'clients') then
    raise exception 'active customers-module read authorization is required' using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at, s.id
   limit 1;
  if not found then
    raise exception 'active staff authorization is required' using errcode = '42501';
  end if;
  if v_status is not null and v_status not in ('open', 'acknowledged', 'resolved', 'closed') then
    raise exception 'unsupported feedback status filter' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', x.id,
    'client_id', x.client_id,
    'customer_name', x.full_name,
    'sale_id', x.sale_id,
    'rating', x.rating,
    'comment', x.comment,
    'recovery_status', x.recovery_status,
    'resolved_by', x.resolved_by,
    'resolved_at', x.resolved_at,
    'resolution_note', x.resolution_note,
    'created_at', x.created_at
  ) order by x.created_at desc, x.id desc), '[]'::jsonb)
    into v_result
    from (
      select f.id, f.client_id, c.full_name, f.sale_id, f.rating, f.comment,
             f.recovery_status, f.resolved_by, f.resolved_at, f.resolution_note, f.created_at
        from public.visit_feedback f
        left join public.clients c on c.id = f.client_id and c.business_id = f.business_id
       where f.business_id = p_business
         and (v_status is null or f.recovery_status = v_status)
       order by f.created_at desc, f.id desc
       limit v_limit
    ) x;
  return jsonb_build_object('status', 'ok', 'feedback', v_result);
end $$;
revoke all privileges on function public.staff_list_visit_feedback(uuid, text, integer)
  from public, anon, authenticated;
grant execute on function public.staff_list_visit_feedback(uuid, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Staff RPC: advance a recovery case (open -> acknowledged -> resolved).
--    GATE: can_module_write('clients') AND has_perm('refund_sales'). Writing to a
--    customer-attached record follows the v41 staff-customer-write precedent
--    (can_module_write('clients')); closing out a service-recovery case is a
--    make-good/accountability action, so it also requires refund_sales (owner/manager,
--    as v40 reversals do) — denying frontdesk/stylist the resolve action while they
--    still SEE the queue via the read gate above.
-- ---------------------------------------------------------------------------
create or replace function public.staff_resolve_feedback(
  p_business uuid,
  p_feedback uuid,
  p_new_status text,
  p_note text default null,
  p_idempotency_key uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_new text := nullif(btrim(lower(coalesce(p_new_status, ''))), '');
  v_note text := nullif(btrim(p_note), '');
  v_row public.visit_feedback%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if not app.can_module_write(p_business, 'clients')
     or not app.has_perm(p_business, 'refund_sales') then
    raise exception 'customers-module write and refund_sales authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
     and 'refund_sales' = any (app.role_perms(s.role))
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at, s.id
   limit 1;
  if not found then
    raise exception 'active staff authorization is required' using errcode = '42501';
  end if;
  if v_new not in ('acknowledged', 'resolved') then
    raise exception 'new status must be acknowledged or resolved' using errcode = '22023';
  end if;
  if v_note is not null and length(v_note) > 2000 then
    raise exception 'resolution note is too long' using errcode = '22023';
  end if;

  select * into v_row from public.visit_feedback f
   where f.id = p_feedback and f.business_id = p_business
   for update;
  if not found then
    raise exception 'feedback not found in this business' using errcode = '42501';
  end if;

  -- Idempotent no-op: already in the requested state.
  if v_row.recovery_status = v_new then
    return app.v53_feedback_staff_json(v_row);
  end if;
  if not (
       (v_row.recovery_status = 'open' and v_new in ('acknowledged', 'resolved'))
    or (v_row.recovery_status = 'acknowledged' and v_new = 'resolved')
  ) then
    raise exception 'illegal service-recovery transition % -> %', v_row.recovery_status, v_new
      using errcode = '22023';
  end if;

  perform set_config('app.visit_feedback_resolve_id', p_feedback::text, true);
  update public.visit_feedback f
     set recovery_status = v_new,
         resolved_by = case when v_new = 'resolved' then v_staff else f.resolved_by end,
         resolved_at = case when v_new = 'resolved' then now() else f.resolved_at end,
         resolution_note = coalesce(v_note, f.resolution_note)
   where f.id = p_feedback and f.business_id = p_business
   returning * into v_row;
  perform set_config('app.visit_feedback_resolve_id', '', true);

  return app.v53_feedback_staff_json(v_row);
end $$;
revoke all privileges on function public.staff_resolve_feedback(uuid, uuid, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.staff_resolve_feedback(uuid, uuid, text, text, uuid) to authenticated;

commit;

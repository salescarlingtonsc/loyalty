-- nestly_v542 — a business waiting on Stripe may ask to pay another way. Nothing else changes.
--
-- OWNER (2026-08-27, screenshot of "Payment confirmation pending" for Bear Bear Cafe): "i need a
-- back button for firms to change from stripe payment to manual payment. because now not able to
-- reverse the payment method." Then, on the shape: "implement it as a narrowly scoped
-- pending-business exception rather than broadly relaxing the guard."
--
-- WHY THERE WAS NO WAY BACK. public.request_self_serve_manual_application_v159 — the only manual
-- route in the product — refuses outright:
--
--     if exists(select 1 from public.staff where user_id=v_actor) then
--       raise exception 'this account is already assigned to a business workspace' 42501
--
-- Creating the business makes its owner staff, so from that instant the manual route is
-- unreachable. Verified on production: admin.peekaa@gmail.com holds an active owner row on
-- bear-bear-cafe, approval_status='pending', onboarding status='payment_pending', and zero
-- applications linked. A plain "back" link would therefore have landed on a form guaranteed to
-- 42501. That guard is CORRECT for what it protects — it stops a live workspace filing a second
-- signup — so it is not touched here. This is a separate, narrower door.
--
-- WHAT THIS IS, AND FIRMLY IS NOT. It records a REQUEST and nothing else:
--   * it does not change approval_status;
--   * it does not open the workspace;
--   * it does not create, record or verify a payment;
--   * it does not touch billing_provider_invoices, subscriptions or the onboarding status.
-- The Super Admin still actions it through the tools that already exist for an existing business
-- (platform_create_manual_invoice_v156 / platform_record_manual_payment_v156 /
-- platform_verify_manual_payment_v156). This migration only gives the firm a way to ask.
--
-- THE DOOR IS AS NARROW AS IT CAN BE. Every one of these must hold or the call is refused:
--   * an authenticated caller;
--   * who is an ACTIVE OWNER of that exact business (tenant safety — a staff member of another
--     firm, or a non-owner of this one, gets 42501, not a row);
--   * whose workspace_controls approval_status is still 'pending';
--   * whose self-serve onboarding is still 'payment_pending'.
-- An approved, active, rejected or suspended business is refused with a message that says so.
--
-- IDEMPOTENT TWO WAYS. A unique (business_id, idempotency_key) makes a retried submit return the
-- same row; a partial unique index on (business_id) where status='open' makes a second request
-- from a different key return the OPEN one rather than opening a queue of duplicates. A firm that
-- taps twice, or reloads mid-request, files one request.
--
-- STRIPE WINS. app.activate_self_serve_paid_v130 — the trigger that flips a business to approved
-- on a provider-confirmed paid invoice — now closes any open request as 'superseded' in the SAME
-- transaction. A firm that asks to pay manually and then completes Stripe anyway does not leave
-- the Super Admin an invoice to raise for a business that has already paid.

begin;

-- ---------------------------------------------------------------------------------------------
-- THE REQUEST
-- ---------------------------------------------------------------------------------------------
create table if not exists public.business_manual_payment_requests_v542(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  requested_by uuid not null,
  idempotency_key uuid not null,
  contact_phone text,
  note text,
  status text not null default 'open'
    check (status in ('open','superseded','actioned','withdrawn')),
  created_at timestamptz not null default now(),
  superseded_at timestamptz,
  actioned_at timestamptz,
  actioned_by uuid,
  decision_reason text,
  constraint business_manual_payment_requests_v542_idem_uk
    unique (business_id, idempotency_key)
);

/* One OPEN request per business. This is the second half of idempotency: a retry with a fresh key
   must not open a duplicate, because a Super Admin looking at two identical asks cannot tell
   whether the firm wants one invoice or two. */
create unique index if not exists business_manual_payment_requests_v542_one_open_uk
  on public.business_manual_payment_requests_v542(business_id)
  where status = 'open';

create index if not exists business_manual_payment_requests_v542_open_idx
  on public.business_manual_payment_requests_v542(status, created_at desc);

comment on table public.business_manual_payment_requests_v542 is
  'nestly_v542: a pending, unpaid business asking to settle by bank transfer or another manual arrangement instead of Stripe. A REQUEST only — it never changes approval status, opens a workspace, or records a payment.';

/* RLS on, and NO policy: the table is unreachable through the API in either direction. The RPC
   below is SECURITY DEFINER and is the only way in; the Super Admin reads it with the service
   role. A firm cannot list, edit or withdraw another firm's request because it cannot see the
   table at all. */
alter table public.business_manual_payment_requests_v542 enable row level security;
revoke all on public.business_manual_payment_requests_v542 from anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- THE ONE WAY IN
-- ---------------------------------------------------------------------------------------------
create or replace function public.business_request_manual_payment_v542(
  p_business uuid,
  p_idempotency_key uuid,
  p_contact_phone text default null,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_control public.business_workspace_controls_v94%rowtype;
  v_onboarding_status text;
  v_row public.business_manual_payment_requests_v542%rowtype;
  v_phone text := nullif(btrim(coalesce(p_contact_phone,'')),'');
  v_note text := left(nullif(btrim(coalesce(p_note,'')),''), 1000);
begin
  if v_actor is null then
    raise exception 'authenticated owner account required' using errcode = '28000';
  end if;
  if p_business is null or p_idempotency_key is null then
    raise exception 'business and idempotency key are required' using errcode = '22023';
  end if;

  /* TENANT SAFETY. Active OWNER of THIS business, not merely staff somewhere. A manager or a
     deactivated owner is refused for the same reason a stranger is: raising an invoice is the
     owner's decision. */
  if not exists (
    select 1 from public.staff s
     where s.business_id = p_business
       and s.user_id = v_actor
       and s.role = 'owner'
       and s.active
  ) then
    raise exception 'active owner of this business required' using errcode = '42501';
  end if;

  select * into v_control
    from public.business_workspace_controls_v94 c
   where c.business_id = p_business
   for share;
  if not found then
    raise exception 'this business has no workspace controls to act on' using errcode = '42704';
  end if;

  /* THE NARROW SCOPE. Only a business still waiting to be paid for may ask. An approved one is
     already open and has nothing to request; anything else is a state a Super Admin owns. */
  if v_control.approval_status is distinct from 'pending' then
    raise exception 'only a business still awaiting first payment can request manual payment (this one is %)',
      v_control.approval_status using errcode = '42501';
  end if;

  select o.status into v_onboarding_status
    from public.self_serve_business_onboarding_v130 o
   where o.business_id = p_business;
  if v_onboarding_status is distinct from 'payment_pending' then
    raise exception 'this business is not awaiting a first self-service payment' using errcode = '42501';
  end if;

  /* IDEMPOTENCY, FIRST FORM: the same key returns the same row. */
  select * into v_row
    from public.business_manual_payment_requests_v542 r
   where r.business_id = p_business and r.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('status','ok','request_id',v_row.id,
      'request_status',v_row.status,'replayed',true,'created_at',v_row.created_at);
  end if;

  /* IDEMPOTENCY, SECOND FORM: a different key while one is still open returns the open one. */
  select * into v_row
    from public.business_manual_payment_requests_v542 r
   where r.business_id = p_business and r.status = 'open';
  if found then
    return jsonb_build_object('status','ok','request_id',v_row.id,
      'request_status',v_row.status,'replayed',true,'created_at',v_row.created_at);
  end if;

  insert into public.business_manual_payment_requests_v542(
    business_id, requested_by, idempotency_key, contact_phone, note
  ) values (p_business, v_actor, p_idempotency_key, v_phone, v_note)
  returning * into v_row;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'MANUAL_PAYMENT_REQUESTED_V542',
    'business_manual_payment_requests_v542', v_row.id,
    jsonb_build_object(
      'approval_status_at_request', v_control.approval_status,
      'onboarding_status_at_request', v_onboarding_status,
      'workspace_unlocked', false,
      'payment_recorded', false));

  return jsonb_build_object('status','ok','request_id',v_row.id,
    'request_status',v_row.status,'replayed',false,'created_at',v_row.created_at);
end
$function$;

comment on function public.business_request_manual_payment_v542(uuid,uuid,text,text) is
  'nestly_v542: a pending, unpaid business asks to pay by another method. Records a request and nothing else — no approval change, no workspace unlock, no payment.';

revoke all on function public.business_request_manual_payment_v542(uuid,uuid,text,text) from public;
/* One role per statement. tests/security-hardening/v21 reads the authenticated allowlist with a
   pattern that ends at `to authenticated;`, so a combined `to authenticated, service_role;` is
   invisible to it — and an RPC the SPA calls that the security test cannot see is exactly what
   that test exists to catch. */
grant execute on function public.business_request_manual_payment_v542(uuid,uuid,text,text) to authenticated;
grant execute on function public.business_request_manual_payment_v542(uuid,uuid,text,text) to service_role;

/* The owner also has to be able to SEE that the ask landed, or they will tap it again and again.
   Read-only, same owner test, nothing but this business's own request. */
create or replace function public.business_get_manual_payment_request_v542(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_row public.business_manual_payment_requests_v542%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authenticated owner account required' using errcode = '28000';
  end if;
  if not exists (
    select 1 from public.staff s
     where s.business_id = p_business and s.user_id = auth.uid()
       and s.role = 'owner' and s.active
  ) then
    raise exception 'active owner of this business required' using errcode = '42501';
  end if;
  select * into v_row
    from public.business_manual_payment_requests_v542 r
   where r.business_id = p_business
   order by case when r.status='open' then 0 else 1 end, r.created_at desc
   limit 1;
  if not found then return jsonb_build_object('status','none'); end if;
  return jsonb_build_object('status','ok','request_id',v_row.id,
    'request_status',v_row.status,'created_at',v_row.created_at,
    'superseded_at',v_row.superseded_at);
end
$function$;

revoke all on function public.business_get_manual_payment_request_v542(uuid) from public;
grant execute on function public.business_get_manual_payment_request_v542(uuid) to authenticated;
grant execute on function public.business_get_manual_payment_request_v542(uuid) to service_role;

-- ---------------------------------------------------------------------------------------------
-- STRIPE SUPERSEDES THE ASK, in the same transaction that opens the workspace.
-- Spliced, not retyped: app.activate_self_serve_paid_v130 is a long settled SECURITY DEFINER
-- trigger and retyping it to add four lines is how v277's incident happened. The anchor is
-- REPRODUCED inside the replacement (the nestly_v513 rule).
-- ---------------------------------------------------------------------------------------------
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    new.business_id,null,''SELF_SERVICE_PAYMENT_CONFIRMED'',';
  v_inject constant text :=
'  -- nestly_v542: the firm asked to pay another way and then paid through Stripe anyway. Close
  -- the ask here, in the same transaction that opens the workspace, so no Super Admin raises an
  -- invoice for a business that has already paid.
  update public.business_manual_payment_requests_v542
     set status=''superseded'', superseded_at=new.first_paid_at,
         decision_reason=''provider-confirmed self-service subscription payment''
   where business_id=new.business_id and status=''open'';

  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    new.business_id,null,''SELF_SERVICE_PAYMENT_CONFIRMED'',';
begin
  v_def := pg_get_functiondef('app.activate_self_serve_paid_v130()'::regprocedure);
  if position('business_manual_payment_requests_v542' in v_def) > 0 then
    raise notice 'nestly_v542: the activation trigger already supersedes manual requests, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v542: anchor did not match exactly once in activate_self_serve_paid_v130 — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    if v_new = v_def then
      raise exception 'nestly_v542: splice produced no change' using errcode='XX001';
    end if;
    execute v_new;
  end if;
end
$splice$;

-- ---------------------------------------------------------------------------------------------
-- Prove the code change took, in the same transaction.
-- ---------------------------------------------------------------------------------------------
do $verify$
begin
  if position('business_manual_payment_requests_v542'
        in pg_get_functiondef('app.activate_self_serve_paid_v130()'::regprocedure)) = 0 then
    raise exception 'nestly_v542: Stripe activation does not supersede an open manual request'
      using errcode='XX001';
  end if;
  if (select count(*) from pg_policies
       where schemaname='public' and tablename='business_manual_payment_requests_v542') <> 0 then
    raise exception 'nestly_v542: the request table must have NO policy — the RPC is the only way in'
      using errcode='XX001';
  end if;
  if not exists (select 1 from pg_class
                  where relname='business_manual_payment_requests_v542_one_open_uk') then
    raise exception 'nestly_v542: the one-open-request index is missing' using errcode='XX001';
  end if;
end
$verify$;

commit;

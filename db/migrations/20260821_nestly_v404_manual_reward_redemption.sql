-- ============================================================================
-- nestly_v404 — staff manual reward redemption, without the customer's QR
--
-- Owner ruling 2026-08-21, photo 1: "'ready' change to redeem > and able to click
-- to redeem", with a quantity control "like record sale", and the trade-off of
-- redeeming without proof of the customer's presence explicitly accepted.
--
-- THE CONSTRAINT THIS WORKS AROUND, AND WHY IT IS NOT REOPENED.
-- v94 revoked EXECUTE on public.redeem_reward_at_context / redeem_reward /
-- redeem_points from `authenticated` — "browser execution is retired". That
-- decision stands: this migration does NOT re-grant any of them, and restates
-- the revokes at the end so a later hand cannot quietly undo it. The browser
-- gets ONE new, narrow, definer-owned entry point instead, which re-derives
-- every permission itself and then delegates the money to the same
-- app.redeem_reward_core the QR scanner already uses. Nothing about points
-- accounting, reward eligibility, limits, provenance or idempotency is
-- reimplemented here.
--
-- WHAT REPLACES THE QR AS A CONTROL.
-- A QR proved the customer was present. Nothing can prove that here, so the
-- compensating control is evidence: every manual redemption writes a row naming
-- the customer, the reward, the quantity, the staff member, the branch, the
-- timestamp, a required reason and method='manual_no_qr'. Manual redemptions are
-- therefore separable from scanned ones in any report, and a staff member who
-- leans on this is visible.
--
-- PERMISSION (owner ruling): owner and manager by default; every other staff
-- member NOT by default, and grantable to individuals by an owner or manager.
-- staff.capabilities is the grant, mirroring the existing staff.modules idiom.
--
-- SCOPE: catalogue point/stamp rewards only — the app.redeem_reward_core path.
-- Promotions, growth offers, packages and gift cards are token-bound by design
-- and stay QR-only. QR remains the default redemption method everywhere.
-- ============================================================================

begin;

-- ---------------------------------------------------------------- the grant
alter table public.staff add column if not exists capabilities text[];

comment on column public.staff.capabilities is
  'v404: per-staff capability grants, NULL or empty = none. Owner and manager do '
  'not need a grant for manual_reward_redemption; every other role does.';

-- ------------------------------------------------------- the permission test
-- Deliberately one function, so the RPC below, the projection the browser reads
-- and any future caller cannot drift into three different answers.
create or replace function app.can_manual_redeem_v404(p_business uuid, p_branch uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select auth.uid() is not null
     -- spending a customer's points is a loyalty write, exactly as the scan path requires
     and app.can_module_write(p_business,'loyalty')
     -- branch scope, workspace-open and suspension are all inside can_see_branch
     and app.can_see_branch(p_business, p_branch)
     and exists (
       select 1 from public.staff s
        where s.business_id = p_business
          and s.user_id = auth.uid()
          and s.active
          and (
            app.role_class(s.role) in ('owner','admin')
            or 'manual_reward_redemption' = any(coalesce(s.capabilities,'{}'::text[]))
          )
     )
$$;

-- ------------------------------------------------------------ granting the grant
create or replace function public.set_staff_capability_v404(
  p_business uuid,
  p_staff uuid,
  p_capability text,
  p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_role text;
  v_target public.staff%rowtype;
  v_after text[];
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  -- Only the two roles the owner named may hand this out.
  select s.role into v_actor_role from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
   order by case when s.role='owner' then 0 else 1 end, s.created_at limit 1;
  if v_actor_role is null or app.role_class(v_actor_role) not in ('owner','admin') then
    raise exception 'only an owner or manager may change staff capabilities' using errcode='42501';
  end if;
  -- One capability exists today. A whitelist, not free text, so this can never
  -- become a way to invent permissions the rest of the schema does not check.
  if p_capability is distinct from 'manual_reward_redemption' then
    raise exception 'unknown capability' using errcode='22023';
  end if;

  select * into v_target from public.staff
   where id=p_staff and business_id=p_business for update;
  if not found then
    raise exception 'staff member not found in this business' using errcode='42704';
  end if;
  -- An owner already holds this by role; letting it be written onto an owner row
  -- would imply it could also be taken away, which it cannot.
  if v_target.role='owner' then
    raise exception 'an owner already holds every capability' using errcode='22023';
  end if;

  v_after := case
    when coalesce(p_enabled,false)
      then (select array(select distinct unnest(coalesce(v_target.capabilities,'{}'::text[]) || array[p_capability])))
    else (select array(select unnest(coalesce(v_target.capabilities,'{}'::text[])) except select p_capability))
  end;
  update public.staff set capabilities=v_after where id=p_staff;

  insert into public.audit_log(id,business_id,actor,action,entity,entity_id,detail)
  values (gen_random_uuid(), p_business, v_actor,
          case when coalesce(p_enabled,false) then 'capability.granted' else 'capability.revoked' end,
          'staff', p_staff,
          jsonb_build_object('capability',p_capability,'enabled',coalesce(p_enabled,false),
                             'capabilities_after',to_jsonb(v_after)));

  return jsonb_build_object('status','ok','staff_id',p_staff,'capabilities',to_jsonb(v_after));
end
$$;

-- ------------------------------------------------------------------- evidence
create table if not exists public.loyalty_manual_redemptions_v404 (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references public.businesses(id) on delete restrict,
  client_id       uuid not null,
  reward_id       uuid,
  staff_id        uuid,
  actor           uuid not null,
  branch_id       uuid,
  quantity        integer not null check (quantity >= 1),
  operation_ids   uuid[] not null,
  method          text not null default 'manual_no_qr' check (method = 'manual_no_qr'),
  reason_code     text not null check (reason_code in ('customer_unable_to_show_qr','other')),
  reason_note     text,
  idempotency_key text not null,
  created_at      timestamptz not null default now(),
  constraint loyalty_manual_redemptions_v404_client_fk
    foreign key (client_id, business_id) references public.clients(id, business_id) on delete restrict,
  constraint loyalty_manual_redemptions_v404_key_uk unique (business_id, idempotency_key)
);

comment on table public.loyalty_manual_redemptions_v404 is
  'v404: one row per manual (no-QR) redemption action. This is the compensating control for '
  'the missing customer-presence proof — it is what makes a manual redemption separable from '
  'a scanned one in reports. Written only by staff_manual_redeem_reward_v404; the table '
  'carries no write policy at all.';

create index if not exists loyalty_manual_redemptions_v404_business_created
  on public.loyalty_manual_redemptions_v404 (business_id, created_at desc);
create index if not exists loyalty_manual_redemptions_v404_client
  on public.loyalty_manual_redemptions_v404 (business_id, client_id, created_at desc);

alter table public.loyalty_manual_redemptions_v404 enable row level security;

drop policy if exists loyalty_manual_redemptions_v404_read on public.loyalty_manual_redemptions_v404;
create policy loyalty_manual_redemptions_v404_read
  on public.loyalty_manual_redemptions_v404 for select to authenticated
  using (app.can_module_read(business_id,'loyalty'));

drop policy if exists loyalty_manual_redemptions_v404_sa_read on public.loyalty_manual_redemptions_v404;
create policy loyalty_manual_redemptions_v404_sa_read
  on public.loyalty_manual_redemptions_v404 for select to authenticated
  using (app.is_super_admin());

-- No INSERT/UPDATE/DELETE policy anywhere: the definer function below is the only writer.
revoke all privileges on table public.loyalty_manual_redemptions_v404 from public, anon, authenticated;
grant select on table public.loyalty_manual_redemptions_v404 to authenticated;

-- ------------------------------------------------------------------ the writer
create or replace function public.staff_manual_redeem_reward_v404(
  p_business uuid,
  p_client uuid,
  p_reward uuid,
  p_quantity integer,
  p_branch uuid,
  p_reason_code text,
  p_reason_note text,
  p_idempotency_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_qty integer := coalesce(p_quantity,1);
  v_max constant integer := 20;
  v_existing public.loyalty_manual_redemptions_v404%rowtype;
  v_unit_key text;
  v_operation uuid;
  v_operations uuid[] := '{}';
  v_result json;
  v_last json;
  i integer;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode='22023';
  end if;
  -- Quantity is bounded HERE; affordability is proved by actually performing each
  -- unit below, never by this function recomputing a balance against a cost.
  if v_qty < 1 or v_qty > v_max then
    raise exception 'manual_redeem_quantity_out_of_range' using errcode='22023';
  end if;
  if p_reason_code is null or p_reason_code not in ('customer_unable_to_show_qr','other') then
    raise exception 'manual_redeem_reason_required' using errcode='22023';
  end if;
  if p_reason_code='other' and coalesce(btrim(p_reason_note),'')='' then
    raise exception 'manual_redeem_reason_note_required' using errcode='22023';
  end if;
  -- The permission the owner defined, re-derived server-side. The browser's copy
  -- of it is a rendering hint and is never trusted.
  if not app.can_manual_redeem_v404(p_business, p_branch) then
    raise exception 'manual_reward_redemption is not permitted for this staff member or branch'
      using errcode='42501';
  end if;

  select s.id into v_staff from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
   order by case when s.role='owner' then 0 else 1 end, s.created_at limit 1;

  -- Replay of the same action returns the same receipt and redeems nothing further.
  select * into v_existing from public.loyalty_manual_redemptions_v404
   where business_id=p_business and idempotency_key=p_idempotency_key;
  if found then
    return jsonb_build_object('status','duplicate_ignored','quantity',v_existing.quantity,
                              'operation_ids',to_jsonb(v_existing.operation_ids));
  end if;

  -- Two staff cannot interleave halves of two multi-unit redemptions of one balance.
  perform pg_advisory_xact_lock(hashtextextended('v404:manual-redeem:'||p_business::text||':'||p_client::text, 0));

  for i in 1..v_qty loop
    -- One core call per unit, each with its own derived key: a replay of the whole
    -- action re-uses the same unit keys, and the core answers each from its stored
    -- result rather than redeeming again.
    v_unit_key := p_idempotency_key||':'||i::text;
    v_result := app.redeem_reward_core(p_business, p_client, p_reward, v_unit_key, p_branch, null, null);
    v_last := v_result;
    select o.id into v_operation from public.loyalty_operations o
     where o.business_id=p_business and o.operation_type='redeem_reward' and o.idempotency_key=v_unit_key;
    if v_operation is null then
      raise exception 'manual redemption operation was not recorded' using errcode='40001';
    end if;
    v_operations := v_operations || v_operation;
  end loop;

  insert into public.loyalty_manual_redemptions_v404(
    business_id,client_id,reward_id,staff_id,actor,branch_id,quantity,operation_ids,
    method,reason_code,reason_note,idempotency_key)
  values (p_business,p_client,p_reward,v_staff,v_actor,p_branch,v_qty,v_operations,
          'manual_no_qr',p_reason_code,nullif(btrim(p_reason_note),''),p_idempotency_key);

  return jsonb_build_object('status','ok','quantity',v_qty,
                            'operation_ids',to_jsonb(v_operations),'last',to_jsonb(v_last));
end
$$;

-- ------------------------------------------- the browser's copy of the permission
-- Added to the projection the workspace already fetches once per business load, so
-- the Record Sale screen can decide whether to DRAW the control without a second
-- round trip. It is a rendering hint only: a revoked capability still sitting in a
-- stale client just draws a button the server refuses.
create or replace function public.get_my_modules(p_business uuid)
returns json
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_perms jsonb;
begin
  v_perms := app.staff_module_perms_at_v115(p_business,null);
  return json_build_object(
    'modules', to_json(coalesce(
      (select array_agg(k order by k)
         from jsonb_object_keys(v_perms) as keys(k)),
      array[]::text[]
    )),
    'module_perms', v_perms,
    'role', (select s.role from public.staff s
              where s.business_id = p_business and s.user_id = auth.uid() and s.active
              order by case when s.role = 'owner' then 0 else 1 end, s.created_at limit 1),
    'capabilities', to_json(coalesce(
      (select s.capabilities from public.staff s
        where s.business_id = p_business and s.user_id = auth.uid() and s.active
        order by case when s.role = 'owner' then 0 else 1 end, s.created_at limit 1),
      array[]::text[]
    )),
    'is_super_admin', app.is_super_admin()
  );
end
$$;

comment on function public.get_my_modules(uuid) is
  'v404: also returns the staff row''s capabilities array, so the workspace can decide '
  'whether to draw the manual-redemption control without a second round trip. v233: resolves '
  'the module set once rather than twice.';

-- ----------------------------------------------------------------------- grants
revoke all privileges on function public.set_staff_capability_v404(uuid,uuid,text,boolean)
  from public, anon;
grant execute on function public.set_staff_capability_v404(uuid,uuid,text,boolean)
  to authenticated;
revoke all privileges on function public.staff_manual_redeem_reward_v404(uuid,uuid,uuid,integer,uuid,text,text,text)
  from public, anon;
grant execute on function public.staff_manual_redeem_reward_v404(uuid,uuid,uuid,integer,uuid,text,text,text)
  to authenticated;
revoke all privileges on function public.get_my_modules(uuid) from public, anon;
grant execute on function public.get_my_modules(uuid) to authenticated;
revoke all privileges on function app.can_manual_redeem_v404(uuid,uuid) from public, anon, authenticated;

-- v94's revokes, restated. This migration adds a redemption path; it must not become
-- the migration that quietly handed the old unguarded ones back to the browser.
revoke execute on function public.redeem_points(uuid,uuid,text) from authenticated;
revoke execute on function public.redeem_reward(uuid,uuid,uuid,text) from authenticated;
revoke execute on function public.redeem_reward_at_context(uuid,uuid,uuid,text,uuid,uuid,uuid) from authenticated;

commit;

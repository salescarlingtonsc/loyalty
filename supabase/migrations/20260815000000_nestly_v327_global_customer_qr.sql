-- NESTLY v327 — global Peekaa customer QR: static, opaque, cross-merchant identity.
--
-- Owner spec (2026-08-15): a customer's QR must resolve to the SAME underlying
-- Peekaa customer at every merchant they join, deduped by phone at the platform
-- level, without the QR itself ever encoding the phone number or an enumerable
-- client id. Scanning staff resolve token -> platform identity -> this
-- business's own client relationship (auto-creating one on first scan), never
-- the reverse (identity -> phone is not derivable from the token).
--
-- Builds entirely on existing infrastructure rather than a new global-customer
-- table:
--   * public.customer_identities / public.customer_links (v30/v31) already
--     model "one platform identity, one clients row per firm" — exactly the
--     shape asked for. Platform-level phone dedup at identity-creation time is
--     also already built (v42, public.customer_register_verified_phone). This
--     migration only adds the QR token layer on top of an existing identity;
--     it does not change how an identity is created or deduped.
--   * Token derivation follows v197 (business join QR) exactly: token =
--     hmac(secret, identity_id||':'||version). The secret lives in Vault and
--     never leaves Postgres; only sha256(token) is ever stored, so a table
--     dump yields no working QR. Being a pure function of (identity, version)
--     means it can be re-displayed indefinitely — no "burn the QR by looking
--     at it" bug like the one v197 fixed for business join QRs.
--   * Resolution reuses app.v89_sha256 and the advisory-lock-then-lookup
--     pattern from merchant_scan_redemption_qr_v117.
--
-- Supersedes the unshipped MEMBER_CODE_CONTRACT_W6I2 client-side stub in
-- app/app.js, which was explicitly documented as per-business-opaque by
-- design ("a code that worked at every business would hand one counter an
-- identifier for all of them"). That constraint is the opposite of this owner
-- directive, so the named-but-never-implemented
-- customer_get_member_code_v310 / staff_resolve_member_code_v310 are retired
-- in favour of the RPCs below. The client keeps emitting the same
-- "nestly:member:<token>" QR payload prefix, so the existing scanner-side
-- parser (redemptionPayloadFromQr) needs no wire-format change — only its
-- dead 'member' branch gets wired up.
--
-- Owner ruling (2026-08-15): first scan at a business with no existing
-- verified relationship silently auto-provisions a clients row + link — no
-- staff confirmation step, matching the walk-in feel of the existing
-- lookup_client_by_phone/record_sale_by_phone till flow.
--
-- verification_method: 'qr_join' was found live in prod (12 rows, the
-- business-join-QR flow) when this migration was dry-run and is added to the
-- allowed set alongside the new 'qr_scan' method, on top of the documented
-- email_claim/firm_invitation/phone_claim.
--
-- APPLIED (2026-08-15): owner explicitly approved applying this exact
-- migration to production (gadpooereceldfpfxsod) after a full rolled-back
-- dry run (this DDL + the pristine two-tenant fixture + every assertion in
-- db/tests/v327_global_customer_qr.sql) passed against prod with nothing left
-- behind, and after the auto-mode classifier initially blocked the apply
-- call. Two things were fixed during that dry run and are folded in below:
-- customer_links_verification_method_check needed 'qr_join' (an existing
-- live value this migration hadn't accounted for), and the customer_links
-- insert needed app.v31_link_immutable_guard's session-sentinel convention
-- (set app.customer_link_insert_id to the pre-generated id before insert) —
-- the same pattern every other verified-claim RPC in v31/v42 already follows.

begin;

alter table public.customer_identities
  add column if not exists qr_token_version integer not null default 1,
  add column if not exists qr_token_hash text;

alter table public.customer_identities
  drop constraint if exists customer_identities_qr_token_hash_format_check;
alter table public.customer_identities
  add constraint customer_identities_qr_token_hash_format_check
  check (qr_token_hash is null or qr_token_hash ~ '^[0-9a-f]{64}$');

create unique index if not exists customer_identities_qr_token_hash_uk
  on public.customer_identities (qr_token_hash) where qr_token_hash is not null;

comment on column public.customer_identities.qr_token_hash is
  'v327. sha256 of the current derived member QR token (hmac(secret, id||'':''||qr_token_version)). Plaintext is never stored; recompute via app.v327_member_qr_token to redisplay.';

-- verification_method previously allowed email_claim/firm_invitation (v31),
-- phone_claim (v42), and qr_join (live in prod — the business-join-QR flow,
-- 12 rows found when this migration was dry-run, not documented in any
-- checked-in migration same as norm_phone/super_admins). A QR-scan-provisioned
-- link is a new, distinct method — it establishes the merchant relationship
-- via the GLOBAL member QR, not the business-join QR.
alter table public.customer_links
  drop constraint if exists customer_links_verification_method_check;
alter table public.customer_links
  add constraint customer_links_verification_method_check
  check (verification_method in ('email_claim', 'firm_invitation', 'phone_claim', 'qr_join', 'qr_scan'));

-- One platform-wide secret, generated inside Postgres so it is never handled
-- by a person or a tool. Rotating it would invalidate every customer's member
-- QR at once, so it is created only if absent and never overwritten.
do $v327_secret$
begin
  if not exists (select 1 from vault.decrypted_secrets where name='v327_member_qr_secret') then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32),'hex'),
      'v327_member_qr_secret',
      'HMAC key deriving the persistent global-customer member QR token (v327). Rotating this invalidates every printed member QR at once.'
    );
  end if;
end
$v327_secret$;

create or replace function app.v327_member_qr_secret()
returns text language plpgsql security definer stable
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_secret text;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name='v327_member_qr_secret' limit 1;
  if v_secret is null or length(v_secret)<32 then
    raise exception 'member QR secret is not configured' using errcode='55000';
  end if;
  return v_secret;
end $$;

create or replace function app.v327_member_qr_token(p_identity uuid, p_version integer)
returns text language plpgsql security definer stable
set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
begin
  if p_identity is null or p_version is null or p_version < 1 then
    raise exception 'identity and rotation version are required' using errcode='22023';
  end if;
  return encode(extensions.hmac(
    p_identity::text||':'||p_version::text,
    app.v327_member_qr_secret(),
    'sha256'
  ),'hex');
end $$;

revoke all on function app.v327_member_qr_secret() from public, anon, authenticated;
revoke all on function app.v327_member_qr_token(uuid,integer) from public, anon, authenticated;

-- Customer-side: fetch (and lazily derive) my own static member QR token.
-- Requires an existing platform identity — call customer_create_identity
-- first, same prerequisite as every other customer_* RPC.
create or replace function public.customer_get_member_qr_v327()
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid := auth.uid();
  v_identity public.customer_identities%rowtype;
  v_token text;
  v_hash text;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  if not app.platform_feature_enabled('customer_identity') then
    raise exception 'customer access is unavailable' using errcode='0A000';
  end if;

  select * into v_identity from public.customer_identities
   where auth_user_id=v_actor for update;
  if not found then
    raise exception 'a platform identity is required before a member QR can be issued'
      using errcode='42501';
  end if;
  if v_identity.status <> 'active' then
    raise exception 'this platform identity is not active' using errcode='42501';
  end if;

  v_token := app.v327_member_qr_token(v_identity.id, v_identity.qr_token_version);
  v_hash := app.v89_sha256(v_token);
  if v_identity.qr_token_hash is distinct from v_hash then
    update public.customer_identities
       set qr_token_hash = v_hash, updated_at = now()
     where id = v_identity.id;
  end if;

  return jsonb_build_object(
    'identity_id', v_identity.id,
    'member_qr', 'nestly:member:'||v_token,
    'token_version', v_identity.qr_token_version
  );
end $$;

-- Rotation is an explicit act: bump the version, which changes the derived
-- token and invalidates every QR shown before the rotation (e.g. "I think my
-- QR photo leaked").
create or replace function public.customer_rotate_member_qr_v327()
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid := auth.uid();
  v_identity public.customer_identities%rowtype;
  v_token text;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  select * into v_identity from public.customer_identities
   where auth_user_id=v_actor for update;
  if not found then
    raise exception 'a platform identity is required before a member QR can be rotated'
      using errcode='42501';
  end if;

  update public.customer_identities
     set qr_token_version = qr_token_version + 1
   where id = v_identity.id
  returning * into v_identity;

  v_token := app.v327_member_qr_token(v_identity.id, v_identity.qr_token_version);
  update public.customer_identities
     set qr_token_hash = app.v89_sha256(v_token), updated_at = now()
   where id = v_identity.id;

  return jsonb_build_object(
    'identity_id', v_identity.id,
    'member_qr', 'nestly:member:'||v_token,
    'token_version', v_identity.qr_token_version
  );
end $$;

-- Merchant-side scan resolution. Response shape mirrors lookup_client_by_phone
-- so the till UI can feed it straight into the existing Record Sale prefill.
-- Resolution is strictly token_hash -> identity -> this business's client; no
-- raw phone or email is ever read from the token itself. The advisory lock is
-- keyed on (business, token_hash), so two concurrent scans of the same QR at
-- the same business fully serialize — the second sees the first's link.
create or replace function public.staff_scan_member_qr_v327(
  p_business uuid,
  p_member_qr text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_token text;
  v_hash text;
  v_identity public.customer_identities%rowtype;
  v_link public.customer_links%rowtype;
  v_client public.clients%rowtype;
  v_actor uuid := auth.uid();
  v_display_name text;
  v_link_id uuid;
  v_created boolean := false;
  v_points integer;
  v_credit integer;
  v_visits integer;
  lp record;
begin
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module_write(p_business, 'clients') then
    raise exception 'clients write and create-sales authorization is required'
      using errcode='42501';
  end if;

  v_token := btrim(coalesce(p_member_qr,''));
  if v_token like 'nestly:member:%' then
    v_token := substring(v_token from length('nestly:member:')+1);
  end if;
  if v_token !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('status','invalid','message','This QR is not a Peekaa member code.');
  end if;
  v_hash := app.v89_sha256(v_token);

  perform pg_advisory_xact_lock(hashtextextended('v327:scan:'||p_business::text||':'||v_hash,0));

  select * into v_identity from public.customer_identities
   where qr_token_hash = v_hash for share;
  if not found or v_identity.status <> 'active' then
    return jsonb_build_object('status','invalid','message','This member QR is no longer active.');
  end if;

  select * into v_link from public.customer_links
   where business_id=p_business and identity_id=v_identity.id and state='verified'
   order by created_at desc limit 1
   for update;

  if found then
    select * into v_client from public.clients where id=v_link.client_id and business_id=p_business;
  else
    select coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'),''), 'Peekaa Member')
      into v_display_name
      from auth.users u where u.id=v_identity.auth_user_id;

    insert into public.clients (business_id, full_name)
    values (p_business, v_display_name)
    returning * into v_client;

    v_link_id := gen_random_uuid();
    perform set_config('app.customer_link_insert_id', v_link_id::text, true);
    insert into public.customer_links (
      id, business_id, identity_id, auth_user_id, client_id, state,
      verification_method, verified_at
    ) values (
      v_link_id, p_business, v_identity.id, v_identity.auth_user_id, v_client.id, 'verified',
      'qr_scan', now()
    )
    returning * into v_link;
    perform set_config('app.customer_link_insert_id', '', true);
    v_created := true;

    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values(p_business, v_actor, 'AUTO_PROVISION_CLIENT_FROM_MEMBER_QR_V327',
      'clients', v_client.id, jsonb_build_object('identity_id', v_identity.id, 'link_id', v_link.id));
  end if;

  select coalesce(sum(points),0) into v_points
    from public.points_ledger where business_id=p_business and client_id=v_client.id;
  select coalesce(sum(amount_cents),0) into v_credit
    from public.credit_ledger where business_id=p_business and client_id=v_client.id;
  select count(*) into v_visits
    from public.sales where business_id=p_business and client_id=v_client.id and counts_as_visit;
  select * into lp from public.loyalty_programs
   where business_id=p_business and active limit 1;

  return jsonb_build_object(
    'status','found','client_id',v_client.id,'full_name',v_client.full_name,
    'phone',v_client.phone_norm,
    'points',v_points,'credit_cents',v_credit,'visits',v_visits,
    'redeem_points',lp.redeem_points,'reward_credit_cents',lp.reward_credit_cents,
    'can_redeem',(lp.redeem_points is not null and v_points>=lp.redeem_points),
    'points_to_next',greatest(coalesce(lp.redeem_points,0)-v_points,0),
    'member_since',v_client.created_at,
    'newly_linked',v_created);
end $$;

revoke all on function public.customer_get_member_qr_v327() from public, anon, authenticated;
revoke all on function public.customer_rotate_member_qr_v327() from public, anon, authenticated;
revoke all on function public.staff_scan_member_qr_v327(uuid,text) from public, anon, authenticated;
grant execute on function public.customer_get_member_qr_v327() to authenticated;
grant execute on function public.customer_rotate_member_qr_v327() to authenticated;
grant execute on function public.staff_scan_member_qr_v327(uuid,text) to authenticated;

commit;

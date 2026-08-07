-- NESTLY v197 — the customer join QR becomes permanent and re-printable.
--
-- Owner report: "I need a persistent QR — I will print it out, I cannot accept
-- the QR keep changing."
--
-- Root cause, and it was structural rather than a settings mistake. v89 stored
-- ONLY sha256(token); the plaintext was returned once, at creation, and
-- business_get_customer_join_qr_status_v91 returns just a count and an expiry.
-- So after leaving the page the QR could never be displayed again, and the only
-- way to see one was to create a new one — which revoked the old. Production
-- shows exactly that: one business burned four QRs in a single day
-- (08:34 -> 09:41 -> 16:26 -> 16:31), each revoking the last. Every attempt to
-- look at the QR destroyed the previous printed copy. A 370-day cap (enforced
-- twice: in the RPCs and as a table CHECK) then killed any survivor within a
-- year.
--
-- The fix is to stop storing a secret we cannot show, and derive it instead:
--
--     token = hmac_sha256(secret, business_id || ':' || token_version)
--
-- The secret lives in Vault and never leaves Postgres. Because the token is a
-- pure function of (business, version), it can be recomputed for display any
-- number of times, so the same QR is shown — and printed — forever. Nothing
-- newly sensitive is stored: the table still keeps only sha256(token), so a
-- dump of this table still yields no working join link, which is the property
-- the original hashing was protecting.
--
-- Rotation becomes an explicit act (bump the version) rather than the
-- accidental side effect of wanting to look at your own QR.
--
-- Compatibility: every consumer — customer_join_business_from_qr_v89,
-- internal_public_join_v89, internal_public_join_page_v89,
-- internal_record_account_open_join_v175 — resolves a scan by token_hash, and
-- token_hash keeps exactly its old meaning and format. None of them change, and
-- neither does any application file.
--
-- ONE-TIME COST, deliberately accepted: existing rows hold random tokens whose
-- plaintext is unrecoverable by construction. They cannot be re-derived, so the
-- first ensure() after this migration rotates such a business once onto a
-- derived token. That invalidates a QR printed before today — unavoidable, and
-- the last time it can ever happen.

begin;

-- The QR is meant to outlive a printed poster on a wall, so the year cap goes.
-- The floor (expiry must follow creation) stays.
alter table public.business_customer_join_qr_v89
  drop constraint if exists business_customer_join_qr_v89_expiry_check;
alter table public.business_customer_join_qr_v89
  add constraint business_customer_join_qr_v89_expiry_check
  check (expires_at > created_at
    and expires_at <= created_at + interval '100 years');

alter table public.business_customer_join_qr_v89
  add column if not exists token_version integer;

comment on column public.business_customer_join_qr_v89.token_version is
  'v197 rotation counter. The join token is hmac(secret, business_id||'':''||token_version), so it can be re-displayed and re-printed indefinitely. NULL marks a pre-v197 random token whose plaintext is unrecoverable.';

-- One platform-wide secret, generated inside Postgres so it is never handled by
-- a person or a tool. Rotating it would invalidate every firm's QR at once, so
-- it is created only if absent and never overwritten.
do $v197_secret$
begin
  if not exists (select 1 from vault.decrypted_secrets where name='v197_join_qr_secret') then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32),'hex'),
      'v197_join_qr_secret',
      'HMAC key deriving persistent customer join QR tokens (v197). Rotating this invalidates every printed QR.'
    );
  end if;
end
$v197_secret$;

create or replace function app.v197_join_qr_secret()
returns text language plpgsql security definer stable
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_secret text;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name='v197_join_qr_secret' limit 1;
  if v_secret is null or length(v_secret)<32 then
    raise exception 'join QR secret is not configured' using errcode='55000';
  end if;
  return v_secret;
end $$;

-- The whole point: a token that is a pure function of the firm and its
-- rotation, so it can be shown again tomorrow and still scan.
create or replace function app.v197_join_token(p_business uuid, p_version integer)
returns text language plpgsql security definer stable
set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
begin
  if p_business is null or p_version is null or p_version < 1 then
    raise exception 'business and rotation version are required' using errcode='22023';
  end if;
  return encode(extensions.hmac(
    p_business::text||':'||p_version::text,
    app.v197_join_qr_secret(),
    'sha256'
  ),'hex');
end $$;

revoke all on function app.v197_join_qr_secret() from public, anon, authenticated;
revoke all on function app.v197_join_token(uuid,integer) from public, anon, authenticated;

-- Creation now derives instead of randomising, and defaults to a permanent
-- expiry. p_expires_at is honoured as a FLOOR: a caller asking for a year still
-- gets a QR that outlives the poster, which is what "persistent" has to mean
-- for something printed and stuck on a wall.
create or replace function public.business_create_customer_join_qr_v89(
  p_business uuid,
  p_expires_at timestamptz default now()+interval '365 days'
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare
  v_token text; v_version integer; v_expires timestamptz;
  v_qr public.business_customer_join_qr_v89%rowtype;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'business owner access is required' using errcode='42501';
  end if;
  if p_expires_at is not null and p_expires_at <= now()+interval '5 minutes' then
    raise exception 'join QR expiry must be at least 5 minutes away' using errcode='22023';
  end if;
  v_expires := greatest(coalesce(p_expires_at, now()), now()+interval '50 years');

  select coalesce(max(token_version),0)+1 into v_version
  from public.business_customer_join_qr_v89 where business_id=p_business;
  v_token := app.v197_join_token(p_business, v_version);

  insert into public.business_customer_join_qr_v89(
    business_id,token_hash,expires_at,issued_by,token_version
  ) values(p_business,app.v89_sha256(v_token),v_expires,auth.uid(),v_version)
  returning * into v_qr;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'CREATE_CUSTOMER_JOIN_QR_V89',
    'business_customer_join_qr_v89',v_qr.id,
    jsonb_build_object('expires_at',v_qr.expires_at,'token_version',v_version));
  return jsonb_build_object('qr_id',v_qr.id,'join_token',v_token,
    'expires_at',v_qr.expires_at,'token_version',v_version);
end $$;

-- ensure() is what the settings page calls on open. Before v197 it returned
-- created=false and NO token for an existing QR, which is precisely why the
-- page could only offer "Replace". It now returns the same derived token every
-- time, so opening the page shows the printed QR instead of destroying it.
create or replace function public.business_ensure_customer_join_qr_v91(
  p_business uuid,
  p_expires_at timestamptz default now()+interval '365 days'
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_existing record; v_created jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'business owner access is required' using errcode='42501';
  end if;
  if p_expires_at is not null and p_expires_at <= now()+interval '5 minutes' then
    raise exception 'join QR expiry must be at least 5 minutes away' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v90:join-qr:'||p_business::text,0));

  select q.id,q.expires_at,q.token_version into v_existing
  from public.business_customer_join_qr_v89 q
  where q.business_id=p_business and q.status='active' and q.expires_at>now()
  order by q.expires_at desc,q.id desc
  limit 1;

  if found and v_existing.token_version is not null then
    -- Keep a printed poster alive: an active derived QR never ages out.
    if v_existing.expires_at < now()+interval '50 years' then
      update public.business_customer_join_qr_v89
         set expires_at=created_at+interval '100 years'
       where id=v_existing.id
      returning expires_at into v_existing.expires_at;
    end if;
    return jsonb_build_object(
      'business_id',p_business,'created',false,'qr_id',v_existing.id,
      'expires_at',v_existing.expires_at,
      'token_version',v_existing.token_version,
      'join_token',app.v197_join_token(p_business,v_existing.token_version)
    );
  end if;

  -- Either nothing active, or a pre-v197 random token that cannot be shown
  -- again. Both resolve to issuing one derived QR — the last change there will
  -- ever be for this firm.
  if found then
    update public.business_customer_join_qr_v89
       set status='revoked',revoked_at=now()
     where business_id=p_business and status='active';
  end if;
  v_created := public.business_create_customer_join_qr_v89(p_business,p_expires_at);
  return v_created||jsonb_build_object(
    'business_id',p_business,'created',true,
    'replaced_legacy_token',found
  );
end $$;

-- create-or-replace preserves existing grants, but a replay from an empty
-- database would inherit PostgreSQL's default EXECUTE-to-PUBLIC, so both
-- recreated overloads restate their access explicitly. create() stays
-- internal: only ensure()/rotate() call it, and both are SECURITY DEFINER.
revoke all on function public.business_create_customer_join_qr_v89(uuid,timestamptz)
  from public, anon, authenticated;
revoke all on function public.business_ensure_customer_join_qr_v91(uuid,timestamptz)
  from public, anon, authenticated;
grant execute on function public.business_ensure_customer_join_qr_v91(uuid,timestamptz)
  to authenticated;

commit;

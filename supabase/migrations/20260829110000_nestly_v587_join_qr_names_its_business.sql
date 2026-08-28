-- nestly_v587 — scanning a business QR must name the business, and land the customer in it.
--
-- Owner, 2026-08-29: "the qrcode scanned but failed to retrieve", with the wanted flow written
-- out — scan, a prompt naming the programme, Yes, and you are inside that business.
--
-- THREE FAULTS, stacked, all proven on production against the owner's own scanned token
-- (93d6b5cf… — the live QR for Jess Salon, status active, not expired, join_enabled true):
--
--   1. THE GATEWAY REFUSED THE TOKEN'S SHAPE. supabase/functions/_shared/validation.ts checks
--      every token against /^[A-Za-z0-9_-]{43}$/ — 43 base64url characters. Since v197 a join
--      token is app.v197_join_token(), which is encode(hmac(...),'hex'): 64 HEX characters. So
--      GET /functions/v1/public-join?token=… returned 404 for every QR minted since v197, and
--      validJoinTokenPayload refused the signed-out counter sign-up for the same reason. Fixed in
--      the function, not here (JOIN_TOKEN_PATTERN accepts both shapes).
--
--   2. THE PREVIEW'S NAME WAS READ FROM A KEY IT NEVER HAD. internal_public_join_page_v89 returns
--      {name, brand_color, industry}; the client read business_name / business.name. Even a
--      working gateway could not have named the business. Fixed in app/app.js.
--
--   3. THE JOIN RESPONSE HAS NO SLUG — this migration. customer_join_business_from_qr_v89 returns
--      outcome + business_id and nothing else, while the client navigates with
--      data.business.slug || data.business_slug. That is always empty, so a successful join fell
--      back to the programmes list instead of opening the business the customer just joined. The
--      owner's third requirement was therefore impossible, not merely unimplemented.
--
-- WHAT CHANGES. Two read-shape additions, no new authority and no behaviour change to joining:
--   * customer_join_business_from_qr_v89 keeps its guard and still delegates the whole join to
--     _base_v90 (untouched, so idempotency, replay and every refusal are exactly as before); it
--     now merges business_slug and business_name into whatever the base returned.
--   * internal_public_join_page_v89 adds 'slug' beside the name it already returns, so the
--     confirmation sheet can open the business even if a join reply is older than this migration.
-- Nothing is granted to a new role, and neither function tells an unauthenticated caller anything
-- it could not already read from the business's own public page.

begin;

create or replace function public.customer_join_business_from_qr_v89(p_join_token text, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
  v_slug text;
  v_name text;
  v_result jsonb;
begin
  select business.id, business.slug, business.name
    into v_business, v_slug, v_name
  from public.business_customer_join_qr_v89 qr
  join public.businesses business on business.id=qr.business_id
  where qr.token_hash=app.v89_sha256(p_join_token)
    and qr.status='active' and qr.expires_at>now()
    and business.join_enabled
  for share of qr,business;
  if not found then
    raise exception 'join QR is invalid, expired, or paused' using errcode='22023';
  end if;

  v_result := public.customer_join_business_from_qr_v89_base_v90(
    p_join_token,p_idempotency_key
  );

  -- nestly_v587: the caller has to be able to open what it just joined. The base's own keys win
  -- if it ever starts returning them, so this can never overwrite a fuller answer.
  return jsonb_build_object('business_slug',v_slug,'business_name',v_name) || coalesce(v_result,'{}'::jsonb);
end
$$;
revoke all on function public.customer_join_business_from_qr_v89(text,uuid) from public, anon;
grant execute on function public.customer_join_business_from_qr_v89(text,uuid) to authenticated, service_role;

create or replace function public.internal_public_join_page_v89(p_join_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_result jsonb;
begin
  if length(coalesce(p_join_token,''))<32 then
    return null;
  end if;
  select jsonb_build_object(
    'name',business.name,'slug',business.slug,'brand_color',business.brand_color,
    'industry',business.industry,'join_token',p_join_token,
    'expires_at',qr.expires_at
  ) into v_result
  from public.business_customer_join_qr_v89 qr
  join public.businesses business on business.id=qr.business_id
  where qr.token_hash=app.v89_sha256(p_join_token)
    and qr.status='active' and qr.expires_at>now() and business.join_enabled;
  return v_result;
end
$$;
revoke all on function public.internal_public_join_page_v89(text) from public, anon, authenticated;
grant execute on function public.internal_public_join_page_v89(text) to service_role;

commit;

-- NESTLY v209 — ONE join QR per business, and it never changes.
--
-- Owner, twice: "i want a static qrcode for customers to scan to join my program - why the
-- qrcode requires me to generate new one every single time?" then "make it static now. and only
-- have 1 - not multiple different variations."
--
-- The token was NEVER random. app.v197_join_token is an HMAC of business:version with a server
-- secret, so the same business and version always produce the same code and the server has been
-- able to recompute it all along. business_ensure_customer_join_qr_v91 already returned it on the
-- "already exists" path — the workspace simply never drew it, because it rendered a QR only when
-- created === true. An owner who already HAD a QR was therefore shown "an active QR already
-- exists" and a Replace button, and the only route back to their own code was to destroy it and
-- print a new one. That is what made a permanent code feel disposable.
--
-- Two changes here, both so the SERVER can never be the reason the owner sees a different code:
--   1. the status read returns the token too, so the panel can draw the QR even while sign-ups
--      are paused (that path deliberately does not create one);
--   2. exactly one active row per business, enforced by a partial unique index, with any
--      historical extras collapsed. An index makes "one QR" a fact rather than a convention that
--      every future writer has to remember.
--
-- Showing the owner a code they already printed on their own counter is not a new exposure, and
-- refusing to was the entire complaint.

begin;

create or replace function public.business_get_customer_join_qr_status_v91(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_count integer; v_expires_at timestamptz; v_version integer; v_id uuid;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'business owner access is required' using errcode='42501';
  end if;
  select count(*)::integer, max(q.expires_at) into v_count, v_expires_at
    from public.business_customer_join_qr_v89 q
   where q.business_id=p_business and q.status='active' and q.expires_at>now();
  select q.id, q.token_version into v_id, v_version
    from public.business_customer_join_qr_v89 q
   where q.business_id=p_business and q.status='active' and q.expires_at>now()
   order by q.expires_at desc, q.id desc limit 1;
  return jsonb_build_object(
    'active_count', v_count,
    'latest_expires_at', v_expires_at,
    'qr_id', v_id,
    'token_version', v_version,
    'join_token', case when v_version is not null
                      then app.v197_join_token(p_business, v_version) end
  );
end
$function$;

-- Replaced above, so restate its grants: owner-only in the body, and never reachable by anon.
revoke all on function public.business_get_customer_join_qr_status_v91(uuid) from public, anon;
grant execute on function public.business_get_customer_join_qr_status_v91(uuid) to authenticated;

with ranked as (
  select id, business_id,
         row_number() over (partition by business_id order by expires_at desc, id desc) as rn
    from public.business_customer_join_qr_v89
   where status='active' and expires_at>now()
)
update public.business_customer_join_qr_v89 q
   set status='revoked', revoked_at=now()
  from ranked
 where q.id=ranked.id and ranked.rn>1;

create unique index if not exists business_customer_join_qr_one_active_v209
  on public.business_customer_join_qr_v89(business_id)
  where status='active';

commit;

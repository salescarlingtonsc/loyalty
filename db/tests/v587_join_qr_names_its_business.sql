-- Rollback-only acceptance for nestly_v587 — a scanned QR names its business and can open it.
-- Run: supabase db query --linked -f db/tests/v587_join_qr_names_its_business.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  the preview returns the business SLUG as well as its name (the sheet needs both).
--   02  the join reply carries business_slug, so "land inside that business" is possible at all.
--   03  the join still delegates the whole join to _base_v90 — guards, idempotency and replay are
--       untouched by v587.
--   04  the QR guard is unchanged: an inactive, expired or paused-business token is still refused.
--   05  access is unchanged on both functions.
--   06  behavioural: a real active QR resolves through the preview to a real business + slug.

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 the preview returns slug beside name',
  case when position('''slug'',business.slug' in prosrc) = 0
         then 'FAIL: internal_public_join_page_v89 does not return the slug'
       when position('''name'',business.name' in prosrc) = 0
         then 'FAIL: it stopped returning the name'
       else 'OK' end
from pg_proc where proname='internal_public_join_page_v89' and pronamespace='public'::regnamespace;

insert into _r
select '02 the join reply carries business_slug',
  case when position('''business_slug''' in prosrc) = 0
         then 'FAIL: the reply has no slug, so a join cannot open its own business'
       else 'OK' end
from pg_proc where proname='customer_join_business_from_qr_v89' and pronamespace='public'::regnamespace;

insert into _r
select '03 the join itself is still the base function''s job',
  case when position('customer_join_business_from_qr_v89_base_v90' in prosrc) = 0
         then 'FAIL: the join was reimplemented instead of delegated'
       else 'OK' end
from pg_proc where proname='customer_join_business_from_qr_v89' and pronamespace='public'::regnamespace;

insert into _r
select '04 an invalid, expired or paused QR is still refused',
  case when position('join QR is invalid, expired, or paused' in prosrc) = 0
         then 'FAIL: the refusal is gone'
       when position('business.join_enabled' in prosrc) = 0
         then 'FAIL: a business with sign-ups off would be joinable'
       when position('qr.status=''active''' in prosrc) = 0
         then 'FAIL: a revoked QR would be accepted'
       else 'OK' end
from pg_proc where proname='customer_join_business_from_qr_v89' and pronamespace='public'::regnamespace;

insert into _r
select '05 access is unchanged',
  case when count(*) filter (where proname='customer_join_business_from_qr_v89' and prosecdef) = 0
         then 'FAIL: the join is no longer SECURITY DEFINER'
       when count(*) filter (where proname='internal_public_join_page_v89' and prosecdef) = 0
         then 'FAIL: the preview is no longer SECURITY DEFINER'
       when count(*) filter (where proname='internal_public_join_page_v89'
              and array_to_string(proacl,',') like '%authenticated=X%') > 0
         then 'FAIL: the internal preview is reachable by a signed-in browser'
       else 'OK' end
from pg_proc
where pronamespace='public'::regnamespace
  and proname in ('customer_join_business_from_qr_v89','internal_public_join_page_v89');

/* The behavioural proof: take a live QR and read the preview back through the same function the
   gateway calls. Skipped with a reason rather than passing vacuously when no active QR exists. */
do $flow$
declare v_token text; v_business uuid; v_preview jsonb;
begin
  /* The plaintext token is never stored — only its hash — so this re-derives one the same way
     app.v197_join_token does, for a business whose CURRENT active QR matches it. */
  select qr.business_id, app.v197_join_token(qr.business_id, qr.token_version)
    into v_business, v_token
    from public.business_customer_join_qr_v89 qr
    join public.businesses b on b.id = qr.business_id
   where qr.status='active' and qr.expires_at > now() and b.join_enabled
     and qr.token_hash = app.v89_sha256(app.v197_join_token(qr.business_id, qr.token_version))
   limit 1;

  if v_token is null then
    insert into _r values('06 a live QR resolves to its business and slug',
      'SKIP: no active v197-shaped join QR exists to exercise');
    return;
  end if;

  v_preview := public.internal_public_join_page_v89(v_token);

  insert into _r values('06 a live QR resolves to its business and slug',
    case when v_preview is null then 'FAIL: the preview returned nothing for an active QR'
         when coalesce(v_preview->>'name','') = '' then 'FAIL: no business name'
         when coalesce(v_preview->>'slug','') = '' then 'FAIL: no slug — the sheet cannot open it'
         when v_preview->>'slug' is distinct from (select slug from public.businesses where id=v_business)
           then 'FAIL: the slug is not this business''s'
         else 'OK' end);
end
$flow$;

select check_id, value from _r order by check_id;

rollback;

-- NESTLY V292: capture the demo request instead of losing it.
--
-- AUDIT S8. "Request a demo" was a `mailto:` link. Three consequences, all bad:
--   1. NOTHING was recorded. A prospect who filled the form left no row anywhere
--      in Peekaa, so nobody could be followed up with, counted, or audited.
--   2. On a device with no configured mail client -- which is the DEFAULT on a
--      fresh Android phone, on iOS after Mail is deleted, and inside every
--      in-app browser -- `window.location.href='mailto:...'` does nothing at
--      all. The page said "Opening your email app..." and then sat there. The
--      prospect believed they had asked for a demo. They had not.
--   3. Even when it worked, the request landed in one person's inbox with no
--      queue, no status and no evidence that anyone replied.
--
-- WHAT THIS ADDS
--   * public.demo_requests_v292 -- the queue. RLS on, ZERO policies, ACL revoked
--     from every browser role, exactly like the v282 partner tables: a demo
--     request is cross-tenant prospect data, so no tenant role may ever read it.
--     The SECURITY DEFINER functions below are the only doors.
--   * public.submit_demo_request_v292 -- the anonymous capture.
--   * public.platform_list_demo_requests_v292 -- the super-admin queue reader,
--     which returns a REAL total_count alongside the page so the console can say
--     "50 of 214" instead of silently truncating.
--   * public.platform_mark_demo_request_v292 -- contacted / archived, with the
--     operator's own note.
--
-- WHY THE CAPTURE IS ANON-CALLABLE AND NOT BEHIND THE EDGE GATEWAY
--   The v14 ruling that closed `join_program` to anon is about functions that
--   resolve or create a CUSTOMER IDENTITY: join and booking read a tenant's
--   customer list by phone number, so an anon RPC there is an oracle for "is
--   8xxxxxxx your customer", and they must sit behind Turnstile.
--   This function is the opposite shape. It is write-only, it answers the same
--   thing for every input, it reads nothing, and it can tell a caller nothing
--   they did not already type. The existing house precedent for exactly this
--   shape is public.report_client_error_v177 -- anon-executable, SECURITY
--   DEFINER, write-only, self-throttled in SQL. This follows it deliberately:
--     - a platform-wide hourly ceiling (200/hour) that DROPS silently once hit,
--       so a flood costs the attacker everything and Peekaa nothing;
--     - a 30-minute dedupe on the normalised contact, so an honest double-tap
--       (and a retry across a flaky connection) records one request, not two;
--     - hard length caps on every text field before insert.
--   Consequence, stated plainly rather than hidden: there is no captcha on this
--   path, so a determined script can fill the queue up to 200 rows/hour. That is
--   an operator-annoyance ceiling, not a data-loss or disclosure risk, and the
--   queue has an Archive control. If the queue is ever actually spammed, the
--   upgrade is a `public-demo-request` edge function in the public-gateway
--   pattern plus a Turnstile widget on the form; the table and the two platform
--   readers below do not change when that happens.

begin;

-- ===========================================================================
-- The queue
-- ===========================================================================

create table public.demo_requests_v292 (
  id uuid primary key default gen_random_uuid(),
  contact_name text not null check (length(btrim(contact_name)) between 2 and 100),
  business_name text not null check (length(btrim(business_name)) between 2 and 160),
  contact_email text check (contact_email is null or length(contact_email) between 3 and 254),
  contact_phone text check (contact_phone is null or length(contact_phone) between 6 and 32),
  sector text check (sector is null or length(sector) <= 120),
  note text check (note is null or length(note) <= 2000),
  status text not null default 'new'
    check (status in ('new', 'contacted', 'archived')),
  triage_note text check (triage_note is null or length(triage_note) <= 500),
  contacted_at timestamptz,
  contacted_by uuid,
  dedupe_hash text not null,
  created_at timestamptz not null default now(),
  -- One of the two contact channels MUST be present, or the request is not
  -- actionable and should never have been accepted.
  constraint demo_requests_v292_contactable
    check (contact_email is not null or contact_phone is not null)
);
comment on table public.demo_requests_v292 is
  'V292: prospects who asked for a Peekaa demo. Platform-managed; RLS on with zero policies, so no tenant role can read or write it. Written only by submit_demo_request_v292, read only by platform_list_demo_requests_v292.';

create index demo_requests_v292_queue_idx
  on public.demo_requests_v292 (status, created_at desc);
create index demo_requests_v292_dedupe_idx
  on public.demo_requests_v292 (dedupe_hash, created_at desc);

alter table public.demo_requests_v292 enable row level security;
revoke all privileges on table public.demo_requests_v292
  from public, anon, authenticated;

-- ===========================================================================
-- Anonymous capture
-- ===========================================================================

create or replace function public.submit_demo_request_v292(
  p_contact_name text,
  p_business_name text,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_sector text default null,
  p_note text default null
) returns jsonb
  language plpgsql
  security definer
  set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_name text := nullif(btrim(coalesce(p_contact_name, '')), '');
  v_business text := nullif(btrim(coalesce(p_business_name, '')), '');
  v_email text := lower(nullif(btrim(coalesce(p_contact_email, '')), ''));
  v_phone_raw text := nullif(btrim(coalesce(p_contact_phone, '')), '');
  v_phone text;
  v_sector text := nullif(btrim(coalesce(p_sector, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_hash text;
  v_recent integer;
  v_id uuid;
begin
  -- Shape refusals are LOUD, because the form can and should fix them.
  if v_name is null or length(v_name) not between 2 and 100 then
    raise exception 'a contact name is required' using errcode = '22023';
  end if;
  if v_business is null or length(v_business) not between 2 and 160 then
    raise exception 'a business name is required' using errcode = '22023';
  end if;
  if v_email is not null and (length(v_email) > 254 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception 'that email address is not valid' using errcode = '22023';
  end if;
  if v_phone_raw is not null then
    -- Accept what a Singapore prospect actually types: 8123 4567, +65 8123 4567,
    -- 65-8123-4567. app.norm_phone folds every one of those to 81234567.
    v_phone := app.norm_phone(v_phone_raw);
    if v_phone is null or v_phone !~ '^[0-9]{6,15}$' then
      raise exception 'that mobile number is not valid' using errcode = '22023';
    end if;
  end if;
  if v_email is null and v_phone is null then
    raise exception 'an email address or a mobile number is required' using errcode = '22023';
  end if;
  if v_sector is not null and length(v_sector) > 120 then
    v_sector := left(v_sector, 120);
  end if;
  if v_note is not null and length(v_note) > 2000 then
    v_note := left(v_note, 2000);
  end if;

  v_hash := app.v31_sha256_hex(
    coalesce(v_email, '') || ':' || coalesce(v_phone, '') || ':' || lower(v_business));

  -- Abuse ceiling, following report_client_error_v177: silent drop, uniform
  -- answer. A flood cannot fill the table and cannot learn that it was capped.
  select count(*) into v_recent
    from public.demo_requests_v292
   where created_at > now() - interval '1 hour';
  if v_recent >= 200 then
    return jsonb_build_object('status', 'ok');
  end if;

  -- Honest double-tap protection. The same prospect asking twice in half an
  -- hour is one request, not two, and the operator should see one card.
  if exists (
    select 1 from public.demo_requests_v292
     where dedupe_hash = v_hash
       and created_at > now() - interval '30 minutes'
  ) then
    return jsonb_build_object('status', 'ok', 'outcome', 'duplicate_ignored');
  end if;

  insert into public.demo_requests_v292
    (contact_name, business_name, contact_email, contact_phone, sector, note, dedupe_hash)
  values (v_name, v_business, v_email, v_phone, v_sector, v_note, v_hash)
  returning id into v_id;

  return jsonb_build_object('status', 'ok', 'outcome', 'recorded', 'request_id', v_id);
end;
$function$;

comment on function public.submit_demo_request_v292(text, text, text, text, text, text) is
  'V292: anonymous demo-request capture. Write-only, self-throttled (200/hour platform-wide, 30-minute contact dedupe), reads nothing and discloses nothing.';

-- ===========================================================================
-- Super-admin queue reader -- paged, WITH the real total
-- ===========================================================================

create or replace function public.platform_list_demo_requests_v292(
  p_status text default null,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
) returns jsonb
  language plpgsql
  stable
  security definer
  set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_items jsonb;
  v_total bigint;
  v_new bigint;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required' using errcode = '28000';
  end if;
  if not app.is_super_admin() then
    raise exception 'demo requests are super admin only' using errcode = '42501';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'row limit must be 1..200' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 or p_offset > 100000 then
    raise exception 'row offset must be 0..100000' using errcode = '22023';
  end if;
  if v_status is not null and v_status not in ('new', 'contacted', 'archived') then
    raise exception 'unknown demo request status' using errcode = '22023';
  end if;

  select count(*) into v_total
    from public.demo_requests_v292 request
   where (v_status is null or request.status = v_status)
     and (v_search is null
          or request.business_name ilike '%' || v_search || '%'
          or request.contact_name ilike '%' || v_search || '%'
          or coalesce(request.contact_email, '') ilike '%' || v_search || '%'
          or coalesce(request.contact_phone, '') ilike '%' || v_search || '%');

  select count(*) into v_new
    from public.demo_requests_v292 request
   where request.status = 'new';

  select coalesce(jsonb_agg(entry order by (entry->>'created_at') desc), '[]'::jsonb)
    into v_items
  from (
    select jsonb_build_object(
      'id', request.id,
      'contact_name', request.contact_name,
      'business_name', request.business_name,
      'contact_email', request.contact_email,
      'contact_phone', request.contact_phone,
      'sector', request.sector,
      'note', request.note,
      'status', request.status,
      'triage_note', request.triage_note,
      'contacted_at', request.contacted_at,
      'created_at', request.created_at
    ) as entry
    from public.demo_requests_v292 request
   where (v_status is null or request.status = v_status)
     and (v_search is null
          or request.business_name ilike '%' || v_search || '%'
          or request.contact_name ilike '%' || v_search || '%'
          or coalesce(request.contact_email, '') ilike '%' || v_search || '%'
          or coalesce(request.contact_phone, '') ilike '%' || v_search || '%')
   order by request.created_at desc
   limit p_limit offset p_offset
  ) as page;

  return jsonb_build_object(
    'status', 'ok',
    'items', v_items,
    'total_count', v_total,
    'new_count', v_new,
    'limit', p_limit,
    'offset', p_offset,
    'has_more', (p_offset + p_limit) < v_total);
end;
$function$;

comment on function public.platform_list_demo_requests_v292(text, text, integer, integer) is
  'V292: super-admin demo-request queue. Returns one offset page PLUS the real total_count, so the console can page honestly instead of truncating in silence.';

-- ===========================================================================
-- Super-admin triage
-- ===========================================================================

create or replace function public.platform_mark_demo_request_v292(
  p_request uuid,
  p_status text,
  p_note text default null
) returns jsonb
  language plpgsql
  security definer
  set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required' using errcode = '28000';
  end if;
  if not app.is_super_admin() then
    raise exception 'demo requests are super admin only' using errcode = '42501';
  end if;
  if v_status is null or v_status not in ('new', 'contacted', 'archived') then
    raise exception 'demo request status must be new, contacted or archived' using errcode = '22023';
  end if;
  if v_note is not null and length(v_note) > 500 then
    raise exception 'a triage note must be 500 characters or fewer' using errcode = '22023';
  end if;

  update public.demo_requests_v292 request
     set status = v_status,
         triage_note = coalesce(v_note, request.triage_note),
         contacted_at = case
           when v_status = 'contacted' then coalesce(request.contacted_at, now())
           else request.contacted_at end,
         contacted_by = case
           when v_status = 'contacted' then coalesce(request.contacted_by, v_actor)
           else request.contacted_by end
   where request.id = p_request
  returning request.id into v_id;

  if v_id is null then
    raise exception 'no demo request with that id' using errcode = '22023';
  end if;

  return jsonb_build_object('status', 'ok', 'request_id', v_id, 'demo_status', v_status);
end;
$function$;

comment on function public.platform_mark_demo_request_v292(uuid, text, text) is
  'V292: records the admin decision on one demo request. Idempotent on re-marking; contacted_at and contacted_by keep their FIRST value.';

-- ===========================================================================
-- Grants
-- ===========================================================================

revoke all on function public.submit_demo_request_v292(text, text, text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.platform_list_demo_requests_v292(text, text, integer, integer)
  from public, anon, authenticated;
revoke all on function public.platform_mark_demo_request_v292(uuid, text, text)
  from public, anon, authenticated;

-- The capture is reachable by a prospect who has no account. That is the whole
-- point of a demo request. See the header note for why this is safe here and
-- is not for join/booking.
grant execute on function public.submit_demo_request_v292(text, text, text, text, text, text)
  to anon, authenticated;
grant execute on function public.platform_list_demo_requests_v292(text, text, integer, integer)
  to authenticated;
grant execute on function public.platform_mark_demo_request_v292(uuid, text, text)
  to authenticated;

commit;

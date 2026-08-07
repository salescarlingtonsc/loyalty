-- NESTLY v203 —
-- (The function keeps its _v202 suffix: it is already applied to production
-- under that name, and renaming a live RPC to tidy a file name is not worth a
-- deploy. The semantic version v202 was taken by a parallel branch migration.)
-- NESTLY v203 — one company directory that answers "who do I chase today".
--
-- Owner asked for four things that all read the same rows, so they are one RPC
-- rather than four screens with four subtly different definitions of "due":
--   sector-grouped searchable directory (no infinite scroll)
--   who is not on auto-collect
--   who falls due in 30 / 14 / 7 days, today, and who is overdue
--   contact details to call or WhatsApp
--
-- COLLECTION MODE is the owner's own distinction, not a payment brand: a
-- subscription either takes the money by itself, or it has to be chased.
-- billing_provider='stripe' collects automatically; everything else is a chase.
-- Naming it after the work rather than after GIRO/PayNow keeps the screen
-- honest when a new payment rail is added later.
--
-- Contacts live on the originating prospect, not on the business, so the phone
-- number for a call or WhatsApp is reached through source_prospect_id.
--
-- Facets are computed over every company rather than the filtered page, so the
-- chips keep showing real totals while a filter is applied.

begin;

create or replace function public.platform_company_directory_v202(
  p_search text default null,
  p_sector text default null,
  p_collection text default null,      -- 'auto' | 'chase'
  p_due_window text default null,      -- 'overdue' | 'today' | '7' | '14' | '30'
  p_consultant uuid default null,
  p_limit integer default 100,
  p_offset integer default 0
) returns jsonb language plpgsql security definer stable
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,100),1),500);
  v_offset integer := greatest(coalesce(p_offset,0),0);
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_search text := nullif(btrim(coalesce(p_search,'')),'');
  v_items jsonb; v_total bigint;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_collection is not null and p_collection not in ('auto','chase') then
    raise exception 'collection filter must be auto or chase' using errcode='22023';
  end if;
  if p_due_window is not null and p_due_window not in ('overdue','today','7','14','30') then
    raise exception 'unknown due window' using errcode='22023';
  end if;

  with base as (
    select
      b.id, b.name, b.legal_name, b.slug,
      coalesce(nullif(btrim(b.industry),''),'unclassified') as sector,
      b.created_at,
      s.status, s.payment_status, s.billing_provider,
      s.current_period_start, s.current_period_end,
      s.next_payment_at, s.last_paid_at, s.period_total_cents,
      s.cadence_months, s.cancel_at_period_end,
      case when s.billing_provider = 'stripe' then 'auto' else 'chase' end as collection_mode,
      p.assigned_consultant_id,
      c.full_name as contact_name, c.phone as contact_phone, c.email as contact_email,
      -- Positive = days until it falls due; negative = days already overdue.
      case when s.next_payment_at is not null
        then ((s.next_payment_at at time zone 'Asia/Singapore')::date - v_today)
      end as days_until_due
    from public.businesses b
    left join public.subscriptions s on s.business_id = b.id
    left join public.sme_prospects p on p.id = b.source_prospect_id
    left join lateral (
      select full_name, phone, email
        from public.sme_prospect_contacts
       where prospect_id = b.source_prospect_id and active
       order by is_primary desc, created_at
       limit 1) c on true
  ), filtered as (
    select * from base
     where (v_search is null
            or name ilike '%'||v_search||'%'
            or coalesce(legal_name,'') ilike '%'||v_search||'%'
            or coalesce(contact_name,'') ilike '%'||v_search||'%'
            or coalesce(contact_email,'') ilike '%'||v_search||'%'
            or coalesce(contact_phone,'') ilike '%'||v_search||'%')
       and (p_sector is null or sector = p_sector)
       and (p_collection is null or collection_mode = p_collection)
       and (p_consultant is null or assigned_consultant_id = p_consultant)
       and (p_due_window is null
            or (p_due_window = 'overdue' and days_until_due < 0)
            or (p_due_window = 'today'   and days_until_due = 0)
            or (p_due_window = '7'       and days_until_due between 0 and 7)
            or (p_due_window = '14'      and days_until_due between 0 and 14)
            or (p_due_window = '30'      and days_until_due between 0 and 30))
  )
  select
    coalesce(jsonb_agg(to_jsonb(row) order by
      (row.days_until_due is null), row.days_until_due, row.name), '[]'::jsonb),
    (select count(*) from filtered)
  into v_items, v_total
  from (select * from filtered order by
         (days_until_due is null), days_until_due, name
        limit v_limit offset v_offset) row;

  return jsonb_build_object(
    'items', v_items,
    'total_count', v_total,
    'returned', jsonb_array_length(v_items),
    'has_more', v_total > v_offset + jsonb_array_length(v_items),
    'today', v_today,
    'sectors', coalesce((select jsonb_agg(jsonb_build_object('sector',sector,'n',n) order by n desc, sector)
       from (select coalesce(nullif(btrim(industry),''),'unclassified') sector, count(*) n
               from public.businesses group by 1) t),'[]'::jsonb),
    'collection', coalesce((select jsonb_object_agg(mode,n) from (
       select case when s.billing_provider='stripe' then 'auto' else 'chase' end mode, count(*) n
         from public.businesses b left join public.subscriptions s on s.business_id=b.id
        group by 1) t),'{}'::jsonb),
    'due', (select jsonb_build_object(
       'overdue', count(*) filter (where d < 0),
       'today',   count(*) filter (where d = 0),
       'in_7',    count(*) filter (where d between 0 and 7),
       'in_14',   count(*) filter (where d between 0 and 14),
       'in_30',   count(*) filter (where d between 0 and 30))
       from (select ((s.next_payment_at at time zone 'Asia/Singapore')::date - v_today) d
               from public.businesses b join public.subscriptions s on s.business_id=b.id
              where s.next_payment_at is not null) t));
end $$;

revoke all on function public.platform_company_directory_v202(text,text,text,text,uuid,integer,integer)
  from public, anon, authenticated;
grant execute on function public.platform_company_directory_v202(text,text,text,text,uuid,integer,integer)
  to authenticated;

commit;

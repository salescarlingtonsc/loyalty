-- nestly_v462 — the offers model the owner ruled on (R2, 2026-08-23).
--
-- FOUR THINGS THE OWNER ASKED FOR, AND THE ONE SENTENCE EACH ANSWERS.
--
-- R2(a) "customer sees ALL live offers on the business's own page — lift the reader's hard 6 and
--       fix its lying `limit` field." public.customer_get_promotions_v155 capped its own CTE at
--       `limit 6` and then reported `'limit',2` in the payload. Two different numbers, neither of
--       them the truth, and neither of them the entitlement. It now reads the SAME entitlement the
--       publish path enforces — app.v104_effective_promotion_entitlement(business)
--       .max_published_offers, ten by default since v104 — and reports exactly that number.
--       Nothing is hardcoded here.
--
-- R2(b) "exactly ONE live offer per business is FEATURED on the customer Home feed, owner-selected,
--       DEFAULT until picked = most recently published live offer."
--       Storage: public.business_featured_offer_v462, PRIMARY KEY (business_id). One-per-business
--       is a property of the KEY, not of the writer's good behaviour and certainly not of the
--       client's. A second featured offer for a firm is not "rejected", it is unrepresentable.
--       Why a side table and not a column on business_customer_content_v95: that row carries the
--       optimistic-concurrency `version` the editor round-trips (v280), it is guarded by three
--       v104 write triggers, and its version is part of the customer-facing version_id the Home
--       card uses to decide whether an offer is NEW. Featuring an offer must not bump any of that.
--       A side table also cannot be "half migrated": zero rows resolves to the default, exactly
--       the way public.sale_policies has resolved defaults since v10.
--       Default: app.v462_effective_featured_offer(business) = the pin if the pinned offer is
--       still live, otherwise the most recently published live one. There is ONE definition of
--       "live enough to be featured" — app.v462_featured_offer_candidates — and the owner editor,
--       the writer's validation and the Home reader all call it, so the marker the owner sees can
--       never disagree with the offer the customer gets.
--
-- R2(c) "publishing when 10 are live prompts the owner to move one to draft first (honest dialog,
--       no silent failure)."
--       This one changes a MEANING, deliberately, and it is the only semantic change in the file.
--       Until now `max_published_offers` counted offers that had EVER been published — v104 called
--       them "first-published offer slots" and the gate only fired on an offer's first publish
--       (`not(metadata ? 'published_once_at')`). Under that rule the dialog the owner asked for
--       would be a lie: moving an offer back to draft frees nothing, because published_once_at is
--       permanent. So the cap is now what the owner said it is — a LIVE cap. It counts offers with
--       active = true (that is precisely "published, not draft", the thing the owner's Live/Draft
--       control moves), it is checked on every draft -> live transition rather than only the first,
--       and drafting an offer frees a slot immediately. Republishing an offer that is already live
--       is not a transition and is never blocked.
--       Migration safety, measured on production gadpooereceldfpfxsod 2026-08-23: 8 offer rows
--       exist across all tenants, 3 of them active, all with branch_id null, and the busiest firm
--       (kopi-tiam-tyeh) holds 2. No tenant is at or over the new cap, so nobody is grandfathered
--       into a state they cannot publish out of.
--       The refusal keeps the name it already had, 'promotion_publish_limit_reached', which
--       business_finalize_promotion_v155 already lists in c_definitive and already returns to the
--       client as a structured 200 {ok:false,blocked:true,code:'promotion_finalize_rejected',
--       reason:'promotion_publish_limit_reached'} (v378). The client can therefore distinguish it
--       without any new error vocabulary and without parsing a message string.
--
-- R2(d) "Home-feed fairness = CLIENT-SIDE shuffle" — nothing here. No rotation logic, no ordering
--       state, no extra column, no cron. The server answers "which one offer per business"; the
--       order those land in is the client's business and costs Supabase nothing.
--
-- NOT TOUCHED, ON PURPOSE: reward readiness and redemption (v432 one-availability-core), the stamp
-- lifecycle (v433-v437), the points/credit ledgers, promotion_finalize_refusals_v378's breaker, the
-- v104 attempt-receipt idempotency, and the v280 version-sync retry. Nothing in this file reads or
-- writes any of them.
--
-- Forward-only. Verified against production inside rolled-back transactions
-- (db/tests/v462_featured_offer_and_live_cap.sql). NOT APPLIED by this file's author.

begin;

-- ---------------------------------------------------------------------------
-- 1. STORAGE — one featured offer per business, enforced by the primary key.
-- ---------------------------------------------------------------------------

create table if not exists public.business_featured_offer_v462(
  business_id uuid primary key
    references public.businesses(id) on delete cascade,
  promotion_id uuid not null
    references public.business_customer_content_v95(id) on delete cascade,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

comment on table public.business_featured_offer_v462 is
  'The one live offer a business puts on the customer Home feed (R2b). PRIMARY KEY(business_id) is the one-per-business rule. No row = the default, resolved by app.v462_effective_featured_offer. RPC-only: no API grants exist, so neither an owner nor a super admin can write it directly.';

create index if not exists business_featured_offer_v462_promotion_idx
  on public.business_featured_offer_v462(promotion_id);

alter table public.business_featured_offer_v462 enable row level security;

-- Deliberately NO policy and NO grants. Like public.super_admins (v14) and
-- public.business_promotion_entitlements_v104, this table is unreachable through PostgREST in
-- either direction; the SECURITY DEFINER RPCs below are the only door.
revoke all privileges on table public.business_featured_offer_v462
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. HELPERS — one definition of "live", one definition of "featured".
-- ---------------------------------------------------------------------------

-- What the LIVE CAP counts. active = true is exactly the state the owner's Live/Draft control
-- moves, which is what makes "move one back to draft" an honest instruction. Date-window state is
-- deliberately NOT part of it: a cap that frees a slot on its own at midnight is a cap an owner
-- cannot reason about, and an ended-but-still-published offer is still occupying a published slot
-- the owner can free.
create or replace function app.v462_live_offer_count(p_business uuid)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select count(*)::integer
  from public.business_customer_content_v95 content
  where content.business_id = p_business
    and content.content_type = 'offer'
    and content.branch_id is null
    and content.active
$$;
revoke all on function app.v462_live_offer_count(uuid)
  from public, anon, authenticated;

-- What may be FEATURED. This is the customer-visibility predicate of
-- public.customer_get_home_offers_v167 (as amended by v172/v173: media optional) and of
-- public.business_get_visible_promotion_count_v167, stated once. The owner editor reads it, the
-- writer validates against it, and the Home reader filters by it, so the "Shown on customer Home"
-- marker on the owner's screen and the card the customer actually receives are the same fact.
create or replace function app.v462_featured_offer_candidates(p_business uuid)
returns table(
  promotion_id uuid,
  published_at timestamptz,
  updated_at timestamptz,
  ends_at timestamptz,
  display_order integer
)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select
    content.id,
    coalesce(
      nullif(content.metadata->>'published_once_at','')::timestamptz,
      content.starts_at,
      content.updated_at
    ),
    content.updated_at,
    content.ends_at,
    content.display_order
  from public.business_customer_content_v95 content
  where content.business_id = p_business
    and content.content_type = 'offer'
    and content.active
    and content.branch_id is null
    and (content.starts_at is null or content.starts_at <= statement_timestamp())
    and content.ends_at > statement_timestamp()
    and (
      not exists(
        select 1 from public.promotion_branch_scopes_v155 mapped
        where mapped.promotion_id = content.id
      )
      or exists(
        select 1
        from public.promotion_branch_scopes_v155 mapped
        join public.branches active_branch
          on active_branch.id = mapped.branch_id
         and active_branch.business_id = p_business
         and coalesce(active_branch.active,true)
        where mapped.promotion_id = content.id
          and mapped.business_id = p_business
      )
    )
$$;
revoke all on function app.v462_featured_offer_candidates(uuid)
  from public, anon, authenticated;

-- The pin if it still points at a live offer of THIS business, else the most recently published
-- live one. The join against the candidate set is what makes a stale pin (offer ended, drafted,
-- deleted, or — impossible today, but cheap to rule out — belonging to another firm) fall through
-- to the default instead of blanking the feed.
create or replace function app.v462_effective_featured_offer(p_business uuid)
returns uuid
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce(
    (
      select pinned.promotion_id
      from public.business_featured_offer_v462 pinned
      join app.v462_featured_offer_candidates(p_business) candidate
        on candidate.promotion_id = pinned.promotion_id
      where pinned.business_id = p_business
    ),
    (
      select candidate.promotion_id
      from app.v462_featured_offer_candidates(p_business) candidate
      order by candidate.published_at desc,
        candidate.updated_at desc,
        candidate.promotion_id
      limit 1
    )
  )
$$;
revoke all on function app.v462_effective_featured_offer(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. WRITER — "feature this offer", gated exactly like the other offer writes.
-- ---------------------------------------------------------------------------

-- Owner only. A super admin is deliberately NOT admitted: the v14 ruling scopes super admins to
-- "read every tenant, write platform tables only", and which offer a merchant puts on Home is the
-- merchant's decision, not the platform's. p_promotion_id => null clears the pin and returns the
-- firm to the default, which is the only way back once a pin has been set.
create or replace function public.business_set_featured_offer_v462(
  p_business uuid,
  p_promotion_id uuid default null::uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_effective uuid;
  v_pinned boolean;
begin
  if v_actor is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null then
    raise exception 'valid_featured_offer_context_required' using errcode='22023';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'owner_required' using errcode='42501';
  end if;

  -- The same per-business advisory lock every other v104 promotion write takes, so featuring
  -- cannot interleave with a publish that is about to change which offers are live.
  perform app.v104_lock_promotion_business(p_business);

  if p_promotion_id is null then
    delete from public.business_featured_offer_v462
    where business_id = p_business;
  else
    if not exists(
      select 1
      from app.v462_featured_offer_candidates(p_business) candidate
      where candidate.promotion_id = p_promotion_id
    ) then
      raise exception 'featured_offer_must_be_live' using errcode='23514';
    end if;
    insert into public.business_featured_offer_v462 as featured
      (business_id,promotion_id,updated_by,updated_at)
    values (p_business,p_promotion_id,v_actor,now())
    on conflict (business_id) do update
      set promotion_id = excluded.promotion_id,
          updated_by   = excluded.updated_by,
          updated_at   = excluded.updated_at;
  end if;

  v_effective := app.v462_effective_featured_offer(p_business);
  v_pinned := exists(
    select 1 from public.business_featured_offer_v462 pinned
    where pinned.business_id = p_business
      and pinned.promotion_id = v_effective
  );

  return jsonb_build_object(
    'business_id',p_business,
    'featured_offer_id',v_effective,
    'featured_offer_pinned',v_pinned
  );
end
$$;

revoke all on function public.business_set_featured_offer_v462(uuid,uuid)
  from public, anon;
-- Two statements, not one: tests/security-hardening/v21-security-hardening.test.mjs reads the
-- authenticated grant of every shipped RPC by exact signature, and its scanner recognises the
-- `... to authenticated;` form. Splitting service_role out keeps the grant machine-checkable.
grant execute on function public.business_set_featured_offer_v462(uuid,uuid) to authenticated;
grant execute on function public.business_set_featured_offer_v462(uuid,uuid) to service_role;

comment on function public.business_set_featured_offer_v462(uuid,uuid) is
  'Owner-only. Pins the one live offer shown on the customer Home feed, or clears the pin (null) back to the most recently published live offer. Refuses a non-live offer with featured_offer_must_be_live.';

-- ---------------------------------------------------------------------------
-- 4. THE CAP BECOMES A LIVE CAP (R2c).
-- ---------------------------------------------------------------------------

-- business_finalize_promotion_v104 is ~400 lines of receipt handling, storage verification and
-- three-way optimistic concurrency. Retyping it to change eight lines is how a body drifts from
-- production, so this patches the definition that is actually installed: it reads it back, asserts
-- the exact text it expects is present, substitutes, and re-executes. Idempotent — a second run
-- sees the new text and does nothing.
do $patch$
declare
  v_src text;
  v_new text;
  c_old_gate constant text := $old$  v_first_adoption:=p_publish
    and not(v_content.metadata ? 'published_once_at');
  if v_first_adoption then
    if now()>=v_entitlement.complimentary_until then
      raise exception 'promotion_publishing_window_closed' using errcode='42501';
    end if;
    select count(*)::integer into v_quota_used
    from public.business_customer_content_v95 content
    where content.business_id=p_business
      and content.content_type='offer'
      and content.metadata->>'schema'='nestly.promotion.v104'
      and content.metadata ? 'published_once_at';
    if v_quota_used>=v_entitlement.max_published_offers then
      raise exception 'promotion_publish_limit_reached' using errcode='23514';
    end if;
  end if;$old$;
  c_new_gate constant text := $new$  v_first_adoption:=p_publish
    and not(v_content.metadata ? 'published_once_at');
  if v_first_adoption then
    if now()>=v_entitlement.complimentary_until then
      raise exception 'promotion_publishing_window_closed' using errcode='42501';
    end if;
  end if;
  /* V462 (owner ruling R2c): the entitlement is a LIVE cap, not a lifetime one. Checked on the
     draft -> live transition only, so republishing an offer that is already live is never blocked
     and moving one back to draft frees its slot at once. */
  if p_publish and not coalesce(v_content.active,false) then
    v_quota_used:=app.v462_live_offer_count(p_business);
    if v_quota_used>=v_entitlement.max_published_offers then
      raise exception 'promotion_publish_limit_reached' using errcode='23514';
    end if;
  end if;$new$;
  c_old_count constant text := $old$  select count(*)::integer into v_quota_used
  from public.business_customer_content_v95 content
  where content.business_id=p_business
    and content.content_type='offer'
    and content.metadata->>'schema'='nestly.promotion.v104'
    and content.metadata ? 'published_once_at';$old$;
  c_new_count constant text := $new$  /* V462: quota_used is now the live count, so the figure the editor prints and the figure the
     gate enforces are one number. */
  v_quota_used:=app.v462_live_offer_count(p_business);$new$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'business_finalize_promotion_v104';
  if v_src is null then
    raise exception 'v462: public.business_finalize_promotion_v104 is missing';
  end if;

  if position('app.v462_live_offer_count' in v_src) = 0 then
    if position(c_old_gate in v_src) = 0 then
      raise exception 'v462: the v104 finalize publish gate is not the text this patch expects';
    end if;
    if position(c_old_count in v_src) = 0 then
      raise exception 'v462: the v104 finalize quota recount is not the text this patch expects';
    end if;
    v_new := replace(replace(v_src,c_old_gate,c_new_gate),c_old_count,c_new_count);
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'business_finalize_promotion_v104';
  if position('app.v462_live_offer_count' in v_src) = 0
     or position($check$content.metadata ? 'published_once_at';$check$ in v_src) > 0 then
    raise exception 'v462: business_finalize_promotion_v104 did not take the live cap';
  end if;
end
$patch$;

-- The owner editor's counts, patched the same way and for the same reason.
do $patch$
declare
  v_src text;
  v_new text;
  c_old_count constant text := $old$  select count(*)::integer into v_quota_used
  from public.business_customer_content_v95 content
  where content.business_id=p_business
    and content.content_type='offer'
    and content.metadata->>'schema'='nestly.promotion.v104'
    and content.metadata ? 'published_once_at';$old$;
  c_new_count constant text := $new$  /* V462: "N of 10 slots used" now means live offers, matching the gate in
     business_finalize_promotion_v104 and the number the customer can actually see. */
  v_quota_used:=app.v462_live_offer_count(p_business);$new$;
  c_old_payload constant text := $old$      'quota_used',v_quota_used,$old$;
  c_new_payload constant text := $new$      'quota_used',v_quota_used,
      'live_count',v_quota_used,
      'live_limit',v_entitlement.max_published_offers,$new$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'business_get_promotion_editor_v104';
  if v_src is null then
    raise exception 'v462: public.business_get_promotion_editor_v104 is missing';
  end if;

  if position('app.v462_live_offer_count' in v_src) = 0 then
    if position(c_old_count in v_src) = 0 then
      raise exception 'v462: the v104 editor quota count is not the text this patch expects';
    end if;
    if position(c_old_payload in v_src) = 0 then
      raise exception 'v462: the v104 editor entitlement payload is not the text this patch expects';
    end if;
    v_new := replace(replace(v_src,c_old_count,c_new_count),c_old_payload,c_new_payload);
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'business_get_promotion_editor_v104';
  if position('app.v462_live_offer_count' in v_src) = 0
     or position($check$'live_count'$check$ in v_src) = 0 then
    raise exception 'v462: business_get_promotion_editor_v104 did not take the live count';
  end if;
end
$patch$;

-- ---------------------------------------------------------------------------
-- 5. OWNER READER — which offer is on Home, and is that the owner's choice or the default.
-- ---------------------------------------------------------------------------

create or replace function public.business_get_promotion_editor_v155(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_base jsonb;
  v_items jsonb;
  v_featured uuid;
  v_pinned boolean;
begin
  -- Authorization, existence and every item field come from v104 unchanged; this wrapper only
  -- decorates. Calling it first also means an unauthorized caller is refused before anything below
  -- reads a row.
  v_base := public.business_get_promotion_editor_v104(p_business);
  with items as (
    select value item
    from jsonb_array_elements(coalesce(v_base->'items','[]'::jsonb))
  )
  select coalesce(jsonb_agg(
    item || jsonb_build_object(
      'branch_scope',case
        when exists(
          select 1 from public.promotion_branch_scopes_v155 mapped
          where mapped.promotion_id = (item->>'id')::uuid
        ) then jsonb_build_object(
          'mode','selected_branches',
          'branch_ids',(
            select coalesce(jsonb_agg(mapped.branch_id order by branch.name),'[]'::jsonb)
            from public.promotion_branch_scopes_v155 mapped
            join public.branches branch on branch.id = mapped.branch_id
            where mapped.promotion_id = (item->>'id')::uuid
          ),
          'branch_names',(
            select coalesce(jsonb_agg(branch.name order by branch.name),'[]'::jsonb)
            from public.promotion_branch_scopes_v155 mapped
            join public.branches branch on branch.id = mapped.branch_id
            where mapped.promotion_id = (item->>'id')::uuid
          )
        )
        else jsonb_build_object('mode','all_branches','branch_ids','[]'::jsonb,'branch_names','[]'::jsonb)
      end
    )
  ),'[]'::jsonb)
  into v_items
  from items;

  /* V462 (R2b): the SAME resolver customer_get_home_offers_v167 filters by, so the owner's
     "Shown on customer Home" marker states the offer the customer is actually being shown —
     including while it is still the default and nobody has chosen yet. */
  v_featured := app.v462_effective_featured_offer(p_business);
  v_pinned := exists(
    select 1 from public.business_featured_offer_v462 pinned
    where pinned.business_id = p_business
      and pinned.promotion_id = v_featured
  );

  return jsonb_set(v_base,'{items}',v_items,true)
    || jsonb_build_object(
      'featured_offer_id',v_featured,
      'featured_offer_pinned',v_pinned
    );
end
$$;

revoke all on function public.business_get_promotion_editor_v155(uuid) from public, anon;
grant execute on function public.business_get_promotion_editor_v155(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. CUSTOMER READERS — all live offers on the business page, one per business on Home.
-- ---------------------------------------------------------------------------

create or replace function public.customer_get_promotions_v155(
  p_business uuid,
  p_branch uuid default null::uuid,
  p_locale text default 'en'::text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_items jsonb;
  v_limit integer;
begin
  if v_actor is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null or p_locale not in ('en','zh-CN') then
    raise exception 'valid_promotion_reader_context_required' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id = p_branch
      and branch.business_id = p_business
      and coalesce(branch.active,true)
  ) then
    raise exception 'branch_not_available' using errcode='42501';
  end if;

  v_identity := app.v31_current_identity();
  if not exists(
    select 1
    from public.customer_links link
    where link.identity_id = v_identity
      and link.auth_user_id = v_actor
      and link.business_id = p_business
      and link.state = 'verified'
  ) then
    raise exception 'verified_customer_link_required' using errcode='42501';
  end if;

  /* V462 (R2a): the bound is the business's own entitlement — the same number
     business_finalize_promotion_v104 refuses to let it exceed — not a hardcoded 6 that no other
     part of the system had heard of. Because the publish gate now caps LIVE offers at this same
     figure, this can only ever truncate if a super admin lowers the entitlement below what is
     already live, which is a deliberate act rather than a silent surprise. */
  select greatest(coalesce(entitlement.max_published_offers,0),0)
  into v_limit
  from app.v104_effective_promotion_entitlement(p_business) entitlement;
  v_limit := coalesce(v_limit,0);

  with visible as (
    select
      content.id,content.display_order,content.starts_at,content.ends_at,
      content.metadata,content.updated_at,
      coalesce(copy.name,english.name,'Offer') name,
      coalesce(copy.tagline,english.tagline) tagline,
      coalesce(copy.description,english.description) description,
      coalesce(copy.terms,english.terms) terms,
      media.url image_url,media.image_alt,
      branches.names branch_names
    from public.business_customer_content_v95 content
    left join public.business_localized_copy_v95 copy
      on copy.business_id = p_business
     and copy.entity_type = 'offer'
     and copy.entity_id = content.id
     and copy.locale = p_locale
    left join public.business_localized_copy_v95 english
      on english.business_id = p_business
     and english.entity_type = 'offer'
     and english.entity_id = content.id
     and english.locale = 'en'
    left join lateral(
      select app.v95_public_media_url(asset.object_path) url,
        case when p_locale='zh-CN'
          then coalesce(asset.alt_zh_cn,asset.alt_en)
          else asset.alt_en
        end image_alt
      from public.business_media_assets_v95 asset
      where asset.business_id = p_business
        and asset.asset_kind = 'offer'
        and asset.entity_id = content.id
        and asset.customer_visible
        and asset.branch_id is null
      order by asset.updated_at desc,asset.id
      limit 1
    ) media on true
    left join lateral(
      select coalesce(jsonb_agg(branch.name order by branch.name),'[]'::jsonb) names
      from public.promotion_branch_scopes_v155 mapped
      join public.branches branch on branch.id = mapped.branch_id
      where mapped.promotion_id = content.id
    ) branches on true
    where content.business_id = p_business
      and content.content_type = 'offer'
      and content.active
      and content.branch_id is null
      and app.promotion_available_at_branch_v155(content.id,p_branch)
      and (content.starts_at is null or content.starts_at <= now())
      and content.ends_at > now()
    order by content.display_order,content.starts_at desc nulls last,
      content.updated_at desc,content.id
    limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',visible.id,
    'name',visible.name,
    'tagline',visible.tagline,
    'description',visible.description,
    'terms',visible.terms,
    'image_url',visible.image_url,
    'image_alt',visible.image_alt,
    'starts_at',visible.starts_at,
    'ends_at',visible.ends_at,
    'display_order',visible.display_order,
    'metadata',visible.metadata,
    'branch_names',visible.branch_names,
    'availability_label',case when jsonb_array_length(visible.branch_names)>0
      then 'Available at ' || (
        select string_agg(value,' and ' order by value)
        from jsonb_array_elements_text(visible.branch_names) value
      )
      else 'Available at all branches' end
  ) order by visible.display_order,visible.starts_at desc nulls last,
      visible.updated_at desc,visible.id),'[]'::jsonb)
  into v_items
  from visible;

  return jsonb_build_object(
    'business_id',p_business,
    'branch_id',p_branch,
    'locale',p_locale,
    'items',v_items,
    'limit',v_limit
  );
end
$$;

revoke all on function public.customer_get_promotions_v155(uuid,uuid,text) from public, anon;
grant execute on function public.customer_get_promotions_v155(uuid,uuid,text)
  to authenticated, service_role;

comment on function public.customer_get_promotions_v155(p_business uuid, p_branch uuid, p_locale text) is
  'Every live offer a verified customer may see on this business page, bounded by the business own promotion entitlement, which the payload limit field reports truthfully.';

create or replace function public.customer_get_home_offers_v167(
  p_locale text default 'en'::text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_items jsonb;
  v_pending_redemption jsonb;
  v_truncated boolean := false;
begin
  if v_actor is null then
    raise exception 'authenticated_customer_session_required' using errcode='28000';
  end if;
  if p_locale not in ('en','zh-CN') then
    raise exception 'supported_locale_required' using errcode='22023';
  end if;
  v_identity := app.v31_current_identity();

  select jsonb_build_object(
    'intent_id',intent.id,
    'expires_at',intent.expires_at,
    'business',jsonb_build_object(
      'id',business.id,
      'slug',business.slug,
      'name',business.name
    ),
    'reward_name',coalesce(reward.name,'reward')
  ) into v_pending_redemption
  from public.customer_redemption_intents_v89 intent
  join public.businesses business on business.id=intent.business_id
  left join public.loyalty_rewards reward on reward.id=intent.reward_id
  where intent.identity_id=v_identity
    and intent.auth_user_id=v_actor
    and intent.status='pending'
    and intent.expires_at>statement_timestamp()
  order by intent.created_at desc,intent.id
  limit 1;

  -- v32_customer_wallet_context is the canonical verified-link resolver. The
  -- caller cannot nominate a customer, identity, business, or tenant.
  /* V462 (R2b): the Home feed carries ONE offer per business — the one its owner featured, or the
     most recently published live one until they choose. `materialized` is load-bearing: without it
     the planner is free to inline app.v462_effective_featured_offer and re-evaluate it per candidate
     row, which is the shape that turned a cheap read into a slow one in v370. */
  with links as materialized (
    select distinct wallet.business_id
    from app.v32_customer_wallet_context(null) wallet
  ), featured as materialized (
    select links.business_id,
      app.v462_effective_featured_offer(links.business_id) promotion_id
    from links
  ), ranked as (
    select
      content.id,
      content.version,
      content.updated_at,
      content.display_order,
      content.starts_at,
      content.ends_at,
      content.metadata,
      context.business_id,
      context.business_slug,
      context.business_name,
      coalesce(copy.name,english.name,'Offer') name,
      coalesce(copy.tagline,english.tagline) tagline,
      coalesce(copy.description,english.description) description,
      coalesce(copy.terms,english.terms) terms,
      media.url image_url,
      media.image_alt,
      app.v95_public_media_url(logo.object_path) logo_url,
      branches.names branch_names,
      exists(select 1 from public.promotion_branch_scopes_v155 mapped where mapped.promotion_id=content.id) branch_scoped,
      row_number() over(order by
        content.ends_at asc,
        content.display_order asc,
        content.updated_at desc,
        content.id
      ) item_rank
    from app.v32_customer_wallet_context(null) context
    join featured
      on featured.business_id=context.business_id
    join public.business_customer_content_v95 content
      on content.business_id=context.business_id
     and content.id=featured.promotion_id
     and content.content_type='offer'
     and content.active
     and content.branch_id is null
     and (content.starts_at is null or content.starts_at<=statement_timestamp())
     and content.ends_at>statement_timestamp()
     and (
       not exists(select 1 from public.promotion_branch_scopes_v155 mapped where mapped.promotion_id=content.id)
       or exists(
         select 1
         from public.promotion_branch_scopes_v155 mapped
         join public.branches active_branch
           on active_branch.id=mapped.branch_id
          and active_branch.business_id=context.business_id
          and coalesce(active_branch.active,true)
         where mapped.promotion_id=content.id
           and mapped.business_id=context.business_id
       )
     )
    left join public.business_localized_copy_v95 copy
      on copy.business_id=context.business_id
     and copy.entity_type='offer'
     and copy.entity_id=content.id
     and copy.locale=p_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=context.business_id
     and english.entity_type='offer'
     and english.entity_id=content.id
     and english.locale='en'
    left join lateral(
      select app.v95_public_media_url(asset.object_path) url,
        case when p_locale='zh-CN'
          then coalesce(asset.alt_zh_cn,asset.alt_en)
          else asset.alt_en
        end image_alt
      from public.business_media_assets_v95 asset
      where asset.business_id=context.business_id
        and asset.asset_kind='offer'
        and asset.entity_id=content.id
        and asset.customer_visible
        and asset.branch_id is null
      order by asset.updated_at desc,asset.id
      limit 1
    ) media on true
    left join public.business_brand_presentation_v95 brand
      on brand.business_id=context.business_id
    left join public.business_media_assets_v95 logo
      on logo.id=brand.logo_asset_id
     and logo.business_id=context.business_id
     and logo.asset_kind='logo'
     and logo.customer_visible
    left join lateral(
      select coalesce(jsonb_agg(branch.name order by branch.name),'[]'::jsonb) names
      from public.promotion_branch_scopes_v155 mapped
      join public.branches branch
        on branch.id=mapped.branch_id
       and branch.business_id=context.business_id
       and coalesce(branch.active,true)
      where mapped.promotion_id=content.id
        and mapped.business_id=context.business_id
    ) branches on true
  ), bounded as (
    select * from ranked where item_rank<=13
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'id',bounded.id,
      'version_id',bounded.id::text||':'||bounded.version::text,
      'name',bounded.name,
      'tagline',bounded.tagline,
      'description',bounded.description,
      'terms',bounded.terms,
      'image_url',bounded.image_url,
      'image_alt',bounded.image_alt,
      'starts_at',bounded.starts_at,
      'ends_at',bounded.ends_at,
      'display_order',bounded.display_order,
      'metadata',bounded.metadata,
      'business',jsonb_build_object(
        'id',bounded.business_id,
        'slug',bounded.business_slug,
        'name',bounded.business_name,
        'logo_url',bounded.logo_url
      ),
      'branch_names',bounded.branch_names,
      'availability_label',case
        when bounded.branch_scoped then 'Available at '||(
          select string_agg(value,' and ' order by value)
          from jsonb_array_elements_text(bounded.branch_names) value
        )
        else 'Available at all branches'
      end
    ) order by bounded.item_rank) filter(where bounded.item_rank<=12),'[]'::jsonb),
    coalesce(bool_or(bounded.item_rank>12),false)
  into v_items,v_truncated
  from bounded;

  return jsonb_build_object(
    'as_of',statement_timestamp(),
    'items',v_items,
    'pending_redemption',v_pending_redemption,
    'limit',12,
    'featured_only',true,
    'truncated',v_truncated
  );
end
$$;

revoke all on function public.customer_get_home_offers_v167(text) from public, anon;
grant execute on function public.customer_get_home_offers_v167(text)
  to authenticated, service_role;

comment on function public.customer_get_home_offers_v167(p_locale text) is
  'One featured offer per verified customer link — owner-chosen, defaulting to the most recently published live one — bounded at twelve businesses. Ordering on Home is shuffled client-side; nothing here rotates.';

commit;

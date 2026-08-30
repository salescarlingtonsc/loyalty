/* nestly_v657 — A DISCOUNT IS ONE OF EXACTLY TWO SHAPES. Owner ruling 2026-08-31, after seeing
   v656's tick-list in production and rejecting it:

     1. Whole bill  — "10% off the entire bill", optionally capped in money ("10% off, up to $20").
     2. One item    — "10% off one selected item per transaction". The owner still ticks a LIST,
                      but that list now means ELIGIBLE, not "all of these at once", and exactly one
                      of them is discounted.

   v656 read a ticked list as "discount every one of these", so a Gold benefit ticking five items
   took 10% off all five. The owner's words: "whatever i want to select only allow for 1 item (even
   though selected multiple)".

   WHICH eligible item, when several are on the bill? The owner asked Peekaa to define it and chose
   the HIGHEST-PRICED one: it needs no decision at the counter, it is the same answer every time,
   and it is the line the customer would have picked themselves.

   Also fixed here, from the same review: a whole-bill discount can carry a money ceiling, which
   nothing supported before — an owner offering "10% off" had no way to stop it costing $300 on a
   $3,000 bill.

   UNCHANGED, deliberately: which discount wins. One tier discount, never stacked, highest
   percentage, and only no-limit ones apply automatically (v370/v656). The owner was asked and
   chose to keep it — a Platinum customer's 30% whole-bill beats a Gold 10% they have outgrown.

   Backfill: every existing discount that named items becomes 'item' (that is what its owner meant
   when they ticked them), and every other discount stays whole-bill, so nothing configured before
   today changes what it takes off a bill except the five-item Gold benefit the owner is asking to
   change.

   Rollback suite: db/tests/v657_discount_two_shapes.sql */
begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The two new columns.
-- ---------------------------------------------------------------------------------------------
alter table public.tier_benefits_v365
  add column if not exists discount_scope text not null default 'bill',
  add column if not exists max_discount_cents integer;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='tier_benefits_v365_discount_scope_check') then
    alter table public.tier_benefits_v365
      add constraint tier_benefits_v365_discount_scope_check
      check (discount_scope in ('bill','item'));
  end if;
  if not exists (select 1 from pg_constraint where conname='tier_benefits_v365_max_discount_check') then
    alter table public.tier_benefits_v365
      add constraint tier_benefits_v365_max_discount_check
      check (max_discount_cents is null
             or (benefit_kind='discount_pct' and discount_scope='bill' and max_discount_cents > 0));
  end if;
end $$;

-- A discount that named items meant "one of these"; everything else is a whole-bill discount.
update public.tier_benefits_v365 b
   set discount_scope='item'
 where b.benefit_kind='discount_pct'
   and b.discount_scope <> 'item'
   and exists (select 1 from public.tier_benefit_scope_v656 s where s.benefit_id=b.id);

-- ---------------------------------------------------------------------------------------------
-- 2. The wording. A single-item discount says so; a capped one says its ceiling.
--    The long comma list v656 put in the label is gone: the eligible items are a SECOND line
--    (scope_items), which is where the owner asked for them ("put all products under description")
--    and which does not fight the 120-character ceiling on this column.
-- ---------------------------------------------------------------------------------------------
create or replace function app.v657_discount_label(p_discount numeric, p_scope text, p_max_cents integer)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $function$
  select regexp_replace(trim(to_char(p_discount, 'FM999990.99')), '\.$', '') || '% off'
    || case when coalesce(p_scope,'bill')='item' then ' one item' else '' end
    || case when p_max_cents is not null
            then ', up to ' || trim(to_char(p_max_cents::numeric/100, 'FM999999990.00')) else '' end
$function$;

revoke all on function app.v657_discount_label(numeric, text, integer) from public, anon;

-- The WORDING has to follow the meaning. A v656 label listed every ticked item ("10% off Cotton
-- Blanket, facial, Lotion 50ml, Pillow for Massage, spa"), which under v657's rule now reads as a
-- promise to discount all five when only one of them is discounted. Re-derive every discount
-- label from its own numbers, and refresh the tier perk_note those labels feed.
update public.tier_benefits_v365 b
   set label = app.v657_discount_label(b.discount_percent, b.discount_scope, b.max_discount_cents)
 where b.benefit_kind = 'discount_pct'
   and b.deleted_at is null
   and b.label is distinct from app.v657_discount_label(b.discount_percent, b.discount_scope, b.max_discount_cents);

do $relabel$
declare r record;
begin
  for r in select distinct business_id, tier_id from public.tier_benefits_v365
            where benefit_kind='discount_pct' and deleted_at is null
  loop
    perform app.v365_apply_perk_note(r.business_id, r.tier_id);
  end loop;
end $relabel$;

-- ---------------------------------------------------------------------------------------------
-- 3. The setter stores the shape and the cap.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.business_set_tier_benefits_v365(p_business uuid, p_tier uuid, p_benefits jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_item jsonb;
  v_index integer := 0;
  v_keep uuid[] := array[]::uuid[];
  v_id uuid;
  v_label text;
  v_limit integer;
  v_period text;
  v_kind text;
  v_discount numeric;
  v_product uuid;
  v_item_label text;
  v_scope_products uuid[];
  v_scope_services uuid[];
  v_scope_given boolean;
  v_scope_names text[];
  v_bad uuid;
  v_disc_scope text;
  v_max_cents integer;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  perform 1 from public.loyalty_tiers where id=p_tier and business_id=p_business;
  if not found then
    raise exception 'tier not found in this business' using errcode='42704';
  end if;
  if p_benefits is not null and jsonb_typeof(p_benefits) <> 'array' then
    raise exception 'benefits must be an array' using errcode='22023';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_benefits,'[]'::jsonb)) loop
    v_kind := coalesce(nullif(btrim(coalesce(v_item->>'benefit_kind','')),''),'custom');
    if v_kind not in ('discount_pct','free_item','custom') then
      raise exception 'benefit kind must be a discount, a free item, or your own wording' using errcode='22023';
    end if;
    v_discount := nullif(v_item->>'discount_percent','')::numeric;
    v_product := nullif(v_item->>'product_id','')::uuid;
    v_item_label := nullif(btrim(coalesce(v_item->>'item_label','')),'');

    /* nestly_v656 — WHICH ITEMS A DISCOUNT COVERS (owner: "10% off selected products able to
       select the product/services ... if blanket 10% also allow that selection"). The arrays are
       only READ when the payload actually carries one of the keys. That matters for the four
       hours in which Cloudflare is still serving the previous bundle: an older client saving a
       tier sends neither key, and must leave the owner's chosen items alone rather than silently
       widening the discount back to the whole bill. */
    /* nestly_v657 (owner ruling 2026-08-31). A discount is one of exactly two shapes, and the
       owner picks which: 'bill' — a percentage off the whole bill, optionally capped in money —
       or 'item' — a percentage off ONE item per transaction, chosen from a list of eligible
       products and services. v656's tick-list meant "discount all of these at once", which the
       owner saw and rejected; the same list now means "any one of these qualifies". */
    v_disc_scope := lower(coalesce(nullif(btrim(coalesce(v_item->>'discount_scope','')),''),'bill'));
    v_max_cents := nullif(v_item->>'max_discount_cents','')::integer;
    v_scope_given := (v_item ? 'scope_product_ids') or (v_item ? 'scope_service_ids');
    v_scope_products := coalesce((select array_agg(value::uuid)
      from jsonb_array_elements_text(case when jsonb_typeof(v_item->'scope_product_ids')='array'
        then v_item->'scope_product_ids' else '[]'::jsonb end)), '{}'::uuid[]);
    v_scope_services := coalesce((select array_agg(value::uuid)
      from jsonb_array_elements_text(case when jsonb_typeof(v_item->'scope_service_ids')='array'
        then v_item->'scope_service_ids' else '[]'::jsonb end)), '{}'::uuid[]);

    if v_kind='discount_pct' then
      if v_discount is null or v_discount <= 0 or v_discount > 100 then
        raise exception 'a discount must be between 0.01 and 100 percent' using errcode='22023';
      end if;
      v_product := null; v_item_label := null;
      -- Every id must be this business's own; a stray one is a mistake worth refusing rather
      -- than dropping, because a silently narrower discount is invisible until a customer is
      -- charged for something the owner thought was covered.
      select p into v_bad from unnest(v_scope_products) p
       where not exists(select 1 from public.products x where x.id=p and x.business_id=p_business) limit 1;
      if v_bad is not null then
        raise exception 'that product does not belong to this business' using errcode='42704';
      end if;
      select s into v_bad from unnest(v_scope_services) s
       where not exists(select 1 from public.services x where x.id=s and x.business_id=p_business) limit 1;
      if v_bad is not null then
        raise exception 'that service does not belong to this business' using errcode='42704';
      end if;
      if v_disc_scope not in ('bill','item') then
        raise exception 'a discount is either off the whole bill or off one chosen item' using errcode='22023';
      end if;
      if v_disc_scope='item' and cardinality(v_scope_products)+cardinality(v_scope_services)=0 then
        raise exception 'choose at least one product or service the discount can come off' using errcode='22023';
      end if;
      if v_disc_scope='bill' then
        -- A cap belongs to a whole-bill discount; on a single-item one the item price is the cap.
        v_scope_products := '{}'::uuid[]; v_scope_services := '{}'::uuid[];
        if v_max_cents is not null and (v_max_cents < 1 or v_max_cents > 100000000) then
          raise exception 'a maximum discount must be a positive amount' using errcode='22023';
        end if;
      else
        v_max_cents := null;
      end if;
    elsif v_kind='free_item' then
      if v_product is not null then
        perform 1 from public.products where id=v_product and business_id=p_business;
        if not found then
          raise exception 'that product does not belong to this business' using errcode='42704';
        end if;
        v_item_label := null;
      elsif v_item_label is null then
        raise exception 'say which item is free, or pick one from your products' using errcode='22023';
      end if;
      v_discount := null;
    else
      v_discount := null; v_product := null; v_item_label := null;
    end if;
    if v_kind <> 'discount_pct' then
      -- Only a discount is scoped. A free item already names its own product, and 'custom' is the
      -- owner's own sentence with nothing for the engine to match against.
      v_scope_products := '{}'::uuid[]; v_scope_services := '{}'::uuid[];
      v_disc_scope := 'bill'; v_max_cents := null;
    end if;

    -- Derived for the structured kinds; the owner's own words for 'custom'.
    -- nestly_v656: a scoped discount names its items in its own wording, so "10% off Facial, Spa"
    -- is what the till, the customer's perk card and every issuance record all read.
    v_scope_names := app.v656_scope_names_for(p_business, v_scope_products, v_scope_services);
    v_label := case when v_kind='discount_pct'
      then app.v657_discount_label(v_discount, v_disc_scope, v_max_cents)
      else app.v369_benefit_label(v_kind, v_discount, v_product, v_item_label,
             nullif(btrim(coalesce(v_item->>'label','')),'')) end;
    if v_label is null or btrim(v_label)='' then
      raise exception 'every benefit needs a description' using errcode='22023';
    end if;

    v_limit := nullif(v_item->>'limit_count','')::integer;
    v_period := coalesce(nullif(btrim(coalesce(v_item->>'limit_period','')),''),'month');
    if v_period not in ('day','week','month','year','ever','birthday_month') then
      raise exception 'benefit period is not one of day/week/month/year/ever/birthday_month' using errcode='22023';
    end if;
    if v_limit is not null and (v_limit < 1 or v_limit > 10000) then
      raise exception 'a benefit limit must be between 1 and 10000' using errcode='22023';
    end if;

    v_id := nullif(v_item->>'id','')::uuid;
    if v_id is not null then
      update public.tier_benefits_v365
         set label=v_label, limit_count=v_limit, limit_period=v_period, sort=v_index,
             benefit_kind=v_kind, discount_percent=v_discount, product_id=v_product, item_label=v_item_label,
             discount_scope=v_disc_scope, max_discount_cents=v_max_cents,
             active=true, deleted_at=null, updated_at=now(), updated_by=auth.uid()
       where id=v_id and business_id=p_business and tier_id=p_tier;
      if not found then
        raise exception 'benefit not found on this tier' using errcode='42704';
      end if;
    else
      insert into public.tier_benefits_v365(business_id,tier_id,label,limit_count,limit_period,sort,
        benefit_kind,discount_percent,product_id,item_label,discount_scope,max_discount_cents,updated_by)
      values(p_business,p_tier,v_label,v_limit,v_period,v_index,
        v_kind,v_discount,v_product,v_item_label,v_disc_scope,v_max_cents,auth.uid())
      returning id into v_id;
    end if;
    -- The scope is replaced wholesale for the benefit, and only when the payload spoke about it.
    if v_scope_given then
      delete from public.tier_benefit_scope_v656 where benefit_id = v_id;
      insert into public.tier_benefit_scope_v656(business_id, benefit_id, product_id, service_id)
      select p_business, v_id, p, null from unnest(v_scope_products) p
      union all
      select p_business, v_id, null, s from unnest(v_scope_services) s
      on conflict do nothing;
    end if;

    v_keep := v_keep || v_id;
    v_index := v_index + 1;
  end loop;

  update public.tier_benefits_v365
     set deleted_at=now(), active=false, updated_at=now(), updated_by=auth.uid()
   where business_id=p_business and tier_id=p_tier and deleted_at is null
     and not (id = any(v_keep));

  perform app.v365_apply_perk_note(p_business,p_tier);

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'tier_benefits.set','loyalty_tiers',p_tier,
    jsonb_build_object('count',v_index));

  return jsonb_build_object('status','ok','tier_id',p_tier,'count',v_index,
    'perk_note',(select perk_note from public.loyalty_tiers where id=p_tier and business_id=p_business));
end $function$;

revoke all on function public.business_set_tier_benefits_v365(uuid, uuid, jsonb) from public, anon;
grant execute on function public.business_set_tier_benefits_v365(uuid, uuid, jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 4. Both readers carry the shape and the cap.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.staff_tier_benefits_for_client_v365(p_business uuid, p_client uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_tier public.loyalty_tiers%rowtype;
  v_rows jsonb;
  v_birthday boolean;
begin
  if auth.uid() is null then raise exception 'authenticated staff required' using errcode='42501'; end if;
  if not (app.is_salon_owner(p_business) or app.can_module_read(p_business,'till')
          or app.can_module_read(p_business,'loyalty')) then
    raise exception 'till or loyalty access required' using errcode='42501';
  end if;
  perform 1 from public.clients where id=p_client and business_id=p_business;
  if not found then raise exception 'client not found in this business' using errcode='42704'; end if;

  v_tier := app.v365_client_tier(p_business,p_client);
  if v_tier.id is null then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;
  v_birthday := coalesce(app.v367_in_birthday_month(p_client, now()), false);

  select coalesce(jsonb_agg(jsonb_build_object(
      'benefit_id',b.id,'tier_id',b.tier_id,'tier_label',t.name,'label',b.label,
      'benefit_kind',b.benefit_kind,'discount_percent',b.discount_percent,
      'product_id',b.product_id,
      'item_label',coalesce((select p.name from public.products p where p.id=b.product_id),b.item_label),
      'limit_count',b.limit_count,'limit_period',b.limit_period,
      'sentence',app.v365_benefit_sentence(b.label,b.limit_count,b.limit_period),
      /* nestly_v656: the items this discount covers, by name, so the till can print the second
         line the owner asked for without a second round trip. Empty means the whole bill. */
      'scope_items',to_jsonb(app.v656_scope_names(b.id)),
      /* nestly_v657: which of the two shapes, and the money ceiling on a whole-bill one. */
      'discount_scope',b.discount_scope,'max_discount_cents',b.max_discount_cents,
      'used',used.count_in_period,
      'remaining',case when b.limit_count is null then null
                       else greatest(0,b.limit_count-used.count_in_period) end,
      'claimable_now',(b.limit_period<>'birthday_month' or v_birthday)
        and (b.limit_count is null or used.count_in_period < b.limit_count),
      'blocked_reason',case when b.limit_period='birthday_month' and not v_birthday then 'not_birthday_month'
                            when b.limit_count is not null and used.count_in_period >= b.limit_count then 'used_up'
                            else null end
    ) order by t.threshold desc, b.sort, b.id),'[]'::jsonb) into v_rows
    from public.tier_benefits_v365 b
    join public.loyalty_tiers t on t.id=b.tier_id and t.business_id=b.business_id
    cross join lateral (
      select count(*)::integer as count_in_period from public.tier_benefit_issues_v365 i
       where i.benefit_id=b.id and i.client_id=p_client
         and i.period_key=app.v365_period_key(b.limit_period,now())
    ) used
   where b.business_id=p_business and b.deleted_at is null and b.active
     and coalesce(t.paused,false)=false and t.deleted_at is null
     and t.threshold<=v_tier.threshold
     and (t.effective_from is null or t.effective_from<=statement_timestamp())
     and (t.expires_at is null or t.expires_at>statement_timestamp());

  return jsonb_build_object('status','ok',
    'tier',jsonb_build_object('id',v_tier.id,'label',v_tier.name,'threshold',v_tier.threshold),
    'in_birthday_month',v_birthday,
    'benefits',v_rows);
end $function$;

revoke all on function public.staff_tier_benefits_for_client_v365(uuid, uuid) from public, anon;
grant execute on function public.staff_tier_benefits_for_client_v365(uuid, uuid) to authenticated, service_role;
CREATE OR REPLACE FUNCTION public.customer_get_tier_benefits_v501(p_business_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_tier public.loyalty_tiers%rowtype;
  v_birthday boolean;
  v_rows jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('loyalty' = any(v_context.enabled_modules)) then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;
  if not exists (
    select 1 from public.business_programmes spine
     where spine.business_id = v_context.business_id and spine.kind = 'tiers' and spine.active
  ) then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;

  v_tier := app.v365_client_tier(v_context.business_id, v_context.client_id);
  if v_tier.id is null then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;
  v_birthday := coalesce(app.v367_in_birthday_month(v_context.client_id, now()), false);

  select coalesce(jsonb_agg(jsonb_build_object(
      'benefit_id', b.id,
      'tier_id', b.tier_id,
      'tier_label', t.name,
      'label', b.label,
      'benefit_kind', b.benefit_kind,
      'discount_percent', b.discount_percent,
      'item_label', coalesce((select p.name from public.products p where p.id = b.product_id), b.item_label),
      'limit_count', b.limit_count,
      'limit_period', b.limit_period,
      'sentence', app.v365_benefit_sentence(b.label, b.limit_count, b.limit_period),
      /* nestly_v656: the items this discount covers, by name. Empty means the whole bill. */
      'scope_items', to_jsonb(app.v656_scope_names(b.id)),
      'discount_scope', b.discount_scope, 'max_discount_cents', b.max_discount_cents,
      'used', used.count_in_period,
      /* nestly_v654: the same lateral, so the date and the count can never describe different
         windows. Null when the perk has no use in this period — the client then prints exactly
         what it printed before. */
      'last_used_at', used.last_in_period,
      'remaining', case when b.limit_count is null then null
                        else greatest(0, b.limit_count - used.count_in_period) end,
      'period_ends_at', case when b.limit_count is null then null
                             else app.v501_period_ends_at(b.limit_period, now()) end,
      'claimable_now', (b.limit_period <> 'birthday_month' or v_birthday)
        and (b.limit_count is null or used.count_in_period < b.limit_count),
      'blocked_reason', case
        when b.limit_period = 'birthday_month' and not v_birthday then 'not_birthday_month'
        when b.limit_count is not null and used.count_in_period >= b.limit_count then 'used_up'
        else null end
    ) order by t.threshold desc, b.sort, b.id), '[]'::jsonb) into v_rows
    from public.tier_benefits_v365 b
    join public.loyalty_tiers t on t.id = b.tier_id and t.business_id = b.business_id
    cross join lateral (
      select count(*)::integer as count_in_period,
             max(i.issued_at) as last_in_period
        from public.tier_benefit_issues_v365 i
       where i.benefit_id = b.id and i.client_id = v_context.client_id
         and i.period_key = app.v365_period_key(b.limit_period, now())
    ) used
   where b.business_id = v_context.business_id
     and b.deleted_at is null and b.active
     and coalesce(t.paused, false) = false and t.deleted_at is null
     and t.threshold <= v_tier.threshold
     and (t.effective_from is null or t.effective_from <= statement_timestamp())
     and (t.expires_at is null or t.expires_at > statement_timestamp());

  return jsonb_build_object(
    'status','ok',
    'tier', jsonb_build_object('id', v_tier.id, 'label', v_tier.name, 'threshold', v_tier.threshold),
    'in_birthday_month', v_birthday,
    'benefits', v_rows);
end;
$function$;

revoke all on function public.customer_get_tier_benefits_v501(text) from public, anon;
grant execute on function public.customer_get_tier_benefits_v501(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 5. THE PRICING AUTHORITY. Same sanctioned-point discipline as v370/v394/v488/v656: the base a
--    percentage is taken from, and the ceiling on it, can only be decided here.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.ps1c_plan_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_config uuid, p_tier_benefit uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_line jsonb; v_ord int := 0; v_n int;
  v_kind text[]; v_id uuid[]; v_name text[]; v_unit int[]; v_qty int[]; v_ltot int[]; v_rem int[];
  v_entered_by uuid[]; v_lreason text[];
  v_subtotal bigint := 0; v_price jsonb; v_pstatus text; v_nm text;
  v_server jsonb := '[]'::jsonb; v_entry jsonb;
  v_payload jsonb; v_active_rules boolean := (p_config is not null);
  r record; v_eff jsonb; v_idx int; v_etype text; v_ckind text; v_cid uuid; v_level text;
  v_stackable boolean; v_cap int; v_period text;
  v_cand jsonb := '[]'::jsonb;
  v_applied jsonb := '[]'::jsonb;
  v_total_discount bigint := 0; v_any_line boolean := false; v_any_bill boolean := false;
  c jsonb; v_target int; v_base int; v_d int; v_reason text; v_suppressed boolean;
  -- V370: the automatic tier discount.
  v_nonstack_applied boolean := false;
  v_tier_benefit record; v_tier_base int; v_tier_d int;
  -- nestly_v656: the scope of the chosen discount, and whether it was chosen by hand.
  v_tier_scoped boolean := false; v_tier_used int; v_tier_names text[];
  -- nestly_v657: which of the two shapes this discount is, and the line it landed on.
  v_tier_target int; v_tier_best int;
  v_ps timestamptz; v_pe timestamptz; v_committed int; v_projected int;
  v_rule_proj jsonb := '{}'::jsonb; v_gst_reg boolean; v_gst_bps int; v_total int; v_gst int;
  j int;
  v_desc text; v_camt numeric; v_creason text; v_limit int; v_may_custom boolean;
  v_bundle jsonb; v_bline jsonb; v_bsrc uuid[]; v_bsrcqty int[];
  v_key text;
begin
  if jsonb_typeof(p_lines) <> 'array' then
    return jsonb_build_object('status', 'invalid', 'reason', 'lines must be a JSON array');
  end if;
  v_n := jsonb_array_length(p_lines);
  if v_n < 1 or v_n > 50 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a cart must have between 1 and 50 lines');
  end if;

  select coalesce(custom_line_limit_cents, 50000) into v_limit from public.businesses where id = p_business;
  v_limit := coalesce(v_limit, 50000);
  v_may_custom := app.is_salon_owner(p_business) or app.has_perm(p_business, 'custom_price_lines');

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_ord := v_ord + 1;
    v_ckind := v_line->>'catalog_kind';
    if v_ckind is null or v_ckind not in ('service', 'product', 'custom', 'bundle') then
      return jsonb_build_object('status', 'bad_kind', 'line', v_ord,
        'reason', 'catalog_kind must be service, product, bundle or custom');
    end if;

    if v_ckind = 'custom' then
      for v_key in select jsonb_object_keys(v_line) loop
        if v_key not in ('catalog_kind', 'description', 'amount_cents', 'reason', 'qty') then
          return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
            'reason', 'custom_line_invalid: a custom line carries only catalog_kind, description, amount_cents and reason');
        end if;
      end loop;
      if not v_may_custom then
        return jsonb_build_object('status', 'custom_line_denied', 'line', v_ord,
          'reason', 'custom_line_denied: you do not have permission to enter a manual price (custom_price_lines)');
      end if;
      if v_line ? 'qty' then
        if jsonb_typeof(v_line->'qty') is distinct from 'number'
           or (v_line->>'qty')::numeric <> 1 then
          return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
            'reason', 'custom_line_invalid: a custom line quantity is always 1');
        end if;
      end if;
      if jsonb_typeof(v_line->'amount_cents') is distinct from 'number' then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line requires a numeric amount_cents');
      end if;
      v_camt := (v_line->>'amount_cents')::numeric;
      if v_camt <> trunc(v_camt) or v_camt = 0 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: amount_cents must be a whole number of cents and cannot be zero');
      end if;
      if abs(v_camt) > v_limit then
        return jsonb_build_object('status', 'custom_line_limit', 'line', v_ord,
          'reason', 'custom_line_limit: amount_cents exceeds this business''s manual-price limit of '
                    || v_limit || ' cents');
      end if;
      v_desc := btrim(coalesce(v_line->>'description', ''));
      v_creason := btrim(coalesce(v_line->>'reason', ''));
      if length(v_desc) < 3 or length(v_desc) > 200 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line needs a description of 3 to 200 characters');
      end if;
      if length(v_creason) > 200 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line reason cannot exceed 200 characters');
      end if;
      v_kind := array_append(v_kind, 'custom');
      v_id := array_append(v_id, null::uuid);
      v_name := array_append(v_name, v_desc);
      v_unit := array_append(v_unit, v_camt::int);
      v_qty := array_append(v_qty, 1);
      v_ltot := array_append(v_ltot, v_camt::int);
      v_rem := array_append(v_rem, v_camt::int);
      v_entered_by := array_append(v_entered_by, auth.uid());
      v_lreason := array_append(v_lreason, v_creason);
      v_bsrc := array_append(v_bsrc, null::uuid);
      v_bsrcqty := array_append(v_bsrcqty, null::int);
      v_subtotal := v_subtotal + v_camt::int;
      continue;
    end if;

    if v_line ? 'unit_price_cents' or v_line ? 'price_cents' or v_line ? 'amount_cents'
       or v_line ? 'line_total_cents' or v_line ? 'unit_cents' or v_line ? 'discount' then
      return jsonb_build_object('status', 'client_priced', 'line', v_ord,
        'reason', 'checkout lines carry catalog_kind + catalog_id + qty ONLY; nothing is client-priceable');
    end if;
    if jsonb_typeof(v_line->'qty') is distinct from 'number' then
      return jsonb_build_object('status', 'bad_qty', 'line', v_ord, 'reason', 'qty must be a number');
    end if;
    if (v_line->>'qty')::numeric <> trunc((v_line->>'qty')::numeric)
       or (v_line->>'qty')::numeric < 1 or (v_line->>'qty')::numeric > 1000000 then
      return jsonb_build_object('status', 'bad_qty', 'line', v_ord, 'reason', 'qty must be a whole number 1..1000000');
    end if;
    v_cid := nullif(v_line->>'catalog_id', '')::uuid;
    if v_ckind = 'bundle' then
      v_bundle := app.ps1c_bundle_lines_v204(p_business, v_cid, (v_line->>'qty')::int);
      if v_bundle->>'status' <> 'ok' then
        return jsonb_build_object('status', 'price_error', 'line', v_ord,
          'catalog_kind', 'bundle', 'catalog_id', v_cid,
          'reason', (v_bundle->>'status') || ':' || coalesce(v_bundle->>'reason', ''));
      end if;
      for v_bline in select * from jsonb_array_elements(v_bundle->'lines') loop
        v_kind := array_append(v_kind, coalesce(v_bline->>'kind', 'service'));
        v_id := array_append(v_id, coalesce(nullif(v_bline->>'item_id',''), v_bline->>'service_id')::uuid);
        v_name := array_append(v_name, v_bline->>'name');
        v_unit := array_append(v_unit, (v_bline->>'line_cents')::int);
        v_qty := array_append(v_qty, 1);
        v_ltot := array_append(v_ltot, (v_bline->>'line_cents')::int);
        v_rem := array_append(v_rem, (v_bline->>'line_cents')::int);
        v_entered_by := array_append(v_entered_by, null::uuid);
        v_lreason := array_append(v_lreason, null::text);
        v_bsrc := array_append(v_bsrc, v_cid);
        v_bsrcqty := array_append(v_bsrcqty, (v_line->>'qty')::int);
        v_subtotal := v_subtotal + (v_bline->>'line_cents')::int;
      end loop;
      continue;
    end if;
    v_price := app.ps1b_catalog_price(p_business, v_ckind, v_cid);
    v_pstatus := v_price->>'status';
    if v_pstatus <> 'ok' then
      return jsonb_build_object('status', 'price_error', 'line', v_ord, 'catalog_kind', v_ckind,
        'catalog_id', v_cid, 'reason', v_pstatus || ':' || coalesce(v_price->>'reason', ''));
    end if;
    if v_ckind = 'service' then
      select name into v_nm from public.services where id = v_cid and business_id = p_business;
    else
      select name into v_nm from public.products where id = v_cid and business_id = p_business;
    end if;
    v_kind := array_append(v_kind, v_ckind);
    v_id := array_append(v_id, v_cid);
    v_name := array_append(v_name, coalesce(v_nm, v_ckind));
    v_unit := array_append(v_unit, (v_price->>'price_cents')::int);
    v_qty := array_append(v_qty, (v_line->>'qty')::int);
    v_ltot := array_append(v_ltot, (v_price->>'price_cents')::int * (v_line->>'qty')::int);
    v_rem := array_append(v_rem, (v_price->>'price_cents')::int * (v_line->>'qty')::int);
    v_entered_by := array_append(v_entered_by, null::uuid);
    v_lreason := array_append(v_lreason, null::text);
    v_bsrc := array_append(v_bsrc, null::uuid);
    v_bsrcqty := array_append(v_bsrcqty, null::int);
    v_subtotal := v_subtotal + ((v_price->>'price_cents')::int * (v_line->>'qty')::int);
  end loop;

  if v_subtotal <= 0 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a checkout must total more than zero');
  end if;
  if v_subtotal > 2147483647 then
    return jsonb_build_object('status', 'invalid', 'reason', 'checkout subtotal exceeds the supported maximum');
  end if;

  for j in 1 .. array_length(v_kind, 1) loop
    v_entry := jsonb_build_object(
      'catalog_kind', v_kind[j], 'catalog_id', v_id[j], 'name', v_name[j],
      'unit_price_cents', v_unit[j], 'qty', v_qty[j], 'line_total_cents', v_ltot[j]);
    if v_kind[j] = 'custom' then
      v_entry := v_entry || jsonb_build_object('entered_by', v_entered_by[j], 'reason', v_lreason[j]);
    end if;
    if v_bsrc[j] is not null then
      v_entry := v_entry || jsonb_build_object('bundle_id', v_bsrc[j], 'bundle_qty', v_bsrcqty[j]);
    end if;
    v_server := v_server || jsonb_build_array(v_entry);
  end loop;

  v_payload := jsonb_build_object('amount_cents', v_subtotal, 'kind', 'cart_sale',
    'branch_id', to_jsonb(p_branch::text), 'client_id', to_jsonb(coalesce(p_client::text, '')),
    'counts_as_visit', true, 'earns_points', true);
  if v_active_rules then
    for r in select c2.rule_id, c2.compiled from public.program_rules_compiled c2
              where c2.business_id = p_business and c2.config_version_id = p_config
                and c2.when_event = 'sale.completed' and c2.active
                and not exists (select 1 from public.studio_rule_emergency_pauses ep
                                 where ep.business_id = p_business and ep.rule_id = c2.rule_id
                                   and ep.lifted_at is null)
              order by c2.rule_id loop
      if not app.ps1b_eval_conditions(v_payload, r.compiled->'if') then continue; end if;
      v_stackable := coalesce((r.compiled->'using'->>'stackable')::boolean, true);
      v_cap := nullif(r.compiled->'with'->>'budget_cap_cents', '')::int;
      v_period := coalesce(r.compiled->'with'->>'budget_period', 'monthly');
      v_idx := 0;
      for v_eff in select * from jsonb_array_elements(coalesce(r.compiled->'then', '[]'::jsonb)) loop
        v_etype := v_eff->>'effect_type';
        if v_etype in ('apply_discount_pct', 'apply_discount_amount') then
          v_ckind := nullif(v_eff->>'catalog_kind', '');
          v_cid := nullif(v_eff->>'catalog_id', '')::uuid;
          v_level := case when v_ckind is not null and v_cid is not null then 'line' else 'bill' end;
          v_cand := v_cand || jsonb_build_array(jsonb_build_object(
            'rule_id', r.rule_id, 'effect_index', v_idx, 'effect_type', v_etype, 'level', v_level,
            'catalog_kind', v_ckind, 'catalog_id', v_cid,
            'discount_pct', v_eff->>'discount_pct', 'amount_cents', v_eff->>'amount_cents',
            'stackable', v_stackable, 'cap_cents', v_cap, 'period', v_period));
        end if;
        v_idx := v_idx + 1;
      end loop;
    end loop;
  end if;

  for c in
    select e from jsonb_array_elements(v_cand) e
     order by (e->>'level') desc,
              (e->>'rule_id'), (e->>'effect_index')::int
  loop
    v_suppressed := false; v_reason := null; v_d := 0; v_target := null;
    v_stackable := (c->>'stackable')::boolean;
    v_cap := nullif(c->>'cap_cents', '')::int;
    v_period := c->>'period';

    if not v_stackable and ((c->>'level' = 'line' and v_any_line) or (c->>'level' = 'bill' and v_any_bill)) then
      v_suppressed := true; v_reason := 'stacking';
    end if;

    if not v_suppressed then
      if c->>'level' = 'line' then
        v_target := null;
        for j in 1 .. array_length(v_kind, 1) loop
          if v_kind[j] = (c->>'catalog_kind') and v_id[j] = nullif(c->>'catalog_id', '')::uuid and v_rem[j] > 0 then
            v_target := j; exit;
          end if;
        end loop;
        if v_target is null then
          v_suppressed := true; v_reason := 'no_target';
        else
          v_base := v_rem[v_target];
        end if;
      else
        v_base := (v_subtotal - v_total_discount)::int;
        if v_base <= 0 then v_suppressed := true; v_reason := 'no_target'; end if;
      end if;
    end if;

    if not v_suppressed then
      if c->>'effect_type' = 'apply_discount_pct' then
        v_d := round(v_base::numeric * (c->>'discount_pct')::numeric / 100.0)::int;
      else
        v_d := least((c->>'amount_cents')::int, v_base);
      end if;
      if v_d > v_base then v_d := v_base; end if;
      if v_d < 0 then v_d := 0; end if;
      if v_d = 0 then v_suppressed := true; v_reason := 'no_target'; end if;
    end if;

    v_ps := null; v_pe := null;
    if v_cap is not null then
      select period_start, period_end into v_ps, v_pe from app.ps1c_period_bounds(now(), v_period);
    end if;
    if not v_suppressed and v_cap is not null then
      select coalesce(committed_cents, 0) into v_committed from public.budget_periods
       where business_id = p_business and rule_id = (c->>'rule_id')::uuid and period_start = v_ps;
      v_committed := coalesce(v_committed, 0);
      v_projected := coalesce((v_rule_proj->>(c->>'rule_id'))::int, 0);
      if v_committed + v_projected + v_d > v_cap then
        v_suppressed := true; v_reason := 'budget_exhausted';
      else
        v_rule_proj := v_rule_proj || jsonb_build_object(c->>'rule_id', v_projected + v_d);
      end if;
    end if;

    if v_suppressed then
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', 0,
        'suppressed', true, 'suppression_reason', v_reason,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    else
      if c->>'level' = 'line' then
        v_rem[v_target] := v_rem[v_target] - v_d; v_any_line := true;
      else
        v_any_bill := true;
      end if;
      v_total_discount := v_total_discount + v_d;
      if not v_stackable then v_nonstack_applied := true; end if;
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', v_d,
        'suppressed', false, 'suppression_reason', null,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    end if;
  end loop;

  -- ===========================================================================================
  -- V370 — THE AUTOMATIC TIER DISCOUNT (owner: "for tiers it will be automatic if there is a
  -- discount % allocated to it").
  -- It is applied HERE, inside the single pricing authority, rather than by the till: a discount
  -- the browser subtracted for itself would make the sale total and this engine disagree, which
  -- is the two-sources-of-truth failure this codebase keeps paying for.
  -- Four rules, each a decision worth stating:
  --   * ONE discount, never stacked. The best (highest) percentage the customer's rung entitles
  --     them to, inherited down the ladder like every other tier benefit. Stacking Gold's 10%
  --     under Diamond's 30% would compound into a number no owner chose.
  --   * UNLIMITED benefits only. A discount carrying a per-period limit has to be COUNTED when it
  --     is used, and counting belongs to the staff-pressed Give button that already does it
  --     (staff_issue_tier_benefit_v365). Applying a limited one here would spend it silently on
  --     every bill and never record the spend.
  --   * Suppressed when a NON-STACKABLE rule effect has already applied. That rule said it does
  --     not stack; a tier discount landing on top would break the promise the owner authored.
  --   * V394: the tier lifecycle is honoured — a paused or soft-deleted tier neither sets the
  --     customer's rung (app.v365_client_tier filters both since v394) nor donates its benefit
  --     down the ladder (this SELECT filters t.paused/t.deleted_at). Owner ruling 2026-08-20:
  --     paused and deleted tiers grant nothing, matching what customers see (v393 display).
  --   * It carries rule_id null and source 'tier_benefit'. public.checkout_discount_lines is keyed
  --     on a real rule and its rule_id is NOT NULL, so record_cart_sale skips that provenance row
  --     for this effect and records the fulfilment and the signed sale_items line instead.
  -- ===========================================================================================
  if p_client is not null then
    if p_tier_benefit is not null then
      -- nestly_v656 — THE HAND-APPLIED DISCOUNT (owner: "when i 'use' the voucher it must deduct
      -- the overall amount by 10%"). A LIMITED discount could not come off a bill at all: v370
      -- deliberately excluded it here because spending an allowance has to be COUNTED, and the
      -- only thing that counted was the staff Give button, which moves no money. So staff pressed
      -- Give, Peekaa recorded that a 20%-off perk had been handed over, and then charged the
      -- customer full price.
      -- The answer is not to auto-apply it — that would spend it on every bill — but to let it be
      -- chosen, here, once, for THIS sale. The count is written by record_cart_sale in the same
      -- transaction that takes the money, so the discount and the spend can never disagree.
      -- Everything the automatic path checks is checked again: the benefit is this business's, it
      -- is a live discount on a tier the customer has actually reached, and it is in date.
      select b.id, b.tier_id, b.label, b.discount_percent, b.limit_count, b.limit_period,
             b.discount_scope, b.max_discount_cents
        into v_tier_benefit
        from public.tier_benefits_v365 b
        join public.loyalty_tiers t on t.id = b.tier_id and t.business_id = b.business_id
       where b.id = p_tier_benefit
         and b.business_id = p_business
         and b.deleted_at is null and b.active
         and b.benefit_kind = 'discount_pct'
         and coalesce(t.paused, false) = false and t.deleted_at is null
         and t.threshold <= coalesce((app.v365_client_tier(p_business, p_client)).threshold, -1)
         and (t.effective_from is null or t.effective_from <= statement_timestamp())
         and (t.expires_at is null or t.expires_at > statement_timestamp());
      if v_tier_benefit.id is null then
        return jsonb_build_object('status', 'tier_benefit_not_available',
          'reason', 'tier_benefit_not_available: that tier discount is not available to this customer');
      end if;
      -- Birthday-month perks are only live in the customer's birthday month, exactly as the
      -- Give button and the customer's own card judge them.
      if v_tier_benefit.limit_period = 'birthday_month'
         and not coalesce(app.v367_in_birthday_month(p_client, now()), false) then
        return jsonb_build_object('status', 'tier_benefit_not_available',
          'reason', 'tier_benefit_not_available: this perk is only available in the customer''s birthday month');
      end if;
      -- The allowance is checked HERE so the till can say so before the customer is charged;
      -- staff_issue_tier_benefit_v365 checks it again under a lock when the sale is finalised.
      if v_tier_benefit.limit_count is not null then
        select count(*)::int into v_tier_used
          from public.tier_benefit_issues_v365 i
         where i.benefit_id = v_tier_benefit.id and i.client_id = p_client
           and i.period_key = app.v365_period_key(v_tier_benefit.limit_period, now());
        if v_tier_used >= v_tier_benefit.limit_count then
          return jsonb_build_object('status', 'tier_benefit_used_up',
            'reason', 'tier_benefit_used_up: this customer has already used that perk for this period');
        end if;
      end if;
    else
    select b.id, b.tier_id, b.label, b.discount_percent, b.limit_count, b.limit_period,
           b.discount_scope, b.max_discount_cents
      into v_tier_benefit
      from public.tier_benefits_v365 b
      join public.loyalty_tiers t on t.id = b.tier_id and t.business_id = b.business_id
     where b.business_id = p_business
       and b.deleted_at is null and b.active
       and b.benefit_kind = 'discount_pct'
       and b.limit_count is null
       and coalesce(t.paused, false) = false and t.deleted_at is null
       and t.threshold <= coalesce((app.v365_client_tier(p_business, p_client)).threshold, -1)
       and (t.effective_from is null or t.effective_from <= statement_timestamp())
       and (t.expires_at is null or t.expires_at > statement_timestamp())
     order by b.discount_percent desc, t.threshold desc, b.id
     limit 1;
    end if;

    if v_tier_benefit.id is not null and not v_nonstack_applied then
      -- nestly_v656 — WHAT THE PERCENTAGE COMES OFF (owner: "10% off selected products able to
      -- select the product/services ... if blanket 10% also allow that selection"). A benefit
      -- that names no item keeps v370's behaviour exactly: the whole remaining bill. A benefit
      -- that names items is worth its percentage of THOSE LINES only, and it reads them from
      -- v_rem[] — each line's remainder AFTER the Studio rules have taken their cut — so a line
      -- already discounted cannot be discounted twice off its full price.
      -- nestly_v657 — TWO SHAPES, AND ONLY TWO (owner ruling 2026-08-31, after seeing v656's
      -- tick-list discount every ticked item at once):
      --   'bill' — a percentage off the whole bill, optionally capped in money.
      --   'item' — a percentage off ONE item per transaction. The tick-list stops being "which
      --            items are discounted" and becomes "which items are ELIGIBLE"; exactly one of
      --            them is discounted, and the owner's ruling for which is the HIGHEST-PRICED
      --            eligible line on this bill — deterministic, needs no decision at the counter,
      --            and it is the line the customer would have chosen themselves.
      v_tier_scoped := coalesce(v_tier_benefit.discount_scope, 'bill') = 'item';
      v_tier_target := null;
      if v_tier_scoped then
        v_tier_best := 0;
        for j in 1 .. coalesce(array_length(v_rem, 1), 0) loop
          if v_rem[j] > v_tier_best and v_id[j] is not null and exists(
               select 1 from public.tier_benefit_scope_v656 sc
                where sc.benefit_id = v_tier_benefit.id
                  and ((v_kind[j] = 'product' and sc.product_id = v_id[j])
                    or (v_kind[j] = 'service' and sc.service_id = v_id[j]))) then
            v_tier_best := v_rem[j];
            v_tier_target := j;
          end if;
        end loop;
        -- Nothing eligible on this bill is not an error for the AUTOMATIC path — the perk simply
        -- does not apply. For a perk the counter chose by hand it IS an error, because the till
        -- quoted it and staff need to be told why it went; that refusal is raised below.
        v_tier_base := coalesce(v_tier_best, 0);
        if v_tier_base = 0 and p_tier_benefit is not null then
          return jsonb_build_object('status', 'tier_benefit_no_eligible_item',
            'reason', 'tier_benefit_no_eligible_item: nothing on this bill is covered by that perk');
        end if;
        -- A bill-level rule discount is not reflected in v_rem, so the base is capped at what is
        -- actually still payable. Without this a bill-level rule plus a tier discount could
        -- together exceed the subtotal.
        v_tier_base := least(v_tier_base, (v_subtotal - v_total_discount)::int);
      else
        v_tier_base := (v_subtotal - v_total_discount)::int;
      end if;
      if v_tier_base > 0 then
        v_tier_d := round(v_tier_base::numeric * v_tier_benefit.discount_percent / 100.0)::int;
        -- nestly_v657 (owner: "Merchant sets a maximum discount, e.g. 10% off, capped at $20").
        -- The ceiling is money, not a percentage, and it is applied AFTER the percentage so the
        -- owner's cap is what the customer's bill actually honours.
        if v_tier_benefit.max_discount_cents is not null then
          v_tier_d := least(v_tier_d, v_tier_benefit.max_discount_cents);
        end if;
        if v_tier_d > 0 then
          v_total_discount := v_total_discount + v_tier_d;
          v_applied := v_applied || jsonb_build_array(jsonb_build_object(
            'rule_id', null, 'effect_index', 0, 'effect_type', 'apply_discount_pct',
            'level', 'bill', 'target_line_index', null, 'amount_cents', v_tier_d,
            'suppressed', false, 'suppression_reason', null,
            'capped', false, 'cap_cents', null,
            'period_start', null, 'period_end', null,
            'source', 'tier_benefit', 'tier_benefit_id', v_tier_benefit.id,
            'tier_id', v_tier_benefit.tier_id, 'label', v_tier_benefit.label,
            'discount_pct', v_tier_benefit.discount_percent,
            /* nestly_v656: record_cart_sale reads these two. `limited` is what tells it to spend
               the customer's allowance when the sale is finalised; `scoped` is provenance for the
               receipt line and for anyone reading an evaluation later. */
            'tier_benefit_limited', v_tier_benefit.limit_count is not null,
            'tier_benefit_scoped', v_tier_scoped,
            /* nestly_v657: the shape, and — for a single-item discount — the line it landed on,
               so the till can name it instead of saying "(whole bill)" about one item. */
            'tier_benefit_mode', coalesce(v_tier_benefit.discount_scope, 'bill'),
            'tier_benefit_item', case when v_tier_target is null then null else v_name[v_tier_target] end,
            'tier_benefit_capped', v_tier_benefit.max_discount_cents is not null
              and v_tier_d = v_tier_benefit.max_discount_cents));
        end if;
      end if;
    end if;
  end if;

  v_total := (v_subtotal - v_total_discount)::int;

  if v_total = 0 then
    return jsonb_build_object('status', 'total_zero_not_supported',
      'reason', 'total_zero_not_supported: this checkout is fully discounted to zero and a zero-value sale is not supported; adjust the cart or the discount');
  end if;

  select gst_registered, gst_rate_bps into v_gst_reg, v_gst_bps from public.businesses where id = p_business;
  if coalesce(v_gst_reg, false) and coalesce(v_gst_bps, 0) > 0 then
    v_gst := round(v_total::numeric * v_gst_bps / (10000 + v_gst_bps))::int;
  else
    v_gst_bps := 0; v_gst := 0;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'server_lines', v_server,
    'subtotal_cents', v_subtotal::int,
    'applied_effects', v_applied,
    'discount_total_cents', v_total_discount::int,
    'total_cents', v_total,
    'gst_cents', v_gst,
    'gst_rate_bps', coalesce(v_gst_bps, 0),
    'cart_hash', app.ps1c_cart_hash(v_server));
end $function$;

revoke all on function app.ps1c_plan_checkout(uuid, uuid, uuid, jsonb, uuid, uuid) from public, anon;

commit;

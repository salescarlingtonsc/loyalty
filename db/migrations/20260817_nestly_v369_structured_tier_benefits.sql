-- NESTLY v369 — a tier benefit becomes STRUCTURED: a kind, and the number or item that goes with it.
--
-- OWNER RULING 2026-08-17: "we may need to ensure that the backend is set properly (currently is
-- using words - very misleading) it should be drop down > discount > add % . or drop down >
-- free item > type the item out or pull from existing products (drop down selection)."
--
-- WHY THIS MATTERS BEYOND THE FORM. v365 stored a benefit as one free-text line, which is fine
-- for a human reading a chip and useless for anything that has to ACT on it: "30% off every
-- visit" is a sentence, not a percentage, so nothing could ever apply it to a bill. The owner's
-- next ask — a tier discount that comes off automatically — is impossible against text. This
-- migration is that prerequisite: the number now exists as a number.
--
-- SHAPE.
--   benefit_kind  'discount_pct' | 'free_item' | 'custom'
--   discount_percent  required by discount_pct, forbidden otherwise
--   product_id        optional for free_item (pull from the catalogue), else the typed item text
--                     lives in item_label
--   label             STILL the customer-facing line, but DERIVED for the two structured kinds
--                     (app.v369_benefit_label) so the words and the number can never disagree.
--                     'custom' keeps whatever the owner typed — existing rows are exactly that.
--
-- EXISTING ROWS ARE NOT GUESSED AT. Every current benefit becomes kind='custom' with its text
-- intact. Parsing "30% off every visit" into a 30 would be inventing an intent the owner never
-- stated in a machine-readable way, and a wrong guess here would later come off a real bill.
--
-- APPLIED 2026-08-17 to gadpooereceldfpfxsod after a rolled-back rehearsal of this file plus
-- db/tests/v365_tier_benefit_limits.sql and db/tests/v367_birthday_month_benefit_period.sql.

begin;

alter table public.tier_benefits_v365
  add column if not exists benefit_kind text not null default 'custom',
  add column if not exists discount_percent numeric(5,2),
  add column if not exists product_id uuid references public.products(id) on delete set null,
  add column if not exists item_label text;

alter table public.tier_benefits_v365
  drop constraint if exists tier_benefits_v365_kind_check;
alter table public.tier_benefits_v365
  add constraint tier_benefits_v365_kind_check
  check (benefit_kind in ('discount_pct','free_item','custom'));

alter table public.tier_benefits_v365
  drop constraint if exists tier_benefits_v365_kind_shape_check;
alter table public.tier_benefits_v365
  add constraint tier_benefits_v365_kind_shape_check check (
    (benefit_kind = 'discount_pct'
      and discount_percent is not null and discount_percent > 0 and discount_percent <= 100
      and product_id is null and item_label is null)
    or (benefit_kind = 'free_item'
      and discount_percent is null
      and (product_id is not null or length(btrim(coalesce(item_label,''))) between 1 and 120))
    or (benefit_kind = 'custom'
      and discount_percent is null and product_id is null and item_label is null));

-- The customer-facing words for a structured benefit, derived from its own fields. One place, so
-- the chip a customer reads is generated from the number the till will one day deduct.
create or replace function app.v369_benefit_label(
  p_kind text, p_discount numeric, p_product uuid, p_item text, p_fallback text)
returns text language sql stable
set search_path to 'pg_catalog','public','pg_temp'
as $$
  select case coalesce(p_kind,'custom')
    /* FM999990.99 leaves a bare trailing '.' on a whole number (30.00 -> "30."), which the
       rehearsal caught as "30.% off". Strip it so 30 reads "30% off" and 12.5 still reads
       "12.5% off". */
    when 'discount_pct' then regexp_replace(trim(to_char(p_discount,'FM999990.99')),'\.$','')||'% off'
    when 'free_item' then 'Free '||coalesce(
      (select p.name from public.products p where p.id = p_product),
      nullif(btrim(coalesce(p_item,'')),''), 'item')
    else btrim(coalesce(p_fallback,''))
  end
$$;
revoke all on function app.v369_benefit_label(text,numeric,uuid,text,text) from public, anon, authenticated;

create or replace function public.business_set_tier_benefits_v365(
  p_business uuid, p_tier uuid, p_benefits jsonb)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
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

    if v_kind='discount_pct' then
      if v_discount is null or v_discount <= 0 or v_discount > 100 then
        raise exception 'a discount must be between 0.01 and 100 percent' using errcode='22023';
      end if;
      v_product := null; v_item_label := null;
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

    -- Derived for the structured kinds; the owner's own words for 'custom'.
    v_label := app.v369_benefit_label(v_kind, v_discount, v_product, v_item_label,
                 nullif(btrim(coalesce(v_item->>'label','')),''));
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
             active=true, deleted_at=null, updated_at=now(), updated_by=auth.uid()
       where id=v_id and business_id=p_business and tier_id=p_tier;
      if not found then
        raise exception 'benefit not found on this tier' using errcode='42704';
      end if;
    else
      insert into public.tier_benefits_v365(business_id,tier_id,label,limit_count,limit_period,sort,
        benefit_kind,discount_percent,product_id,item_label,updated_by)
      values(p_business,p_tier,v_label,v_limit,v_period,v_index,
        v_kind,v_discount,v_product,v_item_label,auth.uid())
      returning id into v_id;
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
end $$;
revoke all privileges on function public.business_set_tier_benefits_v365(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.business_set_tier_benefits_v365(uuid,uuid,jsonb) to authenticated;

-- The till read carries the structure through, so the counter can show "10% off" as a number and
-- the checkout increment that follows has something to compute with.
create or replace function public.staff_tier_benefits_for_client_v365(p_business uuid, p_client uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
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
     and t.threshold<=v_tier.threshold
     and (t.effective_from is null or t.effective_from<=statement_timestamp())
     and (t.expires_at is null or t.expires_at>statement_timestamp());

  return jsonb_build_object('status','ok',
    'tier',jsonb_build_object('id',v_tier.id,'label',v_tier.name,'threshold',v_tier.threshold),
    'in_birthday_month',v_birthday,
    'benefits',v_rows);
end $$;
revoke all privileges on function public.staff_tier_benefits_for_client_v365(uuid,uuid) from public, anon;
grant execute on function public.staff_tier_benefits_for_client_v365(uuid,uuid) to authenticated;

commit;

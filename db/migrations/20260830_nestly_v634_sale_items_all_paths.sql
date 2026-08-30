-- NESTLY v634 — Phase A, M9 (A8/D6): every sale carries its honest line items.
-- Today only the cart-kernel path writes sale_items; package, membership, gift-card,
-- package-session, welcome/bring-back/referral-gift and plain quick sales are single-amount
-- rows, so basket/category analytics silently exclude them. Per owner ruling D6 the five
-- commercial classes stay distinguishable — two new line kinds:
--   package_session   — consumption of a prepaid session; unit_cents = 0 is the truth
--   reward_fulfilment — a $0 redemption visit (welcome / bring-back / referral gift)
-- and NO list price is ever manufactured: each line carries exactly the amount the sale
-- itself knew.
--
-- Writers are patched in place from live definitions with single-occurrence anchors.
-- Injected code references ONLY record fields the live body already references (plpgsql
-- resolves record fields at runtime — an invented field would detonate inside a sale).
-- Where a plan/reward id is not provably available in scope, ref_id is null and the
-- description carries the name snapshot the body already used.
--
-- record_quick_sale synthesizes a 'custom' line UNLESS the cart kernel owns itemization:
-- record_cart_sale marks its delegate call with a transaction-local context so kernel
-- parents never get a duplicate line.
--
-- Guards verified compatible: sale_items_kind_guard only rejects package/membership/
-- gift_card lines under quick_sale/cart_sale parents (ours ride their own kinds);
-- on_sale_item_stock_deduct_v455 only acts on retail lines whose parent sale has no
-- product_id (legacy retail sales carry sales.product_id, so backfilled lines cannot
-- double-deduct stock).
begin;

-- ---------------------------------------------------------------------------
-- 1. Widen the line-kind vocabulary.
-- ---------------------------------------------------------------------------
alter table public.sale_items drop constraint sale_items_item_type_check;
alter table public.sale_items add constraint sale_items_item_type_check
  check (item_type in ('service','retail','package','membership','gift_card','custom',
                       'studio_discount','package_session','reward_fulfilment'));

-- ---------------------------------------------------------------------------
-- 2. Patch the writers.
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_item jsonb;
  v_def text;
  v_anchor text;
  v_count integer;
  v_targets constant jsonb := jsonb_build_array(
    -- record_cart_sale: mark kernel context before delegating the parent row.
    jsonb_build_object(
      'fn', 'public.record_cart_sale(uuid,uuid,uuid,uuid,text,text,jsonb,uuid,boolean,timestamptz,jsonb)',
      'anchor', 'v_financial := public.record_quick_sale(',
      'mode', 'before',
      'inject', E'perform set_config(''app.cart_kernel_context'',''1'',true);\n  '),
    -- record_quick_sale: one custom line per non-kernel quick sale.
    jsonb_build_object(
      'fn', 'public.record_quick_sale(uuid,integer,text,uuid,uuid,uuid,text,text,boolean,timestamptz)',
      'anchor', E') returning * into v_sale;\n\n  if v_paid then',
      'mode', 'after_anchor_head',
      'inject', E') returning * into v_sale;\n\n  -- v634: the sale''s one honest line, unless the cart kernel owns itemization.\n  if coalesce(nullif(current_setting(''app.cart_kernel_context'', true), ''''), '''') <> ''1'' then\n    insert into public.sale_items(sale_id, business_id, item_type, description, qty, unit_cents, line_cents, staff_id)\n    values (v_sale.id, p_business, ''custom'', coalesce(v_note, ''quick sale''), 1, p_amount_cents, p_amount_cents, p_staff);\n  end if;\n\n  if v_paid then'),
    -- appointment completion: declare first, then the service line (each patch
    -- re-reads the fresh definition, so order matters).
    jsonb_build_object(
      'fn', 'app.on_appointment_completed()',
      'anchor', E'declare\n  v_amount integer;',
      'mode', 'after_anchor_head',
      'inject', E'declare\n  v_amount integer;\n  v_sale_id uuid;'),
    jsonb_build_object(
      'fn', 'app.on_appointment_completed()',
      'anchor', E'      ''appointment completed''\n    ) on conflict do nothing;',
      'mode', 'after_anchor_head',
      'inject', E'      ''appointment completed''\n    ) on conflict do nothing returning id into v_sale_id;\n    if v_sale_id is not null then\n      insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, staff_id)\n      values (v_sale_id, new.business_id, ''service'', new.service_id,\n              coalesce((select srv.name from public.services srv where srv.id = new.service_id), ''appointment service''),\n              1, v_amount, v_amount, v_staff);\n    end if;'),
    -- membership enrolment / renewal.
    jsonb_build_object(
      'fn', 'public.enroll_membership(uuid,uuid,uuid)',
      'anchor', E'    ''membership enrollment: '' || mp.name, null\n  ) returning * into v_sale;',
      'mode', 'after',
      'inject', E'\n  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents)\n  values (v_sale.id, p_business, ''membership'', mp.id, mp.name, 1, mp.price_cents, mp.price_cents);'),
    jsonb_build_object(
      'fn', 'app.run_membership_renewals()',
      'anchor', E'        now(), ''membership renewal: '' || due.plan_name, null\n      ) returning * into v_sale;',
      'mode', 'after',
      'inject', E'\n      insert into public.sale_items(sale_id, business_id, item_type, description, qty, unit_cents, line_cents)\n      values (v_sale.id, due.business_id, ''membership'', due.plan_name, 1, due.price_cents, due.price_cents);'),
    -- gift cards.
    jsonb_build_object(
      'fn', 'public.issue_gift_card(uuid,integer,uuid,text,uuid)',
      'anchor', E'    ''gift card liability issued'',v_staff\n  ) returning * into v_sale;',
      'mode', 'after',
      'inject', E'\n  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, staff_id)\n  values (v_sale.id, p_business, ''gift_card'', v_card.id, ''gift card issued'', 1, p_amount, p_amount, v_staff);'),
    jsonb_build_object(
      'fn', 'public.issue_gift_card_at_branch_v117(uuid,uuid,integer,uuid,text,uuid)',
      'anchor', E'    ''gift card liability issued'',v_staff,p_branch\n  )\n  returning * into v_sale;',
      'mode', 'after',
      'inject', E'\n  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, staff_id)\n  values (v_sale.id, p_business, ''gift_card'', v_card.id, ''gift card issued'', 1, p_amount, p_amount, v_staff);'),
    -- package sale + session consumption.
    jsonb_build_object(
      'fn', 'public.sell_package_v102(uuid,uuid,uuid,uuid,uuid)',
      'anchor', E'    ''package sold: ''||v_plan.name,p_branch,v_staff\n  );',
      'mode', 'after',
      'inject', E'\n  insert into public.sale_items(sale_id, business_id, item_type, description, qty, unit_cents, line_cents, staff_id)\n  values (v_sale_id, p_business, ''package'', v_plan.name, 1, v_plan.price_cents, v_plan.price_cents, v_staff);'),
    jsonb_build_object(
      'fn', 'public.use_package_session(uuid,uuid,text)',
      'anchor', E'          ''package session used: '' || v_plan.name, v_branch, v_staff);',
      'mode', 'after',
      'inject', E'\n  insert into public.sale_items(sale_id, business_id, item_type, description, qty, unit_cents, line_cents, staff_id)\n  values (v_sale_id, p_business, ''package_session'', v_plan.name, 1, 0, 0, v_staff);'),
    jsonb_build_object(
      'fn', 'public.use_package_session_v102(uuid,uuid,uuid,text)',
      'anchor', E'    ''package session used: ''||v_package.plan_name_snapshot,p_branch,v_staff\n  );',
      'mode', 'after',
      'inject', E'\n  insert into public.sale_items(sale_id, business_id, item_type, description, qty, unit_cents, line_cents, staff_id)\n  values (v_sale_id, p_business, ''package_session'', v_package.plan_name_snapshot, 1, 0, 0, v_staff);'),
    -- $0 reward-fulfilment visits.
    jsonb_build_object(
      'fn', 'public.staff_redeem_bringback_v361(uuid,uuid,uuid,uuid)',
      'anchor', E'  values (v_sale_id,p_business,p_client,''retail'',0,''bring-back voucher redeemed: ''||v_grant.reward_label,p_branch);',
      'mode', 'after',
      'inject', E'\n  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents)\n  values (v_sale_id, p_business, ''reward_fulfilment'', v_grant.id, v_grant.reward_label, 1, 0, 0);'),
    jsonb_build_object(
      'fn', 'public.staff_redeem_referral_v420(uuid,uuid,uuid,uuid)',
      'anchor', E'  values (v_sale_id,p_business,p_client,''retail'',0,''referral gift redeemed: ''||v_grant.reward_label,p_branch);',
      'mode', 'after',
      'inject', E'\n  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents)\n  values (v_sale_id, p_business, ''reward_fulfilment'', v_grant.id, v_grant.reward_label, 1, 0, 0);'),
    jsonb_build_object(
      'fn', 'public.staff_redeem_welcome_offer_v215(uuid,uuid,uuid,uuid,text)',
      'anchor', E'          0, ''welcome offer redeemed: ''||v_grant.reward_label, p_branch, v_staff);',
      'mode', 'after',
      'inject', E'\n  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, staff_id)\n  values (v_sale_id, p_business, ''reward_fulfilment'', v_grant.id, v_grant.reward_label, 1, 0, 0, v_staff);')
  );
begin
  for v_item in select * from jsonb_array_elements(v_targets) loop
    v_anchor := v_item->>'anchor';
    select pg_get_functiondef(to_regprocedure(v_item->>'fn')) into v_def;
    if v_def is null then
      raise exception 'v634: function % not found — verify the live signature before applying', v_item->>'fn';
    end if;
    v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
    if v_count <> 1 then
      raise exception 'v634: anchor for % occurs % times (expected exactly 1) — live body drifted, refuse to patch',
        v_item->>'fn', v_count;
    end if;
    if v_item->>'mode' = 'before' then
      v_def := replace(v_def, v_anchor, (v_item->>'inject') || v_anchor);
    elsif v_item->>'mode' = 'after' then
      v_def := replace(v_def, v_anchor, v_anchor || (v_item->>'inject'));
    else -- after_anchor_head: the inject text REPLACES the anchor (it embeds it)
      v_def := replace(v_def, v_anchor, v_item->>'inject');
    end if;
    execute v_def;
  end loop;
end;
$patch$;

-- CREATE OR REPLACE preserves each function's existing grants; no signature changed here.

-- ---------------------------------------------------------------------------
-- 3. Backfill: one honest projection line per itemless historical sale, from
--    the sale row's own facts. Machine-written note prefixes deterministically
--    identify the $0 entitlement classes. Reversal rows are skipped (analytics
--    reads them through reversal_of). product_id intentionally rides ref_id
--    only — the parent sales already deducted stock at the time.
-- ---------------------------------------------------------------------------
insert into public.sale_items
  (sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, staff_id)
select s.id, s.business_id,
  case
    when s.note like 'package session used:%' then 'package_session'
    when s.note like 'welcome offer redeemed:%' then 'reward_fulfilment'
    when s.note like 'bring-back voucher redeemed:%' then 'reward_fulfilment'
    when s.note like 'referral gift redeemed:%' then 'reward_fulfilment'
    when s.kind = 'service' then 'service'
    when s.kind = 'retail' then 'retail'
    when s.kind = 'membership' then 'membership'
    when s.kind = 'gift_card' then 'gift_card'
    when s.kind = 'package' then 'package'
    else 'custom'
  end,
  case
    when s.kind = 'service' and s.appointment_id is not null
      then (select a.service_id from public.appointments a where a.id = s.appointment_id)
    when s.kind = 'retail' then s.product_id
    else null
  end,
  left(coalesce(nullif(btrim(s.note), ''), s.kind), 180) || ' ·backfill',
  1, s.amount_cents, s.amount_cents, s.staff_id
from public.sales s
where s.reversal_of is null
  and s.amount_cents >= 0
  and not exists (select 1 from public.sale_items si where si.sale_id = s.id);

-- ---------------------------------------------------------------------------
-- 4. Watermark.
-- ---------------------------------------------------------------------------
insert into public.analytics_observation_watermarks (metric_key, observed_since, reason)
values ('sale_items_full_coverage', now(),
        'all sale paths write line items from v634; earlier itemless sales carry a single ·backfill projection line');

commit;

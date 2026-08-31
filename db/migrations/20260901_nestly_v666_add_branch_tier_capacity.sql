/* nestly_v666 — adding a branch stopped working the moment capacity became a tier.

   Owner report (2026-09-01, photo): pressing "Create branch" answers
   "customer capacity must be one of the published tiers".

   business_add_branch_v202 has always computed the capacity to bill at from the tenant's own
   customer count, rounded up to the next 1,000 — the v124 block model. v664 replaced that model
   with three published tiers (10,000 / 40,000 / 100,000) and made request_billing_command_v124
   refuse anything that is not one of them, which is the right refusal in the wrong place: the
   number was not chosen by the owner, it was derived by this function, and a derived number that
   the pricing engine will not accept is a bug in the deriver.

   Two derived values are repaired, both by mapping through the tier ladder that v664 made the
   authority:
     · no terms row yet (the usual case — nothing has been bought) → the smallest tier that covers
       the customers the business actually has, instead of `count rounded up to 1,000`;
     · a terms row written before v664 → its capacity is rounded UP to the tier that covers it,
       never down, so a firm that bought 3,000 profiles under the old model is quoted the 10,000
       tier rather than being refused.
   A business above the largest tier is told to talk to Peekaa in the same words every other path
   uses, rather than being handed a Stripe page that cannot be priced.

   Nothing else about the branch flow changes: the branch is still created unpaid and switched
   off, still through the one authority, and the payment still activates it.

   Rollback suite: db/tests/v666_add_branch_tier_capacity.sql */
begin;

do $v666_add_branch$
declare
  v_definition text := pg_get_functiondef(
    'public.business_add_branch_v202(uuid,text,text,text,text,uuid,uuid)'::regprocedure);
  v_needle constant text := E'  v_cadence := coalesce(nullif(v_cadence,''''),''annual'');\n  if v_capacity is null then\n    select greatest(1000, ceil(count(*)::numeric/1000)::integer*1000)\n      into v_capacity from public.clients where business_id=p_business;\n  end if;';
  v_replacement constant text := E'  v_cadence := coalesce(nullif(v_cadence,''''),''annual'');\n  /* v666: capacity is a published tier since v664, not a count rounded up to 1,000. Whatever is\n     known about this business — a pre-v664 terms row, or nothing at all — is mapped UP to the\n     smallest tier that covers it, because the branch checkout must ask for a price the pricing\n     engine will accept. */\n  select (app.billing_tier_for_capacity_v664(\n           v_cadence,\n           greatest(coalesce(v_capacity,0), count(*)::integer, 1)\n         )).capacity_ceiling\n    into v_capacity\n    from public.clients where business_id=p_business;\n  if v_capacity is null then\n    raise exception ''customer capacity above the largest tier needs Peekaa support''\n      using errcode=''22023'';\n  end if;';
  v_occurrences integer;
begin
  v_occurrences := (length(v_definition)-length(replace(v_definition,v_needle,'')))/length(v_needle);
  if v_occurrences <> 1 then
    raise exception 'v666 expected one block-model capacity derivation in business_add_branch_v202, found %',
      v_occurrences using errcode='55000';
  end if;
  execute replace(v_definition, v_needle, v_replacement);
end
$v666_add_branch$;

commit;

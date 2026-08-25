-- nestly_v507 — a business is LIVE from the moment it exists. On means live.
--
-- OWNER RULING (2026-08-25): "publish = live - not draft or configuration follow", then
-- "decide & proceed. make sure on = live" — answering "why it shows gifts all set up and on
-- already but it shows off for the rewards?". This restates v415 photo 2 ("pressing save would
-- publish to live. dont need hide in draft"). There is ONE state and one meaning: a switched-on
-- programme is earning and its gifts are redeemable. No draft, no separate configuration step.
--
-- THE DEFECT. Since 2026-07-23 every onboarding path seeds the tenant's loyalty base as a DRAFT:
--
--     values(v_business.id,'points',1,800,2000,false,'classic','draft','onboarding_preset')
--
-- app.seed_loyalty_config_version() copies that word into the v1 firm_config_versions row and —
-- because it is not 'published' — leaves businesses.active_config_version_id NULL. Only
-- publish_loyalty_config ever fills it in, and its only caller is the last step of the setup
-- wizard. Businesses created before that change (Cubbly SPA, 2026-07-16, 'legacy_v1') were seeded
-- published and have never had any of this trouble.
--
-- WHY IT IS NOT COSMETIC. app.resolve_loyalty_branch_config — what the sale trigger calls for the
-- earn rate — returns NO ROW when active_config_version_id is null (its own comment: "a newly
-- onboarded firm may still have only its inactive draft ... there is no earn configuration"), so
-- app.on_sale_recorded earns NOTHING, and app.reward_availability_v432 serves NOTHING, while the
-- owner's own page truthfully reports the switch On and the gift saved. Measured on prod before
-- this migration: eight earns_points sales across AhXiang, HENG HENG 888 and KKY demo with zero
-- points_ledger rows — including a S$3,200 sale on 2026-08-23. Bistro 999: switch On, one live
-- gift, reward_availability_v432 = 0 rows. Fully configured, switched on, invisible.
--
-- THE FIX, IN ONE PLACE. The seed trigger, not the four onboarding functions.
-- app.activate_self_serve_paid_v130, activate_approved_business_application_v95,
-- platform_decide_business_application_v105 and platform_activate_approved_application_v169 all
-- insert the same preset row and all reach this trigger; splicing 'published' into four large
-- SECURITY DEFINER bodies would be four chances to break an activation (exactly how v169 broke
-- one, which v277 had to repair). Seeding the FIRST version live covers every path that exists
-- and every path added later.
--
-- WHAT IS DELIBERATELY NOT CHANGED. loyalty_programs.active stays whatever the seeder passed
-- (false). Since v314 the SPINE is the authority on what is running — business_programmes.active
-- is what app.on_sale_recorded loops over and what the owner's switches write — so a live
-- configuration with every spine row off runs nothing, which is the correct birth state.
-- Publishing the configuration is not switching a programme on; it makes the firm's settings
-- real, so that switching one on means what the owner was told it means.

begin;

create or replace function app.seed_loyalty_config_version()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_id uuid := gen_random_uuid();
begin
  if new.current_config_version_id is not null then return new; end if;
  -- nestly_v507: born 'published', whatever word the inserting path used. The status of a firm's
  -- FIRST version is not a decision anyone makes — there is nothing yet to review, nothing to
  -- compare against, and no earlier version to keep serving while this one is drafted.
  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,snapshot_hash,created_by,published_at
  ) values (
    v_id,new.business_id,1,'published',coalesce(new.recommendation_source,'initial'),
    md5((to_jsonb(new)-'id'-'business_id'-'current_config_version_id')::text),
    auth.uid(),now()
  );
  insert into public.loyalty_program_versions (
    config_version_id,business_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days
  ) values (
    v_id,new.business_id,new.kind,new.loyalty_model,new.active,
    new.earn_points_per_dollar,new.redeem_points,new.reward_credit_cents,new.stamp_target,
    new.stamp_per_cents,new.tier_basis,new.expiry_mode,new.expiry_days
  );
  -- The base row must not keep saying 'draft' about a version that is live, or the Loyalty page
  -- and the engine would read two different answers to the same question.
  update public.loyalty_programs
     set current_config_version_id=v_id, configuration_status='published'
   where id=new.id;
  -- Never clobber a version a business is already serving: this trigger only ever seeds a FIRST
  -- one, so it claims the pointer only when nothing holds it.
  update public.businesses set active_config_version_id=v_id
   where id=new.business_id and active_config_version_id is null;
  return new;
end $function$;

comment on function app.seed_loyalty_config_version() is
  'nestly_v507: a business is live from birth — its first loyalty configuration version is published and adopted, because publish means live and there is no draft state.';

commit;

-- nestly_v684 — a retired offer that actually reached customers can never be deleted (audit F028).
--
-- SYMPTOM. The owner publishes an offer, customers get the in-app alert, and weeks later the owner
-- presses "End" on it. That works: business_delete_promotion_v183 takes its retire branch, sets
-- active=false and pulls ends_at back to now. The row then shows in #/promotions under the label
-- "Draft", with an unconditional Delete button whose confirmation says no customer has seen it.
-- Pressing Delete fails, every time, with "That change couldn't be saved. Check the details and
-- try again." The offer can never be removed from the list.
--
-- CAUSE. The RPC's two branches are chosen on `active`, not on "was this ever published". A
-- retired offer has active=false, so the second press falls into the hard-delete branch — the
-- branch v183's own header reserved for drafts. That branch deletes the branch scopes (v154/v155)
-- and the localized copy and then the content row, but nothing deletes
-- public.promotion_alert_runs_v122, whose promotion_id FK is
--     references public.business_customer_content_v95(id) on delete restrict
-- (verified live: promotion_alert_runs_v122_promotion_id_fkey, confdeltype 'r', enabled, validated,
-- not deferrable — and the only RESTRICT dependent of that table; the five other FKs into it,
-- business_featured_offer_v462, promotion_branch_scopes_v154/v155, promotion_redemption_intents_v290
-- and promotion_redemptions_v290, all CASCADE). A run row exists exactly when a publish or the
-- daily expiry sweep actually enqueued at least one recipient, so the delete raises 23503 and rolls
-- the whole call back precisely for the offers that mattered. An offer nobody was alerted about
-- deletes fine today; the ones customers saw are the ones that stick.
--
-- FIX. The delete branch releases the promotion's watermark rows before dropping the content row.
-- No schema change: the RESTRICT FK stays exactly as it is, so no other writer anywhere can erase
-- a run row by accident. Only this one audited route, which has already taken the content row
-- FOR UPDATE and proved it belongs to p_business, is allowed to let go of them.
--
-- WHY DELETING THOSE ROWS IS CORRECT, AND NOT A LOST AUDIT TRAIL. promotion_alert_runs_v122 is not
-- the record of what was sent. v122 introduces it as "One durable campaign watermark [that]
-- prevents the scheduler from re-running a customer-wide fanout after that exact activation/expiry
-- version succeeded", and it holds nothing but (promotion_id, source_kind, source_version,
-- processed_at) — no business, no recipient, no label. Its whole job is to answer "has this exact
-- promotion version already fanned out?", and once the promotion row is gone that question can
-- never be asked again: the uuid is dead and app.enqueue_promotion_alert_v122 returns 0 at its
-- first SELECT.
--
-- The evidence lives one table over, on purpose. nestly_v255 built
-- public.campaign_send_records_v255 as the immutable, business-attributed, timestamped send record,
-- with campaign_ref_id deliberately NOT a foreign key and campaign_label a denormalized snapshot,
-- stating the requirement in its own header: "a send record must survive
-- business_delete_promotion_v183". Its rolled-back suite already asserts that (v255 point 4). So
-- who was messaged, when, about which offer and under what name outlives this delete untouched;
-- only the scheduler's spent watermark goes.
--
-- NOT CHOSEN, and why:
--   * ON DELETE CASCADE on the FK. Same effect for this route, but it would let every future
--     writer of business_customer_content_v95 drop watermark rows silently, and it makes the
--     release invisible at the one place a reader looks for it. v255's finding 1.5 — a watermark
--     burned against zero recipients, which then muted the promotion forever — is exactly the kind
--     of accident a RESTRICT FK catches early. Keep the guard, name the exception.
--   * Archiving the run rows into a tombstone table. That would duplicate
--     campaign_send_records_v255 with strictly less information (no business, no recipients, no
--     label) while adding a table, its RLS, its grants and its retention question.
--   * Refusing the delete and making retire terminal in the UI. It leaves the owner unable to clear
--     a finished offer from their own list, which is the reported defect, not a fix for it.
--
-- WHAT THE OWNER STILL LOSES BY DELETING, unchanged by this migration and worth stating: the
-- delete branch already removes public.business_localized_copy_v95 for the offer, and since
-- nestly_v571 the customer inbox reader resolves an alert's title through that copy row by
-- source_ref_id with a LEFT JOIN. Deleting an offer therefore makes any historical inbox item
-- about it fall back to its generic title ("New promotion available"). That was already true of
-- every offer the old code could delete; it is now reachable for retired ones too. It degrades,
-- it does not break. The offer photo in business_media_assets_v95 is likewise left where it is
-- (no FK, keyed by entity_id) rather than deleted here: dropping the row without the storage
-- object would trade one orphan for another, and that clean-up is its own change.
--
-- ALSO IN THIS BODY, because the audit row for this exact action was misleading:
--   * detail now carries `published_once_at` and `alert_runs_released`. `was_published` is
--     coalesce(v_row.active,false), so deleting a RETIRED offer recorded was_published=false — the
--     one case where it is most wrong. It is left as it is for any existing reader and the two
--     honest facts are added beside it.
--
-- THE REST OF THE BODY IS THE LIVE FUNCTION, extracted from production with pg_get_functiondef on
-- 2026-09-02 and diffed, not retyped. Note that the live body writes audit_log.detail while
-- db/migrations/20260821_nestly_v412_promotion_delete_module_key.sql records `meta` — a column that
-- does not exist (nestly_v454 fixed the function in production and that file was never corrected).
-- This migration restates prod, so `detail` is what appears below. The module gate ('loyalty'), the
-- FOR UPDATE, the optimistic-version check, both v104 write GUCs and the retire branch are byte
-- identical to what is running.
--
-- REVERSIBLE: re-applying v412's body (with `meta` corrected to `detail`) restores the previous
-- function and the refusal.

begin;

create or replace function public.business_delete_promotion_v183(
  p_business uuid, p_promotion_id uuid, p_expected_version bigint default null
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_row public.business_customer_content_v95%rowtype;
  v_mode text;
  v_alert_runs integer := 0;
begin
  if not app.can_module_write_at_v94(p_business, null, 'loyalty') then
    raise exception 'promotion write access required' using errcode='42501';
  end if;
  select * into v_row from public.business_customer_content_v95
   where business_id = p_business and id = p_promotion_id and content_type = 'offer'
   for update;
  if not found then
    raise exception 'promotion not found in this business' using errcode='42704';
  end if;
  if p_expected_version is not null and v_row.version is distinct from p_expected_version then
    raise exception 'this promotion changed in another tab; reopen it and try again'
      using errcode='40001';
  end if;

  perform set_config('app.v104_promotion_write','on',true);
  perform set_config('app.v104_promotion_copy_write','on',true);

  if coalesce(v_row.active,false) then
    v_mode := 'retired';
    update public.business_customer_content_v95
       set active=false, ends_at=least(coalesce(ends_at,now()),now()),
           version=version+1, updated_by=auth.uid(), updated_at=now()
     where id=p_promotion_id and business_id=p_business;
  else
    v_mode := 'deleted';
    /* nestly_v684. The scheduler's spent watermark, released only here. Scoped by promotion_id
       alone because that table has no business column — the tenant check is the FOR UPDATE select
       above, which already proved this id belongs to p_business. Never touched by the retire
       branch: a retired offer still exists, so its watermark must still mute the fanout. */
    delete from public.promotion_alert_runs_v122
     where promotion_id=p_promotion_id;
    get diagnostics v_alert_runs = row_count;
    delete from public.promotion_branch_scopes_v155
     where promotion_id=p_promotion_id and business_id=p_business;
    delete from public.promotion_branch_scopes_v154
     where promotion_id=p_promotion_id and business_id=p_business;
    delete from public.business_localized_copy_v95
     where business_id=p_business and entity_type='offer' and entity_id=p_promotion_id;
    delete from public.business_customer_content_v95
     where id=p_promotion_id and business_id=p_business;
  end if;

  perform set_config('app.v104_promotion_write','',true);
  perform set_config('app.v104_promotion_copy_write','',true);

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'promotion.'||v_mode, 'promotion', p_promotion_id,
          jsonb_build_object('was_published', coalesce(v_row.active,false),
                             'published_once_at', v_row.metadata->>'published_once_at',
                             'alert_runs_released', v_alert_runs));
  return json_build_object('status','ok','mode',v_mode,'promotion_id',p_promotion_id);
end $$;

revoke all on function public.business_delete_promotion_v183(uuid,uuid,bigint) from public, anon;
grant execute on function public.business_delete_promotion_v183(uuid,uuid,bigint) to authenticated;
grant execute on function public.business_delete_promotion_v183(uuid,uuid,bigint) to service_role;

comment on function public.business_delete_promotion_v183(uuid,uuid,bigint) is
  'v684: retire a published promotion or hard-delete one that is not published. The delete branch '
  'releases the offer''s promotion_alert_runs_v122 watermark rows first - their RESTRICT foreign '
  'key made every retired offer that had actually alerted a customer permanently undeletable. The '
  'send record in campaign_send_records_v255 is the evidence and is untouched.';

commit;

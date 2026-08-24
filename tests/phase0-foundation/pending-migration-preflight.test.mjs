import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const planPath = path.join(repoRoot, 'supabase/canonical-migration-order.plan.json');

const sqlTestBySemanticVersion = new Map([
  ['v24a', 'db/tests/v24a_redemption_idempotency.sql'],
  ['v24b', 'db/tests/v24b_module_dependencies.sql'],
  ['v24c', 'db/tests/v24c_import_foundation.sql'],
  ['v25', 'db/tests/v25_draft_onboarding.sql'],
  ['v26', 'db/tests/v26_config_versions.sql'],
  ['v27', 'db/tests/v27_rich_rewards.sql'],
  ['v28', 'db/tests/v28_reward_taxonomy.sql'],
  ['v29', 'db/tests/v29_branch_overrides_custom_fields.sql'],
  ['v30', 'db/tests/v30_customer_identity.sql'],
  ['v31', 'db/tests/v31_customer_links_claims.sql'],
  ['v32', 'db/tests/v32_customer_wallet.sql'],
  ['v33', 'db/tests/v33_customer_actions_notifications.sql'],
  ['v34', 'db/tests/v34_reversal_provenance.sql'],
  ['v35', 'db/tests/v35_retention_recommendation.sql'],
  ['v36', 'db/tests/v36_safe_draft_reward_editor.sql'],
  ['v37', 'db/tests/v37_branch_override_editor_rpc.sql'],
  ['v37b', 'db/tests/v37b_versioned_retention_taxonomy.sql'],
  ['v38', 'db/tests/v38_customer_personas_and_gates.sql'],
  ['v39', 'db/tests/v39_detailed_customer_wallet.sql'],
  ['v40', 'db/tests/v40_staff_reversal_workflows.sql'],
  ['v41', 'db/tests/v41_customer_module_hardening.sql'],
  ['c42', 'db/tests/v42_consumer_registration_contracts.sql'],
  ['c44', 'db/tests/v44_actionable_customer_wallet.sql'],
  ['c45', 'db/tests/v45_birthday_benefits.sql'],
  ['v46', 'db/tests/v46_customer_in_app_inbox.sql'],
  ['v46a', 'db/tests/v46a_birthday_draft_runtime_fix.sql'],
  ['v47', 'db/tests/v47_smart_staff_scheduling.sql'],
  ['v47a', 'db/tests/v47_smart_staff_scheduling.sql'],
  ['v47b', 'db/tests/v47_smart_staff_scheduling.sql'],
  ['v48', 'db/tests/v48_calendar_details_reschedule.sql'],
  ['v49', 'db/tests/v49_billing_projection.sql'],
  ['v49a', 'db/tests/v49a_lint_and_rehearsal_repairs.sql'],
  ['v49b', 'db/tests/v49b_reports_read_authorization.sql'],
  ['v50', 'db/tests/v50_retention_measurement.sql'],
  ['v50a', 'db/tests/v50a_sgt_birthdate_guard.sql'],
  ['v50b', 'db/tests/v50b_contact_proof_constraint_repair.sql'],
  ['v51', 'db/tests/v51_sale_line_items.sql'],
  ['v51a', 'db/tests/v51a_idempotent_sell_overloads.sql'],
  ['v51b', 'db/tests/v51b_client_credit_history.sql'],
  ['v52', 'db/tests/v52_sgt_date_normalization.sql'],
  ['v53', 'db/tests/v53_visit_feedback.sql'],
  ['v53a', 'db/tests/v53a_wallet_review_url.sql'],
  ['v54', 'db/tests/v54_f2_write_hardening.sql'],
  ['v55', 'db/tests/v55_ps1a_authoring.sql'],
  ['v56', 'db/tests/v56_ps1b_events_execution.sql'],
  ['v57', 'db/tests/v57_ps1b1_price_fail_closed.sql'],
  ['v58', 'db/tests/v58_ps1c_checkout_kernel.sql'],
  ['v59', 'db/tests/v59_ps1c1_cart_hardening.sql'],
  ['v60', 'db/tests/v60_ps1c2_execution_state.sql'],
  ['v61', 'db/tests/v61_ps2a_stored_value_foundation.sql'],
  ['v62', 'db/tests/v62_ps2b_shadow_reconciliation.sql'],
  ['v63', 'db/tests/v63_ps2c_redemption_mechanics.sql'],
  ['v64', 'db/tests/v64_ps2d_pause_controls.sql'],
  ['v65', 'db/tests/v65_ps2live_plan_config.sql'],
  ['v65a', 'db/tests/v65a_ps2live_plan_config_hardening.sql'],
  ['v65b', 'db/tests/v65b_ps2live_numeric_range_guard.sql'],
  ['v66', 'db/tests/v66_ps2live_topup_sale.sql'],
  ['v66a', 'db/tests/v66a_ps2live_billing_view_secinvoker.sql'],
  ['v66b', 'db/tests/v66b_program_rules_secinvoker.sql'],
  ['v67', 'db/tests/v67_ps2live_checkout_tender.sql'],
  ['v68a', 'db/tests/v68a_chargeback_correction.sql'],
  ['v68b', 'db/tests/v68b_sv_reversal_netting.sql'],
  ['v68c', 'db/tests/v68c_customer_gift_cards.sql'],
  ['v69', 'db/tests/v69_controlled_cutover.sql'],
  ['v70', 'db/tests/v70_legacy_non_overlap.sql'],
  ['v71', 'db/tests/v71_customer_legal_manifest.sql'],
  ['v72', 'db/tests/v72_booking_identity_sync.sql'],
  ['v73', 'db/tests/v73_booking_lifecycle.sql'],
  ['v74', 'db/tests/v74_staff_module_permissions.sql'],
  ['v75', 'db/tests/v75_sector_entitlements.sql'],
  ['v76', 'db/tests/v76_sme_crm.sql'],
  ['v77', 'db/tests/v77_stripe_billing.sql'],
  ['v78', 'db/tests/v78_consultant_commissions.sql'],
  ['v79', 'db/tests/v79_conversion_onboarding.sql'],
  ['v80', 'db/tests/v80_customer_legal_manifest.sql'],
  ['v81', 'db/tests/v81_customer_relationship_sync.sql'],
  ['v82', 'db/tests/v82_enterprise_intelligence.sql'],
  ['v83', 'db/tests/v83_customer_intelligence.sql'],
  ['v84', 'db/tests/v84_fast_sale_corrections.sql'],
  ['v85', 'db/tests/v85_conversion_guard_repair.sql'],
  ['v86', 'db/tests/v86_enterprise_sme_crm.sql'],
  ['v87', 'db/tests/v87_overdue_appointment_amendments.sql'],
  ['v88', 'db/tests/v88_platform_firm_onboarding.sql'],
  ['v89', 'db/tests/v89_customer_platform_contracts.sql'],
  ['v90', 'db/tests/v90_production_readiness.sql'],
  ['v91', 'db/tests/v91_customer_game_notifications.sql'],
  ['v96', 'db/tests/v96_customer_programme_selector_media.sql'],
  ['v97', 'db/tests/v97_workspace_interface_localization.sql'],
  ['v99', 'db/tests/v99_v100_campaign_truth_adoption.sql'],
  ['v100', 'db/tests/v99_v100_campaign_truth_adoption.sql'],
  ['v102', 'db/tests/v102_package_checkout_entitlements.sql'],
  ['v103', 'db/tests/v103_customer_summary_business_identity.sql'],
  ['v104', 'db/tests/v104_marketing_offers.sql'],
  ['v105', 'db/tests/v105_admin_task_closure.sql'],
  ['v106', 'db/tests/v106_revenue_truth_foundation.sql'],
  ['v107', 'db/tests/v107_customer_lifecycle_contract.sql'],
  ['v108', 'db/tests/v108_measured_bringback_loop.sql'],
  ['v109', 'db/tests/v109_economics_driver_sector_policy.sql'],
  ['v110', 'db/tests/v110_growth_delivery_lifecycle.sql'],
  ['v111', 'db/tests/v111_customer_identity_governance.sql'],
  ['v112', 'db/tests/v112_concurrent_replay_delivery_backoff.sql'],
  ['v113', 'db/tests/v113_effective_identity_consumers.sql'],
  ['v114', 'db/tests/v114_traceable_growth_costs.sql'],
  ['v115', 'db/tests/v115_effective_module_projection.sql'],
  ['v116', 'db/tests/v116_classic_reward_projection.sql'],
  ['v117', 'db/tests/v117_effective_loyalty_boundaries.sql'],
  ['v120', 'db/tests/v120_staff_blocked_times.sql'],
  ['v121', 'db/tests/v121_appointment_completion_customer_projection.sql'],
  ['v122', 'db/tests/v122_owner_seven_workflows.sql'],
  ['v123', 'db/tests/v123_module_button_readiness.sql'],
  ['v124', 'db/tests/v124_stripe_launch_pricing.sql'],
  ['v125', 'db/tests/v125_no_gst_and_overdue.sql'],
  ['v127', 'db/tests/v127_rewards_overview_birthday_reader.sql'],
  ['v128', 'db/tests/v128_simple_rewards_recommender.sql'],
  ['v129', 'db/tests/v129_trial_test_ux.sql'],
  ['v130', 'db/tests/v130_self_serve_business_onboarding.sql'],
  ['v131', 'db/tests/v131_store_publication_readiness.sql'],
  ['v132', 'db/tests/v130_self_serve_business_onboarding.sql'],
  ['v133', 'db/tests/v133_operational_closure.sql'],
  ['v134', 'db/tests/v134_peekaa_brand_legal.sql'],
  ['v138', 'db/tests/v138_auth_grow_closure.sql'],
  ['v142', 'db/tests/v142_connect_paynow_pos.sql'],
  ['v144', 'db/tests/v144_self_serve_subscription_consent.sql'],
  ['v145', 'db/tests/v145_launch_freeze_metrics.sql'],
  ['v146', 'db/tests/v146_platform_finance.sql'],
  ['v147', 'db/tests/v147_platform_accounting.sql'],
  ['v148', 'db/tests/v148_owner_launch_closure.sql'],
  ['v256', 'db/tests/v256_tier_may_measure_lifetime_points.sql'],
  ['v257', 'db/tests/v257_bundle_finalise_rehash.sql'],
  ['v258', 'db/tests/v258_recommended_draft_inherits_live_status.sql'],
  ['v263', 'db/tests/v263_customer_communication_preferences.sql'],
  ['v264', 'db/tests/v264_promotion_share_event.sql'],
  ['v271', 'db/tests/v271_programme_overview.sql'],
  ['v273', 'db/tests/v273_usage_null_when_never_set_up.sql'],
  ['v275', 'db/tests/v275_bar_bottle_keep.sql'],
  ['v276', 'db/tests/v276_bar_sector_polish.sql'],
  ['v277', 'db/tests/v277_activation_seeds_loyalty.sql'],
  ['v278', 'db/tests/v278_bottle_keep_parity.sql'],
  ['v279', 'db/tests/v279_bottle_owner_walkthrough.sql'],
  ['v280', 'db/tests/v280_branch_billing_units_and_promotion_version.sql'],
  ['v281', 'db/tests/v281_stripe_launch_readiness.sql'],
  ['v284', 'db/tests/v284_comms_foundation.sql'],
  ['v282', 'db/tests/v282_promotion_finalize_conflict_fastfail.sql'],
  ['v283', 'db/tests/v283_customer_claim_execute_grants.sql'],
  ['v265', 'db/tests/v265_marketing_consent_scope.sql'],
  ['v267', 'db/tests/v267_summary_business_logo.sql'],
  ['v268', 'db/tests/v268_offer_share_page.sql'],
  ['v285', 'db/tests/v285_offer_share_imageless_parity.sql'],
  ['v289', 'db/tests/v289_reschedule_respects_business_setting.sql'],
  ['v290', 'db/tests/v290_customer_withdraw_booking_request.sql'],
  ['v293', 'db/tests/v293_customer_intelligence_grants.sql'],
  /* v298 (reference seed) and v299 (RPC surface) are the same feature as v297 and are
     exercised by the same rolled-back suite. */
  ['v297', 'db/tests/v297_merchant_prospecting_map.sql'],
  ['v298', 'db/tests/v297_merchant_prospecting_map.sql'],
  ['v299', 'db/tests/v297_merchant_prospecting_map.sql'],
  ['v300', 'db/tests/v300_growth_readbacks.sql'],
  ['v306', 'db/tests/v306_both_mode_capabilities.sql'],
  ['v307', 'db/tests/v307_programme_read_model.sql'],
  ['v308', 'db/tests/v308_programme_spine.sql'],
  ['v309', 'db/tests/v309_ledger_programme_tag.sql'],
  ['v310', 'db/tests/v310_google_content_retention.sql'],
  /* v311 (the money kernel) and v312 (the pot machinery) are ONE wave applied
     back-to-back and are exercised by the same rolled-back suite: v312's fixtures are
     v311's four tenant shapes, and the S4/S5 cells only mean anything with both
     applied. Both semantic versions are unique, so these bind by version, not by name. */
  ['v311', 'db/tests/v311_v312_programme_money_kernel.sql'],
  ['v312', 'db/tests/v311_v312_programme_money_kernel.sql'],
  /* v313 (reward programme identity) and v314 (the switchboard inversion) are ONE increment
     applied back-to-back and are exercised by the same rolled-back suite: v314's step 0 pins
     v313's post-apply md5s, and the cross-programme redemption cells only mean anything with both
     applied. Both semantic versions are unique, so these bind by version, not by name. */
  ['v313', 'db/tests/v313_v314_programme_switchboard.sql'],
  ['v314', 'db/tests/v313_v314_programme_switchboard.sql'],
  /* v322 (the owner rulings of 2026-08-14, server half: referral pays points, and the stamps
     exclusivity guard returns to public.set_programmes_v314). */
  ['v322', 'db/tests/v322_owner_programme_rulings.sql'],
  /* v325 (owner-authorized exception #1, 2026-08-14 Customer Interface cosmetics brief):
     businesses.bio, a nullable additive column with no backfill. */
  ['v325', 'db/tests/v325_business_bio.sql']
]);

const sqlTestByMigrationName = new Map([
  // The conversion-first prospecting work was renumbered v313/v314 after the
  // parallel programme session claimed v311/v312; bound BY NAME so the mapping
  // survives any future semantic-label reuse.
  ['nestly_v313_conversion_first_prospecting', 'db/tests/v313_conversion_first_prospecting.sql'],
  // The recovery snapshot is a data-only artefact captured from production before
  // v313 dropped those rows; it shares the v313 suite because it has no behaviour
  // of its own to assert.
  ['nestly_v313_rollback_data_snapshot', 'db/tests/v313_conversion_first_prospecting.sql'],
  ['nestly_v314_business_explorer_and_funnel', 'db/tests/v313_conversion_first_prospecting.sql'],
  // v310 semantic label is shared by two applied migrations (programme read path 20260813000600
  // and google content retention 20260813001300); the read-path suite binds BY NAME so the
  // semantic fallback keeps serving the retention entry.
  ['nestly_v310_programme_read_path', 'db/tests/v310_programme_read_path.sql'],
  ['nestly_v292_demo_requests', 'db/tests/v292_demo_requests.sql'],
  ['nestly_v290_server_debt_closure', 'db/tests/v290_server_debt_closure.sql'],
  ['nestly_v285_a4_gap_closure', 'db/tests/v285_a4_gap_closure.sql'],
  ['nestly_v288_a2_gap_closure', 'db/tests/v288_a2_gap_closure.sql'],
  ['nestly_v92_synthetic_reporting_isolation', 'db/tests/v92_synthetic_reporting_isolation.sql'],
  ['nestly_v92_customer_privacy_marketing_manifest', 'db/tests/v92_customer_privacy_marketing_manifest.sql'],
  ['nestly_v93_branch_scoped_merchant_redemption', 'db/tests/v93_synthetic_e2e_campaign.sql'],
  ['nestly_v93_customer_notification_constraints', 'db/tests/v93_customer_notification_constraints.sql'],
  ['nestly_v94_platform_control_intelligence', 'db/tests/v94_platform_control_intelligence.sql'],
  ['nestly_v94_platform_firm_snapshot_null_guard', 'db/tests/v94_platform_firm_snapshot_null_guard.sql'],
  ['nestly_v95_bilingual_programmes', 'db/tests/v95_bilingual_programmes.sql'],
  ['nestly_v95_customer_web_push', 'db/tests/v95_customer_web_push.sql'],
  ['nestly_v156_subscription_operations_crm', 'db/tests/v156_subscription_operations_crm.sql'],
  ['nestly_v158_catalogue_media', 'db/tests/v158_catalogue_media.sql'],
  ['nestly_v156a_v151_invite_search_path_hardening', 'db/tests/v156a_v151_invite_search_path_hardening.sql'],
  ['nestly_v159_selfserve_manual_application_fallback', 'db/tests/v159_selfserve_manual_application_fallback.sql'],
  ['nestly_v160_auth_signup_visibility', 'db/tests/v160_auth_signup_visibility.sql'],
  ['nestly_v162_stripe_launch_price_148', 'db/tests/v124_stripe_launch_pricing.sql'],
  ['nestly_v163_signup_lead_management_consent', 'db/tests/v163_signup_lead_management_consent.sql'],
  ['nestly_v164_account_signup_triage', 'db/tests/v164_account_signup_triage.sql'],
  ['nestly_v167_customer_retention_offers', 'db/tests/v167_customer_retention_offers.sql'],
  ['nestly_v167_customer_repeat_booking_history', 'db/tests/v167_customer_repeat_booking_history.sql'],
  ['nestly_v167_direct_admin_approval_activation', 'db/tests/v167_direct_admin_approval_activation.sql'],
  ['nestly_v169_activate_stranded_approved_applications', 'db/tests/v169_activate_stranded_approved_applications.sql'],
  ['nestly_v170_staff_update_client', 'db/tests/v170_staff_update_client.sql'],
  ['nestly_v171_customerintel_entitlement', 'db/tests/v171_customerintel_entitlement.sql'],
  ['nestly_v172_home_offers_optional_media', 'db/tests/v172_home_offers_optional_media.sql'],
  ['nestly_v173_offer_detail_parity', 'db/tests/v173_offer_detail_parity.sql'],
  ['nestly_v175_marketing_consent_scope_v2', 'db/tests/v175_marketing_consent_scope_v2.sql'],
  ['nestly_v177_client_error_reports', 'db/tests/v177_client_error_reports.sql'],
  ['nestly_v176_reward_tier_gate', 'db/tests/v176_reward_tier_gate.sql'],
  ['nestly_v176b_reward_tier_gate_read_path', 'db/tests/v176b_reward_tier_gate_read_path.sql'],
  ['nestly_v173_pause_enforcement_gaps', 'db/tests/v173_pause_enforcement_gaps.sql'],
  ['nestly_v174_pipeline_stages_demo_flag', 'db/tests/v174_pipeline_stages_demo_flag.sql'],
  ['nestly_v175_customer_account_open_events', 'db/tests/v175_customer_account_open_events.sql'],
  ['nestly_v176_ai_firm_reports', 'db/tests/v176_ai_firm_reports.sql'],
  ['nestly_v177_workspace_mirror', 'db/tests/v177_workspace_mirror.sql'],
  ['nestly_v178_dispatch_secret_db_verify', 'db/tests/v178_dispatch_secret_db_verify.sql'],
  ['nestly_v179_report_insight_evidence', 'db/tests/v179_report_insight_evidence.sql'],
  ['nestly_v180_firm_directory_null_filter', 'db/tests/v180_firm_directory_null_filter.sql'],
  ['nestly_v182_birthday_month_and_tier_schedule', 'db/tests/v182_birthday_month_and_tier_schedule.sql'],
  ['nestly_v183_promotion_delete', 'db/tests/v183_promotion_delete.sql'],
  ['nestly_v184_product_service_sectors', 'db/tests/v184_product_service_sectors.sql'],
  ['nestly_v183_customer_staff_choice_and_live_availability', 'db/tests/v183_customer_staff_choice_and_live_availability.sql'],
  ['nestly_v186_customer_tier_ladder', 'db/tests/v186_customer_tier_ladder.sql'],
  ['nestly_v188_no_self_service_account_deletion', 'db/tests/v188_no_self_service_account_deletion.sql'],
  ['nestly_v188_v189_data_repairs', 'db/tests/v188_v189_data_repairs.sql'],
  ['nestly_v193_manage_unsold_package_plan', 'db/tests/v193_manage_unsold_package_plan.sql'],
  ['nestly_v197_recommendation_duplicate_root_cause', 'db/tests/v197_recommendation_duplicate_root_cause.sql'],
  ['nestly_v185_prospect_archive_merge_erase', 'db/tests/v185_prospect_archive_merge_erase.sql'],
  ['nestly_v194_merge_contact_dedupe', 'db/tests/v194_merge_contact_dedupe.sql'],
  ['nestly_v195_merge_keeps_source_lineage', 'db/tests/v195_merge_keeps_source_lineage.sql'],
  ['nestly_v196_list_archived_prospects', 'db/tests/v196_list_archived_prospects.sql'],
  ['nestly_v202_branch_add_and_billing', 'db/tests/v202_branch_add_and_billing.sql'],
  ['nestly_v239_points_and_tiers_can_both_run', 'db/tests/v239_points_and_tiers_can_both_run.sql'],
  ['nestly_v241_reward_catalog_carries_its_mode_as_an_object', 'db/tests/v241_reward_catalog_object_shape.sql'],
  ['nestly_v248_customer_directory_reports_loyalty_availability', 'db/tests/v248_customer_directory_loyalty_availability.sql'],
  ['nestly_v242_customer_business_directory', 'db/tests/v242_customer_business_directory.sql'],
  ['nestly_v202a_activate_branch_on_paid_command', 'db/tests/v202_branch_add_and_billing.sql'],
  ['nestly_v202b_branch_insert_only_via_paid_rpc', 'db/tests/v202_branch_add_and_billing.sql'],
  ['nestly_v204_bundle_priced_by_the_server', 'db/tests/v204_bundle_priced_by_the_server.sql'],
  ['nestly_v206_fast_corrections', 'db/tests/v206_fast_corrections.sql'],
  ['nestly_v207_staff_invite_and_owner_approval', 'db/tests/v207_staff_invite_and_owner_approval.sql'],
  ['nestly_v209_static_single_join_qr', 'db/tests/v209_static_single_join_qr.sql'],
  ['nestly_v213_sales_mix_audit_column', 'db/tests/v213_sales_mix_audit_column.sql'],
  ['nestly_v215_signup_welcome_offer', 'db/tests/v215_signup_welcome_offer.sql'],
  ['nestly_v217_recent_window_and_staff_reference_code', 'db/tests/v217_recent_window_and_staff_reference_code.sql'],
  ['nestly_v219_products_module_follows_business_config', 'db/tests/v219_v220_products_module_and_staff_slots.sql'],
  ['nestly_v220_next_best_times_for_selected_staff', 'db/tests/v219_v220_products_module_and_staff_slots.sql'],
  ['nestly_v223_table_reservations_opt_in', 'db/tests/v223_table_reservations_opt_in.sql'],
  ['nestly_v229_points_mode_choice', 'db/tests/v229_points_mode_choice.sql'],
  ['nestly_v230_points_mode_in_customer_portal', 'db/tests/v230_points_mode_in_customer_portal.sql'],
  ['nestly_v231_capabilities_follow_the_points_mode', 'db/tests/v231_capabilities_follow_the_points_mode.sql'],
  ['nestly_v232_promotion_lock_cannot_take_down_the_api', 'db/tests/v232_promotion_lock_guard.sql'],
  ['nestly_v233_admin_sessions_get_the_same_reaper', 'db/tests/v233_admin_session_reaper.sql'],
  ['nestly_v234_advisor_hygiene', 'db/tests/v234_advisor_hygiene.sql'],
  ['nestly_v244_retention_audience_server_side', 'db/tests/v244_retention_audience_server_side.sql'],
  ['nestly_v246_personas_direct_resolver', 'db/tests/v246_personas_direct_resolver.sql'],
  ['nestly_v247_explore_nearest_first', 'db/tests/v247_explore_nearest_first.sql'],
  ['nestly_v245_customer_explore_search', 'db/tests/v245_customer_explore_search.sql'],
  ['nestly_v197_persistent_join_qr', 'db/tests/v197_persistent_join_qr.sql'],
  ['nestly_v198_join_qr_print_lock', 'db/tests/v198_join_qr_print_lock.sql'],
  ['nestly_v199_receipt_capture', 'db/tests/v199_receipt_capture.sql'],
  ['nestly_v200_subscription_revenue', 'db/tests/v200_subscription_revenue.sql'],
  ['nestly_v200a_subscription_revenue_schedule', 'db/tests/v200a_subscription_revenue_schedule.sql'],
  ['nestly_v201_receipt_storage_policies', 'db/tests/v201_receipt_storage_policies.sql'],
  ['nestly_v203_company_directory', 'db/tests/v203_company_directory.sql'],
  ['nestly_v225_company_detail', 'db/tests/v225_company_detail.sql'],
  ['nestly_v226_crm_consultant_scope', 'db/tests/v226_crm_consultant_scope.sql'],
  ['nestly_v244_crm_ai_report_flag_matches_v176', 'db/tests/v244_crm_ai_report_flag.sql'],
  ['nestly_v267_salesforce_crm_scope', 'db/tests/v267_salesforce_crm_scope.sql'],
  // V256 — one suite covers all three v255 migrations; they are one change.
  ['nestly_v255_marketing_send_records_and_taxonomy', 'db/tests/v255_marketing_send_records_and_reads.sql'],
  ['nestly_v255a_client_interaction_batch', 'db/tests/v255_marketing_send_records_and_reads.sql'],
  ['nestly_v255b_platform_marketing_reads', 'db/tests/v255_marketing_send_records_and_reads.sql'],
  ['nestly_v315_repair_dropped_lead_score_references', 'db/tests/v315_lead_score_reference_repair.sql'],
  ['nestly_v316_repair_taxonomy_and_match_queue', 'db/tests/v315_lead_score_reference_repair.sql'],
  // v317 restores two wrongly dropped v313 objects and v318 aligns the
  // system-managed stage flags they depend on; both are exercised by the
  // v313 suite, which already asserts the corrected stage semantics.
  ['nestly_v317_restore_wrongly_dropped_dependencies', 'db/tests/v313_conversion_first_prospecting.sql'],
  ['nestly_v318_align_system_managed_stage_flags', 'db/tests/v313_conversion_first_prospecting.sql'],
  /* v323 closes the one half of owner ruling R5 that v322 reported as blocked: a stamp
     milestone claim is non-consuming, is recorded once per (client, cycle, milestone), and the
     FINAL claim closes the cycle. Bound BY FULL NAME rather than by the 'v323' semantic label,
     because the label map is already doubled for v313/v314 and a full name cannot collide with
     a parallel session's renumbering. */
  ['nestly_v323_stamp_quest_milestones', 'db/tests/v323_stamp_quest_milestones.sql'],
  /* v326 gives loyalty_rewards a real third state (on/paused/deleted), all immediate-write, and
     the audit trail for why (the redeem_reward_core landmine, the stale-draft resurrection risk)
     lives in the migration's own header comment. v326a is a same-day anon-EXECUTE hardening
     follow-up with no independent behaviour of its own — it shares v326's suite, same pattern as
     v47a/v47b sharing v47's. Bound by full name for the same collision reason as v323 above. */
  ['nestly_v326_points_gift_lifecycle', 'db/tests/v326_points_gift_lifecycle.sql'],
  ['nestly_v326a_gift_rpc_anon_revoke', 'db/tests/v326_points_gift_lifecycle.sql'],
  ['nestly_v327_customer_branch_choice', 'db/tests/v327_customer_branch_choice.sql'],
  ['nestly_v327_global_customer_qr', 'db/tests/v327_global_customer_qr.sql'],
  /* v328 fixes staff_decide_booking_request_v73_v94_base always passing null/'round_robin' to
     book_appointment_smart_v47 on the manual (non-auto-confirm) booking-confirm path, ignoring
     the customer's own staff choice (v183, booking_requests.staff_id). Bound by full name for
     the same collision reason as v323/v326 above. */
  ['nestly_v328_staff_choice_manual_confirm', 'db/tests/v328_staff_choice_manual_confirm.sql'],
  ['nestly_v329_owner_reschedule_booking_request', 'db/tests/v329_owner_reschedule_booking_request.sql'],
  ['nestly_v330_pending_slot_block_and_confirmation_template', 'db/tests/v330_pending_slot_block_and_confirmation_template.sql'],
  ['nestly_v329_membership_plan_lifecycle', 'db/tests/v329_membership_plan_lifecycle.sql'],
  ['nestly_v331_tier_lifecycle', 'db/tests/v331_tier_lifecycle.sql'],
  ['nestly_v332_retention_program_lifecycle', 'db/tests/v332_retention_program_lifecycle.sql'],
  // v340 is WRITTEN, NOT APPLIED — this suite is the rehearsal it must pass first.
  ['nestly_v340_reward_purchase_requirement', 'db/tests/v340_reward_purchase_requirement.sql'],
  /* The 2026-08-16 rewards wave shares ONE acceptance suite: these migrations are a single
     connected change (move every reward setting off the draft/publish wizard onto immediate-write
     pages), and several only make sense against each other — v354 fixes drift v353 introduced,
     v355 removes a pot migration v354 would otherwise fire more often. Proving them apart would
     assert a state the product is never actually in. */
  ['nestly_v343_reward_edit_v326', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v345_tier_benefit_edit', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v347_tier_basis_immediate_write', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v348_spine_id_in_switch_response', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v350_welcome_offer_custom_item', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v353_stamp_model_immediate_write', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v354_spine_owns_loyalty_model', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v355_no_auto_pot_conversion', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v359_earning_rule_immediate_write', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v361_bringback_module', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v362_bringback_till_surface', 'db/tests/v343_v362_rewards_wave.sql'],
  ['nestly_v365_tier_benefit_limits', 'db/tests/v365_tier_benefit_limits.sql'],
  ['nestly_v414_stamp_card_length', 'db/tests/v414_stamp_card_length.sql'],
  ['nestly_v416_stamp_cycle_config_pin', 'db/tests/v416_stamp_cycle_config_pin.sql'],
  ['nestly_v417_customer_bio', 'db/tests/v417_customer_bio.sql'],
  ['nestly_v418_business_gallery_and_links', 'db/tests/v418_business_gallery_and_links.sql'],
  ['nestly_v419_recommendation_keeps_spend_per_stamp', 'db/tests/v419_recommendation_keeps_spend_per_stamp.sql'],
  ['nestly_v420_referral_free_gift', 'db/tests/v420_referral_free_gift.sql'],
  ['nestly_v421_two_sided_referral', 'db/tests/v421_two_sided_referral.sql'],
  ['nestly_v422_customer_reward_history', 'db/tests/v422_customer_reward_history.sql'],
  ['nestly_v423_reward_edit_reaches_customers', 'db/tests/v423_reward_edit_reaches_customers.sql'],
  ['nestly_v424_birthday_window_honoured', 'db/tests/v424_birthday_window.sql'],
  ['nestly_v425_referral_explicit_reward_type', 'db/tests/v425_referral_explicit_type.sql'],
  ['nestly_v426_canonical_tier_resolver', 'db/tests/v426_tier_resolver.sql'],
  ['nestly_v427_entitlements_reach_customers', 'db/tests/v427_entitlement_visibility.sql'],
  ['nestly_v431_publish_keeps_the_spine_model', 'db/tests/v431_publish_keeps_the_spine_model.sql'],
  ['nestly_v432_staff_redeem_list_matches_customer', 'db/tests/v432_staff_redeem_list_matches_customer.sql'],
  ['nestly_v433_stamp_edit_version_split', 'db/tests/v433_v436_stamp_lifecycle_wave.sql'],
  ['nestly_v434_switch_publish_guard', 'db/tests/v433_v436_stamp_lifecycle_wave.sql'],
  ['nestly_v435_stamp_cycle_expiry', 'db/tests/v433_v436_stamp_lifecycle_wave.sql'],
  ['nestly_v436_stamp_earn_pinned_and_lazy_close', 'db/tests/v433_v436_stamp_lifecycle_wave.sql'],
  ['nestly_v437_history_rows_keep_their_unit', 'db/tests/v433_v436_stamp_lifecycle_wave.sql'],
  ['nestly_v367_birthday_month_benefit_period', 'db/tests/v367_birthday_month_benefit_period.sql'],
  ['nestly_v369_structured_tier_benefits', 'db/tests/v369_structured_tier_benefits.sql'],
  ['nestly_v370_tier_discount_at_checkout', 'db/tests/v370_tier_discount_at_checkout.sql'],
  ['nestly_v371_programme_off_reaches_customer', 'db/tests/v371_programme_off_reaches_customer.sql'],
  ['nestly_v372_gift_follows_its_programme', 'db/tests/v372_gift_follows_its_programme.sql'],
  ['nestly_v374_birthday_gift_saves', 'db/tests/v374_birthday_gift_saves.sql'],
  ['nestly_v375_points_are_not_credit', 'db/tests/v375_points_are_not_credit.sql'],
  ['nestly_v376_no_classic_redemption_offer', 'db/tests/v376_no_classic_redemption_offer.sql'],
  ['nestly_v377_no_credit_reward_types', 'db/tests/v377_no_credit_reward_types.sql'],
  ['nestly_v378_promotion_finalize_breaker', 'db/tests/v378_promotion_finalize_breaker.sql'],
  ['nestly_v379_promotion_finalize_breaker_v154', 'db/tests/v378_promotion_finalize_breaker.sql'],
  ['nestly_v380_promotion_breaker_bigint_overloads', 'db/tests/v380_promotion_breaker_bigint_overloads.sql'],
  ['nestly_v381_balance_follows_live_programme', 'db/tests/v381_balance_follows_live_programme.sql'],
  ['nestly_v383_off_days_block_bookings', 'db/tests/v383_off_days_block_bookings.sql'],
  ['nestly_v384_stamp_conversion_switch', 'db/tests/v384_stamp_conversion_switch.sql'],
  ['nestly_v385_profile_save_and_industry_label', 'db/tests/v385_profile_save_and_industry_label.sql'],
  ['nestly_v386_customer_company_branches', 'db/tests/v386_customer_company_branches.sql'],
  ['nestly_v386_dated_programme_usage', 'db/tests/v386_dated_programme_usage.sql'],
  ['nestly_v391_capabilities_undefined_column', 'db/tests/v391_capabilities_undefined_column.sql'],
  ['nestly_v468_programme_usage_counts', 'db/tests/v468_programme_usage_counts.sql'],
  ['nestly_v469_grant_sales_name_themselves', 'db/tests/v469_grant_sales_name_themselves.sql'],
  ['nestly_v393_customer_tier_visibility', 'db/tests/v393_customer_tier_visibility.sql'],
  ['nestly_v394_tier_lifecycle_checkout', 'db/tests/v394_tier_lifecycle_checkout.sql'],
  ['nestly_v403_stamp_conversion_ledger_token', 'db/tests/v403_stamp_conversion_ledger_token.sql'],
  ['nestly_v404_manual_reward_redemption', 'db/tests/v404_manual_reward_redemption.sql'],
  ['nestly_v409_canonical_points_balance', 'db/tests/v409_points_stamps_points_balance.sql'],
  ['nestly_v410_promotion_finalize_overload_ambiguity', 'db/tests/v410_promotion_finalize_overload_ambiguity.sql'],
  ['nestly_v412_promotion_delete_module_key', 'db/tests/v412_promotion_delete_module_key.sql'],
  ['nestly_v454_audit_log_detail_column', 'db/tests/v454_audit_log_detail_column.sql'],
  ['nestly_v455_stock_follows_sale_items', 'db/tests/v455_stock_follows_sale_items.sql'],
  ['nestly_v460_business_kpi_pot_scope', 'db/tests/v460_business_kpi_pot_scope.sql'],
  ['nestly_v463_stamp_card_max_length', 'db/tests/v463_stamp_card_max_length.sql'],
  ['nestly_v465_home_ready_count', 'db/tests/v465_home_ready_count.sql'],
  ['nestly_v464_earned_reward_expiry', 'db/tests/v464_earned_reward_expiry.sql'],
  ['nestly_v462_featured_offer_and_live_cap', 'db/tests/v462_featured_offer_and_live_cap.sql'],
  ['nestly_v472_reward_end_date_and_menu_gallery', 'db/tests/v472_reward_end_date_and_menu_gallery.sql'],
  ['nestly_v472a_profile_extras_menu', 'db/tests/v472_reward_end_date_and_menu_gallery.sql'],
  ['nestly_v473_erasure_unlinks_the_customer', 'db/tests/v473_erasure_unlinks_the_customer.sql'],
  ['nestly_v474_staff_reads_the_stamp_card', 'db/tests/v474_staff_reads_the_stamp_card.sql'],
  ['nestly_v475_stamp_card_hides_switched_off_gifts', 'db/tests/v475_stamp_card_hides_switched_off_gifts.sql'],
  ['nestly_v477_per_gift_where_it_works', 'db/tests/v477_per_gift_where_it_works.sql'],
  ['nestly_v478_earned_stamp_gifts_survive_a_claimed_card', 'db/tests/v478_earned_stamp_gifts_survive_a_claimed_card.sql'],
  ['nestly_v479_customer_wallet_realtime_signal', 'db/tests/v479_customer_wallet_realtime_signal.sql'],
  ['nestly_v480_loyalty_value_integrity_fence', 'db/tests/executed/v480_loyalty_value_integrity_fence.sql'],
  ['nestly_v481_legacy_referral_credit_fail_closed', 'db/tests/executed/v480_referral_reversal.sql'],
  ['nestly_v482_loyalty_fence_null_guard', 'db/tests/executed/v482_loyalty_fence_null_guard.sql'],
  ['nestly_v488_product_bundles_and_bottle_checkpoints', 'db/tests/v488_product_bundles_and_bottle_checkpoints.sql'],
  ['nestly_v489_stamp_card_auto_rollover', 'db/tests/v489_stamp_card_auto_rollover.sql'],
  ['nestly_v494_wallet_signal_visits_and_grants', 'db/tests/v494_wallet_signal_visits_and_grants.sql'],
  ['nestly_v495_stopped_programme_gifts_not_offered', 'db/tests/v495_stopped_programme_gifts_not_offered.sql']
]);

// Production ledger evidence was read from gadpooereceldfpfxsod on 2026-08-04.
// These exact deployed bytes predate the preflight requirements. Hash pinning
// prevents an edited historical migration from inheriting either exception.
const appliedPreflightExceptions = new Map([
  ['20260803210000_nestly_v151_mobile_staff_invites', {
    sha256: '15f23dcd93f46873a8f856a1af4e0b34bbc69e37172b8af070d2d5c4a1ea0a7e',
    rollbackSuite: false,
    outerTransaction: false
  }],
  ['20260804090000_nestly_v155_multibranch_foundation', {
    sha256: '95cb1433c145c7c5b78a3ca3691d660e92a84871e70ae1e39e47dbe52abe5bc3',
    rollbackSuite: false,
    outerTransaction: true
  }],
  ['20260804054949_nestly_v158_catalogue_media', {
    sha256: 'a158209a43048b50a43f2f7dccdd2e9f69c98373caed4be27965ba22e182342a',
    rollbackSuite: true,
    outerTransaction: false
  }],
  ['20260804170000_nestly_v162_stripe_launch_price_148', {
    sha256: '9d140deebd7d7ed6303fffb47928caa1548c3123aff9267d86d97294120f4efd',
    rollbackSuite: true,
    outerTransaction: false
  }]
]);

const migrationIdentity = (migration) => `${migration.version}_${migration.name}`;
const sha256 = (value) => createHash('sha256').update(value).digest('hex');
const semanticVersionFor = (migration) =>
  migration.name.match(/^(?:frenly|nestly)_(v\d+[a-z]?|c\d+)(?:_|$)/)?.[1];
const rollbackSuiteFor = (migration) =>
  sqlTestByMigrationName.get(migration.name)
  ?? sqlTestBySemanticVersion.get(semanticVersionFor(migration));

const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const statementCount = (sql, statement) =>
  [...sql.matchAll(new RegExp(`^\\s*${statement}\\s*;\\s*$`, 'gim'))].length;

function isEscapeStringPrefix(source, quoteIndex) {
  return source[quoteIndex] === "'"
    && /e/i.test(source[quoteIndex - 1] ?? '')
    && !/[a-z0-9_$]/i.test(source[quoteIndex - 2] ?? '');
}

function parenthesizedBody(source, openIndex) {
  assert.equal(source[openIndex], '(', 'parenthesizedBody must start at an opening parenthesis');
  let depth = 0;
  let quote = null;
  let backslashEscapes = false;

  for (let index = openIndex; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      if (backslashEscapes && character === '\\' && index + 1 < source.length) {
        index += 1;
      } else if (character === quote) {
        if (source[index + 1] === quote) {
          index += 1;
        } else {
          quote = null;
          backslashEscapes = false;
        }
      }
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
      backslashEscapes = isEscapeStringPrefix(source, index);
    } else if (character === '(') {
      depth += 1;
    } else if (character === ')') {
      depth -= 1;
      if (depth === 0) {
        return { body: source.slice(openIndex + 1, index), closeIndex: index };
      }
    }
  }

  throw new Error('Unbalanced SQL function argument list');
}

function splitTopLevel(source) {
  const parts = [];
  let start = 0;
  let depth = 0;
  let quote = null;
  let backslashEscapes = false;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      if (backslashEscapes && character === '\\' && index + 1 < source.length) {
        index += 1;
      } else if (character === quote) {
        if (source[index + 1] === quote) {
          index += 1;
        } else {
          quote = null;
          backslashEscapes = false;
        }
      }
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
      backslashEscapes = isEscapeStringPrefix(source, index);
    } else if (character === '(' || character === '[') {
      depth += 1;
    } else if (character === ')' || character === ']') {
      depth -= 1;
    } else if (character === ',' && depth === 0) {
      parts.push(source.slice(start, index));
      start = index + 1;
    }
  }

  parts.push(source.slice(start));
  return parts.map((part) => part.trim()).filter(Boolean);
}

function stripSqlComments(source) {
  let result = '';
  let quote = null;
  let backslashEscapes = false;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      result += character;
      if (backslashEscapes && character === '\\' && index + 1 < source.length) {
        result += source[index + 1];
        index += 1;
      } else if (character === quote) {
        if (source[index + 1] === quote) {
          result += source[index + 1];
          index += 1;
        } else {
          quote = null;
          backslashEscapes = false;
        }
      }
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
      backslashEscapes = isEscapeStringPrefix(source, index);
      result += character;
    } else if (character === '-' && source[index + 1] === '-') {
      while (index < source.length && source[index] !== '\n') {
        index += 1;
      }
      result += '\n';
    } else if (character === '/' && source[index + 1] === '*') {
      let depth = 1;
      index += 2;
      while (index < source.length && depth > 0) {
        if (source[index] === '/' && source[index + 1] === '*') {
          depth += 1;
          index += 2;
        } else if (source[index] === '*' && source[index + 1] === '/') {
          depth -= 1;
          index += 2;
        } else {
          index += 1;
        }
      }
      assert.equal(depth, 0, 'Unclosed SQL block comment');
      index -= 1;
      result += ' ';
    } else {
      result += character;
    }
  }

  return result;
}

function sqlOutsideCommentsAndLiterals(source) {
  let result = '';

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const dollarTag = character === '$'
      ? source.slice(index).match(/^\$[a-z_][a-z0-9_]*\$|^\$\$/i)?.[0]
      : null;

    if (dollarTag) {
      const bodyEnd = source.indexOf(dollarTag, index + dollarTag.length);
      assert.notEqual(bodyEnd, -1, `Unclosed SQL dollar quote ${dollarTag}`);
      const consumed = source.slice(index, bodyEnd + dollarTag.length);
      result += consumed.replace(/[^\n]/g, ' ');
      index = bodyEnd + dollarTag.length - 1;
    } else if (character === "'" || character === '"') {
      const quote = character;
      const backslashEscapes = isEscapeStringPrefix(source, index);
      result += ' ';
      for (index += 1; index < source.length; index += 1) {
        if (source[index] === '\n') {
          result += '\n';
        } else {
          result += ' ';
        }
        if (backslashEscapes && source[index] === '\\' && index + 1 < source.length) {
          result += ' ';
          index += 1;
        } else if (source[index] === quote) {
          if (source[index + 1] === quote) {
            result += ' ';
            index += 1;
          } else {
            break;
          }
        }
      }
    } else if (character === '-' && source[index + 1] === '-') {
      while (index < source.length && source[index] !== '\n') {
        result += ' ';
        index += 1;
      }
      result += '\n';
    } else if (character === '/' && source[index + 1] === '*') {
      let depth = 1;
      result += '  ';
      index += 2;
      while (index < source.length && depth > 0) {
        if (source[index] === '/' && source[index + 1] === '*') {
          depth += 1;
          result += '  ';
          index += 2;
        } else if (source[index] === '*' && source[index + 1] === '/') {
          depth -= 1;
          result += '  ';
          index += 2;
        } else {
          result += source[index] === '\n' ? '\n' : ' ';
          index += 1;
        }
      }
      assert.equal(depth, 0, 'Unclosed SQL block comment');
      index -= 1;
    } else {
      result += character;
    }
  }

  return result;
}

function dollarBodyHeaderEnd(source, startIndex) {
  for (let index = startIndex; index < source.length; index += 1) {
    const character = source[index];
    const dollarTag = character === '$'
      ? source.slice(index).match(/^\$[a-z_][a-z0-9_]*\$|^\$\$/i)?.[0]
      : null;

    if (dollarTag) {
      const headerPrefix = sqlOutsideCommentsAndLiterals(source.slice(startIndex, index));
      assert.match(headerPrefix, /\bas\s*$/i, 'Dollar-quoted function body must follow AS');
      return index + dollarTag.length;
    }

    if (character === "'" || character === '"') {
      const quote = character;
      const backslashEscapes = isEscapeStringPrefix(source, index);
      for (index += 1; index < source.length; index += 1) {
        if (backslashEscapes && source[index] === '\\' && index + 1 < source.length) {
          index += 1;
        } else if (source[index] === quote) {
          if (source[index + 1] === quote) {
            index += 1;
          } else {
            break;
          }
        }
      }
    } else if (character === '-' && source[index + 1] === '-') {
      while (index < source.length && source[index] !== '\n') {
        index += 1;
      }
    } else if (character === '/' && source[index + 1] === '*') {
      let depth = 1;
      index += 2;
      while (index < source.length && depth > 0) {
        if (source[index] === '/' && source[index + 1] === '*') {
          depth += 1;
          index += 2;
        } else if (source[index] === '*' && source[index + 1] === '/') {
          depth -= 1;
          index += 2;
        } else {
          index += 1;
        }
      }
      assert.equal(depth, 0, 'Unclosed SQL block comment before function body');
      index -= 1;
    }
  }

  throw new Error('Public function must have a bounded dollar-quoted body');
}

function stripTopLevelDefault(argument) {
  let depth = 0;
  let quote = null;
  let backslashEscapes = false;

  for (let index = 0; index < argument.length; index += 1) {
    const character = argument[index];

    if (quote) {
      if (backslashEscapes && character === '\\' && index + 1 < argument.length) {
        index += 1;
      } else if (character === quote) {
        if (argument[index + 1] === quote) {
          index += 1;
        } else {
          quote = null;
          backslashEscapes = false;
        }
      }
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
      backslashEscapes = isEscapeStringPrefix(argument, index);
    } else if (character === '(' || character === '[') {
      depth += 1;
    } else if (character === ')' || character === ']') {
      depth -= 1;
    } else if (depth === 0 && character === '=') {
      return argument.slice(0, index).trim();
    } else if (
      depth === 0
      && argument.slice(index).match(/^default(?:\s|$)/i)
      && (index === 0 || /\s/.test(argument[index - 1]))
    ) {
      return argument.slice(0, index).trim();
    }
  }

  return argument.trim();
}

const unnamedTypeLeads = new Set([
  'bigint',
  'bigserial',
  'bit',
  'boolean',
  'bool',
  'box',
  'bytea',
  'character',
  'cidr',
  'date',
  'decimal',
  'double',
  'inet',
  'int',
  'int2',
  'int4',
  'int8',
  'integer',
  'interval',
  'json',
  'jsonb',
  'money',
  'numeric',
  'real',
  'record',
  'serial',
  'smallint',
  'smallserial',
  'text',
  'time',
  'timestamp',
  'timestamptz',
  'timetz',
  'uuid',
  'varchar',
  'xml'
]);

function normalizeIdentityType(type) {
  return type
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .replace(/\s*([()[\],])\s*/g, '$1')
    .replace(/^int2$/, 'smallint')
    .replace(/^int4$/, 'integer')
    .replace(/^int8$/, 'bigint')
    .replace(/^int$/, 'integer')
    .replace(/^smallserial$/, 'smallint')
    .replace(/^serial$/, 'integer')
    .replace(/^bigserial$/, 'bigint')
    .replace(/^bool$/, 'boolean')
    .replace(/^float4$/, 'real')
    .replace(/^float8$/, 'double precision')
    .replace(/^decimal(?=$|\()/, 'numeric')
    .replace(/^timestamp with time zone$/, 'timestamptz')
    .replace(/^timestamp without time zone$/, 'timestamp')
    .replace(/^time with time zone$/, 'timetz')
    .replace(/^time without time zone$/, 'time')
    .replace(/^character varying(?=$|\()/, 'varchar');
}

function identityArgumentTypes(argumentList, declaration = false) {
  return splitTopLevel(stripSqlComments(argumentList)).flatMap((rawArgument) => {
    let argument = stripTopLevelDefault(rawArgument);
    const mode = argument.match(/^(inout|in|out|variadic)\s+/i)?.[1]?.toLowerCase();
    argument = argument.replace(/^(?:inout|in|out|variadic)\s+/i, '').trim();

    if (mode === 'out') {
      return [];
    }

    if (declaration) {
      const firstToken = argument.match(/^("[^"]+"|[a-z_][a-z0-9_$]*)/i)?.[1];
      const unquotedFirstToken = firstToken?.replace(/^"|"$/g, '').toLowerCase();
      const remainder = firstToken ? argument.slice(firstToken.length).trim() : '';
      const isUnnamedType = unquotedFirstToken
        && (unnamedTypeLeads.has(unquotedFirstToken) || firstToken.includes('.'));

      if (remainder && !isUnnamedType) {
        argument = remainder;
      }
    }

    return [normalizeIdentityType(argument)];
  });
}

function publicFunctionDefinitions(sql) {
  const inspectableSql = sqlOutsideCommentsAndLiterals(sql);
  const pattern = /create\s+(?:or\s+replace\s+)?function\s+(public\.[a-z0-9_]+)\s*\(/gi;
  return [...inspectableSql.matchAll(pattern)].map((match) => {
    const openIndex = match.index + match[0].lastIndexOf('(');
    const argumentsList = parenthesizedBody(sql, openIndex);
    const headerEnd = dollarBodyHeaderEnd(sql, argumentsList.closeIndex + 1);
    return {
      index: match.index,
      name: match[1].toLowerCase(),
      identityTypes: identityArgumentTypes(argumentsList.body, true),
      header: inspectableSql.slice(match.index, headerEnd)
    };
  });
}

const isSecurityDefiner = (definition) => /\bsecurity\s+definer\b/i.test(definition.header);
const hasPinnedSearchPath = (definition) => /\bset\s+search_path\s+(?:to|=)/i.test(definition.header);

function hasExactPublicExecuteRevoke(sql, definition) {
  const inspectableSql = sqlOutsideCommentsAndLiterals(sql);
  const pattern = /revoke\s+(?:all(?:\s+privileges)?|execute)\s+on\s+function\s+(public\.[a-z0-9_]+)\s*\(/gi;

  for (const match of inspectableSql.matchAll(pattern)) {
    const openIndex = match.index + match[0].lastIndexOf('(');
    const argumentsList = parenthesizedBody(inspectableSql, openIndex);
    const tail = inspectableSql.slice(argumentsList.closeIndex + 1);
    const roles = tail.match(/^\s+from\s+([^;]+)\s*;/i)?.[1]
      ?.split(',')
      .map((role) => role.trim().replace(/^"|"$/g, '').toLowerCase());
    const identityTypes = identityArgumentTypes(argumentsList.body, true);

    if (
      match.index > definition.index
      &&
      match[1].toLowerCase() === definition.name
      && identityTypes.length === definition.identityTypes.length
      && identityTypes.every((type, index) => type === definition.identityTypes[index])
      && roles?.includes('public')
    ) {
      return true;
    }
  }

  return false;
}

function hasExplicitTableAcl(sql, table) {
  const inspectableSql = sqlOutsideCommentsAndLiterals(sql);
  const pattern = /\b(?:grant|revoke)\b[\s\S]*?\bon(?:\s+table)?\s+([^;]+?)\s+(?:to|from)\s+[^;]+;/gi;
  return [...inspectableSql.matchAll(pattern)].some((match) =>
    match[1].split(',').map((name) => name.trim().toLowerCase()).includes(table.toLowerCase())
  );
}

async function pendingMigrations() {
  const plan = JSON.parse(await readFile(planPath, 'utf8'));
  return plan.items.filter(({ kind }) => kind === 'pending');
}

test('all pending migrations and SQL acceptance suites have atomic boundaries', async () => {
  const pending = await pendingMigrations();
  assert.equal(pending.length, 364); // + v495 // + v494 // + v489 // + v488 // + v482 NULL lock mode is explicitly denied // + v481 inconsistent legacy referral credit remains fail-closed // + v479 the customer hears about their stamps the way the business hears about bookings (realtime signal) // + v478 an earned stamp gift survives the card closing (owner: unused rewards disappear) // + v477 a gift can say, in the owner's own words, where it works (owner photo 3) // + v475 the stamp card stops advertising a gift the counter refuses (owner photo 2) // + v474 staff and customer read the same stamp number (owner: 15 vs 5 of 10) // + v473 erasing a customer takes the business off that customer's phone (owner batch 11) // + v472a the owner's own profile read learns the menu segment (owner batch 11) // + v472 a gift end date the Point system page can set, and a separate menu gallery (owner batch 11) // + v469 a redeemed grant sale names itself (owner photo 11) // + v468 the programme analytics count uses, not people (owner photo 4) // + v463 the longest stamp card a firm may set is 15, not 100 (owner ruling R3a) // // + v437 history rows keep their unit + the wallet expiry rule // // + the 2026-08-22 stamp lifecycle wave: v433 stamp edit version split, v434 switch publish guard, v435 stamp cycle expiry, v436 stamp earn pinned + lazy close // + v432 staff redeem-now matches the customer // + v431 publish keeps the spine model // + the 2026-08-22 rewards go-live wave: v423 reward edit reaches customers, v424 birthday window honoured, v425 referral explicit reward type, v426 canonical tier resolver, v427 entitlements reach customers // + v422 a customer can see the rewards they have already redeemed (owner photo 6: History tab) // + v421 the friend gets the referral reward too // + v419 a suggested catalogue no longer erases spend-per-stamp // + v420 a referral may pay a free gift // // + v418 business gallery and social links (owner photo 10) // // + v417 the company bio reaches the customer // // + v416 a stamp card belongs to the setup it was started under (a mid-card customer keeps their card) //// + v414 the stamp card gets a length the owner can set (a gift added past the end could never be claimed) // // + v394 tier lifecycle at checkout + v393 customer tier visibility + v391 P0: v384 read running_since/paused_since as columns that do not exist (42703 on every wallet load) // + v386 dated programme usage (a second, independent v386 -- parallel-session number collision, not a real conflict) // + v386 customer company branches (NOT applied to prod) + v384 stamp conversion switch + v385 profile save // + v384 stamp conversion switch + v371 programme-off reaches the customer + v365 tier benefit limits & merchant issuance (applied to prod 2026-08-17) // + the 2026-08-16 rewards wave (v343/v345/v347/v348/v350/v353/v354/v355/v359/v361/v362), all applied to prod and sharing one acceptance suite // + v311 money kernel + v312 pot migration + v315 lead score repair + v316 taxonomy/match queue repair + v317 restored dependencies + v318 system-managed flag alignment + v313/v314 W6 increment 1 (reward programme identity + switchboard inversion) + v322 owner programme rulings + v325 business bio + v326/v326a points-gift lifecycle + v327 customer branch choice + v327 global customer QR (parallel-session v327 number collision) + v328 staff-choice manual confirm + v329 owner reschedule booking request + v330 pending slot block & confirmation template + v329 membership plan lifecycle (parallel-session v329 number collision) + v331 tier lifecycle + v332 retention program lifecycle + v340 reward purchase requirement (NOT applied) // + v410 promotion finalize overload ambiguity (P0: PGRST203 blocked every promotion save) // + v412 promotion delete gated on a module key that does not exist (P0: End/Delete refused the owner)
  const mappedSuites = new Map(pending.map((migration) => [
    migrationIdentity(migration),
    rollbackSuiteFor(migration)
  ]));
  assert.equal(mappedSuites.size, pending.length, 'every pending migration identity must be unique');
  assert.deepEqual(
    [...mappedSuites].filter(([identity, testPath]) =>
      !testPath && appliedPreflightExceptions.get(identity)?.rollbackSuite !== false),
    [],
    'every unique pending migration identity must map to a rollback suite'
  );

  for (const migration of pending) {
    const migrationSql = await readFile(path.join(repoRoot, migration.sourcePath), 'utf8');
    const identity=migrationIdentity(migration);
    const exception = appliedPreflightExceptions.get(identity);
    if (exception) {
      assert.equal(sha256(migrationSql), exception.sha256, `${identity} deployed exception hash drift`);
    }
    if(exception?.outerTransaction !== false){
      assert.equal(statementCount(migrationSql, 'begin'), 1, `${migration.name} must begin one transaction`);
      assert.equal(statementCount(migrationSql, 'commit'), 1, `${migration.name} must commit one transaction`);
    }

    const testPath = mappedSuites.get(migrationIdentity(migration));
    if(exception?.rollbackSuite === false)continue;
    assert.ok(testPath, `${migrationIdentity(migration)} must have a mapped rollback suite`);
    const testSql = await readFile(path.join(repoRoot, testPath), 'utf8');
    assert.doesNotMatch(
      testSql,
      /^\\\\ir\s/m,
      `${testPath} must use one literal backslash for psql include commands`
    );
    assert.equal(statementCount(testSql, 'begin'), 1, `${testPath} must begin one transaction`);
    assert.equal(statementCount(testSql, 'rollback'), 1, `${testPath} must roll back its fixture changes`);
  }
});

test('every newly created public table has RLS and an explicit browser-role ACL', async () => {
  for (const migration of await pendingMigrations()) {
    const sql = await readFile(path.join(repoRoot, migration.sourcePath), 'utf8');
    const tables = [...sql.matchAll(/create table(?: if not exists)?\s+(public\.[a-z0-9_]+)/gi)]
      .map((match) => match[1]);

    for (const table of tables) {
      const escaped = escapeRegExp(table);
      assert.match(
        sql,
        new RegExp(`alter\\s+table\\s+${escaped}\\s+enable\\s+row\\s+level\\s+security`, 'i'),
        `${migration.name}: ${table} must enable RLS`
      );
      assert.ok(
        hasExplicitTableAcl(sql, table),
        `${migration.name}: ${table} must declare its browser-role ACL explicitly`
      );
    }
  }
});

test('pending public SECURITY DEFINER RPCs pin search_path and revoke default execution', async () => {
  for (const migration of await pendingMigrations()) {
    const sql = await readFile(path.join(repoRoot, migration.sourcePath), 'utf8');
    const definitions = publicFunctionDefinitions(sql).filter(isSecurityDefiner);

    for (const definition of definitions) {
      const signature = `${definition.name}(${definition.identityTypes.join(',')})`;
      assert.ok(
        hasPinnedSearchPath(definition),
        `${migration.name}: ${signature} must pin search_path`
      );
      assert.ok(
        hasExactPublicExecuteRevoke(sql, definition),
        `${migration.name}: ${signature} must revoke PostgreSQL's default execute grant from PUBLIC on the exact overload`
      );
    }
  }
});

test('SECURITY DEFINER preflight rejects wrong-role and wrong-overload revocations', () => {
  const declarationSql = `
    create or replace function public.example_rpc(
      p_business uuid,
      p_amount numeric(12, 2) default 0
    )
    returns void
    language plpgsql
    security definer
    set search_path = ''
    as $$ begin null; end; $$;
  `;
  const declaration = publicFunctionDefinitions(declarationSql)[0];
  const withDeclaration = (aclSql) => `${declarationSql}\n${aclSql}`;

  assert.ok(
    hasExactPublicExecuteRevoke(
      withDeclaration(
        'revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, public, anon;'
      ),
      declaration
    ),
    'an exact overload revocation that includes PUBLIC must pass'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration(
        'revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, anon;'
      ),
      declaration
    ),
    false,
    'a revocation that omits PUBLIC must fail'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration('revoke all on function public.example_rpc(uuid) from public;'),
      declaration
    ),
    false,
    'a PUBLIC revocation on the wrong overload must fail'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration(`
        revoke all on function public.example_rpc(uuid) from public;
        revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, anon;
      `),
      declaration
    ),
    false,
    'separate wrong-overload and wrong-role statements must not combine into a false pass'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration(`
        -- revoke all on function public.example_rpc(uuid, numeric(12, 2)) from public;
        select 'revoke all on function public.example_rpc(uuid, numeric(12, 2)) from public;';
        do $acl$
        begin
          perform 'revoke all on function public.example_rpc(uuid, numeric(12, 2)) from public;';
        end
        $acl$;
        revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, anon;
      `),
      declaration
    ),
    false,
    'comments, string literals, and dollar-quoted bodies cannot spoof a PUBLIC revocation'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration(`
        /*
          outer comment
          /* inner comment */
          revoke all on function public.example_rpc(uuid, numeric(12, 2)) from public;
        */
        revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, anon;
      `),
      declaration
    ),
    false,
    'a fake exact revoke inside nested PostgreSQL block comments cannot satisfy the guard'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration(String.raw`
        select E'kept open by \' revoke all on function public.example_rpc(uuid, numeric(12, 2)) from public; still literal';
        revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, anon;
      `),
      declaration
    ),
    false,
    'a fake exact revoke after an escaped quote inside a PostgreSQL E-string cannot satisfy the guard'
  );

  const plainCreateSql = `
    create function public.plain_create_rpc(p_business uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
    as $$ begin null; end; $$;
  `;
  const plainCreate = publicFunctionDefinitions(plainCreateSql)[0];
  assert.equal(plainCreate?.name, 'public.plain_create_rpc', 'plain CREATE FUNCTION must be inspected');
  assert.equal(
    hasExactPublicExecuteRevoke(
      `${plainCreateSql}
       revoke all on function public.plain_create_rpc(uuid) from authenticated, anon;`,
      plainCreate
    ),
    false,
    'a plain CREATE FUNCTION cannot bypass the PUBLIC revocation requirement'
  );

  const contaminationDefinitions = publicFunctionDefinitions(`
    create function public.safe_invoker(p_business uuid)
    returns void
    language plpgsql
    security invoker
    as $$ begin null; end; $$;

    create function app.internal_definer(p_business uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
    as $$ begin null; end; $$;

    create function public.missing_path_definer(p_business uuid)
    returns void
    language plpgsql
    security definer
    as $$ begin null; end; $$;

    create function public.later_safe_invoker(p_business uuid)
    returns void
    language plpgsql
    security invoker
    set search_path = ''
    as $$ begin null; end; $$;
  `);
  assert.equal(
    contaminationDefinitions.filter(isSecurityDefiner).map(({ name }) => name).join(','),
    'public.missing_path_definer',
    'an intervening app definer must not reclassify a public invoker'
  );
  assert.equal(
    hasPinnedSearchPath(contaminationDefinitions.find(({ name }) => name === 'public.missing_path_definer')),
    false,
    'a public definer cannot borrow search_path from a later function header'
  );

  const commentedTokenSql = `
    create /* discovery gap */ function public.commented_tokens_rpc(p_business uuid)
    returns void
    language plpgsql
    security /* classification gap */ definer
    set /* header gap */ search_path = ''
    as $$ begin null; end; $$;
    revoke all on function public.commented_tokens_rpc(uuid) from public;
  `;
  const commentedTokenDefinition = publicFunctionDefinitions(commentedTokenSql)[0];
  assert.equal(
    commentedTokenDefinition?.name,
    'public.commented_tokens_rpc',
    'comments between CREATE FUNCTION tokens cannot hide a public function'
  );
  assert.equal(
    isSecurityDefiner(commentedTokenDefinition),
    true,
    'comments between SECURITY DEFINER tokens cannot hide the authority mode'
  );
  assert.equal(
    hasPinnedSearchPath(commentedTokenDefinition),
    true,
    'comments in a pinned search_path header must not prevent exact inspection'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(commentedTokenSql, commentedTokenDefinition),
    true,
    'the exact active post-definition PUBLIC revocation remains provable'
  );

  const recreatedSql = `
    revoke all on function public.recreated_rpc(uuid) from public;
    drop function public.recreated_rpc(uuid);
    create function public.recreated_rpc(p_business uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
    as $$ begin null; end; $$;
  `;
  const recreatedDefinition = publicFunctionDefinitions(recreatedSql)[0];
  assert.equal(
    hasExactPublicExecuteRevoke(recreatedSql, recreatedDefinition),
    false,
    'a revoke before DROP and plain CREATE cannot secure the newly created function ACL'
  );
});

test('v27 establishes the tenant-safe products parent key before its composite FK', async () => {
  const sql = await readFile(
    path.join(repoRoot, 'db/migrations/20260720_frenly_v27_rich_rewards.sql'),
    'utf8'
  );
  const parentKey = sql.search(/products_id_business_uk\s+unique\s*\(\s*id\s*,\s*business_id\s*\)/i);
  const childReference = sql.search(/references\s+public\.products\s*\(\s*id\s*,\s*business_id\s*\)/i);

  assert.notEqual(parentKey, -1, 'v27 must add products(id,business_id) as a unique parent key');
  assert.notEqual(childReference, -1, 'v27 must keep the tenant-safe product eligibility FK');
  assert.ok(parentKey < childReference, 'the products parent key must exist before the FK is created');
});

test('v40 adversarial fixtures never bypass every database trigger', async () => {
  const sql = await readFile(
    path.join(repoRoot, 'db/tests/v40_staff_reversal_workflows.sql'),
    'utf8'
  );

  assert.doesNotMatch(sql, /session_replication_role/i);
  assert.match(
    sql,
    /disable trigger trg_loyalty_redemption_provenance_immutable/i,
    'v40 may disable only the named provenance immutability trigger'
  );
  assert.match(
    sql,
    /enable trigger trg_loyalty_redemption_provenance_immutable/i,
    'v40 must restore the named provenance immutability trigger'
  );
  assert.doesNotMatch(sql, /disable trigger all/i);
});

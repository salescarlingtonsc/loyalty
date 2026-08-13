-- Recovery snapshot for nestly_v311_conversion_first_prospecting.
--
-- v311 drops reference data that cannot be re-derived from code. This file
-- captures it verbatim (production, 2026-08-14) so the drop is reversible.
-- Not part of the migration chain — it is never executed automatically.
--
-- To restore, re-create the tables from the pre-v311 migration that defined
-- them, then run the inserts below.

-- public.sme_lead_score_weights (9 rows) — the deleted lead-scoring model.
-- Kept only as a record of what the weights were; the owner has explicitly
-- ruled that scoring is not to be rebuilt.
--   rating_high        'Rating 4.2 or higher'       15
--   review_volume      '100+ reviews'               20
--   has_phone          'Reachable by phone'         15
--   has_website        'Has a website'              10
--   has_email          'Has an email'                5
--   operational        'Currently operating'        10
--   geocoded           'Mapped location'             5
--   not_yet_merchant   'Not yet a Peekaa merchant'  10
--   uncontacted        'Not contacted yet'          10
-- public.sme_lead_scores was empty at capture time.

-- public.sme_data_quality_rule_versions (11 rows), all version 1, active.
insert into public.sme_data_quality_rule_versions
  (rule_key, label, severity, weight, version, active) values
  ('company_name','Company name','blocking',15,1,true),
  ('registration_or_domain','Registration number or verified domain','warning',15,1,true),
  ('primary_contact','Primary contact','blocking',15,1,true),
  ('valid_contact_method','Valid contact method','blocking',10,1,true),
  ('source_attribution','Source attribution','warning',10,1,true),
  ('assigned_owner','Assigned owner','warning',10,1,true),
  ('contact_basis','Consent or contact basis','warning',5,1,true),
  ('next_action','Next action','warning',5,1,true),
  ('recent_activity','Recent activity','warning',5,1,true),
  ('qualification','Qualification evidence','info',5,1,true),
  ('commercial_context','Commercial context','info',5,1,true);

-- public.sme_import_batch_reversals and public.sme_import_reversal_rows were
-- both empty at capture time — nothing to restore.

-- Retired pipeline stages (label, sort_order) removed by v311:
--   appt_set 'Appointment Set' 2 | npu_1..npu_6 'NPU 1'..'NPU 6' 3-8
--   call_back 'Call Back' 9 | reschedule 'Reschedule' 10
--   meeting_sent 'Meeting Link Sent / Calendar Set' 11 | site_visit 'Site Visit' 12
--   quotation_sent 'Quotation Sent' 13 | pending_decision 'Pending Decision' 14

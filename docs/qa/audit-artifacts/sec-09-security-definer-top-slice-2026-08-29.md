# SEC-09 top slice — 2026-08-29

Live inventory: 718 callable SECURITY DEFINER functions; 371 static-write candidates; 47 static writes without an exact direct-auth indicator before the first write; 44 of those have a recognized delegated helper.

Categories:
- **Intended public writes:** `submit_demo_request_v292`, `report_client_error_v177`; protect with abuse controls and explicit exceptions.
- **Post-write predicate:** `mark_notification_read`; `is_salon_member` is in the same UPDATE predicate, so the position heuristic is conservative.
- **Helper-auth false positives:** 44 candidates with recognized helper/context calls before the first write; verify helper chains and tenant checks.

| Category | Object | First write | Delegated helper(s) | Action |
|---|---|---|---|---|
| Post-write predicate | `public.mark_notification_read()` | update @ 223 | none | Add cross-member negative test |
| Intended public | `public.report_client_error_v177()` | insert @ 1049 | none | Keep as bounded telemetry; add edge quotas |
| Intended public | `public.submit_demo_request_v292()` | insert @ 3073 | none | Add IP/CAPTCHA/rate limits |
| Helper-auth candidate | `public.set_sale_policy()` | insert @ 640 | has_perm | Review helper definition/call chain |
| Helper-auth candidate | `public.open_drawer()` | insert @ 742 | has_perm | Review helper definition/call chain |
| Helper-auth candidate | `public.record_drawer_movement()` | insert @ 1116 | has_perm | Review helper definition/call chain |
| Helper-auth candidate | `public.close_drawer()` | update @ 1073 | has_perm | Review helper definition/call chain |
| Helper-auth candidate | `public.set_expense_void()` | update @ 458 | has_perm, can_module | Review helper definition/call chain |
| Helper-auth candidate | `public.publish_loyalty_config()` | merge @ 1523 | c45_owner_loyalty_write | Review helper definition/call chain |
| Helper-auth candidate | `public.customer_set_in_app_inbox_preferences()` | insert @ 3327 | platform_feature_enabled | Review helper definition/call chain |
| Helper-auth candidate | `public.customer_sync_in_app_inbox()` | insert @ 4805 | platform_feature_enabled | Review helper definition/call chain |
| Helper-auth candidate | `public.customer_sync_in_app_inbox_global()` | insert @ 2897 | platform_feature_enabled | Review helper definition/call chain |
| Helper-auth candidate | `public.customer_set_in_app_inbox_state()` | insert @ 2315 | platform_feature_enabled | Review helper definition/call chain |
| Helper-auth candidate | `public.customer_submit_visit_feedback()` | insert @ 1990 | v53_customer_feedback_context | Review helper definition/call chain |
| Helper-auth candidate | `public.platform_add_my_prospect_activity_v89()` | insert @ 1064 | v89_platform_can, v89_can_access_prospect, can_access | Review helper definition/call chain |

The CSV contains the three no-recognized-helper exceptions plus the top 25 helper-auth candidates. The full 718-entry inventory retains every prewrite field. Static scanning cannot prove transitive authorization or detect dynamic SQL safely.

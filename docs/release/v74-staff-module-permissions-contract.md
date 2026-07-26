# v74 staff module-permission contract

V74 adds two authenticated, owner-only RPCs. It does not add a direct browser
table-write contract.

`set_staff_module_permissions_v74(staff, module_perms)` accepts only an active,
non-owner staff row in the caller owner's business. SQL `NULL` restores legacy
inheritance and writes both `module_perms` and `modules` as `NULL`. A non-null
value must be an object whose values are only `r` or `rw`.

Requested keys must be currently enabled for the business, present in
`module_registry`, and assignable to non-owner staff. `branches`, `settings`,
and `setup` are rejected. The RPC expands only `requires_modules` recursively:
missing dependencies receive `r`, while an explicitly supplied `rw` mode is
preserved. Recommended modules are never added. The full resolved closure must
also be enabled and assignable.

Expenses and P&L require the canonical `view_finance` role permission. That
allows manager and bookkeeper targets and rejects staff/frontdesk targets.
Resolved permissions are stored in `staff.module_perms`; the sorted resolved
keys are mirrored to legacy `staff.modules`. The response and single
`STAFF_MODULE_PERMISSIONS_SET_V74` audit contain resolved, not raw, permission
truth plus the prior values.

`set_staff_role_v74(staff, role)` accepts only manager, staff, frontdesk, or
bookkeeper and cannot change an owner row. When the new role lacks
`view_finance`, explicit Expenses/P&L entries are removed atomically from both
permission columns. SQL `NULL` inheritance remains `NULL`; it is not frozen
into a point-in-time module list. One `STAFF_ROLE_SET_V74` audit records the
prior/new role, module permissions, and legacy modules.

The authenticated legacy signature `set_staff_modules(uuid,text[])` remains as
a fixed-search-path compatibility adapter. SQL `NULL` delegates as inheritance;
a non-null text array becomes an `rw` object and delegates to
`set_staff_module_permissions_v74`, including required-dependency resolution.
It performs no direct staff update and writes no second audit. Its staff-shaped
JSON response keeps legacy callers practical, and the existing
`apply_module_template` path continues through this adapter.

V74 also replaces `app.staff_module_perms` so non-owner effective discovery
never returns Branches, Settings, or Setup, and never returns Expenses or P&L
without `view_finance`. This closes existing legacy `NULL`-inherit rows without
a data rewrite. Dashboard remains governed by its existing always-reachable
app behavior.

The migration and rollback suite are review candidates only. Run the SQL suite
only against a disposable database after the canonical chain through v74.

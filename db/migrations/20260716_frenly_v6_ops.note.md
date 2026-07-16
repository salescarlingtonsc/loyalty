# 20260716 frenly_v6_ops_modules (applied remotely)
THE relationship: appointment status -> 'completed' trigger books sale(kind service,
amount = total or service price, unique per appointment) -> existing sale trigger
fires loyalty/retention/referral. Idempotent (re-complete = no 2nd sale; verified).
Appointments: +service_id, +resource_id, +note. Resources table.
Inventory: product_stock view; retail sales w/ product_id+qty auto-deduct
stock_batches FEFO (earliest expiry first; verified).
Waitlist: waiting/contacted/booked/removed.
Packages: package_plans + client_packages; sell_package RPC (books revenue, earns
loyalty); use_package_session RPC ($0 service sale -> counts as retention visit).
Bundles + bundle_items tables (UI later).
convert_booking_request RPC: portal request -> match-or-create client -> booked
appointment -> request confirmed (verified).
Membership sales still excluded from earn/retention/referral.

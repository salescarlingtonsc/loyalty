# 20260716 frenly_v7_team_brand (applied remotely)
Team: staff_invites (5 roles, unique 8-char code, 14-day expiry, pending/accepted/
revoked). create_invite RPC (owner-only). accept_invite RPC: signed-in teammate
enters code -> staff row with role, invite consumed, audited (verified: role landed,
case-insensitive, portal payload intact). Onboarding screen now offers "Join team".
Settings: team roster w/ role change + remove (owner-policied), pending invites
w/ copy/revoke; CSV customer import (client-side parser, name/phone/email/gender/
birth_date mapping, 100-row batches).
Brand/Policy: businesses.brand_color + booking_policy; get_business_public
includes both; portal renders brand accent + policy text.
Appointments: List | Week calendar grid view (9:00-19:00, prev/next week,
click-to-complete; deliberately no drag-drop — benchmark's drag had a visual bug).
Services page: Bundles (multi-service at one price) + Resources UI.

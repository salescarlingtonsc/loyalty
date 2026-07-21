revoke all on function app.commission_flat_cents(uuid, text, uuid, uuid, timestamptz, integer)
  from public, anon, authenticated;

comment on function app.commission_flat_cents(uuid, text, uuid, uuid, timestamptz, integer) is
  'Flat-commission resolver (v13 rebased; formally reconciled by v22). Owner-only ACL — the sole '
  'caller is app.on_sale_commission_snapshot() (SECURITY DEFINER trigger). v22 supersedes v20''s '
  '"v13 flat commission is tombstoned" statement: flat commission is the approved model per the '
  'owner''s %-or-flat-per-service ruling, with v20-compatible reversal semantics (a reversal row '
  'copies the original''s flat snapshot and public.sale_commission nets it negative in full).';

comment on column public.sales.commission_flat_cents is
  'IMMUTABLE SNAPSHOT of the resolved FLAT commission in cents at record time, or NULL if not '
  'flat-commission (then commission_rate_bps applies). When NOT NULL this WINS over the rate '
  '(0 is a real flat-zero). A reversal sale copies the original sale''s snapshot and the view '
  'nets it negative. Reinstated by frenly_v13_flat_commission and formally reconciled with the '
  'v20 financial engine by frenly_v22_flat_commission_reconciliation (supersedes the v20 tombstone).';
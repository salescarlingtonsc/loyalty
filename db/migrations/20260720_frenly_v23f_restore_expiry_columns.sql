-- FRENLY v23f — restore loyalty_programs points-expiry columns (v3) missed by the v23d recovery.
-- Applied migration name: frenly_v23f_restore_expiry_columns
--
-- The v23d recovery restored the frenly_init + v2 columns but not v3's points-expiry columns
-- (expiry_mode, expiry_days), which app.on_sale_recorded() and the v20 expiry sweep both read.
-- Without them, recording ANY sale errored ("record lp has no field expiry_mode"). This adds them
-- back, additively (no drop). Default 'none' = no expiry (matches v11a onboarding, which never set
-- an expiry mode). Values observed in code: 'fixed' (expires_at = now + expiry_days) and
-- 'inactivity' (expires on inactivity window); 'none' is the no-expiry default. This is the final
-- piece restoring the pre-regression loyalty_programs contract.

begin;
alter table public.loyalty_programs
  add column if not exists expiry_mode text not null default 'none'
    check (expiry_mode in ('none','fixed','inactivity')),
  add column if not exists expiry_days integer;
commit;

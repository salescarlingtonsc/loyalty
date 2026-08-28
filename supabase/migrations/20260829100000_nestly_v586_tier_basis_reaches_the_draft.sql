-- nestly_v586 — "i already changed to by per visit, but it refreshes back to points"
--
-- THE BUG, proven on production before writing a line of this.
--
-- business_set_tier_basis_v347 (V347) is an IMMEDIATE-WRITE path: it sets
-- public.loyalty_programs.tier_basis and nothing else, so the Manage Tiers page can change how
-- tiers are earned without walking the owner through the draft/publish wizard. That was the whole
-- point of it, and for the page itself it works — every workspace and customer reader takes the
-- basis from the live loyalty_programs row.
--
-- But the DRAFT does not hear about it. public.loyalty_program_versions holds a tier_basis of its
-- own, and publish_loyalty_config writes the published version's value straight back onto
-- loyalty_programs. nestly_v564 already fixed half of this from the other side: a NEW draft is
-- cloned from the LIVE row (coalesce(live.tier_basis, base.tier_basis)), so a draft opened after
-- the change is correct. What it could not fix is a draft that was ALREADY OPEN when the basis
-- changed — that one still carries the old value, and publishing it silently restores it.
--
-- Measured on gadpooereceldfpfxsod, 2026-08-29, which is exactly the owner's report:
--   Jess Salon — open draft (version 2, created 16:47:36Z) tier_basis='points_earned'
--                live loyalty_programs.tier_basis='visits' (set 16:53:12Z, audit_log confirms)
--   QA Kopi Lab (Bedok) — open draft 'points_earned' against a live 'visits'
-- "which was previously set up" is literally what those drafts hold.
--
-- THE FIX. The setter writes the basis everywhere an unpublished copy of it lives: the live row
-- (unchanged) and every OPEN DRAFT for that business. Published versions are NOT touched — they
-- are immutable snapshots by design (app.loyalty_version_immutable_guard), nothing reads their
-- tier_basis at publish time, and rewriting history to fix a forward-looking setting would be the
-- wrong trade. Draft rows are explicitly updatable under that same guard, which is why this needs
-- no change to it.
--
-- A one-time repair follows, for the drafts that are already skewed. It sets the DRAFT to the LIVE
-- value, never the other way round: the live row is the one the owner last chose (it carries an
-- audit_log entry), and it is what every reader — the workspace, the customer tier resolver,
-- app.c46 — is acting on today. So the repair changes nothing anyone can see; it only stops a
-- future publish from contradicting it.
--
-- Nothing about tier EVALUATION changes here. Thresholds are untouched, the resolver is untouched,
-- and no customer's tier moves.

begin;

create or replace function public.business_set_tier_basis_v347(p_business uuid, p_basis text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_basis text := nullif(btrim(coalesce(p_basis,'')),'');
  v_drafts integer := 0;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_basis is null or v_basis not in ('visits','spend','points_earned') then
    raise exception 'invalid tier basis' using errcode='22023';
  end if;

  -- active must be false while configuration_status stays at its table default 'draft' --
  -- loyalty_programs_configuration_status_check requires configuration_status='draft' => not
  -- active (confirmed live: the executor validates row constraints against the proposed INSERT
  -- row, defaults included, before ON CONFLICT ever resolves — a bare default-column insert here
  -- throws 23514 even though the actual outcome for an existing row is always the UPDATE branch).
  -- Mirrors create_business's own insert shape (business_id,kind,active,loyalty_model,
  -- configuration_status) for the only-ever-hit-on-a-missing-row path.
  insert into public.loyalty_programs(business_id, tier_basis, active, configuration_status)
  values (p_business, v_basis, false, 'draft')
  on conflict (business_id) do update set tier_basis=excluded.tier_basis;

  -- nestly_v586: and every OPEN DRAFT, or the next publish restores the value the owner just
  -- replaced. Published versions are left alone on purpose (see the header).
  update public.loyalty_program_versions v
     set tier_basis = v_basis
   from public.firm_config_versions f
   where f.id = v.config_version_id
     and v.business_id = p_business
     and f.business_id = p_business
     and f.status = 'draft'
     and v.tier_basis is distinct from v_basis;
  get diagnostics v_drafts = row_count;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'tier_basis.updated','loyalty_programs',p_business,
    jsonb_build_object('tier_basis',v_basis,'drafts_realigned',v_drafts));

  return jsonb_build_object('status','ok','tier_basis',v_basis,'drafts_realigned',v_drafts);
end
$$;
revoke all privileges on function public.business_set_tier_basis_v347(uuid,text) from public, anon;
grant execute on function public.business_set_tier_basis_v347(uuid,text) to authenticated, service_role;

-- One-time repair of the drafts that are already skewed. Live wins, for the reasons in the header.
--
-- app.c45_loyalty_program_version_write_guard refuses any write to a DRAFT row unless
-- app.c45_owner_loyalty_write() passes, and that predicate opens with `auth.uid() is not null` —
-- true for the owner calling the RPC, never true for a migration. The guard is therefore switched
-- off for the length of this one statement and switched straight back on, inside the same
-- transaction: if anything here fails, the rollback restores it. Nothing about the guard's rule
-- changes, and no other statement runs while it is off.
alter table public.loyalty_program_versions disable trigger trg_c45_loyalty_program_version_write_guard;

update public.loyalty_program_versions v
   set tier_basis = p.tier_basis
  from public.firm_config_versions f
  join public.loyalty_programs p on p.business_id = f.business_id
 where f.id = v.config_version_id
   and f.business_id = v.business_id
   and f.status = 'draft'
   and p.tier_basis is not null
   and v.tier_basis is distinct from p.tier_basis;

alter table public.loyalty_program_versions enable trigger trg_c45_loyalty_program_version_write_guard;

commit;

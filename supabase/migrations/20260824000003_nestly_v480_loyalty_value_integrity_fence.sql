-- nestly_v480_loyalty_value_integrity_fence.sql
-- P0: serialize loyalty-value writes against programme conversion, make drains
-- fail closed, add adjustment idempotency, and bind sale reversal to loyalty
-- clawback.  This migration deliberately leaves conversion disabled; a later,
-- separately approved release gate is required to enable it.

begin;

create table app.loyalty_integrity_control_v480 (
  singleton boolean primary key default true check (singleton),
  conversions_enabled boolean not null default false,
  changed_at timestamptz not null default statement_timestamp(),
  changed_by uuid
);
insert into app.loyalty_integrity_control_v480(singleton, conversions_enabled)
values (true, false);
revoke all on app.loyalty_integrity_control_v480 from public, anon, authenticated;

create or replace function app.loyalty_fence_key_v480(p_business uuid)
returns bigint
language sql immutable strict
set search_path = pg_catalog, public, app, pg_temp
as $$
  select pg_catalog.hashtextextended('peekaa:loyalty:v480:' || p_business::text, 0)
$$;

create or replace function app.loyalty_fence_mode_v480(p_business uuid)
returns text
language sql stable strict security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  with k as (select app.loyalty_fence_key_v480(p_business) as value)
  select case
    when exists (
      select 1 from pg_catalog.pg_locks l, k
       where l.locktype = 'advisory' and l.pid = pg_catalog.pg_backend_pid()
         and l.granted and l.mode = 'ExclusiveLock' and l.objsubid = 1
         and l.classid = (((k.value >> 32) & 4294967295)::bigint)::oid
         and l.objid = ((k.value & 4294967295)::bigint)::oid
    ) then 'exclusive'
    when exists (
      select 1 from pg_catalog.pg_locks l, k
       where l.locktype = 'advisory' and l.pid = pg_catalog.pg_backend_pid()
         and l.granted and l.mode = 'ShareLock' and l.objsubid = 1
         and l.classid = (((k.value >> 32) & 4294967295)::bigint)::oid
         and l.objid = ((k.value & 4294967295)::bigint)::oid
    ) then 'shared'
    else null end
$$;

create or replace function app.acquire_loyalty_shared_v480(p_business uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if app.loyalty_fence_mode_v480(p_business) is null then
    perform pg_catalog.pg_advisory_xact_lock_shared(app.loyalty_fence_key_v480(p_business));
  end if;
  if app.loyalty_fence_mode_v480(p_business) not in ('shared', 'exclusive') then
    raise exception 'loyalty shared fence acquisition could not be proven'
      using errcode = 'XX001';
  end if;
end
$$;

create or replace function app.acquire_loyalty_exclusive_v480(p_business uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare v_mode text;
begin
  v_mode := app.loyalty_fence_mode_v480(p_business);
  if v_mode = 'shared' then
    raise exception 'unsafe loyalty fence upgrade from shared to exclusive'
      using errcode = '40P01';
  end if;
  if v_mode is null then
    perform pg_catalog.pg_advisory_xact_lock(app.loyalty_fence_key_v480(p_business));
  end if;
  if app.loyalty_fence_mode_v480(p_business) <> 'exclusive' then
    raise exception 'loyalty exclusive fence acquisition could not be proven'
      using errcode = 'XX001';
  end if;
end
$$;

create or replace function app.lock_refund_staff_v480(p_business uuid)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare v_staff uuid;
begin
  select s.id into v_staff
    from public.staff s
   where s.business_id=p_business and s.user_id=auth.uid() and s.active
     and 'refund_sales'=any(app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end,
            s.created_at,s.id
   limit 1 for update;
  if not found then
    raise exception 'active staff authorization required' using errcode='42501';
  end if;
  return v_staff;
end
$$;

revoke all on function app.loyalty_fence_key_v480(uuid) from public, anon, authenticated;
revoke all on function app.loyalty_fence_mode_v480(uuid) from public, anon, authenticated;
revoke all on function app.acquire_loyalty_shared_v480(uuid) from public, anon, authenticated;
revoke all on function app.acquire_loyalty_exclusive_v480(uuid) from public, anon, authenticated;
revoke all on function app.lock_refund_staff_v480(uuid) from public, anon, authenticated;

create or replace function app.require_loyalty_shared_v480()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_business uuid := case when tg_op = 'DELETE' then old.business_id else new.business_id end;
begin
  if app.loyalty_fence_mode_v480(v_business) not in ('shared', 'exclusive') then
    raise exception 'loyalty value write requires a transaction fence'
      using errcode = '55000';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;
revoke all on function app.require_loyalty_shared_v480() from public, anon, authenticated;

-- Referral rewards are loyalty value too.  v436 links the referral row to the
-- qualifying sale, but its points/stamps rows used sale_id=NULL and its voucher
-- grants had no immutable payout-to-sale record.  Capture exact two-sided
-- provenance for every new payout.  Existing vouchers can be backfilled exactly
-- from their referral FK; historical points/stamps cannot and therefore fail
-- closed at reversal until explicitly reconciled.
alter table public.referral_grants_v420
  drop constraint referral_grants_v420_status_check;
alter table public.referral_grants_v420
  add constraint referral_grants_v420_status_check
  check (status = any(array['granted','redeemed','expired','reversed']));

alter table public.points_ledger
  add column referral_id uuid,
  add column referral_beneficiary text;
alter table public.points_batches
  add column referral_id uuid,
  add column referral_beneficiary text;
alter table public.points_ledger
  add constraint points_ledger_referral_v480_fk foreign key (referral_id,business_id)
    references public.referrals(id,business_id) on delete restrict,
  add constraint points_ledger_referral_v480_shape check (
    (referral_id is null and referral_beneficiary is null)
    or (referral_id is not null and referral_beneficiary in ('referrer','friend'))
  );
alter table public.points_batches
  add constraint points_batches_referral_v480_fk foreign key (referral_id,business_id)
    references public.referrals(id,business_id) on delete restrict,
  add constraint points_batches_referral_v480_shape check (
    (referral_id is null and referral_beneficiary is null)
    or (referral_id is not null and referral_beneficiary in ('referrer','friend'))
  );
create index points_ledger_referral_lookup_v480
  on public.points_ledger(referral_id,referral_beneficiary)
  where referral_id is not null;
create index points_batches_referral_lookup_v480
  on public.points_batches(referral_id,referral_beneficiary)
  where referral_id is not null;

-- A referral may qualify again after its qualifying sale is reversed.  The
-- immutable child id held by the provenance row, not a lifetime uniqueness
-- constraint on the referral, prevents duplicate value within a qualification.
alter table public.referral_grants_v420
  drop constraint referral_grants_v421_once_per_side;
create index referral_grants_v480_referral_side_idx
  on public.referral_grants_v420(referral_id,beneficiary);

create table app.referral_value_provenance_v480 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  referral_id uuid not null references public.referrals(id) on delete restrict,
  qualifying_sale_id uuid not null,
  beneficiary text not null check (beneficiary in ('referrer','friend')),
  client_id uuid not null,
  benefit_kind text not null check (benefit_kind in ('points','stamps','voucher')),
  programme_id uuid,
  amount integer,
  ledger_id uuid unique,
  batch_id uuid unique,
  grant_id uuid unique,
  created_at timestamptz not null default statement_timestamp(),
  unique (referral_id,qualifying_sale_id,beneficiary),
  foreign key (qualifying_sale_id,business_id) references public.sales(id,business_id),
  foreign key (client_id,business_id) references public.clients(id,business_id),
  check (
    (benefit_kind in ('points','stamps') and programme_id is not null and amount>0
      and ledger_id is not null and grant_id is null)
    or
    (benefit_kind='voucher' and programme_id is null and amount is null
      and ledger_id is null and batch_id is null and grant_id is not null)
  )
);
revoke all on app.referral_value_provenance_v480 from public, anon, authenticated;

create or replace function app.capture_referral_ledger_v480()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare v_ref public.referrals%rowtype; v_kind text;
begin
  if new.referral_id is null then return new; end if;
  select * into v_ref from public.referrals
   where id=new.referral_id and business_id=new.business_id and status='rewarded';
  if not found then raise exception 'referral payout ledger has no qualifying referral' using errcode='XX001'; end if;
  if new.client_id is distinct from
     (case when new.referral_beneficiary='referrer' then v_ref.referrer_client_id else v_ref.referred_client_id end) then
    raise exception 'referral payout beneficiary does not match referral' using errcode='XX001';
  end if;
  select kind into v_kind from public.business_programmes
   where id=new.programme_id and business_id=new.business_id;
  if v_kind not in ('points','stamps') then raise exception 'referral payout programme kind is invalid' using errcode='XX001'; end if;
  insert into app.referral_value_provenance_v480(
    business_id,referral_id,qualifying_sale_id,beneficiary,client_id,benefit_kind,
    programme_id,amount,ledger_id
  ) values(new.business_id,v_ref.id,v_ref.qualified_sale_id,new.referral_beneficiary,new.client_id,v_kind,
           new.programme_id,new.points,new.id);
  return new;
end $$;

create or replace function app.capture_referral_batch_v480()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare v_ref public.referrals%rowtype; v_rows integer;
begin
  if new.referral_id is null then return new; end if;
  select * into v_ref from public.referrals
   where id=new.referral_id and business_id=new.business_id and status='rewarded';
  if not found then raise exception 'referral payout batch has no qualifying referral' using errcode='XX001'; end if;
  update app.referral_value_provenance_v480
     set batch_id=new.id
   where referral_id=v_ref.id and qualifying_sale_id=v_ref.qualified_sale_id
     and beneficiary=new.referral_beneficiary and business_id=new.business_id
     and client_id=new.client_id and programme_id=new.programme_id and amount=new.earned
     and batch_id is null;
  get diagnostics v_rows=row_count;
  if v_rows<>1 then raise exception 'referral payout batch has no unique ledger provenance' using errcode='XX001'; end if;
  return new;
end $$;

create or replace function app.capture_referral_grant_v480()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare v_sale uuid;
begin
  select qualified_sale_id into v_sale from public.referrals
   where id=new.referral_id and business_id=new.business_id and status='rewarded';
  if v_sale is null then raise exception 'referral voucher has no qualifying sale' using errcode='XX001'; end if;
  insert into app.referral_value_provenance_v480(
    business_id,referral_id,qualifying_sale_id,beneficiary,client_id,benefit_kind,grant_id
  ) values(new.business_id,new.referral_id,v_sale,new.beneficiary,new.client_id,'voucher',new.id);
  return new;
end $$;

revoke all on function app.capture_referral_ledger_v480() from public, anon, authenticated;
revoke all on function app.capture_referral_batch_v480() from public, anon, authenticated;
revoke all on function app.capture_referral_grant_v480() from public, anon, authenticated;

create trigger trg_referral_ledger_provenance_v480
after insert on public.points_ledger
for each row execute function app.capture_referral_ledger_v480();
create trigger trg_referral_batch_provenance_v480
after insert on public.points_batches
for each row execute function app.capture_referral_batch_v480();
create trigger trg_referral_grant_provenance_v480
after insert on public.referral_grants_v420
for each row execute function app.capture_referral_grant_v480();

insert into app.referral_value_provenance_v480(
  business_id,referral_id,qualifying_sale_id,beneficiary,client_id,benefit_kind,grant_id,created_at
)
select g.business_id,g.referral_id,r.qualified_sale_id,g.beneficiary,g.client_id,'voucher',g.id,g.granted_at
  from public.referral_grants_v420 g
  join public.referrals r on r.id=g.referral_id and r.business_id=g.business_id
 where r.qualified_sale_id is not null
on conflict (referral_id,qualifying_sale_id,beneficiary) do nothing;

create trigger trg_points_ledger_fence_v480
before insert or update or delete on public.points_ledger
for each row execute function app.require_loyalty_shared_v480();
create trigger trg_points_batches_fence_v480
before insert or update or delete on public.points_batches
for each row execute function app.require_loyalty_shared_v480();
create trigger trg_loyalty_redemptions_fence_v480
before insert or update or delete on public.loyalty_redemptions
for each row execute function app.require_loyalty_shared_v480();
create trigger trg_redemption_drains_fence_v480
before insert or update or delete on public.loyalty_redemption_batch_drains
for each row execute function app.require_loyalty_shared_v480();
create trigger trg_stamp_cycles_fence_v480
before insert or update or delete on public.stamp_cycles
for each row execute function app.require_loyalty_shared_v480();
create trigger trg_stamp_claims_fence_v480
before insert or update or delete on public.stamp_milestone_claims
for each row execute function app.require_loyalty_shared_v480();
create trigger trg_referral_grants_fence_v480
before insert or update or delete on public.referral_grants_v420
for each row execute function app.require_loyalty_shared_v480();

-- Preserve the installed definitions (including production hotfixes) and add
-- the fence at the first PL/pgSQL BEGIN.  Abort if a target is absent or the
-- expected single splice cannot be proven.
do $v480_patch$
declare
  r record;
  v_def text;
  v_new text;
begin
  for r in
    select * from (values
      ('public.adjust_points(uuid,uuid,integer,text)', 'shared', 'p_business'),
      ('app.redeem_points_v40_internal(uuid,uuid,text)', 'shared', 'p_business'),
      ('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)', 'shared', 'p_business'),
      ('app.run_points_expiry_for_business(uuid)', 'shared', 'p_business'),
      ('public.redeem_points(uuid,uuid)', 'shared', 'p_business'),
      ('public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)', 'shared', 'p_business'),
      ('public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)', 'shared', 'p_business'),
      ('public.staff_redeem_referral_v420(uuid,uuid,uuid,uuid)', 'shared', 'p_business'),
      ('app.stamp_expire_open_cycle_v435(uuid,uuid,uuid)', 'shared', 'p_business'),
      ('app.stamp_reward_expire_due_v464(uuid,uuid,uuid)', 'shared', 'p_business'),
      ('public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid)', 'exclusive', 'p_business'),
      ('app.migrate_programme_pot_v312(uuid,uuid,uuid,integer)', 'exclusive', 'p_business'),
      ('public.set_programmes_v314(uuid,jsonb,uuid)', 'exclusive', 'p_business'),
      ('public.business_set_earning_rule_v359(uuid,numeric,integer,text,integer,integer,integer)', 'exclusive', 'p_business'),
      ('public.business_set_loyalty_model_v353(uuid,text)', 'exclusive', 'p_business'),
      ('public.business_set_stamp_card_length_v414(uuid,integer)', 'exclusive', 'p_business'),
      ('public.business_set_tier_basis_v347(uuid,text)', 'exclusive', 'p_business'),
      ('public.save_referral_program(uuid,boolean,integer,integer)', 'exclusive', 'p_business'),
      ('public.save_referral_program_v322(uuid,boolean,integer,integer)', 'exclusive', 'p_business'),
      ('public.save_referral_program_v420(uuid,boolean,text,integer,text,integer)', 'exclusive', 'p_business'),
      ('public.save_referral_program_v421(uuid,boolean,text,integer,text,integer,boolean,integer,text)', 'exclusive', 'p_business')
    ) as x(signature, mode, business_expr)
  loop
    select pg_catalog.pg_get_functiondef(r.signature::regprocedure) into strict v_def;
    if v_def like '%acquire_loyalty_%_v480%' then
      raise exception 'v480 target already contains a fence: %', r.signature;
    end if;
    v_new := pg_catalog.regexp_replace(
      v_def,
      E'([[:space:]]begin[[:space:]]*\\n)',
      E'\\1  perform app.acquire_loyalty_' || r.mode || '_v480(' || r.business_expr || ');' || chr(10)
    );
    if v_new = v_def then
      raise exception 'v480 could not locate outer BEGIN in %', r.signature;
    end if;
    execute v_new;
  end loop;
end
$v480_patch$;

-- The sale trigger is invoked for every sale, including rows that cannot touch
-- loyalty.  Acquire only after its fail-fast no-loyalty branch, but before the
-- first configuration or balance read that can influence a loyalty write.
do $v480_patch$
declare v_def text; v_new text; v_needle text;
begin
  select pg_catalog.pg_get_functiondef('app.on_sale_recorded()'::regprocedure) into v_def;
  v_needle:='if new.reversal_of is not null or new.client_id is null or not(new.earns_points or new.counts_as_visit) then return new; end if;';
  v_new:=replace(v_def,v_needle,v_needle||chr(10)||'  perform app.acquire_loyalty_shared_v480(new.business_id);');
  if v_new=v_def then raise exception 'v480 could not fence the sale loyalty trigger'; end if;
  v_def:=v_new;
  v_new:=replace(v_def,
    $needle$insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
              values(v_earn_id,new.business_id,refrow.referrer_client_id,'earn',v_ref_points,null,'referral qualified: first visit completed',auth.uid(),v_ref_prog);$needle$,
    $replacement$insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id,referral_id,referral_beneficiary)
              values(v_earn_id,new.business_id,refrow.referrer_client_id,'earn',v_ref_points,null,'referral qualified: first visit completed',auth.uid(),v_ref_prog,refrow.id,'referrer');$replacement$);
  if v_new=v_def then raise exception 'v480 could not link referrer ledger provenance'; end if;
  v_def:=v_new;
  v_new:=replace(v_def,
    $needle$insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id)
              values(new.business_id,refrow.referrer_client_id,v_ref_points,v_ref_points,null,now(),v_expires,v_ref_prog);$needle$,
    $replacement$insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id,referral_id,referral_beneficiary)
              values(new.business_id,refrow.referrer_client_id,v_ref_points,v_ref_points,null,now(),v_expires,v_ref_prog,refrow.id,'referrer');$replacement$);
  if v_new=v_def then raise exception 'v480 could not link referrer batch provenance'; end if;
  v_def:=v_new;
  v_new:=replace(v_def,
    $needle$insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
                values(v_friend_earn_id,new.business_id,new.client_id,'earn',v_friend_points,null,'referral qualified: introduced by a friend',auth.uid(),v_ref_prog);$needle$,
    $replacement$insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id,referral_id,referral_beneficiary)
                values(v_friend_earn_id,new.business_id,new.client_id,'earn',v_friend_points,null,'referral qualified: introduced by a friend',auth.uid(),v_ref_prog,refrow.id,'friend');$replacement$);
  if v_new=v_def then raise exception 'v480 could not link friend ledger provenance'; end if;
  v_def:=v_new;
  v_new:=replace(v_def,
    $needle$insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id)
                values(new.business_id,new.client_id,v_friend_points,v_friend_points,null,now(),v_expires,v_ref_prog);$needle$,
    $replacement$insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id,referral_id,referral_beneficiary)
                values(new.business_id,new.client_id,v_friend_points,v_friend_points,null,now(),v_expires,v_ref_prog,refrow.id,'friend');$replacement$);
  if v_new=v_def then raise exception 'v480 could not link friend batch provenance'; end if;
  v_def:=v_new;
  v_needle:='on conflict (referral_id,beneficiary) do nothing';
  if (length(v_def)-length(replace(v_def,v_needle,'')))/length(v_needle)<>2 then
    raise exception 'v480 expected two legacy voucher conflict clauses';
  end if;
  v_new:=replace(v_def,v_needle,'');
  execute v_new;
end
$v480_patch$;

-- Voucher redemption uses the same client-before-grant order as sale reversal.
do $v480_patch$
declare v_def text; v_new text; v_needle text;
begin
  select pg_catalog.pg_get_functiondef('public.staff_redeem_referral_v420(uuid,uuid,uuid,uuid)'::regprocedure) into v_def;
  v_needle:='select * into v_grant from public.referral_grants_v420';
  v_new:=replace(v_def,v_needle,
    E'perform 1 from public.clients where id=p_client and business_id=p_business for update;\n  if not found then raise exception ''referral client does not belong to this business'' using errcode=''42501''; end if;\n\n  '||v_needle);
  if v_new=v_def then raise exception 'v480 could not install referral client/grant lock order'; end if;
  execute v_new;
end
$v480_patch$;

-- publish_loyalty_config resolves business from the version row.
do $v480_patch$
declare v_def text; v_new text;
begin
  select pg_catalog.pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure) into v_def;
  v_new := pg_catalog.regexp_replace(v_def, E'([[:space:]]begin[[:space:]]*\\n)',
    E'\\1  perform app.acquire_loyalty_exclusive_v480((select business_id from public.firm_config_versions where id = p_version));' || chr(10));
  if v_new = v_def then raise exception 'v480 could not fence publish_loyalty_config'; end if;
  execute v_new;
end
$v480_patch$;

-- The conversion entry point is fenced exclusively and remains disabled until
-- the post-deploy concurrency proof is accepted.
do $v480_patch$
declare v_def text; v_new text; v_needle text;
begin
  select pg_catalog.pg_get_functiondef('public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid)'::regprocedure) into v_def;
  v_needle := 'perform app.acquire_loyalty_exclusive_v480(p_business);';
  v_new := pg_catalog.replace(v_def, v_needle, v_needle || E'\n  if not (select conversions_enabled from app.loyalty_integrity_control_v480 where singleton) then\n    raise exception ''loyalty conversion is temporarily disabled'' using errcode = ''55000'';\n  end if;');
  if v_new = v_def then raise exception 'v480 could not install conversion disable gate'; end if;
  execute v_new;
end
$v480_patch$;

-- The amount-correction workflow already owns its exact source-sale points
-- compensation. Route its internal reversal through the renamed money/package/
-- discount base exactly once, and take the same staff-first row lock as every
-- other reversal before it locks the sale.
do $v480_patch$
declare v_def text; v_new text; v_needle text;
begin
  select pg_catalog.pg_get_functiondef('public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)'::regprocedure) into v_def;
  v_needle := 'perform app.acquire_loyalty_shared_v480(p_business);';
  v_new := pg_catalog.replace(v_def,v_needle,v_needle||chr(10)||'  perform app.lock_refund_staff_v480(p_business);');
  if v_new=v_def then raise exception 'v480 could not install correction staff-first lock'; end if;
  v_def:=v_new;
  if (length(v_def)-length(replace(v_def,'public.reverse_sale(','')))/length('public.reverse_sale(')<>1 then
    raise exception 'v480 expected one correction reversal call';
  end if;
  v_new:=replace(v_def,'public.reverse_sale(','public.reverse_sale_v480_base(');
  execute v_new;
end
$v480_patch$;

-- Conversion is allowed only from a conserved pre-state and must leave both
-- affected programme pots conserved per customer.  The exclusive fence makes
-- these checks stable for the whole transaction.
do $v480_patch$
declare v_def text; v_new text;
begin
  select pg_catalog.pg_get_functiondef('public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid)'::regprocedure) into v_def;
  v_new:=replace(v_def,
    E'  v_switch := public.set_programmes_v314(',
    E'  if exists (\n    select 1 from\n      (select client_id,sum(points)::integer total from public.points_ledger where business_id=p_business and programme_id=v_points_programme group by client_id) l\n      full join\n      (select client_id,sum(remaining)::integer total from public.points_batches where business_id=p_business and programme_id=v_points_programme group by client_id) b\n      using(client_id)\n     where coalesce(l.total,0)<>coalesce(b.total,0)\n  ) then raise exception ''points conversion pre-state is not conserved'' using errcode=''XX001''; end if;\n\n  v_switch := public.set_programmes_v314(');
  if v_new=v_def then raise exception 'v480 could not add conversion pre-state conservation'; end if;
  v_def:=v_new;
  v_new:=replace(v_def,
    E'  if found then\n    return v_existing;\n  end if;',
    E'  if found then\n    if not coalesce(p_convert_existing_points,false)\n       or v_rate is distinct from (select points_per_stamp from public.programme_stamp_conversions_v384 where business_id=p_business and idempotency_key=p_idempotency_key) then\n      raise exception ''conversion idempotency key conflicts with a changed request'' using errcode=''23505'';\n    end if;\n    return v_existing;\n  end if;');
  if v_new=v_def then raise exception 'v480 could not harden conversion idempotency replay'; end if;
  v_def:=v_new;
  v_new:=replace(v_def,
    E'  v_response := jsonb_build_object(',
    E'  if exists (\n    select 1 from\n      (select client_id,programme_id,sum(points)::integer total from public.points_ledger where business_id=p_business and programme_id in (v_points_programme,v_stamps_programme) group by client_id,programme_id) l\n      full join\n      (select client_id,programme_id,sum(remaining)::integer total from public.points_batches where business_id=p_business and programme_id in (v_points_programme,v_stamps_programme) group by client_id,programme_id) b\n      using(client_id,programme_id)\n     where coalesce(l.total,0)<>coalesce(b.total,0)\n  ) then raise exception ''points conversion post-state is not conserved'' using errcode=''XX001''; end if;\n\n  v_response := jsonb_build_object(');
  if v_new=v_def then raise exception 'v480 could not add conversion post-state conservation'; end if;
  execute v_new;
end
$v480_patch$;

-- Every negative drain must reconcile to zero before its ledger debit commits.
do $v480_conservation$
declare r record; v_def text; v_new text;
begin
  for r in select * from (values
    ('public.adjust_points(uuid,uuid,integer,text)', E'points adjustment batch drain was incomplete',
      E'if (select coalesce(sum(pb.remaining),0)::integer from public.points_batches pb where pb.business_id=p_business and pb.client_id=p_client and pb.programme_id=v_points_programme) <> v_batch_balance+p_points then raise exception ''points adjustment batch delta does not reconcile'' using errcode=''XX001''; end if;'),
    ('app.redeem_points_v40_internal(uuid,uuid,text)', E'points redemption batch drain was incomplete',
      E'if (select coalesce(sum(pb.remaining),0)::integer from public.points_batches pb where pb.business_id=p_business and pb.client_id=p_client and pb.programme_id=v_points_programme) <> v_batch_balance-lp.redeem_points then raise exception ''points redemption batch delta does not reconcile'' using errcode=''XX001''; end if;'),
    ('public.redeem_points(uuid,uuid)', E'legacy points redemption batch drain was incomplete',
      E'if (select coalesce(sum(pb.remaining),0)::integer from public.points_batches pb where pb.business_id=p_business and pb.client_id=p_client and pb.programme_id=v_points_programme) <> v_batch_balance-lp.redeem_points then raise exception ''legacy points redemption batch delta does not reconcile'' using errcode=''XX001''; end if;')
  ) x(signature, message, reconcile_sql)
  loop
    select pg_catalog.pg_get_functiondef(r.signature::regprocedure) into v_def;
    v_new := pg_catalog.regexp_replace(v_def,
      E'([[:space:]]end loop;[[:space:]]*\\n)',
      E'\\1  if v_remaining <> 0 then raise exception ''' || r.message || E''' using errcode = ''XX001''; end if;' || chr(10) || '  ' || r.reconcile_sql || chr(10));
    if v_new = v_def then raise exception 'v480 could not add conservation assertion to %', r.signature; end if;
    execute v_new;
  end loop;

  select pg_catalog.pg_get_functiondef('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure) into v_def;
  v_new := pg_catalog.replace(v_def,
    E'  end loop;\n  perform set_config(''app.points_ledger_insert_id''',
    E'  end loop;\n  if v_remaining <> 0 then raise exception ''reward batch drain was incomplete'' using errcode = ''XX001''; end if;\n  if (select coalesce(sum(remaining),0)::integer from public.points_batches where business_id=p_business and client_id=p_client and programme_id=v_reward_programme) <> v_batch_balance-v_version.cost_points then raise exception ''reward batch delta does not reconcile'' using errcode=''XX001''; end if;\n  if (select coalesce(sum(drained_points),0) from public.loyalty_redemption_batch_drains where provenance_id=v_provenance_id) <> v_version.cost_points then raise exception ''reward drain provenance does not conserve value'' using errcode = ''XX001''; end if;\n  perform set_config(''app.points_ledger_insert_id''');
  if v_new = v_def then raise exception 'v480 could not add reward conservation assertions'; end if;
  execute v_new;
end
$v480_conservation$;

create table app.loyalty_adjustment_operations_v480 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  idempotency_key uuid not null,
  actor uuid not null,
  request_payload jsonb not null,
  request_hash text not null,
  status text not null default 'pending' check (status in ('pending','completed')),
  result jsonb,
  created_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  unique (business_id, idempotency_key)
);
revoke all on app.loyalty_adjustment_operations_v480 from public, anon, authenticated;

create or replace function public.adjust_points_v480(
  p_business uuid, p_client uuid, p_points integer, p_reason text, p_idempotency_key uuid
) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_payload jsonb;
  v_hash text;
  v_op app.loyalty_adjustment_operations_v480%rowtype;
  v_balance integer;
  v_result jsonb;
begin
  if p_idempotency_key is null then raise exception 'idempotency key is required' using errcode='22023'; end if;
  perform app.acquire_loyalty_shared_v480(p_business);
  v_payload := jsonb_build_object('client_id',p_client,'points',p_points,'reason',btrim(p_reason));
  v_hash := encode(extensions.digest(convert_to(v_payload::text,'UTF8'), 'sha256'), 'hex');
  insert into app.loyalty_adjustment_operations_v480(
    business_id,idempotency_key,actor,request_payload,request_hash
  ) values (p_business,p_idempotency_key,v_actor,v_payload,v_hash)
  on conflict (business_id,idempotency_key) do nothing;
  select * into strict v_op from app.loyalty_adjustment_operations_v480
   where business_id=p_business and idempotency_key=p_idempotency_key for update;
  if v_op.actor is distinct from v_actor or v_op.request_hash is distinct from v_hash then
    raise exception 'adjustment idempotency key conflicts with a changed request' using errcode='23505';
  end if;
  if v_op.status='completed' then return v_op.result || jsonb_build_object('replayed',true); end if;
  v_balance := public.adjust_points(p_business,p_client,p_points,p_reason);
  v_result := jsonb_build_object('balance',v_balance,'replayed',false,'operation_id',v_op.id);
  update app.loyalty_adjustment_operations_v480
     set status='completed',result=v_result,completed_at=statement_timestamp()
   where id=v_op.id;
  return v_result;
end
$$;
revoke all on function public.adjust_points_v480(uuid,uuid,integer,text,uuid) from public, anon;
grant execute on function public.adjust_points_v480(uuid,uuid,integer,text,uuid) to authenticated;
grant execute on function public.adjust_points_v480(uuid,uuid,integer,text,uuid) to service_role;

-- Add the dedicated, sale-linked negative adjustment route to the existing
-- immutable-ledger guard without replacing production-hotfixed logic.
do $v480_guard$
declare v_def text; v_new text;
begin
  select pg_catalog.pg_get_functiondef('app.loyalty_ledger_write_guard()'::regprocedure) into v_def;
  v_new := pg_catalog.replace(v_def,
    E'''referral_reward_points'') then',
    E'''referral_reward_points'',''sale_loyalty_clawback_v480'') then');
  if v_new=v_def then raise exception 'v480 could not extend loyalty ledger scope allowlist'; end if;
  v_def := v_new;
  v_new := pg_catalog.replace(v_def,
    $needle$or (v_scope='referral_reward_points'$needle$,
    $replacement$or (v_scope='sale_loyalty_clawback_v480'
           and (new.entry_type<>'adjust' or new.points>=0 or new.sale_id is null
                or new.actor is distinct from auth.uid()))
        or (v_scope='referral_reward_points'$replacement$);
  if v_new=v_def then raise exception 'v480 could not add loyalty clawback shape rule'; end if;
  v_def:=v_new;
  v_new:=pg_catalog.replace(v_def,
    $needle$or (v_scope='referral_reward_points'
          and (new.entry_type<>'earn' or new.points<=0 or new.sale_id is not null
               or new.programme_id is null))$needle$,
    $replacement$or (v_scope='referral_reward_points'
          and (new.entry_type<>'earn' or new.points<=0 or new.sale_id is not null
               or new.programme_id is null or new.referral_id is null
               or new.referral_beneficiary not in ('referrer','friend')))$replacement$);
  if v_new=v_def then raise exception 'v480 could not require exact referral provenance'; end if;
  execute v_new;
end
$v480_guard$;

create table app.sale_loyalty_reversal_operations_v480 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  idempotency_key text not null,
  actor uuid not null,
  request_payload jsonb not null,
  request_hash text not null,
  status text not null default 'pending' check (status in ('pending','completed')),
  result jsonb,
  created_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  unique (business_id,idempotency_key)
);
create table public.sale_loyalty_reversal_evidence_v480 (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null unique references app.sale_loyalty_reversal_operations_v480(id) on delete restrict,
  business_id uuid not null,
  original_sale_id uuid not null,
  reversal_sale_id uuid not null,
  client_id uuid,
  source_earned integer not null check (source_earned>=0),
  source_available integer not null check (source_available>=0),
  clawed_back integer not null check (clawed_back>=0),
  accepted_shortfall integer not null check (accepted_shortfall>=0),
  referral_id uuid references public.referrals(id) on delete restrict,
  referral_value_earned integer not null default 0 check (referral_value_earned>=0),
  referral_value_available integer not null default 0 check (referral_value_available>=0),
  referral_value_shortfall integer not null default 0 check (referral_value_shortfall>=0),
  referral_grants_issued integer not null default 0 check (referral_grants_issued>=0),
  referral_grants_reversed integer not null default 0 check (referral_grants_reversed>=0),
  referral_grants_shortfall integer not null default 0 check (referral_grants_shortfall>=0),
  override_accepted boolean not null,
  actor uuid not null,
  created_at timestamptz not null default statement_timestamp(),
  foreign key (original_sale_id,business_id) references public.sales(id,business_id),
  foreign key (reversal_sale_id,business_id) references public.sales(id,business_id)
);
alter table public.sale_loyalty_reversal_evidence_v480 enable row level security;
create policy sale_loyalty_reversal_evidence_owner_v480
on public.sale_loyalty_reversal_evidence_v480 for select to authenticated
using (app.has_perm(business_id,'refund_sales'));
create trigger trg_sale_loyalty_evidence_immutable_v480
before update or delete on public.sale_loyalty_reversal_evidence_v480
for each row execute function app.forbid_mutation();
revoke all on app.sale_loyalty_reversal_operations_v480 from public, anon, authenticated;
revoke insert, update, delete on public.sale_loyalty_reversal_evidence_v480 from public, anon, authenticated;
grant select on public.sale_loyalty_reversal_evidence_v480 to authenticated;

alter function public.reverse_sale(uuid,uuid,text,text,text,text)
rename to reverse_sale_v480_base;
revoke all on function public.reverse_sale_v480_base(uuid,uuid,text,text,text,text)
  from public, anon, authenticated, service_role;
revoke all on function public.reverse_sale_v40_base(uuid,uuid,text,text,text,text)
  from public, anon, authenticated, service_role;
revoke all on function public.reverse_sale_v34_base(uuid,uuid,text,text,text,text)
  from public, anon, authenticated, service_role;
revoke all on function public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)
  from public, anon, authenticated, service_role;

-- Owner-directed staged compatibility: the old four-argument adjustment route
-- remains authenticated-only for stale bundles during the bounded transition.
-- It is fenced and conserving immediately; current bundles use v480 idempotency.
revoke all on function public.adjust_points(uuid,uuid,integer,text) from public, anon;
grant execute on function public.adjust_points(uuid,uuid,integer,text) to authenticated;
grant execute on function public.adjust_points(uuid,uuid,integer,text) to service_role;
revoke all on function public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text) from public, anon;
grant execute on function public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text) to authenticated;
grant execute on function public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text) to service_role;
revoke all on function public.reverse_sale_fast_v84(uuid,uuid,text,text) from public, anon;
grant execute on function public.reverse_sale_fast_v84(uuid,uuid,text,text) to authenticated;
grant execute on function public.reverse_sale_fast_v84(uuid,uuid,text,text) to service_role;

create or replace function app.reverse_sale_with_loyalty_v480(
  p_business uuid, p_sale uuid, p_reason text, p_idempotency_key text,
  p_reference text, p_restock_policy text, p_accept_shortfall boolean
) returns json
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_payload jsonb;
  v_hash text;
  v_op app.sale_loyalty_reversal_operations_v480%rowtype;
  v_result json;
  v_reversal uuid;
  v_client uuid;
  v_earned integer := 0;
  v_available integer := 0;
  v_shortfall integer := 0;
  v_referral public.referrals%rowtype;
  v_referral_count integer := 0;
  v_referral_earned integer := 0;
  v_referral_available integer := 0;
  v_referral_shortfall integer := 0;
  v_referral_grants integer := 0;
  v_referral_grants_reversed integer := 0;
  v_referral_grants_shortfall integer := 0;
  v_programme record;
  v_ledger_id uuid;
begin
  if nullif(btrim(p_idempotency_key),'') is null then raise exception 'idempotency key is required' using errcode='22023'; end if;
  perform app.acquire_loyalty_shared_v480(p_business);
  perform app.lock_refund_staff_v480(p_business);
  if p_accept_shortfall and not exists (
    select 1 from public.staff where business_id=p_business and user_id=v_actor and active and role='owner'
  ) then raise exception 'only an active owner may accept a loyalty shortfall' using errcode='42501'; end if;
  v_payload := jsonb_build_object('sale_id',p_sale,'reason',btrim(p_reason),'reference',coalesce(p_reference,''),
    'restock_policy',coalesce(p_restock_policy,'none'),'accept_shortfall',p_accept_shortfall);
  v_hash := encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');
  insert into app.sale_loyalty_reversal_operations_v480(
    business_id,idempotency_key,actor,request_payload,request_hash
  ) values (p_business,btrim(p_idempotency_key),v_actor,v_payload,v_hash)
  on conflict (business_id,idempotency_key) do nothing;
  select * into strict v_op from app.sale_loyalty_reversal_operations_v480
   where business_id=p_business and idempotency_key=btrim(p_idempotency_key) for update;
  if v_op.actor is distinct from v_actor or v_op.request_hash is distinct from v_hash then
    raise exception 'sale reversal idempotency key conflicts with a changed request' using errcode='23505';
  end if;
  if v_op.status='completed' then return (v_op.result || jsonb_build_object('replayed',true))::json; end if;

  select client_id into v_client from public.sales
   where id=p_sale and business_id=p_business for update;
  if not found then raise exception 'sale not found in this business' using errcode='42501'; end if;

  select count(*)::integer into v_referral_count from public.referrals
   where business_id=p_business and qualified_sale_id=p_sale and status='rewarded';
  if v_referral_count>1 then
    raise exception 'qualifying sale has multiple rewarded referrals' using errcode='XX001';
  end if;
  select * into v_referral from public.referrals
   where business_id=p_business and qualified_sale_id=p_sale and status='rewarded'
   for update;

  -- All customer rows are locked in UUID order before any grant or FEFO batch.
  -- This matches redemption's customer-before-batch order and prevents the
  -- two-sided referral from creating a client-order inversion.
  perform 1 from public.clients c
   where c.business_id=p_business and c.id in (
     select v_client where v_client is not null
     union select p.client_id from app.referral_value_provenance_v480 p
       where p.business_id=p_business and p.qualifying_sale_id=p_sale
     union select v_referral.referrer_client_id where v_referral.id is not null
     union select v_referral.referred_client_id where v_referral.id is not null
   ) order by c.id for update;

  perform 1 from app.referral_value_provenance_v480 p
   where p.business_id=p_business and p.qualifying_sale_id=p_sale
   order by p.client_id,p.beneficiary,p.id for update;

  -- Existing points/stamps referrals predate exact payout provenance.  Guessing
  -- from current programme settings would be accounting corruption, so those
  -- reversals remain blocked until an explicit reconciliation records the exact
  -- ledger and batch children.
  if v_referral.id is not null and coalesce(v_referral.reward_points,0)>0
     and not exists (
       select 1 from app.referral_value_provenance_v480 p
        where p.referral_id=v_referral.id and p.qualifying_sale_id=p_sale
          and p.benefit_kind in ('points','stamps')
     ) then
    raise exception 'historical referral loyalty provenance requires reconciliation before reversal'
      using errcode='55000';
  end if;
  if exists (
    select 1 from app.referral_value_provenance_v480 p
    left join public.points_ledger l on l.id=p.ledger_id
    left join public.points_batches b on b.id=p.batch_id
    where p.business_id=p_business and p.qualifying_sale_id=p_sale
      and p.benefit_kind in ('points','stamps')
      and (p.batch_id is null or l.id is null or b.id is null
        or (l.business_id,l.client_id,l.programme_id,l.sale_id,l.entry_type,l.points,
            l.referral_id,l.referral_beneficiary)
           is distinct from (p.business_id,p.client_id,p.programme_id,null::uuid,'earn'::text,p.amount,
                             p.referral_id,p.beneficiary)
        or (b.business_id,b.client_id,b.programme_id,b.sale_id,b.earned,
            b.referral_id,b.referral_beneficiary)
           is distinct from (p.business_id,p.client_id,p.programme_id,null::uuid,p.amount,
                             p.referral_id,p.beneficiary))
  ) then raise exception 'referral loyalty provenance is incomplete or inconsistent' using errcode='XX001'; end if;
  if (select count(*) from public.points_ledger l
       where l.business_id=p_business and l.entry_type='earn'
         and l.id in (select p.ledger_id from app.referral_value_provenance_v480 p
           where p.business_id=p_business and p.qualifying_sale_id=p_sale
             and p.ledger_id is not null))
     <> (select count(*) from app.referral_value_provenance_v480 p
          where p.business_id=p_business and p.qualifying_sale_id=p_sale
            and p.benefit_kind in ('points','stamps')) then
    raise exception 'referral loyalty children are not fully classified' using errcode='XX001';
  end if;

  perform 1 from public.referral_grants_v420 g
   join app.referral_value_provenance_v480 p on p.grant_id=g.id
   where p.business_id=p_business and p.qualifying_sale_id=p_sale
   order by g.client_id,g.id for update of g;
  if exists (
    select 1 from app.referral_value_provenance_v480 p
    left join public.referral_grants_v420 g on g.id=p.grant_id
    where p.business_id=p_business and p.qualifying_sale_id=p_sale and p.benefit_kind='voucher'
      and (g.id is null or (g.business_id,g.client_id,g.referral_id,g.beneficiary)
         is distinct from (p.business_id,p.client_id,p.referral_id,p.beneficiary))
  ) then raise exception 'referral voucher provenance is incomplete or inconsistent' using errcode='XX001'; end if;

  perform 1 from public.points_batches
   where business_id=p_business and (
     sale_id=p_sale or id in (select batch_id from app.referral_value_provenance_v480
       where business_id=p_business and qualifying_sale_id=p_sale and batch_id is not null)
   ) order by client_id,programme_id,id for update;
  select coalesce(sum(earned),0)::integer,coalesce(sum(remaining),0)::integer
    into v_earned,v_available from public.points_batches
   where business_id=p_business and (
     sale_id=p_sale or id in (select batch_id from app.referral_value_provenance_v480
       where business_id=p_business and qualifying_sale_id=p_sale and batch_id is not null)
   );
  if v_earned<0 or v_available<0 or v_available>v_earned then
    raise exception 'sale loyalty source batches violate earned/remaining bounds' using errcode='XX001';
  end if;
  if v_earned <> coalesce((select sum(points)::integer from public.points_ledger
     where business_id=p_business and entry_type='earn' and (
       sale_id=p_sale or id in (select ledger_id from app.referral_value_provenance_v480
         where business_id=p_business and qualifying_sale_id=p_sale and ledger_id is not null)
     )),0) then
    raise exception 'sale loyalty provenance is inconsistent' using errcode='XX001';
  end if;
  if exists (
    select 1 from
      (select client_id,programme_id,sum(earned)::integer total from public.points_batches
        where business_id=p_business and (
          sale_id=p_sale or id in (select batch_id from app.referral_value_provenance_v480
            where business_id=p_business and qualifying_sale_id=p_sale and batch_id is not null)
        ) group by client_id,programme_id) b
      full join
      (select client_id,programme_id,sum(points)::integer total from public.points_ledger
        where business_id=p_business and entry_type='earn' and (
          sale_id=p_sale or id in (select ledger_id from app.referral_value_provenance_v480
            where business_id=p_business and qualifying_sale_id=p_sale and ledger_id is not null)
        ) group by client_id,programme_id) l
      using(client_id,programme_id) where coalesce(b.total,0)<>coalesce(l.total,0)
  ) then raise exception 'sale loyalty customer/programme provenance is inconsistent' using errcode='XX001'; end if;
  select coalesce(sum(p.amount),0)::integer,coalesce(sum(b.remaining),0)::integer
    into v_referral_earned,v_referral_available
    from app.referral_value_provenance_v480 p
    join public.points_batches b on b.id=p.batch_id
   where p.business_id=p_business and p.qualifying_sale_id=p_sale
     and p.benefit_kind in ('points','stamps');
  v_referral_shortfall:=v_referral_earned-v_referral_available;
  select count(*)::integer,count(*) filter(where g.status='redeemed')::integer
    into v_referral_grants,v_referral_grants_shortfall
    from app.referral_value_provenance_v480 p
    join public.referral_grants_v420 g on g.id=p.grant_id
   where p.business_id=p_business and p.qualifying_sale_id=p_sale and p.benefit_kind='voucher';
  v_shortfall := v_earned-v_available;
  if (v_shortfall>0 or v_referral_grants_shortfall>0) and not p_accept_shortfall then
    raise exception 'loyalty_already_spent: % source-sale units and % referral grants are unavailable; owner override required',v_shortfall,v_referral_grants_shortfall
      using errcode='55000';
  end if;

  v_result := public.reverse_sale_v480_base(p_business,p_sale,p_reason,p_idempotency_key,p_reference,p_restock_policy);
  v_reversal := nullif(v_result->>'reversal_sale_id','')::uuid;
  if v_reversal is null then raise exception 'sale reversal returned no reversal sale' using errcode='XX001'; end if;
  for v_programme in
    select client_id,programme_id,sum(remaining)::integer as amount from public.points_batches
     where business_id=p_business and (
       sale_id=p_sale or id in (select batch_id from app.referral_value_provenance_v480
         where business_id=p_business and qualifying_sale_id=p_sale and batch_id is not null)
     ) group by client_id,programme_id having sum(remaining)>0
  loop
    v_ledger_id := gen_random_uuid();
    perform set_config('app.points_ledger_insert_id',v_ledger_id::text,true);
    perform set_config('app.points_ledger_write_scope','sale_loyalty_clawback_v480',true);
    insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
    values(v_ledger_id,p_business,v_programme.client_id,'adjust',-v_programme.amount,v_reversal,
      'sale reversal loyalty clawback: '||p_sale,v_actor,v_programme.programme_id);
    perform set_config('app.points_ledger_insert_id','',true);
    perform set_config('app.points_ledger_write_scope','',true);
  end loop;
  update public.points_batches set remaining=0
   where business_id=p_business and remaining>0 and (
     sale_id=p_sale or id in (select batch_id from app.referral_value_provenance_v480
       where business_id=p_business and qualifying_sale_id=p_sale and batch_id is not null)
   );
  update public.referral_grants_v420 g set status='reversed'
    from app.referral_value_provenance_v480 p
   where p.grant_id=g.id and p.business_id=p_business and p.qualifying_sale_id=p_sale
     and g.status in ('granted','expired');
  get diagnostics v_referral_grants_reversed=row_count;
  -- Compensation is complete.  Return only this still-matching qualification
  -- to pending so a later legitimate sale may qualify it again.  The operation
  -- row makes an exact replay return before this state transition.
  if v_referral.id is not null then
    update public.referrals
       set status='pending',qualified_at=null,qualified_sale_id=null,
           reward_cents=0,reward_points=0,blocked_reason=null
     where id=v_referral.id and business_id=p_business
       and status='rewarded' and qualified_sale_id=p_sale;
    if not found and not (
      coalesce(v_referral.reward_cents,0)>0 and exists (
        select 1 from public.referrals r
         where r.id=v_referral.id and r.business_id=p_business
           and r.status='pending' and r.qualified_at is null
           and r.qualified_sale_id is null and r.reward_cents=0
           and coalesce(r.reward_points,0)=0
      )
    ) then
      raise exception 'matching referral qualification was not reset after compensation'
        using errcode='XX001';
    end if;
  end if;
  if exists (
    select 1 from (
      select client_id,programme_id,sum(points)::integer as total from public.points_ledger
       where business_id=p_business and client_id in (
         select client_id from public.points_ledger where business_id=p_business and entry_type='earn'
           and (sale_id=p_sale or referral_id=v_referral.id)
       ) group by client_id,programme_id
    ) l full join (
      select client_id,programme_id,sum(remaining)::integer as total from public.points_batches
       where business_id=p_business and client_id in (
         select client_id from public.points_ledger where business_id=p_business and entry_type='earn'
           and (sale_id=p_sale or referral_id=v_referral.id)
       ) group by client_id,programme_id
    ) b using(client_id,programme_id) where coalesce(l.total,0)<>coalesce(b.total,0)
  ) then raise exception 'sale reversal left loyalty ledger and batches inconsistent' using errcode='XX001'; end if;
  insert into public.sale_loyalty_reversal_evidence_v480(
    operation_id,business_id,original_sale_id,reversal_sale_id,client_id,source_earned,
    source_available,clawed_back,accepted_shortfall,referral_id,referral_value_earned,
    referral_value_available,referral_value_shortfall,referral_grants_issued,
    referral_grants_reversed,referral_grants_shortfall,override_accepted,actor
  ) values(v_op.id,p_business,p_sale,v_reversal,v_client,v_earned,v_available,v_available,
    v_shortfall,v_referral.id,v_referral_earned,v_referral_available,v_referral_shortfall,
    v_referral_grants,v_referral_grants_reversed,v_referral_grants_shortfall,p_accept_shortfall,v_actor);
  v_result := (v_result::jsonb || jsonb_build_object('loyalty_clawed_back',v_available,
    'loyalty_shortfall',v_shortfall,'referral_loyalty_clawed_back',v_referral_available,
    'referral_loyalty_shortfall',v_referral_shortfall,
    'referral_grants_reversed',v_referral_grants_reversed,
    'referral_grants_shortfall',v_referral_grants_shortfall,
    'loyalty_shortfall_accepted',p_accept_shortfall))::json;
  update app.sale_loyalty_reversal_operations_v480
     set status='completed',result=v_result::jsonb,completed_at=statement_timestamp() where id=v_op.id;
  return v_result;
end
$$;
revoke all on function app.reverse_sale_with_loyalty_v480(uuid,uuid,text,text,text,text,boolean) from public, anon, authenticated;

create or replace function public.reverse_sale(
  p_business uuid, p_sale uuid, p_reason text, p_idempotency_key text,
  p_reference text default null, p_restock_policy text default 'none'
) returns json language sql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$ select app.reverse_sale_with_loyalty_v480($1,$2,$3,$4,$5,$6,false) $$;
create or replace function public.reverse_sale_accept_loyalty_shortfall_v480(
  p_business uuid, p_sale uuid, p_reason text, p_idempotency_key text,
  p_reference text default null, p_restock_policy text default 'none'
) returns json language sql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$ select app.reverse_sale_with_loyalty_v480($1,$2,$3,$4,$5,$6,true) $$;
create or replace function public.reverse_sale_fast_accept_loyalty_shortfall_v480(
  p_business uuid, p_sale uuid, p_note text, p_idempotency_key text
) returns json language sql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select app.reverse_sale_with_loyalty_v480(
    p_business,p_sale,
    case when nullif(btrim(p_note),'') is null then 'Staff-confirmed sale reversal'
         else 'Staff note: '||btrim(p_note) end,
    p_idempotency_key,'Peekaa quick reversal','none',true
  )
$$;
revoke all on function public.reverse_sale(uuid,uuid,text,text,text,text) from public, anon;
revoke all on function public.reverse_sale_accept_loyalty_shortfall_v480(uuid,uuid,text,text,text,text) from public, anon;
revoke all on function public.reverse_sale_fast_accept_loyalty_shortfall_v480(uuid,uuid,text,text) from public, anon;
grant execute on function public.reverse_sale(uuid,uuid,text,text,text,text) to authenticated;
grant execute on function public.reverse_sale(uuid,uuid,text,text,text,text) to service_role;
grant execute on function public.reverse_sale_accept_loyalty_shortfall_v480(uuid,uuid,text,text,text,text) to authenticated;
grant execute on function public.reverse_sale_accept_loyalty_shortfall_v480(uuid,uuid,text,text,text,text) to service_role;
grant execute on function public.reverse_sale_fast_accept_loyalty_shortfall_v480(uuid,uuid,text,text) to authenticated;
grant execute on function public.reverse_sale_fast_accept_loyalty_shortfall_v480(uuid,uuid,text,text) to service_role;

-- Migration postcondition: conversion cannot accidentally be enabled here.
do $$ begin
  if (select conversions_enabled from app.loyalty_integrity_control_v480 where singleton) then
    raise exception 'v480 must finish with conversion disabled';
  end if;
  if has_function_privilege('anon','public.reverse_sale_v480_base(uuid,uuid,text,text,text,text)','execute')
     or has_function_privilege('authenticated','public.reverse_sale_v480_base(uuid,uuid,text,text,text,text)','execute')
     or has_function_privilege('service_role','public.reverse_sale_v480_base(uuid,uuid,text,text,text,text)','execute')
     or has_function_privilege('authenticated','public.reverse_sale_v40_base(uuid,uuid,text,text,text,text)','execute')
     or has_function_privilege('authenticated','public.reverse_sale_v34_base(uuid,uuid,text,text,text,text)','execute')
     or has_function_privilege('authenticated','public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)','execute') then
    raise exception 'v480 reversal base ACL closure is incomplete';
  end if;
  if has_function_privilege('anon','public.adjust_points(uuid,uuid,integer,text)','execute')
     or not has_function_privilege('authenticated','public.adjust_points(uuid,uuid,integer,text)','execute') then
    raise exception 'v480 staged adjustment compatibility ACL is wrong';
  end if;
end $$;

commit;

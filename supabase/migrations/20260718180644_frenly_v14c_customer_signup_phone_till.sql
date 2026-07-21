-- ============================================================================
-- v14c: public customer sign-up (QR + link) and the 8-digit phone till flow
-- ============================================================================

alter table public.businesses add column if not exists join_enabled boolean not null default true;

-- Idempotency for the till. Two taps on "Confirm" must never earn points twice.
alter table public.sales add column if not exists idem_key text;
create unique index if not exists sales_business_idem_uidx
  on public.sales (business_id, idem_key) where idem_key is not null;

-- ---------- 1. PUBLIC SIGN-UP (anon) ----------
-- Reachable by an unauthenticated customer who scanned the QR / opened the link.
-- Returns a deliberately uniform payload whether the number was new or already a
-- member: any difference would turn this form into an oracle for "is 8xxxxxxx a
-- customer of this shop", which is exactly the PDPA leak we must not ship.
create or replace function public.join_program(
  p_slug text, p_name text, p_phone text,
  p_email text default null, p_consent boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare v_biz uuid; v_biz_name text; v_norm text; v_client uuid;
begin
  select id, name into v_biz, v_biz_name
    from public.businesses where slug = p_slug and join_enabled;
  if v_biz is null then raise exception 'This sign-up link is not active.'; end if;

  if p_name is null or length(trim(p_name)) < 2 then
    raise exception 'Please enter your name.';
  end if;
  if length(trim(p_name)) > 80 then raise exception 'Name is too long.'; end if;

  v_norm := app.norm_phone(p_phone);
  if v_norm is null then
    raise exception 'Please enter a valid 8-digit Singapore mobile number.';
  end if;

  insert into public.clients (business_id, full_name, phone, email, marketing_consent)
  values (v_biz, trim(p_name), v_norm,
          nullif(trim(coalesce(p_email,'')), ''), coalesce(p_consent, false))
  on conflict (business_id, phone_norm) where phone_norm is not null do nothing
  returning id into v_client;

  if v_client is not null then
    -- PDPA: record the consent decision at the moment it was made, with its source.
    insert into public.consents (business_id, client_id, channel, action, source)
    values (v_biz, v_client, 'marketing',
            case when coalesce(p_consent,false) then 'granted' else 'withdrawn' end,
            'self_signup');
    insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
    values (v_biz, null, 'CUSTOMER_SELF_SIGNUP', 'clients', v_client,
            json_build_object('source','qr_or_link','consent',coalesce(p_consent,false))::jsonb);
  end if;

  return json_build_object('status','ok','business_name', v_biz_name);
end $$;
revoke all on function public.join_program(text,text,text,text,boolean) from public;
grant execute on function public.join_program(text,text,text,text,boolean) to anon, authenticated;

-- Minimal public shopfront for the join page: name + colour only. No service list,
-- no counts, nothing a competitor could scrape.
create or replace function public.get_join_page(p_slug text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('name', b.name, 'brand_color', b.brand_color, 'slug', b.slug)
  from public.businesses b where b.slug = p_slug and b.join_enabled;
$$;
revoke all on function public.get_join_page(text) from public;
grant execute on function public.get_join_page(text) to anon, authenticated;

-- ---------- 2. TILL: LOOK UP BY 8-DIGIT NUMBER ----------
-- Cashier types 81863833 -> this returns who it is + their loyalty standing, so the
-- screen can show the customer and a Confirm button. Gated on create_sales, which is
-- the permission the till actually needs (a frontdesk/staff user has it; a
-- module-restricted employee still needs the clients module to see the name).
create or replace function public.lookup_client_by_phone(p_business uuid, p_phone text)
returns json language plpgsql stable security definer set search_path = public as $$
declare v_norm text; c public.clients; lp record;
        v_points integer; v_credit integer; v_visits integer;
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'not allowed to take sales for this business';
  end if;
  v_norm := app.norm_phone(p_phone);
  if v_norm is null then
    return json_build_object('status','invalid',
      'message','Enter the customer''s 8-digit mobile number.');
  end if;

  select * into c from public.clients
   where business_id = p_business and phone_norm = v_norm;
  if not found then
    return json_build_object('status','not_found','phone', v_norm);
  end if;

  select coalesce(sum(points),0) into v_points
    from public.points_ledger where business_id = p_business and client_id = c.id;
  select coalesce(sum(amount_cents),0) into v_credit
    from public.credit_ledger where business_id = p_business and client_id = c.id;
  select count(*) into v_visits
    from public.sales where business_id = p_business and client_id = c.id and counts_as_visit;
  select * into lp from public.loyalty_programs
   where business_id = p_business and active limit 1;

  return json_build_object(
    'status','found',
    'client_id', c.id, 'full_name', c.full_name, 'phone', c.phone_norm,
    'points', v_points, 'credit_cents', v_credit, 'visits', v_visits,
    'redeem_points', lp.redeem_points, 'reward_credit_cents', lp.reward_credit_cents,
    'can_redeem', (lp.redeem_points is not null and v_points >= lp.redeem_points),
    'points_to_next', greatest(coalesce(lp.redeem_points,0) - v_points, 0),
    'member_since', c.created_at);
end $$;
revoke all on function public.lookup_client_by_phone(uuid, text) from public, anon;
grant execute on function public.lookup_client_by_phone(uuid, text) to authenticated;

-- ---------- 3. TILL: CONFIRM THE SALE ----------
-- Staff presses Confirm -> one sales row -> the existing v10 policy triggers decide
-- revenue/visit/points, and on_sale_recorded does the earning. This RPC deliberately
-- does not touch any ledger itself: CLAUDE.md's first principle is that completion is
-- the signal and modules subscribe, none writes the ledger directly.
create or replace function public.record_sale_by_phone(
  p_business uuid, p_phone text, p_amount_cents integer,
  p_kind text default 'quick_sale', p_note text default null,
  p_staff uuid default null, p_idem text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_norm text; c public.clients; s public.sales;
        v_points_before integer; v_points_after integer; v_earned integer;
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'not allowed to take sales for this business';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Enter the amount paid.';
  end if;
  if p_kind not in ('service','retail','quick_sale','membership','gift_card','package') then
    raise exception 'unknown sale kind: %', p_kind;
  end if;

  v_norm := app.norm_phone(p_phone);
  if v_norm is null then raise exception 'Enter a valid 8-digit mobile number.'; end if;

  select * into c from public.clients where business_id = p_business and phone_norm = v_norm;
  if not found then
    raise exception 'No customer with number %. Add them first.', v_norm;
  end if;

  -- Replay guard: same key => return the original sale, earn nothing more.
  if p_idem is not null then
    select * into s from public.sales where business_id = p_business and idem_key = p_idem;
    if found then
      select coalesce(sum(points),0) into v_points_after
        from public.points_ledger where business_id = p_business and client_id = c.id;
      return json_build_object('status','duplicate_ignored','sale_id', s.id,
        'client_id', c.id, 'full_name', c.full_name, 'points', v_points_after);
    end if;
  end if;

  select coalesce(sum(points),0) into v_points_before
    from public.points_ledger where business_id = p_business and client_id = c.id;

  insert into public.sales (business_id, client_id, kind, amount_cents, note, staff_id, idem_key)
  values (p_business, c.id, p_kind, p_amount_cents,
          coalesce(p_note, 'till: ' || v_norm), p_staff, p_idem)
  returning * into s;

  select coalesce(sum(points),0) into v_points_after
    from public.points_ledger where business_id = p_business and client_id = c.id;
  v_earned := v_points_after - v_points_before;

  return json_build_object('status','ok','sale_id', s.id,
    'client_id', c.id, 'full_name', c.full_name,
    'amount_cents', s.amount_cents, 'kind', s.kind,
    'points_earned', v_earned, 'points', v_points_after,
    'counts_as_revenue', s.counts_as_revenue, 'counts_as_visit', s.counts_as_visit);
end $$;
revoke all on function public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text) from public, anon;
grant execute on function public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text) to authenticated;

-- ---------- 4. TILL: ADD A CUSTOMER ON THE SPOT ----------
create or replace function public.quick_add_client(
  p_business uuid, p_phone text, p_name text, p_consent boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare v_norm text; c public.clients;
begin
  if not app.can_module(p_business, 'clients') then
    raise exception 'not allowed to add customers for this business';
  end if;
  v_norm := app.norm_phone(p_phone);
  if v_norm is null then raise exception 'Enter a valid 8-digit mobile number.'; end if;
  if p_name is null or length(trim(p_name)) < 2 then raise exception 'Enter the customer''s name.'; end if;

  insert into public.clients (business_id, full_name, phone, marketing_consent)
  values (p_business, trim(p_name), v_norm, coalesce(p_consent,false))
  on conflict (business_id, phone_norm) where phone_norm is not null do nothing
  returning * into c;

  if c.id is null then
    select * into c from public.clients where business_id = p_business and phone_norm = v_norm;
    return json_build_object('status','existing','client_id', c.id, 'full_name', c.full_name);
  end if;
  insert into public.consents (business_id, client_id, channel, action, source, actor)
  values (p_business, c.id, 'marketing',
          case when coalesce(p_consent,false) then 'granted' else 'withdrawn' end,
          'till', auth.uid());
  return json_build_object('status','created','client_id', c.id, 'full_name', c.full_name);
end $$;
revoke all on function public.quick_add_client(uuid,text,text,boolean) from public, anon;
grant execute on function public.quick_add_client(uuid,text,text,boolean) to authenticated;

-- ---------- 5. NEW FIRMS GET A SUBSCRIPTION ----------
create or replace function public.create_business(p_name text, p_slug text, p_industry text, p_modules text[])
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid; rec public.businesses; v_staff uuid; v_branch uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'sign in required'; end if;
  if p_name is null or length(trim(p_name)) < 2 then raise exception 'business name required'; end if;
  insert into public.businesses (name, slug, industry, enabled_modules)
  values (trim(p_name), p_slug, coalesce(p_industry,'other'),
          coalesce(p_modules, array['dashboard','clients','sales','loyalty','retention','referrals']))
  returning * into rec;
  insert into public.staff (business_id, user_id, role, full_name)
  values (rec.id, v_uid, 'owner', coalesce(auth.jwt()->>'email','Owner'))
  returning id into v_staff;
  insert into public.branches (business_id, name, is_default, active)
  values (rec.id, trim(p_name), true, true) returning id into v_branch;
  insert into public.staff_branches (business_id, staff_id, branch_id)
  values (rec.id, v_staff, v_branch);
  insert into public.loyalty_programs (business_id, kind, earn_points_per_dollar,
                                       redeem_points, reward_credit_cents, active)
  values (rec.id, 'points', 1, 800, 2000, true);
  -- v14: every firm starts on the $25 + $10/seat plan, 14-day trial.
  insert into public.subscriptions (business_id) values (rec.id)
  on conflict (business_id) do nothing;
  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (rec.id, v_uid, 'ONBOARD', 'businesses', rec.id,
          json_build_object('name', rec.name, 'industry', rec.industry)::jsonb);
  return row_to_json(rec);
end $$;
-- nestly_v469 rollback suite — a redeemed grant sale names itself, without leaking the note.
--
-- One transaction, ends in ROLLBACK, safe against production.
--
-- WHAT IT PROVES
--   01  the three grant prefixes reduce to the gift's own customer-facing name;
--   02  every other note — including the real ones production holds today: a phone number, a
--       staff remark, a typo'd scribble — reduces to NULL. This is the assertion that matters:
--       sales.note is free text a human types, and shipping it to a customer's phone would
--       publish the shop's internal remarks about them;
--   03  a grant prefix with nothing after it is null, not an empty label;
--   04  the function still refuses an unauthenticated caller;
--   05  the payload gained 'grant_label' and lost nothing.

begin;

create temp table _v469(k text, ok boolean, d text) on commit drop;
grant all on _v469 to public;

do $$
declare v_note text; v_expect text; v_got text;
begin
  for v_note, v_expect in
    select * from (values
      ('welcome offer redeemed: Free Soyabean',        'Free Soyabean'),
      ('bring-back voucher redeemed: Free Coffee',     'Free Coffee'),
      ('referral gift redeemed: Free Lotion',          'Free Lotion'),
      ('welcome offer redeemed:    Free  Kaya Toast',  'Free  Kaya Toast'),
      -- notes production actually holds, none of which may ever reach a customer
      ('till: 81863833',                                null),
      ('Nestly quick reversal: Staff note: admin error',null),
      ('fsfdfdddfdfdfdf: mistakeeeeeeeeee',             null),
      ('cart checkout (kernel)',                        null),
      ('package session used: 5x facial',               null),
      ('gift card sold: GC-36C99BEF',                   null),
      -- a prefix with no gift name is an absent label, never an empty one
      ('welcome offer redeemed: ',                      null),
      ('welcome offer redeemed:',                       null)
    ) t(n,e)
  loop
    v_got := case
      when v_note like 'welcome offer redeemed: %'
        then nullif(btrim(substring(v_note from 'welcome offer redeemed: (.*)$')), '')
      when v_note like 'bring-back voucher redeemed: %'
        then nullif(btrim(substring(v_note from 'bring-back voucher redeemed: (.*)$')), '')
      when v_note like 'referral gift redeemed: %'
        then nullif(btrim(substring(v_note from 'referral gift redeemed: (.*)$')), '')
    end;
    insert into _v469 values(
      'reduce ' || left(v_note, 40),
      v_got is not distinct from v_expect,
      'got ' || coalesce(v_got, '(null)') || ' want ' || coalesce(v_expect, '(null)'));
  end loop;
end $$;

-- 04: still refuses an anonymous caller.
do $$
declare v_raised boolean := false;
begin
  begin
    execute 'reset role';
    execute 'set local role anon';
    perform public.customer_get_transaction_history_v167('any-slug', '{}'::jsonb);
  exception when others then v_raised := true;
  end;
  execute 'reset role';
  insert into _v469 values('04 anonymous caller refused', v_raised, 'must raise');
end $$;

-- 05: the wrapper builds grant_label and still delegates to the v81 base read.
insert into _v469
select '05 wrapper adds grant_label and keeps its base read',
       def like '%grant_label%' and def like '%customer_get_transaction_history_v81%',
       'definition checked'
  from (select pg_get_functiondef(p.oid) as def
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where p.proname = 'customer_get_transaction_history_v167') d;

-- 06: the raw note must never be published under its own key.
insert into _v469
select '06 the raw note is never a payload key',
       def not like '%''note'', %' and def not like '%''sale_note''%',
       'no note key in the built object'
  from (select pg_get_functiondef(p.oid) as def
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where p.proname = 'customer_get_transaction_history_v167') d;

reset role;
select k, ok, d from _v469 order by k;
select count(*) as checks, count(*) filter (where not ok) as failures from _v469;

rollback;

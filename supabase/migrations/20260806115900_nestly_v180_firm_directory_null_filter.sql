-- NESTLY v180 — firm directory: JSON null filter values must not hide every firm.
--
-- Bug (live since v88): the platform console always sends
--   {"search":null,"sector":null,"lane":null,"attention_severity":null,"attention_due":null}
-- and platform_list_firm_onboarding_v88 tests `v_filters ? 'attention_due'`
-- (key EXISTENCE). A JSON null passes the 'true'/'false' validation (NULL NOT IN
-- (...) is NULL, not true) and then compiles to `attention_due = NULL::boolean`,
-- which matches no row. Every real console session therefore saw
-- "Total firms 0" and an empty onboarding kanban, while `{}` returned all firms.
--
-- Fix: strip null-valued keys from the filter object on entry
-- (jsonb_strip_nulls), so a null value and an absent key behave identically in
-- both the validation and the WHERE clause. Patched with the v92 idiom:
-- assert the deployed source contains the exact line once, replace, re-execute.

begin;

do $v180$
declare
  v_def text;
  v_old text := $$v_filters jsonb:=coalesce(p_filters,'{}'::jsonb);$$;
  v_new text := $$v_filters jsonb:=jsonb_strip_nulls(coalesce(p_filters,'{}'::jsonb));$$;
begin
  v_def := pg_get_functiondef(to_regprocedure(
    'public.platform_list_firm_onboarding_v88(jsonb,timestamptz,integer,timestamptz,uuid)'));
  if v_def is null then
    raise exception 'v180: platform_list_firm_onboarding_v88 is missing';
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'v180: expected exactly one v_filters declaration to patch';
  end if;
  if position('jsonb_strip_nulls' in v_def) > 0 then
    raise exception 'v180: function already strips nulls; refusing double patch';
  end if;
  execute replace(v_def, v_old, v_new);
end
$v180$;

commit;

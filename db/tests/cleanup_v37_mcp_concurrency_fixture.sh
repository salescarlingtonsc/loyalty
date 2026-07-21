#!/bin/sh
set -eu

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL is required." >&2
  exit 2
fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *)
  echo "DATABASE_URL must be a PostgreSQL URL." >&2; exit 2;;
esac
url_authority="${DATABASE_URL#*://}"; url_authority="${url_authority%%/*}"
case "$url_authority" in *@*)
  url_userinfo="${url_authority%@*}"
  case "$url_userinfo" in *:*|*%3[Aa]*)
    echo "DATABASE_URL must not contain embedded password material; use PGPASSWORD." >&2; exit 2;;
  esac;;
esac
url_lower="$(printf '%s' "$DATABASE_URL" | tr '[:upper:]' '[:lower:]')"
case "$url_lower" in *\?*pass*=*|*\&*pass*=*)
  echo "DATABASE_URL must not contain password query material; use PGPASSWORD." >&2; exit 2;;
esac
if [ -z "${PGPASSWORD:-}" ]; then
  echo "PGPASSWORD is required with the passwordless DATABASE_URL." >&2; exit 2
fi

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
export PGAPPNAME="v37-mcp-cleanup-3547cfc9"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
target_id="3547cfc9-ad9b-4f9c-8b3a-132b9cb04e12"
target_name="V37 MCP concurrency"
target_slug="v37-mcp-c814a28d"
confirmation_phrase="DELETE-V37-MCP-CONCURRENCY-3547CFC9"

inventory="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v target_id="$target_id" -v target_name="$target_name" -v target_slug="$target_slug" <<'SQL'
with target as (
  select b.id from public.businesses b
   where b.id=:'target_id'::uuid and b.name=:'target_name' and b.slug=:'target_slug'
), owners as (
  select distinct s.user_id,u.email
    from public.staff s join auth.users u on u.id=s.user_id
   where s.business_id=(select id from target) and s.role='owner'
)
select
  (select count(*) from public.businesses where id=:'target_id'::uuid),
  (select count(*) from target),
  (select count(*) from owners),
  coalesce((select min(user_id::text) from owners),''),
  coalesce((select min(email) from owners),''),
  coalesce((select count(*) from public.staff s join owners o on o.user_id=s.user_id
             where s.business_id<>:'target_id'::uuid),0);
SQL
)"
IFS='|' read -r id_rows exact_rows owner_rows owner_id owner_email external_staff_rows <<EOF
$inventory
EOF

echo "V37 MCP cleanup inventory: id_rows=$id_rows exact_identity_rows=$exact_rows owner_auth_users=$owner_rows external_staff_links=$external_staff_rows"

if [ "${V37_MCP_CLEANUP_CONFIRM:-}" = "" ]; then
  echo "Dry run only; no rows changed."
  exit 0
fi
if [ "${V37_CONFIRM_DISPOSABLE_DB:-}" != "YES" ] \
   || [ "$V37_MCP_CLEANUP_CONFIRM" != "$confirmation_phrase" ]; then
  echo "Refusing cleanup: disposable confirmation and exact cleanup phrase are required." >&2
  exit 2
fi
if [ "$id_rows" != "1" ] || [ "$exact_rows" != "1" ] || [ "$owner_rows" != "1" ] \
   || [ "$external_staff_rows" != "0" ]; then
  echo "Refusing cleanup: dry-run inventory did not match the one expected synthetic fixture." >&2
  exit 1
fi
case "$owner_email" in v37-mcp-*@example.test) ;; *)
  echo "Refusing cleanup: owner account is not recognizably synthetic." >&2
  exit 1;;
esac

psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
  -v cleanup_confirm="YES-SCOPED-SYNTHETIC-CLEANUP" \
  -v cleanup_business="$target_id" -v cleanup_business_name="$target_name" \
  -v cleanup_business_slug="$target_slug" \
  -v cleanup_auth_user_1="$owner_id" -v cleanup_auth_email_1="$owner_email" \
  -v cleanup_auth_user_2="" -v cleanup_auth_email_2="" \
  -f "$script_dir/cleanup_synthetic_fixture.sql"

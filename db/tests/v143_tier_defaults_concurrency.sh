#!/bin/sh
# True two-session V143 recommended-tier race. Run only on a dedicated,
# disposable database containing the canonical chain through V143.
set -eu

if [ "${V143_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V143_CONFIRM_DISPOSABLE_DB=YES." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ] || [ -z "${PGPASSWORD:-}" ]; then
  echo "DATABASE_URL and PGPASSWORD are required." >&2
  exit 2
fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *)
  echo "DATABASE_URL must be PostgreSQL." >&2
  exit 2
esac
case "$DATABASE_URL" in
  *gadpooereceldfpfxsod*)
    echo "Refusing to run against the protected production project." >&2
    exit 2
    ;;
esac

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=15000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

database_name="$(q -c 'select current_database()')"
case "$database_name" in *v143*retry*) ;; *)
  echo "Refusing database '$database_name': name must contain v143 and retry." >&2
  exit 2
esac
if [ "$(q -c "select count(*) from pg_proc where oid='public.add_recommended_loyalty_tiers_v143(uuid,uuid,text,text,uuid)'::regprocedure")" != "1" ]; then
  echo "V143 recommended-tier RPC is not installed." >&2
  exit 1
fi
if [ "$(q -c 'select count(*) from public.businesses')" != "0" ]; then
  echo "Disposable database must start without business fixtures." >&2
  exit 1
fi

q -f db/tests/fixtures/pristine_chain_fixture.psql >/dev/null
business="$(q -c "select b.id from public.businesses b join public.staff s on s.business_id=b.id and s.role='owner' where b.created_at='2000-01-01 00:00:00+00' order by s.created_at limit 1")"
owner="$(q -c "select s.user_id from public.staff s where s.business_id='$business' and s.role='owner' order by s.created_at limit 1")"
draft="$(q -c "begin; set local request.jwt.claims to '{\"sub\":\"$owner\",\"role\":\"authenticated\"}'; set local role authenticated; select (public.create_loyalty_config_draft('$business',null,'v143-concurrent-defaults')::jsonb->>'version_id'); commit")"
snapshot="$(q -c "select snapshot_hash from public.firm_config_versions where id='$draft'")"
key_a="$(q -c 'select gen_random_uuid()')"
key_b="$(q -c 'select gen_random_uuid()')"
prefix="${business%%-*}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/peekaa-v143-tier-race.XXXXXX")"
trap 'rm -f "$work_dir"/*; rmdir "$work_dir" 2>/dev/null || true' EXIT HUP INT TERM

(
  PGAPPNAME="v143-tier-first-$prefix" q >"$work_dir/first.out" 2>"$work_dir/first.err" <<SQL
begin;
set local request.jwt.claims to '{"sub":"$owner","role":"authenticated"}';
set local role authenticated;
select public.add_recommended_loyalty_tiers_v143('$business','$draft','visits','$snapshot','$key_a');
select pg_sleep(2);
commit;
SQL
) &
first_pid=$!

attempts=0
while [ "$(q -c "select count(*) from pg_stat_activity where application_name='v143-tier-first-$prefix' and wait_event='PgSleep'")" != "1" ]; do
  attempts=$((attempts+1))
  if [ "$attempts" -ge 50 ]; then
    echo "Timed out waiting for the first tier-default transaction." >&2
    exit 1
  fi
  sleep 0.1
done

q >"$work_dir/second.out" 2>"$work_dir/second.err" <<SQL
begin;
set local request.jwt.claims to '{"sub":"$owner","role":"authenticated"}';
set local role authenticated;
select public.add_recommended_loyalty_tiers_v143('$business','$draft','visits',null,'$key_b');
commit;
SQL
wait "$first_pid"

if ! grep -q '"status"[[:space:]]*:[[:space:]]*"draft_ready"' "$work_dir/first.out" \
   || ! grep -q '"status"[[:space:]]*:[[:space:]]*"existing_tiers"' "$work_dir/second.out" \
   || [ "$(q -c "select count(*) from public.loyalty_tier_versions where config_version_id='$draft'")" != "3" ] \
   || [ "$(q -c "select count(*) from app.loyalty_tier_default_operations_v143 where config_version_id='$draft'")" != "2" ] \
   || [ "$(q -c "select count(*) from public.loyalty_tiers where business_id='$business'")" != "0" ]; then
  echo "V143 concurrent default-tier writes did not serialize to one unpublished three-tier draft." >&2
  exit 1
fi

echo "V143 tier-default concurrency passed: one writer, one existing-tier result, three draft rows, zero published rows."

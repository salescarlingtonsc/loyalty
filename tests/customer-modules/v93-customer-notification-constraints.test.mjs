import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('v93 is a byte-identical forward repair after immutable production v91 and v92',async()=>{
  const [source,canonical,v91]=await Promise.all([
    read('db/migrations/20260728_nestly_v93_customer_notification_constraints.sql'),
    read('supabase/migrations/20260728120000_nestly_v93_customer_notification_constraints.sql'),
    read('db/migrations/20260727_nestly_v91_customer_game_notifications.sql')
  ]);
  assert.equal(source,canonical);
  assert.doesNotMatch(v91,/drop constraint customer_in_app_inbox_events_title_check/);
  assert.match(source,/reviewed v48 predecessor/);
  assert.match(source,/Appointment time changed/);
  assert.match(source,/Open this business wallet to review your updated appointment/);
  assert.match(source,/Points expire tomorrow/);
  assert.match(source,/Stamps expire within 3 days/);
  assert.match(source,/Reward unlocked!/);
  assert.match(source,/Quest almost complete/);
  assert.match(source,/Birthday surprise unlocked/);
  assert.match(source,/Open this programme now to review your expiring points/);
  assert.match(source,/Open this programme to view and redeem your reward/);
});

test('v93 accepts only the exact predecessor or final constraint states',async()=>{
  const sql=await read('db/migrations/20260728_nestly_v93_customer_notification_constraints.sql');
  assert.match(sql,/lock table public\.customer_in_app_inbox_events in share row exclusive mode/);
  assert.match(sql,/if v_title_definition is null or v_body_definition is null/);
  assert.match(sql,/regexp_matches\(v_title_definition/);
  assert.match(sql,/v_title_values = v_final_titles and v_body_values = v_final_bodies/);
  assert.match(sql,/v_title_values <> v_predecessor_titles/);
  assert.match(sql,/unexpected expression shape/);
  assert.match(sql,/raise exception 'customer inbox copy constraints do not match the reviewed v48 predecessor'/);
  assert.match(sql,/drop constraint customer_in_app_inbox_events_title_check/);
  assert.match(sql,/drop constraint customer_in_app_inbox_events_body_check/);
});

test('v93 rollback acceptance proves the final catalog definitions transactionally',async()=>{
  const sql=await read('db/tests/v93_customer_notification_constraints.sql');
  assert.match(sql,/^begin;/);
  assert.match(sql,/pg_get_constraintdef/);
  assert.match(sql,/Points expire tomorrow/);
  assert.match(sql,/Appointment time changed/);
  assert.match(sql,/Open this business wallet to review your updated appointment\./);
  assert.match(sql,/Open this programme now to review your expiring points\./);
  assert.match(sql,/rollback;\s*$/);
});

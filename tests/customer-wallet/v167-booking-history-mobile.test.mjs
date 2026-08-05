import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const sql=await readFile(new URL('../../supabase/migrations/20260805043956_nestly_v167_customer_repeat_booking_history.sql',import.meta.url),'utf8');

test('repeat booking derives a prior service only from the authenticated tenant appointment',()=>{
  assert.match(sql,/create or replace function public\.customer_get_repeat_booking_preference_v167/);
  assert.match(sql,/auth\.uid\(\) is null/);
  assert.match(sql,/app\.v32_customer_wallet_context\(p_business_slug\)/);
  assert.match(sql,/appointment\.business_id = v_context\.business_id[\s\S]*appointment\.client_id = v_context\.client_id[\s\S]*appointment\.status = 'completed'/);
  assert.match(sql,/service\.active[\s\S]*service\.show_on_booking_page/);
  assert.match(sql,/public\.staff_branches[\s\S]*public\.staff_services/);
  assert.match(sql,/'staff_name', staff_member\.full_name/);
  assert.doesNotMatch(sql,/p_customer|p_client/);
  assert.match(sql,/revoke all on function public\.customer_get_repeat_booking_preference_v167\(text, uuid\)[\s\S]*grant execute[\s\S]*to authenticated/);
});

test('customer surfaces expose Book again only through booking-enabled paths',()=>{
  assert.match(app,/function openCustomerRepeatBookingV167/);
  assert.match(app,/customer_get_repeat_booking_preference_v167/);
  assert.match(app,/data-repeat-booking data-business-slug/);
  assert.match(app,/group\.bookingEnabled&&item\.status==='completed'/);
  assert.match(app,/a\.status==='completed'/);
  assert.match(app,/bookingEnabled\?`<section[\s\S]*Book again/);
  assert.match(app,/repeat_service=/);
  assert.match(app,/customerRepeatBookingPreferencesV167/);
  assert.match(app,/repeatPreference\?\.staffName\?'named':'any'/);
  assert.match(app,/selSvc!==repeatService\?\.id[\s\S]*teamPref='any'/);
});

test('repeat service is allowlisted against the current public booking catalogue',()=>{
  assert.match(app,/const repeatServiceParam=\/\^\[0-9a-f\]/);
  assert.match(app,/const repeatService=repeatServiceParam\?services\.find\(service=>service\.id===repeatServiceParam\)\|\|null:null/);
  assert.match(app,/let selSvc=repeatService\?\.id\|\|null/);
  assert.match(app,/showStep\(repeatService\?steps\.indexOf\('time'\):0\)/);
  assert.match(sql,/service\.active[\s\S]*service\.show_on_booking_page/);
});

test('signed-in booking shows server-authoritative identity and preserves idempotent submission',()=>{
  assert.match(app,/function customerBookingIdentitySummaryV167/);
  assert.match(app,/Booking as \$\{esc\(identity\.name\)\}/);
  assert.match(app,/Edit booking details/);
  assert.match(app,/prefillEmptyPortalDetails\(\{profile:profileResult/);
  assert.match(app,/bookingSubmissionId=crypto\.randomUUID\(\)/);
  assert.match(app,/View in Bookings/);
  assert.match(sql,/verified customer link required/);
});

test('package session history requires explicit immutable provenance',()=>{
  assert.match(sql,/public\.customer_get_transaction_history_v167/);
  assert.match(sql,/public\.package_session_consumptions package_use/);
  assert.match(sql,/package_use\.sale_id = nullif\(listed\.item->>'source_id'/);
  assert.match(sql,/'is_package_session', true/);
  assert.match(sql,/'package_reference', left\(customer_package\.id::text, 8\)/);
  assert.match(app,/Package session used/);
  assert.match(app,/item\.is_package_session===true\?'':/);
  assert.doesNotMatch(app,/gross===0\?['"]Package session used/);
});

test('history keeps individual rows, adds recent activity, and retains full history',()=>{
  assert.match(app,/<h2>Recent activity<\/h2>/);
  assert.match(app,/transactionState\.items\.slice\(0,3\)\.map\(historyItemMarkup\)/);
  assert.match(app,/<span>Full history<\/span>/);
  assert.match(app,/transactionState\.items\.map\(historyItemMarkup\)/);
  assert.doesNotMatch(app,/groupBy\([^)]*event_at|new Map\([^)]*event_at/);
});

test('camera denial exposes and focuses tested image and paste fallbacks',()=>{
  assert.match(app,/id="customerJoinScannerPaste"/);
  assert.match(app,/Choose a QR image or paste the QR link/);
  assert.match(app,/pasteFallback\.open=true;imageInput\.focus\(\)/);
  assert.match(app,/createImageBitmap\(file\)/);
  assert.match(app,/customerJoinTokenFromQr/);
  assert.doesNotMatch(app,/id="customerJoinScannerImage"[^>]*capture=/);
  assert.doesNotMatch(app,/id="merchantScannerImage"[^>]*capture=/);
});

test('feedback retains an accessible radiogroup and discoverable public review action',()=>{
  assert.match(app,/role="radiogroup" aria-label="Rate from 1 to 5 stars"/);
  assert.match(app,/Leave a public review for/);
  assert.match(app,/This option is the same for every rating/);
});

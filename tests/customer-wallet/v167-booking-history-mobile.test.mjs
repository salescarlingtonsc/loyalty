import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
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
  // v178: Book again is now offered on the Cancelled and History tabs (anything that is not a
  // live upcoming booking), still only when the business has customer booking enabled.
  assert.match(app,/group\.bookingEnabled&&group\.business_slug&&customerBookingAppointmentTabV178\(item\)!=='bookings'/);
  assert.match(app,/a\.status==='completed'/);
  // v194 shrank the programme's own booking action into the header; Book again on the booking
  // tabs is unchanged and still gated on the business having customer booking enabled.
  assert.match(app,/\$\{bookingEnabled\?`<a class="btn sm customer-programme-book"/);
  assert.match(app,/group\.bookingEnabled&&group\.business_slug[\s\S]{0,400}?Book again/);
  assert.match(app,/repeat_service=/);
  assert.match(app,/customerRepeatBookingPreferencesV167/);
  /* v183: "who would you like" is no longer a free-text preference carried in the notes, so a
     repeat booking no longer pre-fills a name. It pre-fills the SERVICE and lands on the time
     step; the person is chosen from the business's real, validated roster. */
  assert.doesNotMatch(app,/repeatPreference\?\.staffName\?'named':'any'/);
  assert.match(app,/if\(staffChoice&&!staffForService\(\)\.some\(member=>member\.id===selStaff\)\)selStaff=null/);
  assert.match(app,/showStep\(repeatService\?steps\.indexOf\('time'\):0\)/);
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

/* v183 (owner: "don't need in-house feedback — just Google review"): the in-app star rating is
   gone from the customer surface. The public review link remains, ungated by any rating, which
   satisfies the anti-review-gating invariant by construction rather than by convention. */
test('the customer surface offers only the public review action, never an in-app rating first',()=>{
  assert.doesNotMatch(app,/role="radiogroup" aria-label="Rate from 1 to 5 stars"/);
  assert.doesNotMatch(app,/customer_submit_visit_feedback/,'the in-app rating write path is removed');
  assert.match(app,/<span>Leave a public review<\/span>/);
  assert.match(app,/function walletReviewUrlV183/);
  assert.match(app,/const host=\$\('walletFeedback'\);if\(!host\|\|!walletReviewUrl\)return/,
    'the review card renders only when the business supplied an https review URL');
});

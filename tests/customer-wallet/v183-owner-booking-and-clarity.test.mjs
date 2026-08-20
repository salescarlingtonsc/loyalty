import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')
  +'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const customerUi=readFileSync(new URL('../../app/customer-ui.js',import.meta.url),'utf8');
const migration=readFileSync(new URL('../../db/migrations/20260806_nestly_v183_customer_staff_choice_and_live_availability.sql',import.meta.url),'utf8');
const gateway=readFileSync(new URL('../../supabase/functions/public-booking/index.ts',import.meta.url),'utf8');
const validation=readFileSync(new URL('../../supabase/functions/_shared/validation.ts',import.meta.url),'utf8');
const security=readFileSync(new URL('../../supabase/functions/_shared/security.ts',import.meta.url),'utf8');

function section(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return source.slice(from,to);
}

/* ---------------------------------------------------------------- offers shelf */

test('an offer counts down in Singapore calendar days instead of printing a date range',()=>{
  const helper=section(app,'function customerOfferCountdownV183','function customerHomeOfferMarkupV167');
  const {customerOfferCountdownV183}=new Function(`${helper};return {customerOfferCountdownV183};`)();
  const now=Date.parse('2026-08-06T04:00:00Z'); // 12:00 SGT
  assert.equal(customerOfferCountdownV183({ends_at:'2026-08-06T15:00:00Z'},now),'Ends today');
  assert.equal(customerOfferCountdownV183({ends_at:'2026-08-07T02:00:00Z'},now),'Ends tomorrow');
  assert.equal(customerOfferCountdownV183({ends_at:'2026-08-27T02:00:00Z'},now),'Ends in 21 days');
  assert.equal(customerOfferCountdownV183({ends_at:'2026-08-05T02:00:00Z'},now),'','an ended offer has no countdown');
  assert.equal(customerOfferCountdownV183({},now),'','no end date means no countdown');
  // 23:00 SGT tonight is still "today", not "in 0 days"
  assert.equal(customerOfferCountdownV183({ends_at:'2026-08-06T15:30:00Z'},now),'Ends today');
});

test('the offer card carries the business logo and paints the countdown in the brand red',()=>{
  const card=section(app,'function customerHomeOfferMarkupV167','function interleaveCustomerOffersV173');
  assert.match(card,/logo=customerMediaUrlV95\(business\.logo_url\)/);
  assert.match(card,/class="customer-home-offer-logo"/);
  assert.match(card,/customer-home-offer-logo--fallback/,'a business without a logo still gets an identity chip');
  /* nestly_v395 (owner photo 2: the chip ringed with an arrow drawn to under the title, "put
     here"). The countdown was painted INSIDE the media block, absolutely positioned over the
     artwork's top-right corner — on top of the very picture the owner says is too small. Same
     node, same class, same red-on-soft colours; it is a line of the copy after the title now, so
     the card reads picture → who → what → when. The absolute slot div is gone with it. */
  assert.match(card,/countdown\s*\r?\n?\s*\?`<p class="customer-home-offer-countdown">/);
  assert.doesNotMatch(card,/customer-home-offer-countdown-slot-v5/,
    'and it is no longer painted over the artwork');
  assert.match(card,/:validity\?/,'an offer with no end date keeps its validity line');
  assert.match(app,/\.customer-home-offer-copy>\.customer-home-offer-countdown\{order:1/,
    'it sorts after the title, not before it');
  assert.match(app,/\.customer-home-offer-countdown\{[^}]*color:var\(--coral\)/);
});

test('the offers shelf title is one icon-led line',()=>{
  assert.match(app,/<h2 id="customerHomeOffersTitle" class="customer-home-offers-title">/);
  assert.doesNotMatch(app,/Worth coming back for/);
});

/* ------------------------------------------------------------------ My Rewards */

/* v339 (owner mockup "photo 1") inverted the reward card's resting line: the reward NAME is now
   the card's heading and the cost sits directly beneath it, replacing the single
   "150 points → Free facial add-on" sentence. Both halves of the exchange are still stated on the
   card, from the same two sources, which is what this test exists to protect — a card that named
   a reward without pricing it, or priced one without naming it, still fails. */
test('a reward states the exchange — what it is, and what it costs',()=>{
  const rewards=section(app,'const loadRewards=async','const loadTransactions=');
  assert.match(rewards,/class="wallet-reward-trade customer-reward-name-v339">\$\{esc\(r\.customer_name\|\|'Reward'\)\}<\/b>/);
  assert.match(rewards,/class="wallet-reward-cost customer-reward-cost-v339">\$\{esc\(customerPointTotalV103\(cost\)\)\} \$\{esc\(rewardUnit\)\}<\/p>/);
  assert.doesNotMatch(rewards,/<span class="pill">\$\{esc\(customerPointTotalV103\(r\.cost_points\|\|0\)\)\}/,
    'the duplicate cost pill is gone now that the cost leads the line');
});

test('merchant-authoring guidance never reaches a customer reward card',()=>{
  const helper=section(app,'const MERCHANT_DRAFT_COPY_PATTERNS_V183','function customerRewardProgressMarkupV167');
  const {customerRewardDescriptionV183}=new Function(`${helper};return {customerRewardDescriptionV183};`)();
  assert.equal(customerRewardDescriptionV183('Suggested starting benefit. Replace this with an item or service that fits your margins.'),'');
  assert.equal(customerRewardDescriptionV183('  Replace this with your own wording  '),'');
  assert.equal(customerRewardDescriptionV183('One free coffee after ten visits.'),'One free coffee after ten visits.');
  assert.equal(customerRewardDescriptionV183(null),'');
});

test('a wallet card shows prepaid sessions and store credit beside the points',()=>{
  const holdings=section(app,'function customerProgrammeHoldingsMarkupV183','function customerProgrammeTileMarkupV96');
  assert.match(holdings,/card\?\.packages\?\.sessions_remaining/);
  /* V375 (owner, photo 3: "i don't want credit feature"): the credit chip left this row with
     the feature. Prepaid sessions — the other holding it states — are unchanged. */
  assert.doesNotMatch(holdings,/card\?\.credit\?\.balance_cents/);
  assert.match(holdings,/sessions>0/,'a zero session balance must not render an empty row');
  assert.match(holdings,/return chips\.length\?/);
  assert.match(app,/\$\{holdings\?`<div style="grid-column:1\/-1">\$\{holdings\}<\/div>`:''\}/);
});

/* -------------------------------------------------------------------- bookings */

test('a business with nothing booked is not listed as a booking',()=>{
  const grouping=section(app,'function customerBookingTabGroupsV178','function customerBookingEmptyMarkupV183');
  assert.match(grouping,/\.filter\(group=>group\.tabRequests\.length\|\|group\.tabAppointments\.length\)/);
  assert.doesNotMatch(grouping,/tab==='bookings'&&group\.bookingEnabled/,
    'the phantom "0 requests · 0 appointments" card is gone');
  const empty=section(app,'function customerBookingEmptyMarkupV183','async function renderCustomerBookings');
  assert.match(empty,/tab==='bookings'\s*\?groups\.filter\(group=>group\.bookingEnabled&&group\.business_slug\)/,
    'the entry point moves into the empty state, and only on the default tab');
  assert.match(empty,/Book with \$\{esc\(group\.business_name\)\}/);
});

/* ------------------------------------------------- sheet navigation (the "bounce") */

test('navigating out of a sheet replaces the sheet history entry instead of racing it',()=>{
  const nav=section(app,'function wireCustomerSheetNavV183','function showCustomerBusinessDetailV178');
  assert.match(nav,/event\.preventDefault\(\)/);
  assert.match(nav,/deactivate\(\{restoreFocus:false,handOffHistory:handOff\}\)/);
  assert.match(nav,/history\.replaceState\(null,'',href\)/);
  assert.match(nav,/route\(\)/,'replaceState fires no hashchange, so the router is called directly');
  assert.match(nav,/event\.metaKey\|\|event\.ctrlKey\|\|event\.shiftKey/,'modifier-clicks still open a new tab');
});

test('a handed-off dialog entry is neither unwound twice nor pushed twice',()=>{
  const activate=section(customerUi,'function activateDialog(','function setButtonBusy(');
  assert.match(activate,/if\(!inherited\)history\.pushState/);
  assert.match(activate,/if\(handOffHistory\)closedByUs=true;/);
  assert.match(activate,/else if\(!closedByUs&&history\.state\?\.cuiDialog===historyId\)/);
  assert.match(customerUi,/currentDialogHistoryId/);
});

test('the offer sheet opens the company sheet and keeps only the booking action',()=>{
  const sheet=section(app,'function showCustomerOfferDetailV173','function wireCustomerHomeOffersV167');
  /* v326 (owner: "when I click this, straightaway go to company profile inside, don't need
     another pop-out"): the company row now navigates straight to the business's own programme
     page instead of opening the showCustomerBusinessDetailV178 sheet. */
  assert.match(sheet,/const target=`#\/wallet\/\$\{encodeURIComponent\(business\.slug\|\|''\)\}`/);
  assert.doesNotMatch(sheet,/showCustomerBusinessDetailV178\(business,\{inheritHistoryId:handOff\}\)/,
    'the row no longer opens a second pop-out modal');
  assert.doesNotMatch(sheet,/data-offer-detail-nav>\$\{esc\(ct\('openProgramme'/,
    'the owner struck the "Open <business> rewards" button off the offer sheet');
  const company=section(app,'function showCustomerBusinessDetailV178','function showCustomerOfferDetailV173');
  assert.match(company,/industry\?`<p class="muted small" style="margin-top:2px">\$\{esc\(industry\)\}<\/p>`/,
    'the company sheet names the business type');
  assert.match(company,/href="tel:/);
  /* v386 (owner photo 2): the sheet's own "Open <business> rewards" button is struck out too —
     it navigated to the programme page the customer had to be standing on to open this sheet. */
  assert.doesNotMatch(company,/ct\('openProgramme',\{business:name\}\)/);
});

/* ---------------------------------------------------------------------- portal */

test('the team step exists only when the business turned staff choice on',()=>{
  const portal=section(app,'async function renderPortal(slug){','async function boot(){');
  assert.match(portal,/const bookableStaff=\(biz\.booking_staff_choice===true&&Array\.isArray\(biz\.staff\)\)\?biz\.staff:\[\]/);
  assert.match(portal,/const middleStep=usesTables\?'table':\(staffChoice\?'team':''\)/);
  assert.match(portal,/\.filter\(Boolean\)/,'an absent middle step must not leave a hole in the progress rail');
  assert.doesNotMatch(portal,/Preferred team member: \$\{staffName\(\)\}/,
    'the old free-text preference that rode along in the notes is gone');
  assert.doesNotMatch(portal,/teamPref/,'no remnant of the placeholder preference model');
});

test('the portal only offers people the server would accept for that service',()=>{
  const portal=section(app,'async function renderPortal(slug){','async function boot(){');
  const resolver=section(portal,'const staffForService=','const staffMember=');
  assert.match(resolver,/if\(!selSvc\)return true/);
  assert.match(resolver,/if\(!assigned\.length\)return true/,'an unassigned service is offered by everyone');
  assert.match(resolver,/return assigned\.includes\(selSvc\)/);
  assert.match(portal,/if\(staffChoice&&!staffForService\(\)\.some\(member=>member\.id===selStaff\)\)selStaff=null/,
    'changing service must drop a person who no longer qualifies');
});

test('live availability is fetched through the gateway and degrades to a plain time request',()=>{
  const portal=section(app,'async function renderPortal(slug){','async function boot(){');
  assert.match(portal,/availability=1/);
  assert.match(portal,/&days=14/);
  assert.match(portal,/if\(key==='time'\)loadAvailability\(\)/);
  assert.match(portal,/data\.hours_configured!==true/);
  assert.match(portal,/has not published working hours yet/);
  assert.match(portal,/Live availability could not be checked just now/);
  assert.match(portal,/No free times in the next two weeks/);
  assert.match(portal,/if\(manual\)manual\.hidden=false/,'every fallback restores the manual picker');
  assert.match(portal,/The business still confirms your booking/,
    'availability is advisory — the sheet never promises a hold');
});

test('a chosen slot is submitted as an exact instant and the person rides in the payload',()=>{
  const portal=section(app,'async function renderPortal(slug){','async function boot(){');
  assert.match(portal,/preferred:selectedSlot\|\|sgIso\(\$\('pt'\)\?\.value\)/);
  assert.match(portal,/staff:usesTables\?null:selStaff/);
  assert.match(portal,/if\(!selectedSlot&&!\$\('pt'\)\?\.value\)/,'either source satisfies the time step');
});

test('a signed-in customer sees their own bookings instead of being asked for a code',()=>{
  const loader=section(app,'async function loadPortalUpcomingBookingsV183','async function renderPortal(slug){');
  assert.match(loader,/customer_get_appointments_page/);
  assert.match(loader,/customer_get_booking_requests/);
  assert.match(loader,/CANCELLED_CUSTOMER_BOOKING_STATUSES_V178\.has/);
  assert.match(loader,/isActiveCustomerBookingRequest\(item\)/);
  assert.match(loader,/String\(item\?\.business_slug\|\|''\)===slug/,'only this business’s requests are listed');
  assert.match(loader,/wireWalletAppointmentActions\(slug\)/,'change and cancel reuse the audited wallet path');
  assert.match(loader,/could not be loaded right now/,'a failed read must not block a new booking');
  const portal=section(app,'async function renderPortal(slug){','async function boot(){');
  assert.match(portal,/<details id="portalManageToken"/,'the guest code entry survives, collapsed');
  assert.match(portal,/Booked as a guest\? Open with your booking link or code/);
  assert.match(portal,/loadPortalUpcomingBookingsV183\(slug,isPortalCurrent\)/);
});

/* --------------------------------------------------------------- business side */

/* V228 (owner: "staff schedule should not be in bookings - it should be in staff modules").
   The rota moved to Staff Members; the shop's own opening hours stayed in Bookings, because
   they belong to the branch and not to a person. Every rule these tests protect is unchanged —
   they are pointed at the two places that now own them. */
test('each person can work their own rota, and unticking returns them to shop hours',()=>{
  const load=section(app,'async function loadStaffRotaV228','async function saveStaffRotaV228')
    +section(app,'function staffRotaSectionMarkupV228','\nasync function staffMembersPage');
  assert.match(load,/sb\.from\('staff_hours'\)\.select\('staff_id,weekday,starts_at,ends_at'\)/);
  assert.match(load,/rotaResult\.error/,'a failed rota read must not render a half-truthful editor');
  assert.match(load,/\{opens_at:row\.starts_at,closes_at:row\.ends_at\}/,'rota columns are translated once');
  assert.match(load,/data-staff-rota="\$\{esc\(staffId\)\}"[^>]*\$\{rota\?'checked':''\}/);
  assert.match(load,/data-staff-hours="\$\{esc\(staffId\)\}" \$\{rota\?'':'hidden'\}/);
  assert.match(load,/Replaces the shop hours for this person — including days the shop is closed\./,
    'the copy states the engine’s actual rule rather than implying an intersection');
  assert.match(load,/pill\.textContent=box\.checked\?'Own rota':'Shop hours'/);
  // one row template, namespaced so a rota row can never be read as a shop row
  const row=section(app,'const v183HourRowMarkup=','async function bookingsPage');
  assert.match(row,/data-day-scope="\$\{esc\(scope\)\}"/);
  assert.match(row,/id="v183Open-\$\{esc\(scope\)\}-\$\{weekday\}"/,'ids stay unique across every grid on the page');
});

test('a rota save is scoped, ordered and refuses to publish an empty rota',()=>{
  const save=section(app,'async function saveStaffRotaV228','async function loadTeam');
  assert.match(save,/\[data-day-closed\]\[data-day-scope="\$\{CSS\.escape\(scope\)\}"\]/);
  assert.match(save,/readDayGrid\(staffId,member\)/);
  assert.match(save,/box\.checked\|\|!opens\|\|!closes\|\|closes<=opens/,'an inverted or blank range is closed, never saved');
  assert.match(save,/const emptyRota=rotas\.find\(rota=>rota\.wantsRota&&!rota\.open\.length\)/);
  assert.match(save,/works their own hours but has no open day/);
  assert.match(save,/return;\s*\}\s*const results=await Promise\.all/,'the guard aborts before ANY write');
  assert.match(save,/sb\.from\('staff_hours'\)\.upsert\([\s\S]{0,220}\{onConflict:'staff_id,weekday'\}\)/);
  assert.match(save,/sb\.from\('staff_hours'\)\.delete\(\)\.eq\('business_id',S\.biz\.id\)\.eq\('staff_id',rota\.staffId\)\.in\('weekday',rota\.closed\)/);
  assert.match(save,/:\[sb\.from\('staff_hours'\)\.delete\(\)\.eq\('business_id',S\.biz\.id\)\.eq\('staff_id',rota\.staffId\)\]/,
    'unticking clears the whole rota — that is what restores shop hours');
});

test('the availability engine prefers a rota over shop hours and offers nothing on an unrostered day',()=>{
  const windows=section(migration,'), windows as (','), slots as (');
  assert.match(windows,/coalesce\(own\.starts_at, branch\.opens_at\) as starts_at/);
  assert.match(windows,/on own\.business_id = v_business\.id[\s\S]{0,200}own\.weekday = extract\(dow from calendar\.day\)::smallint/);
  assert.match(windows,/\) branch on not exists \(\s*select 1 from public\.staff_hours any_row/,
    'branch hours are joined ONLY for a person with no rota at all');
  assert.match(windows,/where coalesce\(own\.starts_at, branch\.opens_at\) is not null/,
    'a rostered person with no row for that weekday simply has no window');
});

test('the business owns the switch, the opening hours and who is bookable',()=>{
  assert.match(app,/id="setStaffChoice"[^>]*\$\{S\.biz\.booking_staff_choice\?'checked':''\}/);
  assert.match(app,/Let customers choose a team member/);
  /* V325 (owner-authorized relocation, 2026-08-14 Customer Interface cosmetics brief): this
     handler moved from bookingsPage into wireBookingRulesV325, rendered by Customer Interface's
     Appointment Setting step — same code, just relocated, so the end marker moved with it. */
  const save=section(app,"$('setAvailabilitySave').onclick=",'function customerInterfacePreviewSideCardHtmlV325(');
  assert.match(save,/sb\.from\('businesses'\)\.update\(\{booking_staff_choice:staffChoice\}\)/);
  assert.match(save,/sb\.from\('branch_hours'\)\.upsert\(rows,\{onConflict:'branch_id,weekday'\}\)/);
  assert.match(save,/sb\.from\('branch_hours'\)\.delete\(\)/,'unchecking a day removes its hours');
  assert.match(save,/closes<=opens/,'an inverted or empty range is treated as closed, never saved');
  /* Who is bookable travels with the rota, to Staff Members. */
  const rotaSave=section(app,'async function saveStaffRotaV228','async function loadTeam');
  assert.match(rotaSave,/sb\.from\('staff'\)\.update\(\{customer_bookable:member\.customer_bookable\}\)/);
});

/* ----------------------------------------------------------------- gateway/DB */

test('the gateway validates the availability query and passes the person through',()=>{
  assert.match(gateway,/params\.get\('availability'\) === '1'/);
  assert.match(gateway,/enforceRateLimit\(req, 'booking-availability', 120, 60\)/);
  assert.match(gateway,/if \(\(service && !UUID_PATTERN\.test\(service\)\) \|\| \(staff && !UUID_PATTERN\.test\(staff\)\)\s*\n\s*\|\| \(branch && !UUID_PATTERN\.test\(branch\)\)\) return publicError\(req\)/);
  assert.match(gateway,/if \(!Number\.isInteger\(days\) \|\| days < 1 \|\| days > 14\) return publicError\(req\)/);
  assert.match(gateway,/p_staff: body\.staff \|\| null/);
  assert.match(validation,/\(!body\.staff \|\| UUID_PATTERN\.test\(String\(body\.staff\)\)\)/);
});

test('adding the person to the fingerprint cannot invalidate a pre-v183 retry',()=>{
  const canonical=section(security,'export function canonicalBookingRequest','export function canonicalBookingChange');
  assert.match(canonical,/if \(input\.staff\) request\.staff = String\(input\.staff\);/);
  assert.doesNotMatch(canonical,/staff: input\.staff \|\| null/,
    'a null staff key would change every existing guest fingerprint');
});

test('the migration fails closed, hardens search_path and never exposes the roster by default',()=>{
  assert.match(migration,/booking_staff_choice boolean not null default false/);
  assert.match(migration,/customer_bookable boolean not null default true/);
  assert.match(migration,/if coalesce\(v_business\.booking_staff_choice, false\) is not true then[\s\S]{0,240}'staff', '\[\]'::jsonb/);
  assert.equal((migration.match(/set search_path = pg_catalog, public, app, pg_temp/g)||[]).length,4);
  assert.doesNotMatch(migration,/set search_path = public, app, pg_temp/);
  for(const fn of ['internal_public_booking_availability','internal_public_booking_page','internal_public_booking_submit']){
    assert.ok(migration.includes(`revoke all on function public.${fn}`),`${fn} must revoke default execution`);
  }
  assert.match(migration,/grant execute on function public\.internal_public_booking_availability[\s\S]{0,120}to service_role/);
  assert.doesNotMatch(migration,/grant execute[^;]*internal_public_booking_availability[^;]*to (anon|authenticated)/);
  // the slot engine must subtract real work, not just publish opening hours
  assert.match(migration,/from public\.appointments booked/);
  assert.match(migration,/from public\.staff_blocked_times blocked/);
  assert.match(migration,/booked\.status not in \('cancelled', 'no_show', 'declined'\)/);
  assert.match(migration,/slots\.slot_at >= v_earliest/,'past and imminent slots are never offered');
  assert.match(migration,/least\(greatest\(coalesce\(p_days, 7\), 1\), 14\)/,'the horizon is bounded');
});

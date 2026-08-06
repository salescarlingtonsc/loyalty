import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));

function sourceBetween(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing source block ${start}`);
  return app.slice(from,to);
}

test('actual public booking submit sends a fresh nonblank bearer and never a client id',async()=>{
  const source=sourceBetween('async function submitPublicBookingGateway(','let turnstileLoader;');
  const calls=[];
  const context={
    sb:{auth:{getSession:async()=>({data:{session:{user:{id:'customer-1'},access_token:'  signed-token  '}},error:null})}},
    publicGateway:async(name,options)=>{calls.push({name,options});return {status:'pending'}}
  };
  const submit=vm.runInNewContext(`(()=>{${source};return submitPublicBookingGateway})()`,context);
  const body={slug:'kopi-tiam',submission_id:'attempt-1'};
  await submit(body,{id:'customer-1'},()=>true);

  assert.equal(JSON.stringify(calls),JSON.stringify([{name:'public-booking',options:{body,accessToken:'signed-token'}}]));
  assert.equal('client_id' in calls[0].options.body,false);
  const portal=sourceBetween('async function renderPortal(slug){','async function boot(){');
  assert.match(portal,/submitPublicBookingGateway\(\{\.\.\.bookingPayload,submission_id:bookingSubmissionId,\s*turnstile_token:bookingTurnstileToken\},signedInUser,isPortalCurrent\)/);
  assert.doesNotMatch(portal,/bookingPayload\s*=\s*\{[\s\S]*?\bclient_id\b/);
});

test('guest submit has no bearer, while a stale or expired signed-in submit never reaches the gateway',async()=>{
  const source=sourceBetween('async function submitPublicBookingGateway(','let turnstileLoader;');
  const calls=[];
  const context={
    sb:{auth:{getSession:async()=>({data:{session:null},error:null})}},
    publicGateway:async(name,options)=>{calls.push({name,options});return {status:'pending'}}
  };
  const submit=vm.runInNewContext(`(()=>{${source};return submitPublicBookingGateway})()`,context);
  await submit({slug:'kopi-tiam'},null,()=>true);
  assert.equal(JSON.stringify(calls[0]),JSON.stringify({name:'public-booking',options:{body:{slug:'kopi-tiam'},accessToken:''}}));

  await assert.rejects(()=>submit({slug:'kopi-tiam'},{id:'customer-1'},()=>true),/session has expired/i);
  await assert.rejects(()=>submit({slug:'kopi-tiam'},null,()=>false),/view changed/i);
  assert.equal(calls.length,1,'expired and stale flows must not submit as guests');
  assert.match(app,/credentials:'omit'/);
  assert.match(app,/if\(token\)headers\.Authorization=`Bearer \$\{token\}`/);
});

test('portal identity copy and prefill stay linked-business scoped and generation guarded',()=>{
  const portal=sourceBetween('async function renderPortal(slug){','async function boot(){');
  const linked=portal.indexOf('if(customer){');
  const prefill=portal.indexOf('prefillEmptyPortalDetails(',linked);
  const unlinked=portal.indexOf('}else if(personaResult?.error)',linked);
  assert.ok(linked>=0&&prefill>linked&&prefill<unlinked,'contact prefill must exist only inside the linked-programme branch');
  assert.match(portal,/if\(!isPortalCurrent\(\)\|\|!slot\.isConnected\)return;\s*prefillEmptyPortalDetails/);
  assert.match(portal,/Booking as an unlinked guest/);
  assert.match(portal,/visit the participating business and scan its current Peekaa QR/i);
  assert.doesNotMatch(portal,/Add programme|href="#\/claim\?business=/);
  assert.match(portal,/verified relationship will be validated securely when you submit/i);
  assert.match(portal,/After secure validation, this booking will be attached/i);
});

test('active requests and appointments compose once, remain grouped, and tolerate a partial appointment error',()=>{
  const source=app.match(/const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES=[\s\S]*?function composeCustomerBookingGroups\([^\n]*\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(source);
  const compose=vm.runInNewContext(`(()=>{${source};return composeCustomerBookingGroups})()`);
  const programmes=[{business:{slug:'kopi-tiam',name:'Kopi Tiam'}},{business:{slug:'spa',name:'A Spa'}}];
  const requests={items:[
    {request_id:'r1',business_slug:'kopi-tiam',business_name:'Kopi Tiam',status:'pending'},
    {request_id:'r1',business_slug:'kopi-tiam',business_name:'Kopi Tiam',status:'pending'},
    {request_id:'r2',business_slug:'spa',business_name:'A Spa',status:'waitlisted'}
  ]};
  const appointments=[
    {card:programmes[0],data:{items:[{appointment_id:'a1',status:'booked'},{appointment_id:'a1',status:'booked'}]},error:null},
    {card:programmes[1],data:null,error:{message:'temporary'}}
  ];
  const groups=compose(programmes,requests,appointments);
  assert.equal(groups.length,2);
  assert.equal(groups.find(group=>group.business_slug==='kopi-tiam').requests.length,1);
  assert.equal(groups.find(group=>group.business_slug==='kopi-tiam').activeRequests.length,1);
  assert.equal(groups.find(group=>group.business_slug==='kopi-tiam').appointments.length,1);
  assert.equal(groups.find(group=>group.business_slug==='spa').requests.length,1,
    'a request remains visible when that programme appointment feed fails');
});

test('customer booking reader uses cursor pagination with truthful continuation and partial retry states',()=>{
  const bookings=sourceBetween('async function renderCustomerBookings(){','async function renderCustomerMessages(){');
  assert.match(bookings,/customer_get_booking_requests',\{p_limit:50,p_cursor:null\}/);
  assert.match(bookings,/requestPayload\?\.next_cursor/);
  assert.match(bookings,/id="customerBookingsMore">Load more requests/);
  assert.match(bookings,/customer_get_booking_requests',\{p_limit:50,p_cursor:cursor\}/);
  assert.match(bookings,/incoming\.filter\(item=>!seen\.has\(item\.request_id\)\)/);
  assert.match(bookings,/Pending and waitlisted booking requests are temporarily unavailable/);
  assert.match(bookings,/Confirmed appointments could not be discovered/);
  assert.match(app,/programmesIntro:'Pick a business to open its rewards, benefits, bookings and activity\.'/);
});

test('registered zero-programme customers qualify; staff-only accounts do not',()=>{
  const source=app.match(/function customerSurfaceQualifies\([^\n]*\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(source);
  const qualifies=vm.runInNewContext(`(${source})`);
  assert.equal(qualifies({full_name:'Zero Program'},[]),true);
  assert.equal(qualifies(null,[{business_slug:'legacy'}]),true);
  assert.equal(qualifies(null,[]),false);
  assert.match(app,/renderNoCustomerDestination\(staff\)/);
});

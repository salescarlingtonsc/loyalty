import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole({throwingSessionStorage=false}={}){
  const source=await read('app/platform-console.js');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect};
  if(throwingSessionStorage)Object.defineProperty(context,'sessionStorage',{get(){throw new Error('storage denied')}});
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

test('V133 gives privacy operators an audited lifecycle without browser-side deletion',async()=>{
  const [migration,consoleSource]=await Promise.all([
    read('supabase/migrations/20260801235900_nestly_v133_operational_closure.sql'),
    read('app/platform-console.js')
  ]);

  assert.match(migration,/create table public\.account_deletion_request_events/);
  assert.match(migration,/force row level security/);
  assert.match(migration,/platform_transition_account_deletion_request_v133/);
  assert.match(migration,/perform pg_advisory_xact_lock/);
  assert.match(migration,/V133 preflight blocked:[\s\S]+legacy processing\/completed deletion requests/);
  assert.match(migration,/not valid;[\s\S]+validate constraint account_deletion_requests_v133_lifecycle_check/);
  assert.match(migration,/reject_account_deletion_event_mutation_v133/);
  assert.match(migration,/before update or delete on public\.account_deletion_request_events/);
  assert.match(migration,/before truncate on public\.account_deletion_request_events/);
  assert.match(migration,/revoke all on table public\.account_deletion_request_events from service_role/);
  assert.match(migration,/result_snapshot jsonb not null/);
  assert.match(migration,/return v_existing\.result_snapshot/);
  assert.match(migration,/retention_review/);
  assert.doesNotMatch(migration,/claimed_by uuid references auth\.users/);
  assert.doesNotMatch(migration,/operator_auth_user_id uuid references auth\.users/);
  assert.match(migration,/deleted_where_permitted/);
  assert.match(migration,/retained_legal/);
  assert.match(migration,/request_invalid/);
  assert.match(migration,/revoke all on table public\.account_deletion_request_events from public, anon, authenticated/);
  assert.match(migration,/grant execute on function public\.platform_transition_account_deletion_request_v133/);
  assert.doesNotMatch(migration,/delete\s+from\s+auth\.users/i);
  assert.doesNotMatch(migration,/delete\s+from\s+public\./i);

  assert.match(consoleSource,/platform_list_account_deletion_requests_v133/);
  assert.match(consoleSource,/platform_transition_account_deletion_request_v133/);
  assert.match(consoleSource,/privacyOperationAttempt\('claim',requestId,payload\)/);
  assert.match(consoleSource,/privacyOperationAttempt\(action,requestId,payload\)/);
  assert.match(consoleSource,/data-deletion-review/);
  assert.match(consoleSource,/This records the reviewed outcome; it does not delete data/);

  /* v188 removed self-service submission; the operator lifecycle above is untouched. What the
     customer surface must still do is REPORT the outcome of a request they already made — the
     copy moved from a dialog to the account & privacy card. */
  const customerSource=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(customerSource,/Closure request reviewed/);
  assert.match(customerSource,/Closure request received/);
  assert.match(customerSource,/outcomes\[request\.resolution_code\]/);
  assert.match(customerSource,/deleted_where_permitted:'Deleted where permitted'/);
  assert.match(customerSource,/retained_legal:'Retained under legal obligation'/);
  assert.doesNotMatch(customerSource,/request_account_deletion_v131/,
    'the browser may read the outcome but never create the request');
});

test('privacy queue makes overdue, claimed and resolved states observable',async()=>{
  const Console=await loadConsole();
  assert.equal(typeof Console.accountDeletionQueueHtml,'function');
  const CUI={
    emptyState:({title,body})=>`<div><b>${title}</b><p>${body}</p></div>`,
    status:(label,tone)=>`<span data-tone="${tone}">${label}</span>`
  };
  const html=Console.accountDeletionQueueHtml([
    {request_id:'request-overdue',status:'pending',requested_at:'2026-06-01T00:00:00Z',response_due_at:'2026-07-01T00:00:00Z',is_overdue:true},
    {request_id:'request-claimed',status:'processing',requested_at:'2026-07-25T00:00:00Z',response_due_at:'2026-08-24T00:00:00Z',is_overdue:false,claimed_at:'2026-07-26T00:00:00Z'},
    {request_id:'request-retained',status:'completed',requested_at:'2026-07-01T00:00:00Z',response_due_at:'2026-07-31T00:00:00Z',is_overdue:false,resolution_code:'retained_legal',retention_until:'2031-07-31T00:00:00Z'},
    {request_id:'request-retention-due',status:'completed',requested_at:'2025-07-01T00:00:00Z',response_due_at:'2025-07-31T00:00:00Z',is_overdue:true,resolution_code:'retained_legal',retention_until:'2026-07-31T00:00:00Z'}
  ],CUI);

  assert.match(html,/Account deletion requests/);
  assert.match(html,/Overdue/);
  assert.match(html,/data-deletion-claim="request-overdue"/);
  assert.match(html,/data-deletion-resolve="request-claimed"/);
  assert.match(html,/Retained under legal obligation/);
  assert.doesNotMatch(html,/data-deletion-resolve="request-retained"/);
  assert.match(html,/Retention review due/);
  assert.match(html,/data-deletion-review="request-retention-due"/);
  assert.doesNotMatch(html,/sofia|email|phone/i);
});

test('privacy queue empty state remains explicit and action free',async()=>{
  const Console=await loadConsole();
  const html=Console.accountDeletionQueueHtml([],{
    emptyState:({title,body})=>`<div><b>${title}</b><p>${body}</p></div>`,
    status:(label)=>label
  });
  assert.match(html,/No account deletion requests/);
  assert.match(html,/No pending privacy work was returned/);
  assert.doesNotMatch(html,/data-deletion-(?:claim|resolve|review)/);
});

test('privacy queue failure is isolated and offers one truthful retry',async()=>{
  const Console=await loadConsole();
  const html=Console.accountDeletionQueueHtml([],{
    emptyState:({title,body})=>`<div><b>${title}</b><p>${body}</p></div>`,
    status:(label)=>label
  },{error:true});
  assert.match(html,/Account deletion requests could not be loaded/);
  assert.equal((html.match(/data-deletion-retry/g)||[]).length,1);
  assert.doesNotMatch(html,/No account deletion requests/);
});

test('privacy operation retries reuse one key only for the same payload',async()=>{
  const Console=await loadConsole();
  const payload={p_request:'request-1',p_action:'resolve',p_reason:'Reviewed outcome'};
  const first=Console.privacyOperationAttempt('resolve','request-1',payload);
  const lostResponseRetry=Console.privacyOperationAttempt('resolve','request-1',payload);
  assert.equal(first.key,lostResponseRetry.key);
  const changed=Console.privacyOperationAttempt('resolve','request-1',{...payload,p_reason:'Changed reviewed outcome'});
  assert.notEqual(changed.key,first.key);
  changed.clear();
  const afterSuccess=Console.privacyOperationAttempt('resolve','request-1',{...payload,p_reason:'Changed reviewed outcome'});
  assert.notEqual(afterSuccess.key,changed.key);

  const StorageDeniedConsole=await loadConsole({throwingSessionStorage:true});
  const deniedFirst=StorageDeniedConsole.privacyOperationAttempt('claim','request-2',{p_action:'claim'});
  const deniedRetry=StorageDeniedConsole.privacyOperationAttempt('claim','request-2',{p_action:'claim'});
  assert.equal(deniedFirst.key,deniedRetry.key);
});

test('privacy queue exposes bounded continuation when more than 100 requests exist',async()=>{
  const Console=await loadConsole();
  const CUI={status:label=>label};
  const rows=Array.from({length:100},(_,index)=>({
    request_id:`request-${index}`,status:'pending',requested_at:'2026-07-01T00:00:00Z',
    response_due_at:'2026-07-31T00:00:00Z',is_overdue:false,total_count:101
  }));
  const html=Console.accountDeletionQueueHtml(rows,CUI,{hasMore:true});
  assert.equal((html.match(/data-deletion-request=/g)||[]).length,100);
  assert.equal((html.match(/data-deletion-more/g)||[]).length,1);
  assert.match(html,/Load more privacy requests/);
});

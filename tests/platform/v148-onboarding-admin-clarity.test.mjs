import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const read=path=>readFile(new URL(`../../${path}`,import.meta.url),'utf8');

test('authenticated business setup identifies the current email and signs out only this browser',async()=>{
  const source=await read('app/index.html');
  const onboarding=source.match(/\/\* ---------- onboarding ---------- \*\/[\s\S]+?\/\* ={20,}/)?.[0]||'';
  assert.match(onboarding,/function businessSetupAccountHtml/);
  assert.match(onboarding,/Signed in as/);
  assert.match(onboarding,/S\.user\?\.email/);
  assert.match(onboarding,/Payment setup needs help[\s\S]+businessSetupAccountHtml/);
  assert.match(onboarding,/sb\.auth\.signOut\(\{scope:'local'\}\)/);
  assert.match(onboarding,/resetClientSessionState\(\)[\s\S]+renderAuth\('in'/);
});

test('admin platform console uses the V168 cache-busting asset key',async()=>{
  const source=await read('app/index.html');
  assert.match(source,/\/platform-console\.js\?v=20260805-v168-approved-admission/);
  assert.doesNotMatch(source,/\/platform-console\.js\?v=20260802-v134/);
});

test('platform separates assisted applications from paid website self-service',async()=>{
  const source=await read('app/platform-console.js');
  const queue=source.match(/function businessApplicationQueueHtml[\s\S]+?\n  function wireBusinessApplicationQueue/)?.[0]||'';
  const render=source.match(/async function renderOnboarding[\s\S]+?\n  function paymentManagedSignupItems/)?.[0]||'';
  assert.match(queue,/Assisted applications/);
  assert.match(queue,/Website signups activate after Stripe confirms payment/);
  assert.match(render,/platform_list_account_signups_v160/);
  assert.match(render,/accountSignupQueueHtml\(accountSignupQueue,CUI\)[\s\S]+paymentManagedSignupQueueHtml\(items,CUI\)[\s\S]+businessApplicationQueueHtml\(applicationQueue,CUI,items\)/);
  assert.match(render,/wireAccountSignupQueue\(\{\.\.\.context,filters\}\)/);
  assert.match(source,/Business owner signups/);
  assert.match(source,/Use Approve, Reject or Pending for each signup/);
  assert.match(source,/Approve lets this signup continue business setup/);
  assert.match(source,/Admin decision saved/);
  assert.doesNotMatch(source,/Email setup\/demo link/);
  assert.doesNotMatch(source,/Approve\/reject becomes available after a company\/demo\/manual-payment application is submitted/);
  assert.doesNotMatch(source,/Manage these as inbound CRM leads/);
  assert.match(source,/platform_record_account_signup_triage_v164/);
  assert.match(source,/data-account-signup-triage="contacted"/);
  assert.match(source,/data-account-signup-triage="follow_up"/);
  assert.match(source,/data-account-signup-triage="archived"/);
  assert.match(source,/Approve/);
  assert.match(source,/Reject/);
  assert.match(source,/Pending/);
  assert.match(source,/Website signups and paid workspaces/);
  assert.match(source,/Self-service signups are payment-managed/);
  assert.match(source,/Open firm directory/);
  assert.match(source,/Open billing/);
  assert.doesNotMatch(queue,/No owner account or workspace can be created until a super admin approves/);
  assert.doesNotMatch(queue,/New public business applications will appear here before any owner account can be created/);
});

test('self-service signups are surfaced by name without manual approval controls',async()=>{
  const source=await read('app/platform-console.js');
  const queue=source.match(/function paymentManagedSignupItems[\s\S]+?\n  function wireBusinessApplicationQueue/)?.[0]||'';
  assert.match(queue,/paymentManagedSignupItems/);
  assert.match(queue,/business_id/);
  assert.match(queue,/prospectCompany\(item\)/);
  assert.match(queue,/subscription_status/);
  assert.match(queue,/onboarding_status/);
  assert.match(queue,/approve\/reject is intentionally unavailable/);
  assert.doesNotMatch(queue,/data-business-approval/);
  assert.ok(queue.indexOf('function paymentManagedSignupQueueHtml')<queue.indexOf('function businessApplicationQueueHtml'));
});

test('account-only signup queue gives simple approve reject pending actions',async()=>{
  const consoleModule=await import('../../app/platform-console.js');
  const CUI={icon:()=>''};
  const html=consoleModule.accountSignupQueueHtml({
    items:[{
      phone:'+65 8160 0999',
      user_id:'00000000-0000-4000-8000-000000000160',
      created_at:'2026-08-04T04:00:00.000Z',
      status:'needs_business_details',
      triage_status:'follow_up',
      triage_note:'Owner asked for a demo callback.'
    }]
  },CUI);
  assert.match(html,/Business owner signups/);
  assert.match(html,/Admin decision/);
  assert.match(html,/Pending/);
  assert.match(html,/Approve lets this signup continue business setup/);
  assert.match(html,/Owner asked for a demo callback/);
  assert.match(html,/Approve/);
  assert.match(html,/Reject/);
  assert.match(html,/Pending/);
  assert.match(html,/data-account-signup-triage="contacted"/);
  assert.match(html,/data-account-signup-triage="archived"/);
  assert.match(html,/data-account-signup-triage="follow_up"/);
  assert.doesNotMatch(html,/Call owner/);
  assert.doesNotMatch(html,/Mark contacted/);
  assert.doesNotMatch(html,/Archive/);
  assert.doesNotMatch(html,/Follow up here/);
  assert.doesNotMatch(html,/href="tel:/);
  assert.doesNotMatch(html,/mailto:/);
  assert.doesNotMatch(html,/data-business-approval/);
});

test('enterprise filter helper occupies its own readable grid space',async()=>{
  const styles=await read('app/platform-console.css');
  const searchRule=styles.match(/\.platform-enterprise-search>p\{([^}]*)\}/)?.[1]||'';
  assert.doesNotMatch(searchRule,/margin-top\s*:\s*-/);
  assert.match(searchRule,/margin-top\s*:\s*(?:6|8|10)px/);
  assert.match(styles,/\.platform-enterprise-search\{[^}]*display:grid[^}]*gap:/);
  assert.match(styles,/@media\(max-width:760px\)[\s\S]*\.platform-enterprise-search\{grid-column:auto/);
});

test('existing onboarding CRM offers URL-persistent Kanban and List views',async()=>{
  const [source,styles]=await Promise.all([
    read('app/platform-console.js'),
    read('app/platform-console.css')
  ]);
  assert.match(source,/data-onboarding-view="kanban"/);
  assert.match(source,/data-onboarding-view="list"/);
  assert.match(source,/aria-pressed="\$\{view==='kanban'\}"/);
  assert.match(source,/params\.set\('view',view\)/);
  assert.match(source,/filters\.view=filters\.view==='list'\?'list':'kanban'/);
  assert.match(source,/platform-kanban"\$\{view==='kanban'\?'':' hidden'\}/);
  assert.match(source,/platform-prospect-list platform-prospect-list-view"\$\{view==='list'\?'':' hidden'\}/);
  assert.match(styles,/\.platform-kanban\[hidden\],\.platform-prospect-list\[hidden\]\{display:none!important\}/);
  assert.match(styles,/\.platform-kanban:not\(\[hidden\]\)\{display:grid;grid-template-columns:1fr\}/);
});

test('new prospect keeps one request identity through lost-response retry',async()=>{
  const source=await read('app/platform-console.js');
  const create=source.match(/async function newProspectModal[\s\S]+?\n  function prospectImportModal/)?.[0]||'';
  assert.match(create,/const createAttemptKey=idempotencyKey\(\)/);
  assert.match(create,/p_idempotency_key:createAttemptKey/);
  assert.doesNotMatch(create,/p_idempotency_key:idempotencyKey\(\)/);
  assert.match(create,/Prospect \{name\} was saved\. Refresh the onboarding list/);
});

test('Super Admin finance exposes the existing P&L and accounting scope on the V145 baseline',async()=>{
  const consoleModule=await import('../../app/platform-console.js');
  const superAccess=consoleModule.normalizePlatformAccess({role:'super_admin',module_permissions:{'*':'rw'}});
  const adminAccess=consoleModule.normalizePlatformAccess({role:'admin',module_permissions:{billing:'rw'}});
  assert.ok(consoleModule.visibleRoutes(superAccess).some(route=>route.key==='pnl'));
  assert.ok(!consoleModule.visibleRoutes(adminAccess).some(route=>route.key==='pnl'));
  assert.ok(consoleModule.platformNavigationGroups(consoleModule.visibleRoutes(superAccess))
    .find(group=>group.key==='finance').routes.some(route=>route.key==='pnl'));
  const source=await read('app/platform-console.js');
  assert.match(source,/platform_get_finance_v146/);
  assert.match(source,/platform_get_accounting_books_v147/);
  assert.match(source,/Operating expense ledger/);
  assert.match(source,/Trial balance/);
  assert.match(source,/General ledger/);
});

test('forward-integrated finance migrations remain append-only and balanced',async()=>{
  const [finance,accounting]=await Promise.all([
    read('db/migrations/20260803_nestly_v146_platform_finance.sql'),
    read('db/migrations/20260803_nestly_v147_platform_accounting.sql')
  ]);
  assert.match(finance,/create table public\.platform_operating_expense_entries_v146/i);
  assert.match(finance,/before update or delete on public\.platform_operating_expense_entries_v146/i);
  assert.match(finance,/app\.is_super_admin\(\)/i);
  assert.match(accounting,/create table public\.platform_accounting_journal_entries_v147/i);
  assert.match(accounting,/v_debits<>v_credits/);
  assert.match(accounting,/posted accounting records are immutable; reverse and replace instead/);
  assert.match(accounting,/platform_accounting_period_gate/);
});

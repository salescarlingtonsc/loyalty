import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('Firms route uses complete snapshot hierarchy, customer and report contracts',async()=>{
  const source=await read('app/platform-console.js');
  for(const rpc of [
    'platform_get_enterprise_hierarchy_v82',
    'platform_list_enterprise_customers_v82',
    'platform_generate_improvement_report_v82'
  ])assert.match(source,new RegExp(rpc));
  assert.match(source,/fetchEnterpriseFirmPages/);
  assert.match(source,/fetchEnterpriseCustomerPage/);
  assert.match(source,/fetchAllEnterpriseCustomers/);
  assert.match(source,/p_snapshot_at:snapshot/);
  assert.match(source,/p_after_created_at:cursor\?\.created_at/);
  assert.match(source,/p_after_business:cursor\?\.business_id/);
  assert.match(source,/p_after_client:cursor\?\.client_id/);
  assert.doesNotMatch(source,/p_firm_limit|p_customer_limit/);
});

test('enterprise search and scope reach both report and detail calls',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/p_search:filters\.search\\|\\|null/);
  assert.match(source,/Firm scope <span class="muted small">\(select one or more\)<\/span>/);
  assert.match(source,/Select exactly one firm to filter by branch/);
  assert.match(source,/data-enterprise-firm/);
  assert.match(source,/data-enterprise-branch/);
  assert.match(source,/Complete snapshot/);
});

test('enterprise detail has explicit branch and paged customer views',async()=>{
  const source=await read('app/platform-console.js');
  for(const label of [
    'Firm, branch and customer directory','Scope summary','Branches','Customers',
    'Net revenue','Cash collected','Completed transactions','Returning customers',
    'Load more customers'
  ])assert.match(source,new RegExp(label));
  assert.match(source,/customer\.phone/);
  assert.match(source,/customer\.email/);
  assert.match(source,/customer\.first_purchase_at/);
  assert.match(source,/customer\.last_purchase_at/);
});

test('report isolates currencies and downloads every customer page',async()=>{
  const [source,styles]=await Promise.all([
    read('app/platform-console.js'),read('app/platform-console.css')
  ]);
  assert.match(source,/Money by currency/);
  assert.match(source,/Money remains separated by currency/);
  assert.match(source,/Download complete CSV/);
  assert.match(source,/Preparing complete CSV/);
  assert.match(source,/reportCsvRows\(report,customers\)/);
  assert.match(source,/\['net_revenue_cents','completed_transactions','active_customers','returning_customers'\]/);
  assert.match(source,/while\(cursor\)/);
  assert.doesNotMatch(source,/p_limit:\s*10000|customers\.slice\(0,\s*250\)/);
  assert.match(source,/The returning-rate denominator is active customers/);
  assert.match(styles,/\.platform-report-sheet/);
  assert.match(styles,/@media print/);
});

test('enterprise default report dates are Singapore-local',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/function singaporeIsoDate/);
  assert.match(source,/timeZone:'Asia\/Singapore'/);
  assert.doesNotMatch(source,/function enterpriseDefaults[\s\S]{0,300}toISOString/);
});

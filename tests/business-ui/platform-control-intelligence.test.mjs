import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const [app,migration]=await Promise.all([
  readFile(new URL('../../app/index.html',import.meta.url),'utf8'),
  readFile(new URL('../../db/migrations/20260728_nestly_v94_platform_control_intelligence.sql',import.meta.url),'utf8')
]);

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
}

test('inventory and customer intelligence are absent from business navigation and typed routes fail closed',()=>{
  const nav=section("function navHtml(page,idPrefix='nav'){",'function wireNav(){');
  const route=section('async function route(){','/* ---------- customer wallet ---------- */');
  assert.match(app,/const HIDDEN_BUSINESS_SURFACES=new Set\(\['customerintel','inventory'\]\)/);
  assert.match(nav,/filter\(module=>!HIDDEN_BUSINESS_SURFACES\.has\(module\)\)/);
  assert.match(route,/if\(HIDDEN_BUSINESS_SURFACES\.has\(pageKey\)\)/);
  assert.match(route,/This area is not available in the business workspace/);
  assert.doesNotMatch(nav,/enabled\.push\('customerintel'\)/);
});

test('workspace switching distinguishes customer view, current firm and other staff workspaces',()=>{
  const customer=section('function customerWorkspaceSwitchHtml(','function businessWorkspaceSwitchHtml(');
  const business=section('function businessWorkspaceSwitchHtml(','function renderNoCustomerDestination(');
  const shell=section('function renderShell(page){','const M=()=>');
  assert.match(customer,/\$\{esc\(name\)\} workspace/);
  assert.match(customer,/Business workspaces \(\$\{workspaces\.length\}\)/);
  assert.match(business,/workspace\.business_slug!==currentBusinessSlug/);
  assert.match(business,/hasCustomerPersona/);
  assert.match(business,/Customer view/);
  assert.match(business,/Switch workspace/);
  assert.match(shell,/businessWorkspaceSwitchHtml\(S\.staffWorkspaces,S\.biz\.slug,S\.hasCustomerPersona\)/);
  assert.doesNotMatch(shell,/customerWorkspaceSwitchHtml\(S\.staffWorkspaces\)/);
});

test('Quick Earn is catalogue-first and an explicit firm setting can fall back to amount-only',()=>{
  const till=section('async function tillPage(){','async function salesPage(){');
  assert.match(till,/let catalogueSelectionEnabled=S\.biz\.quick_earn_catalogue_enabled!==false/);
  assert.match(till,/return catalogueSelectionEnabled\?drawCartComposer\(\):drawCustomerCard\(\)/);
  assert.doesNotMatch(till,/TILL_CART_PREF|tModeToggle|sessionStorage\.getItem\([^)]*cartMode/);
  assert.match(till,/business_get_checkout_catalogue_v94/);
  assert.match(till,/p_business:S\.biz\.id,p_branch:tillBranchId,p_include_inactive:false/);
  assert.match(till,/checkout_active===true&&item\?\.branch_available!==false/);
  assert.doesNotMatch(till,/wantProducts=canReadModule\('inventory'\)/);
  assert.doesNotMatch(till,/sb\.from\('services'\)[\s\S]{0,180}eq\('active',true\)/);
  assert.doesNotMatch(till,/sb\.from\('products'\)[\s\S]{0,180}eq\('active',true\)/);
  assert.match(till,/Choose products or services, review the checked total, then select how the customer paid/);
  assert.match(till,/legend style="font-size:13px;font-weight:700">Payment received/);
  assert.match(till,/evaluate_checkout/);
  assert.match(till,/record_cart_sale/);
  assert.match(till,/Loading products and services for this branch/);
  assert.match(till,/id="tCatRetry"/);
  assert.match(till,/cart=\[\];catalog=null;catalogError=null;clearCheckoutState\(\)/);
  assert.match(till,/No checkout items at this branch/);
});

test('customer profile cannot bypass the branch-scoped QR redemption workflow',()=>{
  const detail=section('async function clientDetail(id){','async function tillPage(){');
  assert.match(detail,/To complete a customer reward, scan their pending QR in Record sale\. Points change only after confirmation\./);
  assert.match(detail,/Open Record sale scanner/);
  assert.doesNotMatch(detail,/sb\.rpc\('redeem_points'/);
  assert.doesNotMatch(detail,/sb\.rpc\('redeem_reward(?:_at_context)?'/);
  assert.doesNotMatch(detail,/class="btn sm rewardGo"/);
});

test('v94 retires direct redemption grants and enforces Till at immutable sale boundaries',()=>{
  for(const signature of [
    'redeem_points\\(uuid,uuid,text\\)',
    'redeem_reward\\(uuid,uuid,uuid,text\\)',
    'redeem_reward_at_context\\([\\s\\n]*uuid,uuid,uuid,text,uuid,uuid,uuid[\\s\\n]*\\)'
  ]){
    assert.match(migration,new RegExp(`revoke execute on function public\\.${signature}[\\s\\S]*?from authenticated`,'i'));
  }
  assert.match(migration,/trg_sales_branch_module_v94[\s\S]*?'sales','rw','till','rw','quick_sale'/);
  assert.match(migration,/trg_checkout_evaluations_branch_module_v94[\s\S]*?'sales','rw','till','rw'/);
  assert.match(migration,/active_branch_required[\s\S]*?app\.require_branch_module_v94\([\s\S]*?'loyalty','rw'/);
});

test('v94 catalogue and consolidated reports fail closed for partial branch scope',()=>{
  assert.match(migration,/app\.can_see_branch\(p_business,branch\.id\)/);
  assert.match(migration,/explicit_branch_required_for_partial_report_scope/);
  assert.match(migration,/not app\.can_see_branch\(p_business,branch\.id\)[\s\S]*?or not app\.can_module_read_at_v94\([\s\S]*?p_business,branch\.id,'reports'/);
});

test('catalogue and workspace controls retain mobile touch sizing and responsive placement',()=>{
  assert.match(app,/\.till-cart-catalog \.btn\{min-height:64px/);
  assert.match(app,/\.business-workspace-switch \.menu a,[\s\S]*min-height:44px/);
  assert.match(app,/\.checkout-catalogue-item\{[\s\S]*min-height:64px/);
  assert.match(app,/\.checkout-catalogue-item \.btn\{min-height:44px/);
  assert.match(app,/@media\(max-width:960px\)[\s\S]*\.appbar\{[\s\S]*flex-wrap:wrap/);
});

test('owner Settings exposes a stock-free Checkout Catalogue with fail-closed RPC controls',()=>{
  const settings=section('async function settingsPage(){','/* ---------- billing (read-only) ---------- */');
  assert.match(settings,/data-settab="catalogue">Checkout catalogue/);
  assert.match(settings,/id="checkoutCatalogueWrap"/);
  assert.match(settings,/business_get_checkout_catalogue_v94/);
  assert.match(settings,/p_business:S\.biz\.id,p_branch:branchId\|\|null,p_include_inactive:true/);
  assert.match(settings,/business_set_checkout_catalogue_enabled_v94/);
  assert.match(settings,/business_set_checkout_catalogue_item_v94/);
  assert.match(settings,/item&&\['service','product'\]\.includes\(item\.item_type\)/);
  assert.match(settings,/Not offered at this branch/);
  assert.match(settings,/Checkout catalogue unavailable/);
  assert.match(settings,/checkoutCatalogueRetry/);
  assert.match(settings,/No products or services yet/);
  assert.match(settings,/This does not manage stock/);
  assert.doesNotMatch(settings,/from\('(?:inventory|stock|suppliers)'|quantity_on_hand|cost_cents|reorder_level/i);
});

test('business routes fail closed before modules when approval or billing blocks the workspace',()=>{
  const route=section('async function route(){','/* ---------- customer wallet ---------- */');
  const blocked=section('function renderBusinessWorkspaceControl(','/* ---------- auth ---------- */');
  const controlCall=route.indexOf("'platform_get_business_control_v94'");
  const moduleCall=route.indexOf("'get_my_modules'");
  assert.ok(controlCall>0&&controlCall<moduleCall,'workspace control must resolve before module or business data');
  const businessRead=route.indexOf("sb.from('businesses').select('*').eq('slug',workspaceSlug)");
  assert.ok(controlCall<businessRead,'pending owners must see the gate before the business-row policy is evaluated');
  assert.match(route,/p_business:workspaceStaffPersona\.business_id/);
  assert.match(route,/if\(result\.error\|\|!result\.data\)return renderPersonaResolutionUnavailable\(\)/);
  assert.match(route,/if\(workspaceControl\.workspace_access!==true\)return renderBusinessWorkspaceControl\(workspaceControl\)/);
  assert.match(route,/S\.biz\.quick_earn_catalogue_enabled=workspaceControl\.quick_earn_catalogue_enabled!==false/);
  assert.match(blocked,/Approval pending/);
  assert.match(blocked,/Business access paused/);
  assert.match(blocked,/must approve it before any business information or functions are available/);
  assert.match(blocked,/Business-owner access is paused until provider payment is confirmed/);
  assert.match(blocked,/href="tel:\$\{esc\(hotline\)\}"/);
});

test('new self-service firms remain locked until provider-confirmed payment',()=>{
  const onboard=section('function renderOnboard(){','/* ============================================================================');
  assert.match(onboard,/start_self_serve_business_v130/);
  assert.match(onboard,/request_self_serve_checkout_v130/);
  assert.match(onboard,/remains locked until Stripe confirms the first paid invoice/);
  assert.doesNotMatch(onboard,/create_business|p_modules|Workspace ready/);
});

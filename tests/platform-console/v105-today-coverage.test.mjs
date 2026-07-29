import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);

async function loadConsole(){
  const source=await readFile(new URL('app/platform-console.js',root),'utf8');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

const CUI={
  emptyState:({title,body})=>`<div data-empty-state><b>${title}</b><p>${body}</p></div>`
};

test('Today exhausts every safe attention page and keeps actionable row 251',async()=>{
  const Console=await loadConsole();
  const calls=[];
  const first=Array.from({length:250},(_,index)=>({
    id:`attention-${String(index+1).padStart(3,'0')}`,
    prospect_id:`prospect-${index+1}`,company_name:`Spa ${index+1}`,
    attention_due:true,days_unattended:400-index
  }));
  const final=[{
    id:'attention-251',prospect_id:'prospect-251',
    company_name:'Beyond First Page Spa',attention_due:true,days_unattended:149
  }];
  const sb={rpc:async(name,args)=>{
    calls.push({name,args});
    assert.equal(name,'platform_list_firm_attention_v88');
    if(calls.length===1)return{data:{
      snapshot_at:'2026-07-29T10:00:00Z',total_count:251,items:first,
      next_cursor:{days_unattended:151,id:'attention-250'}
    }};
    return{data:{
      snapshot_at:'2026-07-29T10:00:00Z',total_count:251,items:final,
      next_cursor:{days_unattended:149,id:'attention-251'}
    }};
  }};

  const result=await Console.fetchAllFirmAttentionV88(sb,{limit:250,maxPages:4});
  assert.equal(calls.length,2);
  assert.equal(calls[1].args.p_snapshot_at,'2026-07-29T10:00:00Z');
  assert.equal(calls[1].args.p_after_days_unattended,151);
  assert.equal(calls[1].args.p_after_id,'attention-250');
  assert.equal(result.items.length,251);
  assert.equal(result.items.at(-1).company_name,'Beyond First Page Spa');
  assert.equal(result.complete,true);
  assert.equal(result.truncated,false);
});

test('delegated admin and sales Today exhaust row 51 inside the frozen scoped cursor',async()=>{
  const Console=await loadConsole();
  for(const role of ['admin','sales_staff']){
    const calls=[];
    const healthy=Array.from({length:50},(_,index)=>({
      prospect_id:`${role}-prospect-${index+1}`,
      company_name:`${role} healthy firm ${index+1}`,
      stage:'activated',
      next_action_at:'2026-08-30T10:00:00Z'
    }));
    const second=Array.from({length:25},(_,index)=>({
      prospect_id:`${role}-prospect-${index+51}`,
      company_name:index===0?'Beyond First Page Salon':`${role} healthy firm ${index+51}`,
      stage:index===0?'onboarding':'activated',
      onboarding_status:index===0?'blocked':'healthy',
      overdue_task_count:index===0?1:0,
      next_action_at:'2026-08-30T10:00:00Z'
    }));
    const sb={rpc:async(name,args)=>{
      calls.push({name,args});
      assert.equal(name,'platform_list_my_firms_v105');
      return{data:calls.length===1?{
        scope:role==='sales_staff'?'own_created_or_assigned':'all',
        snapshot_at:'2026-07-29T11:00:00Z',
        total_count:75,items:healthy,
        next_cursor:{updated_at:'2026-07-01T00:00:00Z',id:`${role}-cursor-50`}
      }:{
        scope:role==='sales_staff'?'own_created_or_assigned':'all',
        snapshot_at:'2026-07-29T11:00:00Z',
        total_count:75,items:second,next_cursor:null
      }};
    }};

    const payload=await Console.fetchAllScopedFirms(sb,'',{limit:50,maxPages:4});
    const queue=Console.buildPlatformTodayQueue({
      prospects:payload.items,scoped:true
    });
    assert.equal(calls.length,2,`${role} must load the page after 50`);
    assert.equal(calls[1].args.p_snapshot_at,'2026-07-29T11:00:00Z');
    assert.equal(calls[1].args.p_after_id,`${role}-cursor-50`);
    assert.equal(payload.complete,true);
    assert.equal(payload.items.length,75);
    assert.ok(queue.some(item=>item.name==='Beyond First Page Salon'),
      `${role} Today must not omit an actionable case after the first page`);
  }
});

test('delegated Today exposes partial lower bounds when its safe paging guard stops',async()=>{
  const Console=await loadConsole();
  const first=Array.from({length:50},(_,index)=>({
    prospect_id:`partial-prospect-${index+1}`,
    company_name:`Partial firm ${index+1}`,stage:'activated'
  }));
  const sb={rpc:async()=>({data:{
    scope:'own_created_or_assigned',snapshot_at:'2026-07-29T11:00:00Z',
    total_count:75,items:first,
    next_cursor:{updated_at:'2026-07-01T00:00:00Z',id:'partial-cursor-50'}
  }})};
  const payload=await Console.fetchAllScopedFirms(sb,'',{limit:50,maxPages:1});
  const coverage=Console.buildPlatformTodayCoverage([
    Console.platformTodayCoverageDomain({
      key:'scoped-firms',label:'Assigned and self-created firms',
      returned:payload.items.length,total:payload.total_count,
      truncated:payload.truncated
    })
  ]);
  const domain=coverage.domains[0];
  const html=Console.platformTodayQueueHtml([],CUI,{
    sales:true,scope:'own_created_or_assigned',coverage
  });

  assert.equal(payload.complete,false);
  assert.equal(payload.truncated,true);
  assert.equal(domain.state,'partial');
  assert.equal(Console.platformTodayMetric(0,domain),'0+');
  assert.equal(Console.platformTodayMetric(75,domain,{exact:true}),'75');
  assert.doesNotMatch(html,/You are caught up/);
  assert.match(html,/data-coverage-domain="scoped-firms" data-coverage-state="partial"/);
});

test('both delegated role routes wire exhaustive scoped coverage into queue and KPI rendering',async()=>{
  const source=await readFile(new URL('app/platform-console.js',root),'utf8');
  const start=source.indexOf('async function renderScopedOverview');
  const end=source.indexOf('async function loadRoster',start);
  assert.notEqual(start,-1);
  assert.notEqual(end,-1);
  const scoped=source.slice(start,end);
  assert.match(source,/const useScopedV89=access\.role!=='super_admin'/);
  assert.match(scoped,/fetchAllScopedFirms\(sb,''/);
  assert.match(scoped,/platformTodayCoverageDomain/);
  assert.match(scoped,/platformTodayQueueHtml[\s\S]*coverage:scopedCoverage/);
  assert.match(scoped,/platformTodayMetric\(value,scopedDomain,\{exact\}\)/);
  assert.doesNotMatch(scoped,/coverageNote:/);
});

test('every cap-only Today domain reports partial coverage instead of exact completeness',async()=>{
  const Console=await loadConsole();
  const coverage=Console.buildPlatformTodayCoverage([
    Console.platformTodayCoverageDomain({
      key:'firms',label:'Firms',returned:50,total:421,truncated:true
    }),
    Console.platformTodayCoverageDomain({
      key:'attention',label:'Onboarding attention',returned:301,total:301
    }),
    Console.platformTodayCoverageDomain({
      key:'billing',label:'Billing',returned:250,limit:250
    }),
    Console.platformTodayCoverageDomain({
      key:'commissions',label:'Commissions',returned:100,limit:100
    }),
    Console.platformTodayCoverageDomain({
      key:'applications',label:'Owner applications',returned:100,truncated:true
    }),
    Console.platformTodayCoverageDomain({
      key:'automation',label:'Automation',returned:50,limit:50
    })
  ]);

  assert.equal(coverage.complete,false);
  assert.deepEqual(
    Array.from(coverage.partial),
    ['firms','billing','commissions','applications','automation']
  );
  assert.equal(coverage.domains.find(domain=>domain.key==='attention').state,'complete');
  assert.equal(
    Console.platformTodayMetric(100,coverage.domains.find(domain=>domain.key==='applications')),
    '100+'
  );
  assert.equal(
    Console.platformTodayMetric(421,coverage.domains.find(domain=>domain.key==='firms'),{exact:true}),
    '421'
  );
});

test('partial or failed coverage never renders the caught-up claim',async()=>{
  const Console=await loadConsole();
  await assert.rejects(
    Console.fetchAllFirmAttentionV88({
      rpc:async()=>({error:{message:'attention reader timed out'}})
    }),
    error=>error?.message==='attention reader timed out'
  );
  const coverage=Console.buildPlatformTodayCoverage([
    Console.platformTodayCoverageDomain({
      key:'applications',label:'Owner applications',returned:100,truncated:true
    }),
    Console.platformTodayCoverageDomain({
      key:'billing',label:'Billing',failed:true
    })
  ]);
  const html=Console.platformTodayQueueHtml([],CUI,{coverage});

  assert.doesNotMatch(html,/You are caught up/);
  assert.match(html,/No work is visible in the loaded coverage/);
  assert.match(html,/data-coverage-complete="false"/);
  assert.match(html,/data-coverage-domain="applications" data-coverage-state="partial"/);
  assert.match(html,/data-coverage-domain="billing" data-coverage-state="unavailable"/);
  assert.match(html,/Coverage incomplete/);

  const complete=Console.buildPlatformTodayCoverage([
    Console.platformTodayCoverageDomain({
      key:'attention',label:'Onboarding attention',returned:0,total:0
    })
  ]);
  assert.match(Console.platformTodayQueueHtml([],CUI,{coverage:complete}),/You are caught up/);
});

test('Today remains visually bounded while disclosing all loaded work beyond the first view',async()=>{
  const Console=await loadConsole();
  const applications=Array.from({length:105},(_,index)=>({
    id:`application-${index+1}`,business_name:`Firm ${index+1}`,
    status:'submitted',submitted_at:'2026-07-29T10:00:00Z'
  }));
  const queue=Console.buildPlatformTodayQueue({applications});
  const coverage=Console.buildPlatformTodayCoverage([
    Console.platformTodayCoverageDomain({
      key:'applications',label:'Owner applications',
      returned:100,truncated:true
    })
  ]);
  const html=Console.platformTodayQueueHtml(queue,CUI,{limit:12,coverage});

  assert.equal((html.match(/data-platform-today-item/g)||[]).length,12);
  assert.match(html,/93 more items remain in the linked work areas/);
  assert.match(html,/Coverage incomplete/);
  assert.match(html,/At least 100 records loaded/);
});

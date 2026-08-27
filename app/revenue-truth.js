(function revenueTruthModule(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.RevenueTruthUI=api;
})(typeof globalThis!=='undefined'?globalThis:this,function revenueTruthFactory(){
  'use strict';

  const READY_STATES=new Set(['ready','available','exact','complete','ok']);
  const PARTIAL_STATES=new Set(['partial','partial_data','partial_coverage','lower_bound']);
  const EMPTY_STATES=new Set(['empty','no_data']);
  const INSUFFICIENT_STATES=new Set(['insufficient','insufficient_data','suppressed']);
  const STALE_STATES=new Set(['stale','expired']);
  const BRANCH_STATES=new Set(['branch','branch_unavailable']);
  const PERMISSION_STATES=new Set(['permission','permission_denied','forbidden']);
  const ERROR_STATES=new Set(['error','failed','unavailable']);
  const INCREMENTAL_STATES=new Set(['experiment_valid','incremental_eligible','measured']);
  const SENT_STATES=new Set(['sent','delivered']);
  const DELIVERED_STATES=new Set(['delivered']);
  const PROFIT_STATES=new Set(['complete','profit_eligible','measured']);

  const asObject=value=>value&&typeof value==='object'&&!Array.isArray(value)?value:{};
  const asArray=value=>Array.isArray(value)?value:[];
  const finite=value=>{
    if(value===null||value===undefined||value==='')return null;
    const number=Number(value);
    return Number.isFinite(number)?number:null;
  };
  const clampPercent=value=>{
    const number=finite(value);
    return number===null?null:Math.max(0,Math.min(100,number));
  };
  const text=value=>value===null||value===undefined?'':String(value);
  const escapeHtml=value=>text(value)
    .replaceAll('&','&amp;')
    .replaceAll('<','&lt;')
    .replaceAll('>','&gt;')
    .replaceAll('"','&quot;')
    .replaceAll("'",'&#039;');

  function normalizeStatus(value,fallback='insufficient'){
    const status=text(value).trim().toLowerCase();
    if(READY_STATES.has(status))return 'ready';
    if(PARTIAL_STATES.has(status))return 'partial';
    if(EMPTY_STATES.has(status))return 'empty';
    if(INSUFFICIENT_STATES.has(status))return 'insufficient';
    if(status==='not_computed')return 'not_computed';
    if(STALE_STATES.has(status))return 'stale';
    if(BRANCH_STATES.has(status))return 'branch';
    if(PERMISSION_STATES.has(status))return 'permission';
    if(ERROR_STATES.has(status))return 'error';
    return fallback;
  }

  function money(cents,currency=''){
    const value=finite(cents);
    const currencyCode=text(currency).trim().toUpperCase();
    if(value===null||!currencyCode)return 'Not available';
    try{
      return new Intl.NumberFormat('en-SG',{
        style:'currency',currency:currencyCode,
        currencyDisplay:'code',
        minimumFractionDigits:2,maximumFractionDigits:2
      }).format(value/100);
    }catch(_error){
      return `${currencyCode} ${(value/100).toFixed(2)}`;
    }
  }

  function percentage(value){
    const number=clampPercent(value);
    return number===null?'Not enough data':`${number.toFixed(number%1===0?0:1)}%`;
  }

  function safeDate(value){
    if(!value)return '';
    const date=new Date(value);
    if(Number.isNaN(date.getTime()))return text(value);
    return new Intl.DateTimeFormat('en-SG',{
      day:'numeric',month:'short',year:'numeric',hour:'numeric',minute:'2-digit',
      timeZone:'Asia/Singapore'
    }).format(date);
  }

  function claimCapabilities(briefing){
    const source=asObject(briefing);
    const action=asObject(source.top_action);
    const execution=asObject(action.execution);
    const measurement=asObject(action.measurement);
    const profit=asObject(action.profit);
    const claims=asObject(action.claims);
    const executionState=text(execution.state||action.execution_status).toLowerCase();
    const measurementState=text(measurement.status).toLowerCase();
    const profitState=text(profit.status||action.profit_status).toLowerCase();
    return {
      sent:claims.sent===true&&SENT_STATES.has(executionState),
      delivered:claims.delivered===true&&DELIVERED_STATES.has(executionState),
      incremental:claims.incremental_revenue===true&&INCREMENTAL_STATES.has(measurementState),
      profit:claims.profit===true&&PROFIT_STATES.has(profitState)
    };
  }

  function guardClaimText(value,capabilities={}){
    let guarded=text(value);
    if(!capabilities.delivered)guarded=guarded.replace(/\bdelivered\b/gi,'delivery not confirmed');
    if(!capabilities.sent)guarded=guarded.replace(/\bsent\b/gi,'prepared');
    if(!capabilities.incremental)guarded=guarded.replace(/\bincremental\b/gi,'estimated');
    if(!capabilities.profit)guarded=guarded.replace(/\bprofits?\b/gi,'revenue');
    return guarded;
  }

  function truthState(truth){
    const source=asObject(truth);
    const explicit=normalizeStatus(source.status,'');
    if(explicit)return explicit;
    const freshness=normalizeStatus(asObject(source.freshness).status,'');
    if(freshness==='stale')return 'stale';
    return 'insufficient';
  }

  function normalizeTruth(payload){
    const source=asObject(payload);
    const totals=asObject(source.totals);
    const coverage=asObject(source.coverage);
    const scope=asObject(source.scope);
    const period=asObject(scope.period);
    const freshness=asObject(source.freshness);
    const limitations=asArray(source.limitations).map(text).filter(Boolean);
    const explicitState=truthState(source);
    const knownRevenue=finite(totals.known_revenue_minor);
    return {
      contractVersion:text(source.contract_version),
      state:explicitState,
      asOf:source.as_of||source.generated_at||null,
      scope:{
        businessId:scope.business_id||null,
        branchId:scope.branch_id||null,
        businessName:text(scope.business_name),
        branchName:text(scope.branch_name),
        currency:text(scope.currency).toUpperCase(),
        timezone:text(scope.timezone||'Asia/Singapore'),
        from:text(period.from||scope.from),
        to:text(period.to||scope.to)
      },
      totals:{
        knownRevenueMinor:knownRevenue,
        identifiedRevenueMinor:finite(totals.identified_revenue_minor),
        anonymousRevenueMinor:finite(totals.anonymous_revenue_minor),
        completedTransactions:finite(totals.completed_transactions),
        identifiedTransactions:finite(totals.identified_transactions),
        anonymousTransactions:finite(totals.anonymous_transactions),
        itemizedTransactions:finite(totals.itemized_transactions)
      },
      coverage:{
        identityRevenuePct:clampPercent(coverage.identity_revenue_pct),
        identityTransactionPct:clampPercent(coverage.identity_transaction_pct),
        itemizationTransactionPct:clampPercent(coverage.itemization_transaction_pct),
        reconciledTransactionPct:clampPercent(coverage.reconciled_transaction_pct)
      },
      freshness:{
        latestSaleOccurredAt:freshness.latest_sale_occurred_at||null,
        latestSaleRecordedAt:freshness.latest_sale_recorded_at||null,
        latestExternalEventReceivedAt:freshness.latest_external_event_received_at||null,
        reconciliationConflicts:finite(freshness.reconciliation_conflicts)
      },
      merchantSourceComplete:false,
      limitations
    };
  }

  function normalizeLifecycle(payload){
    const source=asObject(payload);
    const metrics=asObject(source.metrics);
    const definitions=asObject(source.definitions);
    const coverage=asObject(source.coverage);
    return {
      state:normalizeStatus(source.status,'insufficient'),
      asOf:source.as_of||source.generated_at||null,
      metrics:{
        transactingIdentifiedCustomers:finite(metrics.transacting_identified_customers),
        newCustomers:finite(metrics.new_customers),
        existingReturningCustomers:finite(metrics.existing_returning_customers),
        repeatPurchasersInPeriod:finite(metrics.repeat_purchasers_in_period),
        reactivatedCustomers:finite(metrics.reactivated_customers),
        existingCustomerSharePct:clampPercent(metrics.existing_customer_share_pct),
        repeatInPeriodRatePct:clampPercent(metrics.repeat_in_period_rate_pct),
        customerCadenceClassifications:finite(metrics.customer_cadence_classifications),
        fallbackClassifications:finite(metrics.fallback_classifications)
      },
      definitions:{
        existingReturning:text(definitions.existing_returning_customer||
          'Bought before this period and bought again during it.'),
        repeatInPeriod:text(definitions.repeat_purchaser_in_period||
          'Made at least two eligible purchases inside this period.'),
        reactivated:text(definitions.reactivated_customer||
          'Bought again after passing the applicable lapse threshold.')
      },
      identityTransactionPct:clampPercent(coverage.identified_transaction_pct)
    };
  }

  function normalizeBriefing(payload){
    const source=asObject(payload);
    const action=source.top_action&&typeof source.top_action==='object'?source.top_action:null;
    const capabilities=claimCapabilities(source);
    const safe=value=>guardClaimText(value,capabilities);
    const expected=asObject(action?.expected_incremental_revenue);
    const confidence=asObject(action?.confidence);
    const audience=asObject(action?.audience);
    const actionDetail=asObject(action?.action);
    const measurement=asObject(action?.measurement);
    const evidence=asArray(action?.evidence).slice(0,4).map(item=>{
      if(item&&typeof item==='object'){
        return {
          label:safe(item.label||item.title||item.metric||'Evidence'),
          value:safe(item.value??item.detail??item.explanation??'')
        };
      }
      return {label:'Evidence',value:safe(item)};
    }).filter(item=>item.value);
    return {
      state:normalizeStatus(source.data_status||source.status,action?'ready':'insufficient'),
      generatedAt:source.generated_at||source.as_of||null,
      suppressions:asArray(source.suppressions).map(safe).filter(Boolean),
      capabilities,
      action:action?{
        id:action.recommendation_id||null,
        status:text(action.status),
        type:text(action.type||'bring_back'),
        title:safe(action.title||'Bring back customers who are overdue'),
        finding:safe(action.finding||'A customer group may be ready for a timely reminder.'),
        evidence,
        observationWindow:asObject(action.observation_window),
        comparisonWindow:asObject(action.comparison_window),
        audience:{
          eligible:finite(audience.eligible),
          excluded:finite(audience.excluded),
          treatment:finite(audience.treatment),
          holdout:finite(audience.holdout)
        },
        revenueRange:{
          lowCents:finite(expected.low_cents),
          highCents:finite(expected.high_cents),
          currency:text(expected.currency).toUpperCase(),
          unavailableReason:safe(expected.unavailable_reason)
        },
        estimatedCostCents:finite(action.estimated_cost_cents),
        confidence:{
          level:text(confidence.level||'insufficient').toLowerCase(),
          scoreBps:finite(confidence.score_bps),
          reasons:asArray(confidence.reasons).map(safe).filter(Boolean)
        },
        action:{
          label:safe(actionDetail.label||'Preview action'),
          channel:safe(actionDetail.channel||'Not selected'),
          offer:safe(actionDetail.offer||'No offer preview is available yet.'),
          expiresAt:actionDetail.expires_at||null,
          valueCents:finite(actionDetail.value_cents),
          currency:text(actionDetail.currency||expected.currency).toUpperCase(),
          expiresInDays:finite(actionDetail.expires_in_days),
          requiresOwnerApproval:actionDetail.requires_owner_approval!==false
        },
        measurement:{
          method:safe(measurement.method||'Not yet measured'),
          attributionDays:finite(measurement.attribution_days),
          minimumSample:finite(measurement.minimum_sample),
          status:text(measurement.status||'not_started').toLowerCase()
        }
      }:null
    };
  }

  function combineState(truth,lifecycle,briefing,requestState='ready'){
    const requested=normalizeStatus(requestState,'ready');
    if(['permission','branch','error','stale'].includes(requested))return requested;
    if(['permission','branch','error','stale'].includes(truth.state))return truth.state;
    if(['permission','branch','error','stale'].includes(lifecycle.state))return lifecycle.state;
    if(truth.state==='empty')return 'empty';
    if(truth.state==='partial'||lifecycle.state==='partial'||briefing.state==='partial')return 'partial';
    if(truth.state==='insufficient'||lifecycle.state==='insufficient')return 'insufficient';
    return 'ready';
  }

  function buildViewModel({truth,lifecycle,briefing,requestState='ready',errorMessage=''}={}){
    const normalizedTruth=normalizeTruth(truth);
    const normalizedLifecycle=normalizeLifecycle(lifecycle);
    const normalizedBriefing=normalizeBriefing(briefing);
    const state=combineState(normalizedTruth,normalizedLifecycle,normalizedBriefing,requestState);
    const actionAllowed=['ready','partial'].includes(state)&&
      normalizedBriefing.state==='ready'&&!!normalizedBriefing.action&&
      !['insufficient','low'].includes(normalizedBriefing.action.confidence.level);
    return {
      state,
      truth:normalizedTruth,
      lifecycle:normalizedLifecycle,
      briefing:normalizedBriefing,
      actionAllowed,
      errorMessage:text(errorMessage)
    };
  }

  const statusCopy={
    ready:{
      label:'Current evidence',
      title:'Your revenue picture is ready',
      body:'Figures below use the selected business, period and branch.'
    },
    partial:{
      label:'Partial coverage',
      title:'Useful, but not the whole business',
      body:'Peekaa can explain the recorded rows below. Missing or unreconciled sources may make the true business total higher.'
    },
    empty:{
      label:'No sales yet',
      title:'There is no revenue to summarise yet',
      body:'Record a completed sale in this scope, then return for a truthful briefing.'
    },
    insufficient:{
      label:'Building evidence',
      title:'Not enough reliable data yet',
      body:'Peekaa is withholding ratios and recommendations until their denominators and evidence are defensible.'
    },
    stale:{
      label:'Needs refresh',
      title:'This briefing is stale',
      body:'Refresh before using these figures or acting on a customer opportunity.'
    },
    permission:{
      label:'Restricted',
      title:'Finance access is required',
      body:'Ask the owner for finance access to view revenue coverage and customer intelligence.'
    },
    branch:{
      label:'Branch unavailable',
      title:'This branch is outside your current access',
      body:'Choose a branch assigned to your role. No business-wide figure has been substituted.'
    },
    error:{
      label:'Could not load',
      title:'Revenue truth is temporarily unavailable',
      body:'Nothing below should be treated as current. Try loading the briefing again.'
    }
  };

  function stateBanner(view){
    /* nestly_v571 (owner mark): the all-clear banner ("Your revenue picture is ready") repeated
       what the figures underneath already state, so it is suppressed. Every other state is a
       caveat the owner must see before trusting a number — those still render. */
    if(view.state==='ready'&&!view.errorMessage)return '';
    const copy=statusCopy[view.state]||statusCopy.insufficient;
    const action=['stale','error'].includes(view.state)
      ?'<button class="btn ghost sm revenue-truth-retry" type="button" data-revenue-truth-action="retry">Try again</button>'
      :'';
    return `<section class="revenue-truth-state revenue-truth-state--${escapeHtml(view.state)}" role="status" aria-live="polite">
      <div><span class="revenue-truth-eyebrow">${escapeHtml(copy.label)}</span>
      <h2>${escapeHtml(copy.title)}</h2><p>${escapeHtml(view.errorMessage||copy.body)}</p></div>${action}</section>`;
  }

  function metricCard(label,value,helper,{tone='neutral'}={}){
    return `<article class="revenue-truth-metric revenue-truth-metric--${escapeHtml(tone)}">
      <span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong><small>${escapeHtml(helper)}</small>
    </article>`;
  }

  function revenueMarkup(view){
    const truth=view.truth,currency=truth.scope.currency;
    if(view.state==='permission'||view.state==='branch')return '';
    const recorded=truth.totals.knownRevenueMinor===null
      ?'No recorded revenue total is available.'
      :`${money(truth.totals.knownRevenueMinor,currency)} is recorded in the Peekaa sales ledger.`;
    const reconciliation=truth.coverage.reconciledTransactionPct===null
      ?'External reconciliation coverage is not available.'
      :`${percentage(truth.coverage.reconciledTransactionPct)} of native Peekaa sale records have a linked external reconciliation.`;
    const recordedHelper=`${recorded} ${reconciliation} This does not prove merchant-source completeness, so total business revenue remains unavailable.`;
    const identifiedHelper=truth.coverage.identityRevenuePct===null
      ?'Linked customer coverage cannot be calculated yet.'
      :'Revenue linked to a verified or known customer record.';
    /* nestly_v522: this tested anonymousRevenueCents, a key buildViewModel never sets — it
       sets anonymousRevenueMinor — so the "not supplied" branch was unreachable and a
       missing figure was captioned as though it were a real recorded zero. The VALUE was
       always honest (money(null) renders "Not available"); only the caption was wrong. */
    const anonymousHelper=truth.totals.anonymousRevenueMinor===null
      ?'Unattributed revenue has not been supplied by the current contract.'
      :'Recorded revenue with no linked customer identity.';
    const coverageHelper=truth.coverage.identityRevenuePct===null
      ?'A zero denominator is shown as not enough data, never 0%.'
      :'Identified customer revenue ÷ revenue recorded in Peekaa.';
    return `<section class="revenue-truth-section" aria-labelledby="revenueTruthHeading">
      <div class="revenue-truth-section-head"><div><span class="revenue-truth-eyebrow">Revenue truth</span>
      <h2 id="revenueTruthHeading">What Peekaa can prove</h2></div>
      <span class="revenue-truth-asof">As of ${escapeHtml(safeDate(truth.asOf)||'not supplied')}</span></div>
      <div class="revenue-truth-metrics">
        ${metricCard('Peekaa recorded revenue',truth.totals.knownRevenueMinor===null?'Not available':money(truth.totals.knownRevenueMinor,currency),recordedHelper,{tone:'caution'})}
        ${metricCard('Identified customer revenue',money(truth.totals.identifiedRevenueMinor,currency),identifiedHelper)}
        ${metricCard('Anonymous / unattributed revenue',money(truth.totals.anonymousRevenueMinor,currency),anonymousHelper)}
        ${metricCard('Member revenue coverage',percentage(truth.coverage.identityRevenuePct),coverageHelper,{tone:truth.coverage.identityRevenuePct===null?'caution':'neutral'})}
      </div>
      ${truth.limitations.length?`<details class="revenue-truth-limitations"><summary>Coverage notes</summary><ul>${truth.limitations.slice(0,5).map(item=>`<li>${escapeHtml(item)}</li>`).join('')}</ul></details>`:''}
    </section>`;
  }

  /* nestly_v522 — ONE canonical lifecycle presentation, and this is not it.
     This block used to render five metric cards (existing returning, repeat purchasers,
     reactivated, existing share, repeat rate) from get_customer_lifecycle_v107 — the exact same
     RPC and the exact same metrics that Business Insights -> Customer Retention already renders,
     but laid out differently and without the period-on-period comparison that tab carries. Two
     visually different answers backed by one RPC is how a product ends up unable to say which
     screen is right, so the full feature stays in Business Insights and Customer Intelligence
     keeps a one-line summary plus the way there.
     Anti-fabrication is unchanged: a null denominator says so instead of printing a zero. */
  function lifecycleMarkup(view){
    if(view.state==='permission'||view.state==='branch')return '';
    const metrics=view.lifecycle.metrics;
    const returned=metrics.existingReturningCustomers;
    const transacting=metrics.transactingIdentifiedCustomers;
    /* nestly_v526: both halves must carry their MEANING, not just their number. Seen live on
       2026-08-26: "0 of 6 ... had bought before. Repeat purchase rate this period: 66.7%" reads as
       a contradiction, and is not one — nobody bought BEFORE the window (so 0 returned) while four
       of six bought twice INSIDE it (so 66.7% repeat). The five cards this replaced each carried a
       definition; condensing them dropped those, which is the one thing the block existed to
       prevent. The wording now states each window explicitly. */
    const summary=(returned===null||transacting===null||transacting===0)
      ?'Not enough data to describe returning customers for this period.'
      :`${returned} of ${transacting} identified customers who purchased in this period had also bought before it.`;
    const rate=percentage(metrics.repeatInPeriodRatePct);
    const rateLine=rate==='Not enough data'
      ?'How many bought twice within the period: not enough data.'
      :`${rate} of them made two or more purchases within the period itself.`;
    return `<section class="revenue-truth-section" aria-labelledby="customerMeaningHeading">
      <div class="revenue-truth-section-head"><div><span class="revenue-truth-eyebrow">Customer behaviour</span>
      <h2 id="customerMeaningHeading">Who came back</h2></div></div>
      <p class="revenue-truth-lifecycle-summary">${escapeHtml(summary)} ${escapeHtml(rateLine)}</p>
      <p class="revenue-truth-crosslink"><a href="#/reports">Full retention analysis, including the
      comparison with the previous period, is in Business Insights &rarr; Customer Retention</a></p>
    </section>`;
  }

  function confidenceLabel(confidence){
    if(!confidence||['','insufficient','low'].includes(confidence.level))return 'Insufficient data quality';
    if(confidence.level==='high')return 'Higher data quality';
    if(confidence.level==='medium')return 'Moderate data quality';
    return `${confidence.level.charAt(0).toUpperCase()}${confidence.level.slice(1)} data quality`;
  }

  function opportunityMarkup(view){
    const briefing=view.briefing,action=briefing.action;
    if(!view.actionAllowed||!action){
      const reasons=briefing.suppressions.length?briefing.suppressions:[
        view.state==='stale'?'The briefing must be refreshed first.':
          view.state==='permission'?'Finance permission is required.':
            view.state==='branch'?'The selected branch is outside your current access.':
              briefing.state==='not_computed'?'No recommendation has been generated for this scope yet.':
            'The current evidence or confidence gate did not permit a recommendation.'
      ];
      return `<section class="revenue-opportunity revenue-opportunity--withheld" aria-labelledby="dailyActionHeading">
        <div><span class="revenue-truth-eyebrow">Today’s best action</span>
        <h2 id="dailyActionHeading">No reliable action to recommend yet</h2>
        <p>Peekaa is withholding the suggestion rather than guessing.</p></div>
        <ul>${reasons.slice(0,4).map(reason=>`<li>${escapeHtml(reason)}</li>`).join('')}</ul>
        <div data-growth-recommendation-refresh-mount></div>
      </section>`;
    }
    const currency=action.revenueRange.currency||view.truth.scope.currency;
    const range=action.revenueRange.lowCents===null||action.revenueRange.highCents===null
      ?`Unavailable${action.revenueRange.unavailableReason?` — ${action.revenueRange.unavailableReason}`:''}`
      :`${money(action.revenueRange.lowCents,currency)}–${money(action.revenueRange.highCents,currency)}`;
    const audience=action.audience.eligible===null?'Not supplied':`${action.audience.eligible} eligible`;
    const cost=action.estimatedCostCents===null?'Cost not fully known':money(action.estimatedCostCents,currency);
    return `<section class="revenue-opportunity" aria-labelledby="dailyActionHeading">
      <div class="revenue-opportunity-rank"><span>1</span><small>Top action</small></div>
      <div class="revenue-opportunity-main"><span class="revenue-truth-eyebrow">Today’s best action</span>
        <h2 id="dailyActionHeading">${escapeHtml(action.title)}</h2>
        <p class="revenue-opportunity-finding">${escapeHtml(action.finding)}</p>
        <div class="revenue-opportunity-facts">
          <div><span>Estimated revenue opportunity</span><strong>${escapeHtml(range)}</strong></div>
          <div><span>Audience</span><strong>${escapeHtml(audience)}</strong></div>
          <div><span>Estimated cost</span><strong>${escapeHtml(cost)}</strong></div>
          <div><span>Data quality</span><strong>${escapeHtml(confidenceLabel(action.confidence))}</strong></div>
        </div>
        ${action.evidence.length?`<div class="revenue-opportunity-evidence"><h3>Why this is ranked first</h3><ul>${action.evidence.map(item=>`<li><span>${escapeHtml(item.label)}</span><strong>${escapeHtml(item.value)}</strong></li>`).join('')}</ul></div>`:''}
        <div class="revenue-opportunity-owner-mount" data-growth-owner-action-mount></div>
      </div>
    </section>`;
  }

  function render(input={}){
    const view=input&&input.truth&&input.lifecycle&&input.briefing&&input.state
      ?input
      :buildViewModel(input);
    const scope=view.truth.scope;
    const scopeLabel=(scope.branchName||scope.branchId)?'Selected branch':'All permitted branches';
    const period=scope.from&&scope.to?`${scope.from} to ${scope.to}`:'Period not supplied';
    return `<div class="revenue-truth" data-revenue-truth-state="${escapeHtml(view.state)}">
      <header class="revenue-truth-header">
        <div><span class="revenue-truth-eyebrow">Revenue truth &amp; daily briefing</span>
        <h2>Know what happened. See what to do next.</h2>
        <p>${escapeHtml(scopeLabel)} · ${escapeHtml(period)}</p></div>
      </header>
      ${stateBanner(view)}
      ${revenueMarkup(view)}
      ${lifecycleMarkup(view)}
      ${opportunityMarkup(view)}
    </div>`;
  }

  function bind(container,{onRetry}={}){
    if(!container||typeof container.querySelectorAll!=='function')return function noop(){};
    const listeners=[];
    const listen=(element,event,handler)=>{
      element.addEventListener(event,handler);
      listeners.push(()=>element.removeEventListener(event,handler));
    };
    container.querySelectorAll('[data-revenue-truth-action="retry"]').forEach(button=>{
      listen(button,'click',()=>{if(typeof onRetry==='function')onRetry()});
    });
    return ()=>listeners.splice(0).forEach(remove=>remove());
  }

  return Object.freeze({
    buildViewModel,
    claimCapabilities,
    guardClaimText,
    money,
    normalizeBriefing,
    normalizeLifecycle,
    normalizeStatus,
    normalizeTruth,
    percentage,
    render,
    bind
  });
});

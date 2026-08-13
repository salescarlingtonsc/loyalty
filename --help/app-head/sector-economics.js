(function sectorEconomicsModule(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.NestlySectorEconomics=api;
})(typeof globalThis!=='undefined'?globalThis:this,function sectorEconomicsFactory(){
  'use strict';

  const ECONOMICS_CONTRACT='period_economics_v109';
  const DRIVERS_CONTRACT='revenue_driver_decomposition_v109';
  const POLICY_CONTRACT='effective_sector_policy_v109';
  const POLICY_KEY='lapse_detection';

  const asObject=value=>value&&typeof value==='object'&&!Array.isArray(value)?value:{};
  const asArray=value=>Array.isArray(value)?value:[];
  const text=value=>String(value??'').trim();
  const finite=value=>{
    if(value===null||value===undefined||value==='')return null;
    const number=Number(value);
    return Number.isFinite(number)?number:null;
  };
  const integer=value=>{
    const number=finite(value);
    return number!==null&&Number.isInteger(number)?number:null;
  };
  const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,char=>({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
  })[char]);
  const makeUuid=()=>{
    if(globalThis.crypto&&typeof globalThis.crypto.randomUUID==='function'){
      return globalThis.crypto.randomUUID();
    }
    if(globalThis.crypto&&typeof globalThis.crypto.getRandomValues==='function'){
      const bytes=new Uint8Array(16);
      globalThis.crypto.getRandomValues(bytes);
      bytes[6]=(bytes[6]&0x0f)|0x40;
      bytes[8]=(bytes[8]&0x3f)|0x80;
      const value=Array.from(bytes,byte=>byte.toString(16).padStart(2,'0')).join('');
      return `${value.slice(0,8)}-${value.slice(8,12)}-${value.slice(12,16)}-${value.slice(16,20)}-${value.slice(20)}`;
    }
    throw new Error('Secure request identifiers are not available in this browser.');
  };

  function money(cents,currency='',{signed=false}={}){
    const amount=finite(cents);
    const currencyCode=text(currency).toUpperCase();
    if(amount===null||!currencyCode)return 'Unavailable';
    const absolute=Math.abs(amount);
    const formatted=`${currencyCode} ${(absolute/100).toLocaleString('en-SG',{
      minimumFractionDigits:2,maximumFractionDigits:2
    })}`;
    if(!signed||amount===0)return amount<0?`−${formatted}`:formatted;
    return amount>0?`+${formatted}`:`−${formatted}`;
  }

  function percentageFromBps(value){
    const bps=finite(value);
    if(bps===null)return 'Not available';
    const percent=bps/100;
    return `${percent.toLocaleString('en-SG',{
      minimumFractionDigits:percent%1===0?0:1,
      maximumFractionDigits:2
    })}%`;
  }

  function dateLabel(value){
    if(!value)return 'Not supplied';
    const date=new Date(value);
    if(Number.isNaN(date.getTime()))return text(value);
    return new Intl.DateTimeFormat('en-SG',{
      day:'numeric',month:'short',year:'numeric',timeZone:'Asia/Singapore'
    }).format(date);
  }

  function classifyError(error){
    const code=text(error?.code);
    const message=text(error?.message||error||'The request could not be completed.');
    if(code==='0A000'||/v109 economics and sector policy is not enabled|feature.+not enabled/i.test(message)){
      return {
        kind:'disabled',
        message:'Evidence-gated economics and sector policy are not enabled for this workspace yet.'
      };
    }
    if(/branch does not belong|branch visibility|branch access|no branch assigned/i.test(message)){
      return {
        kind:'branch',
        message:'This branch is not available to your current workspace access. Choose another branch.'
      };
    }
    if(code==='42501'||/finance access required|owner only|permission|forbidden|not authorized/i.test(message)){
      return {
        kind:'permission',
        message:'Your current role does not have finance permission for this decision support.'
      };
    }
    if(code==='22023'||/required|must be|unsupported parameter|valid.+period/i.test(message)){
      return {kind:'validation',message};
    }
    return {
      kind:'error',
      message:'The economics and policy evidence could not be loaded. No financial conclusion is shown.'
    };
  }

  function normalizeEconomics(payload){
    const source=asObject(payload);
    const coverage=asObject(source.coverage);
    const profit=asObject(source.profit);
    const roi=asObject(source.roi);
    const contractValid=text(source.contract_version)===ECONOMICS_CONTRACT;
    const costContractVersion=text(
      source.cost_contract_version||coverage.cost_contract_version
    );
    const growthCostContract=costContractVersion==='growth_costs_v114';
    const status=text(source.status).toLowerCase();
    const coveragePasses=coverage.traceable_cost_coverage_passes===true;
    const profitFields={
      revenueCents:finite(profit.revenue_cents),
      traceableCogsCents:finite(profit.traceable_cogs_cents),
      grossProfitCents:finite(
        profit.gross_profit_before_growth_costs_cents
        ??profit.gross_profit_cents
      ),
      traceableBenefitCostCents:finite(profit.traceable_benefit_cost_cents),
      traceableDeliveryCostCents:finite(profit.traceable_delivery_cost_cents),
      traceableGrowthCostCents:finite(profit.traceable_growth_cost_cents),
      totalTraceableCostCents:finite(profit.total_traceable_cost_cents),
      contributionAfterGrowthCostsCents:finite(
        profit.contribution_after_growth_costs_cents
      )
    };
    const requiredProfitFields=[
      profitFields.revenueCents,
      profitFields.traceableCogsCents,
      profitFields.grossProfitCents
    ];
    if(growthCostContract){
      requiredProfitFields.push(
        profitFields.traceableBenefitCostCents,
        profitFields.traceableDeliveryCostCents,
        profitFields.traceableGrowthCostCents,
        profitFields.totalTraceableCostCents,
        profitFields.contributionAfterGrowthCostsCents
      );
    }
    const profitAvailable=contractValid&&status==='ready'&&coveragePasses
      &&requiredProfitFields.every(value=>value!==null);
    const roiFields={
      investmentCents:finite(roi.investment_cents),
      investmentReference:text(roi.investment_reference),
      netReturnCents:finite(roi.net_return_cents),
      roiBps:finite(roi.return_on_investment_bps)
    };
    const roiAvailable=profitAvailable&&roiFields.investmentCents!==null
      &&roiFields.investmentCents>0&&roiFields.investmentReference.length>=3
      &&roiFields.netReturnCents!==null&&roiFields.roiBps!==null;
    return {
      contractValid,
      costContractVersion,
      growthCostContract,
      status,
      period:asObject(source.period),
      coverage:{
        eligibleSales:integer(coverage.eligible_sales),
        coveredSales:integer(coverage.covered_sales),
        transactionCoverageBps:integer(coverage.transaction_coverage_bps),
        eligibleRevenueCents:finite(coverage.eligible_revenue_cents),
        coveredRevenueCents:finite(coverage.covered_revenue_cents),
        revenueCoverageBps:integer(coverage.revenue_coverage_bps),
        salePasses:growthCostContract
          ?coverage.sale_cost_coverage_passes===true
          :coveragePasses,
        eligibleBenefits:integer(coverage.eligible_redeemed_benefits),
        coveredBenefits:integer(coverage.covered_redeemed_benefits),
        benefitCoverageBps:integer(coverage.benefit_cost_coverage_bps),
        benefitPasses:growthCostContract
          ?coverage.benefit_cost_coverage_passes===true
          :true,
        eligibleDeliveries:integer(coverage.eligible_deliveries),
        coveredDeliveries:integer(coverage.covered_deliveries),
        deliveryCoverageBps:integer(coverage.delivery_cost_coverage_bps),
        deliveryPasses:growthCostContract
          ?coverage.delivery_cost_coverage_passes===true
          :true,
        passes:coveragePasses
      },
      profit:{
        available:profitAvailable,
        currency:text(profit.currency).toUpperCase(),
        ...profitFields
      },
      roi:{available:roiAvailable,...roiFields},
      unavailableReasons:asArray(source.unavailable_reasons).map(text).filter(Boolean),
      limitations:asArray(source.limitations).map(text).filter(Boolean)
    };
  }

  const DRIVER_LABELS=Object.freeze({
    identified_customer_count_cents:'Identified customer base',
    purchase_frequency_cents:'Purchase frequency',
    average_transaction_value_cents:'Spend per transaction',
    anonymous_revenue_cents:'Anonymous sales'
  });

  function normalizeDrivers(payload){
    const source=asObject(payload);
    const rawDrivers=asObject(source.drivers);
    const reconciliation=asObject(source.reconciliation);
    const periods=asObject(source.periods);
    const coverage=asObject(source.coverage);
    const rawLineItemAnalysis=asObject(source.line_item_analysis);
    const contractValid=text(source.contract_version)===DRIVERS_CONTRACT;
    const status=text(source.status).toLowerCase();
    const delta=finite(reconciliation.period_revenue_delta_cents);
    const serverSum=finite(reconciliation.sum_driver_contributions_cents);
    const serverResidual=finite(reconciliation.rounding_residual_cents);
    const substantive=Object.entries(DRIVER_LABELS).map(([key,label])=>({
      key,label,cents:finite(rawDrivers[key])
    }));
    const allDriverValuesPresent=substantive.every(driver=>driver.cents!==null)
      &&serverResidual!==null;
    const computedServerSum=allDriverValuesPresent
      ?substantive.reduce((sum,driver)=>sum+driver.cents,0)+serverResidual
      :null;
    const backendReconciles=contractValid&&status==='ready'
      &&reconciliation.reconciles===true&&delta!==null&&serverSum!==null
      &&computedServerSum===delta&&serverSum===delta;
    const ranked=backendReconciles
      ?[...substantive].sort((a,b)=>Math.abs(b.cents)-Math.abs(a.cents)
        ||a.label.localeCompare(b.label))
      :[];
    const topDrivers=ranked.slice(0,3);
    const omitted=ranked.slice(3);
    const displayResidual=backendReconciles
      ?delta-topDrivers.reduce((sum,driver)=>sum+driver.cents,0)
      :null;
    const displayReconciles=backendReconciles
      &&topDrivers.reduce((sum,driver)=>sum+driver.cents,0)+displayResidual===delta;
    const normalizeLineItemPeriod=(periodKey,coveragePrefix)=>{
      const period=asObject(periods[periodKey]);
      return {
        transactions:integer(period.transactions),
        itemizedTransactions:integer(period.itemized_transactions),
        transactionCoverageBps:integer(
          coverage[`${coveragePrefix}_itemized_transaction_bps`]
        ),
        revenueCents:finite(period.revenue_cents),
        itemizedRevenueCents:finite(period.itemized_revenue_cents),
        revenueCoverageBps:integer(
          coverage[`${coveragePrefix}_itemized_revenue_bps`]
        )
      };
    };
    const hasLineItemContract=[
      'comparison_itemized_transaction_bps',
      'current_itemized_transaction_bps',
      'comparison_itemized_revenue_bps',
      'current_itemized_revenue_bps'
    ].some(key=>Object.hasOwn(coverage,key))
      ||Object.keys(rawLineItemAnalysis).length>0
      ||['comparison','current'].some(key=>{
        const period=asObject(periods[key]);
        return Object.hasOwn(period,'itemized_transactions')
          ||Object.hasOwn(period,'itemized_revenue_cents');
      });
    return {
      contractValid,
      status,
      unavailableReason:text(source.unavailable_reason),
      periods,
      coverage,
      lineItemCoverage:{
        available:contractValid&&hasLineItemContract,
        current:normalizeLineItemPeriod('current','current'),
        comparison:normalizeLineItemPeriod('comparison','comparison')
      },
      lineItemAnalysis:{
        status:text(rawLineItemAnalysis.status).toLowerCase(),
        priceVolumeMixStatus:text(
          rawLineItemAnalysis.price_volume_mix_status
        ).toLowerCase(),
        reason:text(rawLineItemAnalysis.reason),
        causalClaim:rawLineItemAnalysis.causal_claim===true
      },
      deltaCents:delta,
      topDrivers,
      residual:{
        cents:displayResidual,
        includedDriverLabels:omitted.map(driver=>driver.label),
        serverRoundingCents:serverResidual
      },
      backendReconciles,
      displayReconciles,
      available:backendReconciles&&displayReconciles,
      causalClaim:asObject(source.method).causal_claim===true
    };
  }

  const PARAMETER_META=Object.freeze({
    minimum_prior_visits:{
      label:'Minimum prior visits',
      helper:'A customer needs this many earlier visits before lapse detection can assess them.',
      min:2,max:20,step:1,integer:true
    },
    cadence_multiplier:{
      label:'Usual-interval multiplier',
      helper:'Wait this many times the customer’s observed visit interval before considering them overdue.',
      min:1.1,max:5,step:0.05,integer:false
    },
    minimum_lapse_days:{
      label:'Minimum days without a visit',
      helper:'Never consider a customer overdue before this many days have passed.',
      min:3,max:365,step:1,integer:true
    },
    minimum_audience:{
      label:'Minimum eligible audience',
      helper:'Suppress an audience smaller than this number.',
      min:10,max:5000,step:1,integer:true
    }
  });

  const SUPPRESSION_COPY=Object.freeze({
    insufficient_history:'Not enough customer history',
    unknown_service_cadence:'Service timing is not known',
    membership_state_unknown:'Membership state is not known',
    product_cycle_unknown:'Product repeat cycle is not known',
    sector_not_specialized:'No reviewed policy exists for this sector yet',
    low_identity_coverage:'Too little revenue is linked to identified customers',
    audience_below_minimum:'Eligible audience is below the minimum'
  });

  const FALLBACK_ACTION_COPY=Object.freeze({
    use_sector_minimum_only_after_minimum_history:
      'Use the sector minimum only after the business has enough customer history.',
    suppress_until_service_history_is_sufficient:
      'Do not classify customers until service history is sufficient.',
    suppress_until_attendance_history_is_sufficient:
      'Do not classify customers until attendance history is sufficient.',
    suppress_until_repeat_purchase_history_is_sufficient:
      'Do not classify customers until repeat-purchase history is sufficient.',
    do_not_classify:'Do not classify a customer when their own cadence is unavailable.'
  });

  function normalizePolicy(payload){
    const source=asObject(payload);
    const base=asObject(source.base_policy);
    const override=source.owner_override&&typeof source.owner_override==='object'
      ?asObject(source.owner_override):null;
    const effective=asObject(source.effective_parameters);
    const parameters=Object.entries(PARAMETER_META).map(([key,meta])=>({
      key,
      ...meta,
      value:finite(effective[key])
    }));
    const contractValid=text(source.contract_version)===POLICY_CONTRACT;
    const baseValid=contractValid&&text(source.policy_key)===POLICY_KEY
      &&text(base.id)&&integer(base.version_no)!==null
      &&parameters.every(parameter=>parameter.value!==null);
    const fallback=asObject(base.fallback_policy);
    return {
      contractValid,
      available:baseValid,
      requestedSector:text(source.requested_sector||'other'),
      resolvedSector:text(source.resolved_sector||'other'),
      usedFallbackSector:source.used_fallback_sector===true,
      policyKey:text(source.policy_key),
      base:{
        id:text(base.id),
        versionNo:integer(base.version_no),
        effectiveFrom:base.effective_from||null,
        effectiveTo:base.effective_to||null,
        evidence:asArray(base.evidence_basis).map(text).filter(Boolean),
        suppressions:asArray(base.suppression_rules).map(rule=>{
          const value=typeof rule==='string'?rule:asObject(rule).reason||asObject(rule).code;
          const code=text(value);
          return code?{
            code,
            explanation:SUPPRESSION_COPY[code]||code.replaceAll('_',' ')
          }:null;
        }).filter(Boolean),
        limitations:asArray(base.limitations).map(text).filter(Boolean),
        fallback:{
          when:text(fallback.when)==='individual_cadence_unavailable'
            ?'When a customer’s usual visit interval cannot be calculated'
            :text(fallback.when).replaceAll('_',' '),
          action:FALLBACK_ACTION_COPY[text(fallback.action)]
            ||text(fallback.action).replaceAll('_',' ')
        }
      },
      ownerOverride:override?{
        id:text(override.id),
        versionNo:integer(override.version_no),
        reason:text(override.reason),
        effectiveFrom:override.effective_from||null
      }:null,
      parameters,
      requiresLocalEvidence:source.requires_local_evidence===true,
      universalChurnNumber:source.universal_churn_number??null
    };
  }

  function resolveState({requestState='auto',errors=[],economics,drivers,policy}={}){
    const explicit=text(requestState).toLowerCase();
    if(['disabled','permission','branch','error','empty','ready'].includes(explicit)){
      return explicit;
    }
    const classified=asArray(errors).filter(Boolean).map(classifyError);
    for(const kind of ['disabled','permission','branch','error']){
      if(classified.some(item=>item.kind===kind))return kind;
    }
    if(!economics.contractValid||!drivers.contractValid||!policy.contractValid)return 'error';
    if(economics.status==='no_data'&&drivers.status==='unavailable')return 'empty';
    return 'ready';
  }

  function buildViewModel({
    economics:rawEconomics,
    drivers:rawDrivers,
    policy:rawPolicy,
    errors=[],
    requestState='auto',
    errorMessage='',
    branchName='All branches',
    role='manager',
    currency=''
  }={}){
    const economics=normalizeEconomics(rawEconomics);
    const drivers=normalizeDrivers(rawDrivers);
    const policy=normalizePolicy(rawPolicy);
    const state=resolveState({requestState,errors,economics,drivers,policy});
    const classified=asArray(errors).filter(Boolean).map(classifyError);
    const stateError=classified.find(item=>item.kind===state);
    return {
      state,
      economics,
      drivers,
      policy,
      branchName:text(branchName||'All branches'),
      currency:text(currency||economics.profit.currency).toUpperCase(),
      role:text(role),
      errorMessage:text(errorMessage||stateError?.message),
      canOverride:role==='owner'&&policy.available
        &&!['disabled','permission','branch','error'].includes(state)
    };
  }

  const STATE_COPY=Object.freeze({
    disabled:{
      label:'Not enabled',
      title:'Evidence-gated economics is not enabled yet',
      body:'No profit, ROI, driver or sector-policy conclusion is shown while this feature is off.'
    },
    permission:{
      label:'Restricted',
      title:'Finance access is required',
      body:'Ask the owner for finance access to view this evidence and policy.'
    },
    branch:{
      label:'Branch unavailable',
      title:'Choose a branch you can access',
      body:'No branch-level figure is shown because the selected branch is outside your current access.'
    },
    error:{
      label:'Could not load',
      title:'Economics and policy evidence is unavailable',
      body:'Nothing in this section should be treated as current. Try loading it again.'
    },
    empty:{
      label:'No eligible sales',
      title:'There is no period economics to calculate yet',
      body:'The sector starting policy is still shown below. Record eligible sales to build economics and drivers.'
    },
    ready:{
      label:'Evidence checked',
      title:'Economics and revenue drivers',
      body:'Financial claims below are shown only when their server-side evidence gates pass.'
    }
  });

  function stateBanner(view){
    const copy=STATE_COPY[view.state]||STATE_COPY.error;
    const retry=view.state==='error'
      ?'<button class="btn ghost sm sector-economics-retry" type="button" data-sector-action="retry">Try again</button>'
      :'';
    return `<section class="sector-economics-state sector-economics-state--${escapeHtml(view.state)}" role="${view.state==='error'?'alert':'status'}" aria-live="polite">
      <div><span class="sector-economics-eyebrow">${escapeHtml(copy.label)}</span>
      <h2>${escapeHtml(copy.title)}</h2>
      <p>${escapeHtml(view.errorMessage||copy.body)}</p></div>${retry}</section>`;
  }

  function unavailableReason(reason){
    const copy={
      no_eligible_sales:'No eligible sales were recorded in this period.',
      incomplete_traceable_cost_coverage:
        'Every eligible sale needs a source-referenced cost rule before gross profit can be shown.',
      incomplete_traceable_sale_cost_coverage:
        'Every eligible sale needs a source-referenced cost rule before profit can be shown.',
      incomplete_traceable_benefit_cost_coverage:
        'Every redeemed customer benefit needs an effective, source-referenced cost rule.',
      incomplete_traceable_delivery_cost_coverage:
        'Every delivered message needs an effective provider-cost rule.',
      traceable_investment_not_provided:
        'ROI needs a traceable investment amount and reference for this period.',
      positive_traceable_investment_required:
        'ROI needs a positive traceable investment amount.',
      comparison_period_has_no_revenue:'The comparison period has no eligible revenue.',
      current_period_has_no_revenue:'The current period has no eligible revenue.',
      comparison_period_has_no_identified_customer_base:
        'The comparison period has no identified customer base.',
      current_period_has_no_identified_customer_base:
        'The current period has no identified customer base.'
    };
    return copy[text(reason)]||text(reason).replaceAll('_',' ');
  }

  function economicsMarkup(view){
    const economics=view.economics;
    if(!economics.contractValid)return '';
    const coverage=economics.coverage;
    const coverageText=coverage.eligibleSales===null||coverage.coveredSales===null
      ?'Coverage not available'
      :`${coverage.coveredSales} of ${coverage.eligibleSales} eligible sales have traceable costs`;
    const benefitCoverageText=!economics.growthCostContract
      ?''
      :coverage.eligibleBenefits===0
        ?'No redeemed benefits in this period'
        :`${coverage.coveredBenefits??0} of ${coverage.eligibleBenefits??0} redeemed benefits have traceable costs`;
    const deliveryCoverageText=!economics.growthCostContract
      ?''
      :coverage.eligibleDeliveries===0
        ?'No delivered messages in this period'
        :`${coverage.coveredDeliveries??0} of ${coverage.eligibleDeliveries??0} delivered messages have traceable provider costs`;
    const completeCoverageText=[
      coverageText,benefitCoverageText,deliveryCoverageText
    ].filter(Boolean).join(' · ');
    const reasons=economics.unavailableReasons.map(unavailableReason);
    if(!economics.profit.available){
      return `<section class="sector-economics-card" aria-labelledby="periodEconomicsHeading">
        <div class="sector-economics-section-head"><div>
          <span class="sector-economics-eyebrow">Period economics</span>
          <h2 id="periodEconomicsHeading">Profit and ROI are unavailable</h2>
          <p>${escapeHtml(completeCoverageText)}. Peekaa will not estimate missing costs.</p>
        </div><span class="sector-economics-badge sector-economics-badge--withheld">Withheld</span></div>
        <div class="sector-economics-coverage" aria-label="Traceable cost coverage summary">
          <strong>${escapeHtml(percentageFromBps(coverage.transactionCoverageBps))}</strong>
          <span>sale cost coverage</span>
          ${economics.growthCostContract?`
            <strong>${escapeHtml(
              coverage.eligibleBenefits===0
                ?'No events'
                :percentageFromBps(coverage.benefitCoverageBps)
            )}</strong>
            <span>redeemed benefit cost coverage</span>
            <strong>${escapeHtml(
              coverage.eligibleDeliveries===0
                ?'No events'
                :percentageFromBps(coverage.deliveryCoverageBps)
            )}</strong>
            <span>delivery cost coverage</span>
          `:''}
        </div>
        ${reasons.length?`<ul class="sector-economics-notes">${reasons.map(reason=>`<li>${escapeHtml(reason)}</li>`).join('')}</ul>`:''}
      </section>`;
    }
    const profit=economics.profit,roi=economics.roi;
    return `<section class="sector-economics-card" aria-labelledby="periodEconomicsHeading">
      <div class="sector-economics-section-head"><div>
        <span class="sector-economics-eyebrow">Period economics</span>
        <h2 id="periodEconomicsHeading">${
          economics.growthCostContract
            ?'Contribution with complete cost coverage'
            :'Gross profit with complete cost coverage'
        }</h2>
        <p>${escapeHtml(completeCoverageText)}.</p>
      </div><span class="sector-economics-badge sector-economics-badge--ready">Coverage passed</span></div>
      <div class="sector-economics-metrics">
        <article><span>Revenue</span><strong>${escapeHtml(money(profit.revenueCents,view.currency))}</strong></article>
        <article><span>Traceable cost of sales</span><strong>${escapeHtml(money(profit.traceableCogsCents,view.currency))}</strong></article>
        <article><span>Gross profit before growth costs</span><strong>${escapeHtml(money(profit.grossProfitCents,view.currency))}</strong></article>
        ${economics.growthCostContract?`
          <article><span>Redeemed benefit cost</span><strong>${escapeHtml(money(profit.traceableBenefitCostCents,view.currency))}</strong></article>
          <article><span>Delivered message cost</span><strong>${escapeHtml(money(profit.traceableDeliveryCostCents,view.currency))}</strong></article>
          <article><span>Contribution after growth costs</span><strong>${escapeHtml(money(profit.contributionAfterGrowthCostsCents,view.currency))}</strong></article>
        `:''}
        ${roi.available
          ?`<article><span>Period ROI</span><strong>${escapeHtml(percentageFromBps(roi.roiBps))}</strong>
            <small>Against ${escapeHtml(roi.investmentReference)}</small></article>`
          :`<article class="sector-economics-metric--withheld"><span>Period ROI</span>
            <strong>Unavailable</strong><small>A traceable investment amount and reference were not supplied.</small></article>`}
      </div>
      <details class="sector-economics-disclosure"><summary>Method and limitations</summary>
        <ul>${economics.limitations.map(item=>`<li>${escapeHtml(item)}</li>`).join('')}</ul>
      </details>
    </section>`;
  }

  function lineItemCoverageMarkup(view){
    const drivers=view.drivers;
    const coverage=drivers.lineItemCoverage;
    if(!drivers.contractValid||!coverage?.available)return '';
    const periodCard=(label,period)=>{
      const transactionText=period.transactions===0
        ?'No recorded transactions'
        :period.transactions===null||period.itemizedTransactions===null
          ?'Transaction itemization is unavailable'
          :`${period.itemizedTransactions.toLocaleString('en-SG')} of ${
            period.transactions.toLocaleString('en-SG')
          } transactions itemized`;
      const transactionPercent=period.transactions===0
        ?'No activity'
        :percentageFromBps(period.transactionCoverageBps);
      const revenueText=period.revenueCents===0
        ?'No recorded revenue'
        :period.revenueCents===null||period.itemizedRevenueCents===null
          ?'Revenue itemization is unavailable'
          :`${money(period.itemizedRevenueCents,view.currency)} of ${
            money(period.revenueCents,view.currency)
          } revenue itemized`;
      const revenuePercent=period.revenueCents===0
        ?'No activity'
        :percentageFromBps(period.revenueCoverageBps);
      return `<article class="sector-line-item-period">
        <h3>${escapeHtml(label)}</h3>
        <dl>
          <div><dt>Itemized transactions</dt>
            <dd><strong>${escapeHtml(transactionPercent)}</strong>
              <span>${escapeHtml(transactionText)}</span></dd></div>
          <div><dt>Itemized revenue</dt>
            <dd><strong>${escapeHtml(revenuePercent)}</strong>
              <span>${escapeHtml(revenueText)}</span></dd></div>
        </dl>
      </article>`;
    };
    const notClaimed=drivers.lineItemAnalysis.priceVolumeMixStatus==='not_claimed';
    const statusCopy=notClaimed
      ?`<p class="sector-line-item-limit">
          <strong>Product price, volume and mix are not attributed for this comparison.</strong>
          Itemized coverage shows how much recorded activity has line-item detail; it does not
          show that a product, price, volume or mix change caused the revenue change.
        </p>`
      :`<p class="sector-line-item-limit">
          Line-item coverage is available for this comparison. It describes record completeness
          and does not by itself establish why revenue changed.
        </p>`;
    return `<section class="sector-economics-card" aria-labelledby="lineItemCoverageHeading">
      <div class="sector-economics-section-head"><div>
        <span class="sector-economics-eyebrow">Line-item evidence</span>
        <h2 id="lineItemCoverageHeading">Itemized transaction and revenue coverage</h2>
        <p>Current and comparison coverage are shown separately so missing product detail is visible.</p>
      </div><span class="sector-economics-badge">${
        escapeHtml(notClaimed?'Coverage only':'Coverage available')
      }</span></div>
      <div class="sector-line-item-grid">
        ${periodCard('Current period',coverage.current)}
        ${periodCard('Comparison period',coverage.comparison)}
      </div>
      ${statusCopy}
    </section>`;
  }

  function driversMarkup(view){
    const drivers=view.drivers;
    if(!drivers.contractValid)return '';
    if(!drivers.available){
      return `<section class="sector-economics-card" aria-labelledby="revenueDriversHeading">
        <div class="sector-economics-section-head"><div>
          <span class="sector-economics-eyebrow">Revenue drivers</span>
          <h2 id="revenueDriversHeading">Revenue drivers are unavailable</h2>
          <p>${escapeHtml(unavailableReason(drivers.unavailableReason||
            'The revenue bridge did not reconcile, so Peekaa withheld it.'))}</p>
        </div><span class="sector-economics-badge sector-economics-badge--withheld">Withheld</span></div>
      </section>`;
    }
    const residualParts=[
      ...drivers.residual.includedDriverLabels,
      drivers.residual.serverRoundingCents!==0?'rounding':''
    ].filter(Boolean);
    const residualHelper=residualParts.length
      ?`Includes ${residualParts.join(' and ').toLowerCase()}.`
      :'No material residual remains.';
    return `<section class="sector-economics-card" aria-labelledby="revenueDriversHeading">
      <div class="sector-economics-section-head"><div>
        <span class="sector-economics-eyebrow">Revenue drivers</span>
        <h2 id="revenueDriversHeading">What changed with recorded revenue</h2>
        <p>These are deterministic associations, not proof that one factor caused another.</p>
      </div><div class="sector-economics-delta"><span>Period change</span>
        <strong>${escapeHtml(money(drivers.deltaCents,view.currency,{signed:true}))}</strong></div></div>
      <div class="sector-driver-list">
        ${drivers.topDrivers.map((driver,index)=>`<article>
          <span>${index+1}. ${escapeHtml(driver.label)}</span>
          <strong>${escapeHtml(money(driver.cents,view.currency,{signed:true}))}</strong>
        </article>`).join('')}
        <article class="sector-driver-residual"><span>Residual</span>
          <strong>${escapeHtml(money(drivers.residual.cents,view.currency,{signed:true}))}</strong>
          <small>${escapeHtml(residualHelper)}</small></article>
      </div>
      <p class="sector-economics-reconcile">Reconciled: the three drivers plus residual equal
        ${escapeHtml(money(drivers.deltaCents,view.currency,{signed:true}))} exactly.</p>
    </section>`;
  }

  function parameterValue(parameter){
    if(parameter.key==='cadence_multiplier'){
      return `${parameter.value.toLocaleString('en-SG',{maximumFractionDigits:2})}×`;
    }
    if(parameter.key==='minimum_lapse_days')return `${parameter.value} days`;
    if(parameter.key==='minimum_prior_visits')return `${parameter.value} visits`;
    return `${parameter.value} customers`;
  }

  function overrideForm(policy){
    return `<details class="sector-policy-override">
      <summary>Customize this starting policy</summary>
      <form data-sector-policy-override-form novalidate>
        <p class="sector-policy-helper">Only the owner can change these guardrails. Changes are versioned and audited.</p>
        <div class="sector-policy-form-grid">
          ${policy.parameters.map(parameter=>`<label>
            <span>${escapeHtml(parameter.label)}</span>
            <input type="number" name="${escapeHtml(parameter.key)}"
              value="${escapeHtml(parameter.value)}" min="${parameter.min}" max="${parameter.max}"
              step="${parameter.step}" inputmode="${parameter.integer?'numeric':'decimal'}" required>
            <small>${escapeHtml(parameter.helper)}</small>
          </label>`).join('')}
        </div>
        <label class="sector-policy-reason"><span>Reason for this change</span>
          <textarea name="reason" rows="3" minlength="3" maxlength="1000" required
            placeholder="Example: our treatment plan normally repeats every 45 days"></textarea>
          <small>This reason appears in the audit history.</small>
        </label>
        <div class="sector-policy-form-status" data-sector-policy-status role="status" aria-live="polite"></div>
        <button class="btn sector-policy-save" type="submit" data-sector-policy-save>Save policy change</button>
      </form>
    </details>`;
  }

  function policyMarkup(view){
    const policy=view.policy;
    if(!policy.available)return '';
    const version=`Version ${policy.base.versionNo} · effective ${dateLabel(policy.base.effectiveFrom)}`;
    return `<section class="sector-economics-card sector-policy-card" aria-labelledby="sectorPolicyHeading">
      <div class="sector-economics-section-head"><div>
        <span class="sector-economics-eyebrow">Sector starting policy</span>
        <h2 id="sectorPolicyHeading">When to consider a customer overdue</h2>
        <p>${escapeHtml(policy.resolvedSector)} starting policy · ${escapeHtml(version)}</p>
      </div><span class="sector-economics-badge">${policy.usedFallbackSector?'Fallback sector':'Sector matched'}</span></div>
      ${policy.usedFallbackSector?`<div class="sector-policy-callout" role="note">
        No reviewed policy matched “${escapeHtml(policy.requestedSector)}”, so Peekaa used the
        “${escapeHtml(policy.resolvedSector)}” fallback. Local evidence is still required.
      </div>`:''}
      <div class="sector-policy-parameters">
        ${policy.parameters.map(parameter=>`<article><span>${escapeHtml(parameter.label)}</span>
          <strong>${escapeHtml(parameterValue(parameter))}</strong>
          <small>${escapeHtml(parameter.helper)}</small></article>`).join('')}
      </div>
      ${policy.ownerOverride?`<div class="sector-policy-callout sector-policy-callout--override">
        <strong>Owner override version ${escapeHtml(policy.ownerOverride.versionNo)}</strong>
        <span>${escapeHtml(policy.ownerOverride.reason)} · effective ${escapeHtml(dateLabel(policy.ownerOverride.effectiveFrom))}</span>
      </div>`:''}
      <div class="sector-policy-evidence-grid">
        <details class="sector-economics-disclosure" open><summary>Evidence and fallback</summary>
          <ul>${policy.base.evidence.map(item=>`<li>${escapeHtml(item)}</li>`).join('')}</ul>
          <p><strong>${escapeHtml(policy.base.fallback.when)}:</strong>
            ${escapeHtml(policy.base.fallback.action)}</p>
        </details>
        <details class="sector-economics-disclosure"><summary>When Peekaa suppresses this</summary>
          <ul>${policy.base.suppressions.map(item=>`<li><strong>Unavailable</strong> —
            ${escapeHtml(item.explanation)} <code>${escapeHtml(item.code)}</code></li>`).join('')}</ul>
        </details>
        <details class="sector-economics-disclosure"><summary>Limitations</summary>
          <ul>${policy.base.limitations.map(item=>`<li>${escapeHtml(item)}</li>`).join('')}</ul>
          <p>Peekaa does not supply a universal churn number. The business’s own evidence must be reviewed.</p>
        </details>
      </div>
      ${view.canOverride?overrideForm(policy):''}
    </section>`;
  }

  function render(input={}){
    const view=input&&input.economics&&input.drivers&&input.policy&&input.state
      ?input:buildViewModel(input);
    const blocked=['disabled','permission','branch','error'].includes(view.state);
    return `<section class="sector-economics" data-sector-economics-state="${escapeHtml(view.state)}">
      <header class="sector-economics-header">
        <div><span class="sector-economics-eyebrow">Evidence-gated decision support</span>
          <h2>Understand the economics behind the revenue</h2>
          <p>${escapeHtml(view.branchName)} · profit and ROI are never estimated from missing costs.</p>
        </div>
      </header>
      ${stateBanner(view)}
      ${blocked?'':economicsMarkup(view)}
      ${blocked?'':driversMarkup(view)}
      ${blocked?'':lineItemCoverageMarkup(view)}
      ${blocked?'':policyMarkup(view)}
    </section>`;
  }

  function validateOverride(input={}){
    const parameters=asObject(input.parameters);
    const normalized={};
    for(const [key,meta] of Object.entries(PARAMETER_META)){
      const value=meta.integer?integer(parameters[key]):finite(parameters[key]);
      if(value===null||value<meta.min||value>meta.max){
        return {
          ok:false,
          message:`${meta.label} must be between ${meta.min} and ${meta.max}.`
        };
      }
      normalized[key]=value;
    }
    const reason=text(input.reason);
    if(reason.length<3||reason.length>1000){
      return {ok:false,message:'Enter a reason between 3 and 1,000 characters.'};
    }
    const effectiveFrom=input.effectiveFrom||new Date().toISOString();
    if(Number.isNaN(new Date(effectiveFrom).getTime())){
      return {ok:false,message:'The effective time is invalid. Refresh and try again.'};
    }
    return {ok:true,parameters:normalized,reason,effectiveFrom};
  }

  function createOverrideController({
    rpc,businessId,makeId=makeUuid,now=()=>new Date().toISOString()
  }={}){
    if(typeof rpc!=='function')throw new TypeError('rpc is required');
    if(!text(businessId))throw new TypeError('businessId is required');
    let inFlight=null,lastFingerprint='',idempotencyKey='',lastResult=null,lastError=null;
    const snapshot=()=>({
      saving:!!inFlight,
      idempotencyKey,
      result:lastResult?{...lastResult}:null,
      error:lastError?{...lastError}:null
    });
    const submit=input=>{
      if(inFlight)return inFlight;
      const validation=validateOverride({...input,effectiveFrom:input?.effectiveFrom||now()});
      if(!validation.ok){
        lastError={kind:'validation',message:validation.message};
        return Promise.reject(Object.assign(new Error(validation.message),{code:'VALIDATION'}));
      }
      const fingerprint=JSON.stringify({
        parameters:validation.parameters,
        reason:validation.reason,
        effectiveFrom:validation.effectiveFrom
      });
      if(fingerprint!==lastFingerprint){
        lastFingerprint=fingerprint;
        idempotencyKey=makeId();
      }
      lastError=null;
      inFlight=(async()=>{
        try{
          const response=await rpc('set_business_sector_policy_override_v109',{
            p_business:businessId,
            p_policy_key:POLICY_KEY,
            p_override_parameters:validation.parameters,
            p_reason:validation.reason,
            p_effective_from:validation.effectiveFrom,
            p_idempotency_key:idempotencyKey
          });
          if(response?.error)throw response.error;
          lastResult=asObject(response?.data);
          return lastResult;
        }catch(error){
          lastError=classifyError(error);
          throw error;
        }finally{
          inFlight=null;
        }
      })();
      return inFlight;
    };
    return Object.freeze({submit,snapshot});
  }

  function bind(container,{
    onRetry,onRefresh,rpc,businessId,role='manager',makeId,now
  }={}){
    if(!container||typeof container.querySelectorAll!=='function')return function noop(){};
    const listeners=[];
    const listen=(element,event,handler)=>{
      element.addEventListener(event,handler);
      listeners.push(()=>element.removeEventListener(event,handler));
    };
    container.querySelectorAll('[data-sector-action="retry"]').forEach(button=>{
      listen(button,'click',()=>{if(typeof onRetry==='function')onRetry()});
    });
    const form=container.querySelector('[data-sector-policy-override-form]');
    if(form&&role==='owner'&&typeof rpc==='function'&&text(businessId)){
      const controller=createOverrideController({rpc,businessId,makeId,now});
      const button=form.querySelector('[data-sector-policy-save]');
      const status=form.querySelector('[data-sector-policy-status]');
      listen(form,'submit',async event=>{
        event.preventDefault();
        const formData=new FormData(form);
        const parameters=Object.fromEntries(
          Object.keys(PARAMETER_META).map(key=>[key,formData.get(key)])
        );
        button.disabled=true;
        button.textContent='Saving…';
        status.textContent='';
        try{
          const result=await controller.submit({
            parameters,reason:formData.get('reason')
          });
          status.textContent=result?.replayed
            ?'This policy change was already saved.'
            :'Policy change saved and added to the audit history.';
          if(typeof onRefresh==='function')await onRefresh();
        }catch(error){
          const classified=controller.snapshot().error||classifyError(error);
          status.textContent=classified.message;
          button.disabled=false;
          button.textContent='Retry policy change';
        }
      });
    }
    return ()=>listeners.splice(0).forEach(remove=>remove());
  }

  return Object.freeze({
    ECONOMICS_CONTRACT,
    DRIVERS_CONTRACT,
    POLICY_CONTRACT,
    POLICY_KEY,
    PARAMETER_META,
    buildViewModel,
    classifyError,
    createOverrideController,
    money,
    normalizeDrivers,
    normalizeEconomics,
    normalizePolicy,
    percentageFromBps,
    render,
    resolveState,
    validateOverride,
    bind
  });
});

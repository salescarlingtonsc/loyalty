(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.NestlyGrowthOffers=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';

  const asObject=value=>value&&typeof value==='object'&&!Array.isArray(value)?value:{};
  const asArray=value=>Array.isArray(value)?value:[];
  const finite=value=>{
    if(value===null||value===undefined||value==='')return null;
    const number=Number(value);
    return Number.isFinite(number)?number:null;
  };
  const text=value=>String(value??'').trim();
  const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,char=>({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
  })[char]);
  const money=(cents,currency='')=>{
    const value=finite(cents);
    const currencyCode=text(currency).toUpperCase();
    if(value===null||!currencyCode)return 'Not supplied';
    return `${currencyCode} ${(value/100).toLocaleString('en-SG',{
      minimumFractionDigits:2,maximumFractionDigits:2
    })}`;
  };
  const safeDate=value=>{
    if(!value)return '';
    const date=new Date(value);
    if(Number.isNaN(date.getTime()))return '';
    return date.toLocaleString('en-SG',{
      day:'numeric',month:'short',year:'numeric',hour:'numeric',minute:'2-digit'
    });
  };
  const safeDateInTimezone=(value,timezone)=>{
    if(!value||!text(timezone))return '';
    const date=new Date(value);
    if(Number.isNaN(date.getTime()))return '';
    try{
      return new Intl.DateTimeFormat('en-SG',{
        timeZone:text(timezone),day:'numeric',month:'short',year:'numeric',
        hour:'numeric',minute:'2-digit'
      }).format(date);
    }catch{
      return '';
    }
  };
  const nullableId=value=>{
    const normalized=text(value);
    return normalized||null;
  };
  const OFFER_TEMPLATES=Object.freeze({
    welcome_back:'Warm welcome back',
    member_thank_you:'Member thank-you',
    simple_saving:'Simple saving'
  });
  const DELIVERY_STATUSES=Object.freeze([
    'queued','scheduled','delivering','delivered',
    'held_out','suppressed','failed','cancelled'
  ]);
  const DELIVERY_SUPPRESSION_REASONS=Object.freeze([
    'feature_disabled','module_disabled','execution_cancelled',
    'execution_expired','branch_unavailable','link_unavailable',
    'consent_withdrawn'
  ]);
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

  function classifyError(error){
    const code=text(error?.code);
    const message=text(error?.message||error||'The request could not be completed.');
    if(code==='0A000'||/growth closed loop is not enabled/i.test(message)){
      return {kind:'disabled',message:'Measured growth recommendations are not enabled for this workspace yet.'};
    }
    if(/branch does not belong to business|branch is outside actor scope/i.test(message)){
      return {kind:'branch',message};
    }
    if(code==='42501'&&/no longer executable|not dismissible|expired|not redeemable/i.test(message)){
      return {kind:'stale',message:'This recommendation or offer is no longer current. Refresh before acting.'};
    }
    if(/recommendation is no longer executable|recommendation is not dismissible|recommendation not found/i.test(message)){
      return {kind:'stale',message:'This recommendation is no longer current. Refresh before acting.'};
    }
    if(code==='42501'||/owner only|permission|forbidden|access required|verified customer link required/i.test(message)){
      return {kind:'permission',message:'Your current account does not have permission for this action.'};
    }
    if(code==='22023'||/guardrail|must be|required|characters|audience is too small/i.test(message)){
      return {kind:'validation',message};
    }
    return {kind:'error',message:'The request did not complete. Try again without changing the details.'};
  }

  async function invokeRpc(rpc,name,args){
    try{
      const response=await rpc(name,args);
      if(response?.error)throw response.error;
      return response?.data;
    }catch(error){
      throw error;
    }
  }

  function normalizeOwnerAction(input={}){
    const source=asObject(input);
    const briefing=asObject(source.briefing||source);
    const action=asObject(briefing.action||briefing.top_action);
    if(!text(action.id||action.recommendation_id))return null;
    const audience=asObject(action.audience);
    const detail=asObject(action.action);
    const valueFromAction=finite(detail.valueCents??detail.value_cents);
    const treatment=finite(audience.treatment);
    const currency=text(detail.currency).toUpperCase();
    if(valueFromAction===null||!currency)return null;
    const requestedTemplate=text(detail.offer_template||detail.offerTemplate);
    const offerTemplate=Object.hasOwn(OFFER_TEMPLATES,requestedTemplate)
      ?requestedTemplate
      :'welcome_back';
    return {
      recommendationId:text(action.id||action.recommendation_id),
      title:text(action.title||'Bring overdue customers back'),
      audience:{
        eligible:finite(audience.eligible),
        excluded:finite(audience.excluded),
        treatment,
        holdout:finite(audience.holdout)
      },
      defaultValueCents:valueFromAction,
      offerTemplate,
      defaultLabel:OFFER_TEMPLATES[offerTemplate],
      currency,
      expiresAt:detail.expiresAt||detail.expires_at||null,
      requiresOwnerApproval:detail.requiresOwnerApproval??detail.requires_owner_approval??true
    };
  }

  function normalizePreview(payload={}){
    const source=asObject(payload);
    return {
      recommendationId:text(source.recommendation_id),
      status:text(source.status||'presented'),
      eligibleCount:finite(source.eligible_count),
      excludedCount:finite(source.excluded_count),
      eligible:asArray(source.eligible).map(item=>({
        clientId:text(item?.client_id),
        evidence:asObject(item?.evidence)
      })),
      excludedByReason:asObject(source.excluded_by_reason)
    };
  }

  function validateApproval(valueCents,label){
    const cents=Math.round(Number(valueCents));
    const offerLabel=text(label);
    if(!Number.isInteger(cents)||cents<100){
      return {ok:false,message:'Enter a credit of at least 1.00 in the workspace currency.'};
    }
    if(!Object.hasOwn(OFFER_TEMPLATES,offerLabel)){
      return {ok:false,message:'Choose one of the Peekaa verified message styles.'};
    }
    return {ok:true,valueCents:cents,label:offerLabel};
  }

  function createOwnerController({
    rpc,businessId,recommendationId,offerTemplate='welcome_back',makeId=makeUuid
  }={}){
    if(typeof rpc!=='function')throw new TypeError('rpc is required');
    const state={
      mode:'idle',preview:null,confirmation:null,result:null,error:null,
      previewing:false,approving:false,dismissing:false
    };
    let previewPromise=null,approvePromise=null,dismissPromise=null;
    let approvalIdempotencyKey=null,dismissIdempotencyKey=null;

    const snapshot=()=>({
      ...state,
      preview:state.preview?{...state.preview}:null,
      confirmation:state.confirmation?{...state.confirmation}:null,
      result:state.result?{...state.result}:null,
      error:state.error?{...state.error}:null
    });

    const preview=async(limit=100)=>{
      if(previewPromise)return previewPromise;
      state.previewing=true;state.error=null;
      previewPromise=(async()=>{
        try{
          const data=await invokeRpc(rpc,'preview_growth_recommendation_v108',{
            p_business:businessId,p_recommendation:recommendationId,p_limit:limit
          });
          state.preview=normalizePreview(data);state.mode='preview';
          return state.preview;
        }catch(error){
          state.error=classifyError(error);
          if(state.error.kind==='stale'||state.error.kind==='permission')state.mode=state.error.kind;
          throw error;
        }finally{
          state.previewing=false;previewPromise=null;
        }
      })();
      return previewPromise;
    };

    const beginApprove=({valueCents,template}={})=>{
      const selectedTemplate=Object.hasOwn(OFFER_TEMPLATES,text(template))
        ?text(template)
        :offerTemplate;
      const validated=validateApproval(valueCents,selectedTemplate);
      if(!validated.ok){
        state.error={kind:'validation',message:validated.message};
        return {ok:false,error:state.error};
      }
      state.error=null;
      state.confirmation={
        kind:'approve',valueCents:validated.valueCents,label:validated.label
      };
      state.mode='confirm-approve';
      return {ok:true,confirmation:{...state.confirmation}};
    };

    const confirmApprove=async()=>{
      if(approvePromise)return approvePromise;
      const confirmation=state.confirmation;
      if(!confirmation||confirmation.kind!=='approve'){
        throw new Error('Approval must be reviewed before it is confirmed.');
      }
      if(!approvalIdempotencyKey)approvalIdempotencyKey=makeId();
      state.approving=true;state.error=null;
      approvePromise=(async()=>{
        try{
          const data=await invokeRpc(rpc,'approve_growth_recommendation_v108',{
            p_business:businessId,
            p_recommendation:recommendationId,
            p_offer_value_cents:confirmation.valueCents,
            p_offer_label:confirmation.label,
            p_idempotency_key:approvalIdempotencyKey
          });
          state.result=asObject(data);state.mode='approved';state.confirmation=null;
          return data;
        }catch(error){
          state.error=classifyError(error);
          state.mode=state.error.kind==='stale'||state.error.kind==='permission'
            ?state.error.kind
            :'confirm-approve';
          throw error;
        }finally{
          state.approving=false;approvePromise=null;
        }
      })();
      return approvePromise;
    };

    const beginDismiss=(reason='')=>{
      state.error=null;
      state.confirmation={kind:'dismiss',reason:text(reason)};
      state.mode='confirm-dismiss';
      return {ok:true,confirmation:{...state.confirmation}};
    };

    const confirmDismiss=async()=>{
      if(dismissPromise)return dismissPromise;
      const confirmation=state.confirmation;
      if(!confirmation||confirmation.kind!=='dismiss'){
        throw new Error('Dismissal must be reviewed before it is confirmed.');
      }
      if(!dismissIdempotencyKey)dismissIdempotencyKey=makeId();
      state.dismissing=true;state.error=null;
      dismissPromise=(async()=>{
        try{
          const data=await invokeRpc(rpc,'dismiss_growth_recommendation_v108',{
            p_business:businessId,
            p_recommendation:recommendationId,
            p_reason:confirmation.reason||null,
            p_idempotency_key:dismissIdempotencyKey
          });
          state.result=asObject(data);state.mode='dismissed';state.confirmation=null;
          return data;
        }catch(error){
          state.error=classifyError(error);
          state.mode=state.error.kind==='stale'||state.error.kind==='permission'
            ?state.error.kind
            :'confirm-dismiss';
          throw error;
        }finally{
          state.dismissing=false;dismissPromise=null;
        }
      })();
      return dismissPromise;
    };

    const cancelConfirmation=()=>{
      state.confirmation=null;state.error=null;
      state.mode=state.preview?'preview':'idle';
    };

    return Object.freeze({
      snapshot,preview,beginApprove,confirmApprove,
      beginDismiss,confirmDismiss,cancelConfirmation
    });
  }

  function errorMarkup(error){
    if(!error)return '';
    return `<div class="growth-inline-state growth-inline-state--${escapeHtml(error.kind)}" role="alert">
      ${escapeHtml(error.message)}</div>`;
  }

  function createRecommendationRefreshController({
    rpc,businessId,branchId=null
  }={}){
    if(typeof rpc!=='function')throw new TypeError('rpc is required');
    if(!text(businessId))throw new TypeError('businessId is required');
    const state={mode:'idle',result:null,error:null};
    let inFlight=null;
    const snapshot=()=>({
      mode:state.mode,
      result:state.result?{...state.result}:null,
      error:state.error?{...state.error}:null,
      refreshing:!!inFlight
    });
    const refresh=()=>{
      if(inFlight)return inFlight;
      state.mode='loading';state.error=null;
      inFlight=(async()=>{
        try{
          const data=await invokeRpc(rpc,'refresh_growth_recommendation_v108',{
            p_business:businessId,
            p_branch:text(branchId)||null
          });
          state.result=asObject(data);state.mode='success';
          return state.result;
        }catch(error){
          state.error=classifyError(error);
          state.mode=state.error.kind;
          throw error;
        }finally{
          inFlight=null;
        }
      })();
      return inFlight;
    };
    return Object.freeze({refresh,snapshot});
  }

  function renderRecommendationRefresh(state={}){
    const mode=text(state.mode||'idle');
    if(mode==='loading'){
      return `<section class="growth-owner-console growth-recommendation-refresh" aria-busy="true">
        <div class="growth-inline-state" role="status" aria-live="polite">Checking this branch for an evidence-backed action…</div>
        <button class="growth-button growth-button--primary" type="button" disabled>Checking…</button>
      </section>`;
    }
    if(mode==='success'){
      const replayed=state.result?.replayed===true;
      return `<section class="growth-owner-console growth-recommendation-refresh">
        <div class="growth-inline-state" role="status" aria-live="polite">
          ${replayed?'The current recommendation was already generated safely.':'Recommendation evidence refreshed.'}
        </div>
        <button class="growth-button growth-button--secondary" type="button" data-growth-recommendation-action="reload">Load current briefing</button>
      </section>`;
    }
    const error=['disabled','permission','branch','error','validation','stale'].includes(mode)
      ?state.error:null;
    return `<section class="growth-owner-console growth-recommendation-refresh" aria-busy="false">
      ${errorMarkup(error)}
      ${mode==='disabled'
        ?''
        :`<button class="growth-button growth-button--primary" type="button" data-growth-recommendation-action="refresh">
          ${mode==='error'?'Try recommendation refresh again':'Check for an evidence-backed action'}
        </button>`}
    </section>`;
  }

  function bindRecommendationRefresh(container,{
    rpc,businessId,branchId=null,onRefresh
  }={}){
    if(!container||typeof container.querySelector!=='function')return {destroy(){}};
    const controller=createRecommendationRefreshController({rpc,businessId,branchId});
    let destroyed=false;
    const render=()=>{
      if(destroyed)return;
      container.innerHTML=renderRecommendationRefresh(controller.snapshot());
      const refreshButton=container.querySelector('[data-growth-recommendation-action="refresh"]');
      if(refreshButton)refreshButton.onclick=()=>{
        const request=controller.refresh();
        render();
        request.then(()=>{
          if(!destroyed)render();
        }).catch(()=>{
          if(!destroyed)render();
        });
      };
      const reloadButton=container.querySelector('[data-growth-recommendation-action="reload"]');
      if(reloadButton)reloadButton.onclick=()=>{
        if(typeof onRefresh==='function')onRefresh();
      };
    };
    render();
    return Object.freeze({controller,destroy(){destroyed=true;container.replaceChildren?.()}});
  }

  function normalizeDeliveryStatus(payload={}){
    const source=asObject(payload);
    const deliveries=asArray(source.deliveries).map(item=>{
      const row=asObject(item);
      const status=text(row.status);
      if(!text(row.dispatch_id)||!DELIVERY_STATUSES.includes(status))return null;
      const entitlementStatus=text(row.entitlement_status);
      const suppressionReason=text(row.suppression_reason);
      const entitlementSuppressed=row.entitlement_suppressed===true||
        entitlementStatus==='suppressed';
      const suppressionReasonKnown=entitlementSuppressed&&
        DELIVERY_SUPPRESSION_REASONS.includes(suppressionReason);
      return {
        dispatchId:text(row.dispatch_id),
        deliveryId:text(row.delivery_id),
        status,
        scheduledFor:row.scheduled_for||null,
        attemptCount:finite(row.attempt_count),
        deliveredAt:row.delivered_at||null,
        failureCode:text(row.failure_code),
        cancelledAt:row.cancelled_at||null,
        updatedAt:row.updated_at||null,
        entitlementStatus,
        entitlementSuppressed,
        suppressionReason:suppressionReasonKnown?suppressionReason:''
      };
    }).filter(Boolean);
    const rawCounts=asObject(source.counts);
    const counts={};
    for(const status of DELIVERY_STATUSES){
      const count=finite(rawCounts[status]);
      if(count!==null)counts[status]=count;
    }
    return {
      contractVersion:text(source.contract_version),
      executionId:text(source.execution_id),
      businessId:text(source.business_id),
      branchId:text(source.branch_id),
      counts,
      deliveries
    };
  }

  function normalizeActiveExecution(payload={},{
    expectedBranchId=null
  }={}){
    const envelope=asObject(payload);
    const source=asObject(envelope.active_execution||envelope);
    const executionId=text(source.execution_id);
    if(!executionId)return null;

    const branchId=nullableId(source.branch_id);
    if(branchId!==nullableId(expectedBranchId))return null;

    const copy=asObject(source.governed_copy);
    const conditions=asObject(copy.conditions);
    const locked=asObject(copy.locked_facts);
    const recommendationId=text(source.recommendation_id);
    const templateId=text(locked.template_id);
    const currency=text(source.currency).toUpperCase();
    const lockedCurrency=text(locked.currency).toUpperCase();
    const timezone=text(locked.timezone);
    const expiry=locked.expires_at;
    const expiryTime=new Date(expiry).getTime();
    const conditionsExpiryTime=new Date(conditions.expires_at).getTime();
    const valueCents=finite(locked.offer_value_cents);
    const ctaLabel=text(copy.cta_label);
    const ctaDestination=text(copy.cta_destination);

    if(
      text(copy.schema)!=='nestly.growth_offer_copy'||
      finite(copy.version)!==1||
      !Object.hasOwn(OFFER_TEMPLATES,templateId)||
      !text(copy.title)||
      !text(copy.body)||
      ctaLabel!=='Redeem now'||
      ctaDestination!=='customer_growth_offer_qr'||
      text(locked.cta_label)!==ctaLabel||
      text(locked.cta_destination)!==ctaDestination||
      text(locked.recommendation_id)!==recommendationId||
      nullableId(locked.branch_id)!==branchId||
      valueCents===null||valueCents<0||
      !currency||lockedCurrency!==currency||
      !timezone||text(conditions.timezone)!==timezone||
      !Number.isFinite(expiryTime)||
      !Number.isFinite(conditionsExpiryTime)||
      expiryTime!==conditionsExpiryTime||
      !safeDateInTimezone(expiry,timezone)
    )return null;

    const rawDelivery=asObject(source.delivery);
    const delivery={};
    for(const status of DELIVERY_STATUSES){
      const count=finite(rawDelivery[status]);
      delivery[status]=count===null?0:Math.max(0,Math.trunc(count));
    }

    const normalizeArm=arm=>{
      const row=asObject(arm);
      return {
        members:finite(row.members),
        buyers:finite(row.buyers),
        conversionRateBps:finite(row.conversion_rate_bps),
        associatedRevenueCents:finite(row.associated_revenue_cents)
      };
    };
    const measurementSource=asObject(source.provisional_measurement);
    const measurementStatus=text(measurementSource.measurement_status);
    const allowedMeasurementStatuses=[
      'provisional','final','invalid_overlap','inconclusive_small_sample'
    ];
    const estimateSource=asObject(measurementSource.estimated_incremental_revenue);
    const estimateCurrency=text(estimateSource.currency).toUpperCase();
    const estimate=estimateCurrency===currency&&finite(estimateSource.low_cents)!==null&&
      finite(estimateSource.high_cents)!==null
      ?{
        currency,
        pointEstimateCents:finite(estimateSource.point_estimate_cents),
        lowCents:finite(estimateSource.low_cents),
        highCents:finite(estimateSource.high_cents),
        confidenceLevel:text(estimateSource.confidence_level)
      }
      :null;
    const provisionalMeasurement=allowedMeasurementStatuses.includes(measurementStatus)
      ?{
        status:measurementStatus,
        method:text(measurementSource.method),
        treatment:normalizeArm(asObject(measurementSource.arms).treatment),
        holdout:normalizeArm(asObject(measurementSource.arms).holdout),
        estimatedIncrementalRevenue:estimate,
        incrementalGrossProfit:measurementSource.incremental_gross_profit??null,
        cost:asObject(measurementSource.cost),
        limitations:asArray(measurementSource.limitations).map(text).filter(Boolean)
      }
      :null;

    const rawArms=asObject(source.arms);
    return {
      executionId,
      recommendationId,
      branchId,
      currency,
      status:text(source.status),
      startedAt:source.started_at||null,
      endsAt:source.ends_at||null,
      title:text(copy.title),
      body:text(copy.body),
      ctaLabel,
      ctaDestination,
      templateId,
      valueCents,
      expiresAt:expiry,
      timezone,
      delivery,
      arms:{
        treatment:finite(rawArms.treatment),
        holdout:finite(rawArms.holdout)
      },
      provisionalMeasurement
    };
  }

  function createDeliveryController({
    rpc,businessId,executionId,makeId=makeUuid
  }={}){
    if(typeof rpc!=='function')throw new TypeError('rpc is required');
    const state={mode:'idle',data:null,error:null,pending:null};
    let loadPromise=null;
    const inflight=new Map();
    const idempotencyKeys=new Map();
    const snapshot=()=>({
      ...state,
      data:state.data?{
        ...state.data,
        counts:{...state.data.counts},
        deliveries:state.data.deliveries.map(item=>({...item}))
      }:null,
      error:state.error?{...state.error}:null,
      pending:state.pending?{...state.pending}:null
    });
    const load=async()=>{
      if(loadPromise)return loadPromise;
      state.mode='loading';state.error=null;
      loadPromise=(async()=>{
        try{
          const data=await invokeRpc(rpc,'get_growth_delivery_status_v110',{
            p_business:businessId,p_execution:executionId
          });
          state.data=normalizeDeliveryStatus(data);
          state.mode='ready';
          return state.data;
        }catch(error){
          state.error=classifyError(error);state.mode=state.error.kind;
          throw error;
        }finally{
          loadPromise=null;
        }
      })();
      return loadPromise;
    };
    const mutate=async(kind,dispatchId,reason='')=>{
      const id=text(dispatchId);
      const dispatch=state.data?.deliveries.find(item=>item.dispatchId===id);
      if(!dispatch)throw new Error('Delivery status must be loaded before acting.');
      if(kind==='cancel'){
        if(!['queued','scheduled','delivering','failed'].includes(dispatch.status)){
          throw new Error('Only pending, delivering, or failed deliveries can be cancelled.');
        }
        if(text(reason).length<2||text(reason).length>500){
          throw new Error('Enter a cancellation reason between 2 and 500 characters.');
        }
      }else if(kind==='retry'){
        if(dispatch.status!=='failed'||dispatch.attemptCount===null||dispatch.attemptCount>=5){
          throw new Error('Only failed deliveries below the five-attempt limit can be retried.');
        }
      }else{
        throw new Error('Unsupported delivery action.');
      }
      const requestKey=`${kind}:${id}`;
      if(inflight.has(requestKey))return inflight.get(requestKey);
      if(!idempotencyKeys.has(requestKey))idempotencyKeys.set(requestKey,makeId());
      state.pending={kind,dispatchId:id};state.error=null;
      const request=(async()=>{
        try{
          const name=kind==='cancel'
            ?'cancel_growth_delivery_v110'
            :'retry_growth_delivery_v110';
          const args=kind==='cancel'
            ?{
              p_business:businessId,p_dispatch:id,p_reason:text(reason),
              p_idempotency_key:idempotencyKeys.get(requestKey)
            }
            :{
              p_business:businessId,p_dispatch:id,
              p_idempotency_key:idempotencyKeys.get(requestKey)
            };
          const result=asObject(await invokeRpc(rpc,name,args));
          dispatch.status=text(result.status)||dispatch.status;
          const attempts=finite(result.attempt_count);
          if(attempts!==null)dispatch.attemptCount=attempts;
          state.mode='ready';
          return result;
        }catch(error){
          state.error=classifyError(error);
          throw error;
        }finally{
          state.pending=null;inflight.delete(requestKey);
        }
      })();
      inflight.set(requestKey,request);
      return request;
    };
    return Object.freeze({
      load,
      cancel:(dispatchId,reason)=>mutate('cancel',dispatchId,reason),
      retry:dispatchId=>mutate('retry',dispatchId),
      snapshot
    });
  }

  const deliveryStatusCopy=status=>({
    queued:'Queued',
    scheduled:'Scheduled',
    delivering:'Delivering',
    delivered:'Delivered',
    held_out:'Measurement holdout',
    suppressed:'Suppressed by safeguards',
    failed:'Needs attention',
    cancelled:'Cancelled'
  })[status]||status;
  const deliverySuppressionCopy=reason=>({
    feature_disabled:'Growth offers were paused before provider confirmation',
    module_disabled:'The retention module was disabled before provider confirmation',
    execution_cancelled:'The campaign was cancelled before provider confirmation',
    execution_expired:'The campaign ended before provider confirmation',
    branch_unavailable:'The branch became unavailable before provider confirmation',
    link_unavailable:'The customer programme link became unavailable',
    consent_withdrawn:'The customer withdrew marketing consent'
  })[reason]||'Eligibility changed before provider confirmation';

  function renderActiveExecution(payload={},options={}){
    const execution=normalizeActiveExecution(payload,options);
    if(!execution)return '';
    const measurement=execution.provisionalMeasurement;
    const measurementIsFinal=measurement?.status==='final';
    const measurementStatusLabel=({
      provisional:'Early measurement',
      final:'Final measurement',
      invalid_overlap:'Measurement invalidated',
      inconclusive_small_sample:'Not enough evidence yet'
    })[measurement?.status]||'Measurement pending';
    const treatment=measurement?.treatment;
    const holdout=measurement?.holdout;
    const estimate=measurement?.estimatedIncrementalRevenue;
    const deliveryItems=DELIVERY_STATUSES.map(status=>
      `<li><strong>${escapeHtml(execution.delivery[status])}</strong><span>${escapeHtml(deliveryStatusCopy(status))}</span></li>`
    ).join('');
    const windowEnd=safeDateInTimezone(execution.endsAt,execution.timezone);
    const expiresAt=safeDateInTimezone(execution.expiresAt,execution.timezone);
    const inProgress=execution.delivery.queued+
      execution.delivery.scheduled+
      execution.delivery.delivering;
    const members=value=>value===null?'—':String(value);
    const buyers=value=>value===null?'—':String(value);
    return `<section class="growth-active-execution" aria-labelledby="growthActiveExecutionHeading">
      <div class="growth-section-heading">
        <div>
          <span class="growth-eyebrow">Active measured offer</span>
          <h2 id="growthActiveExecutionHeading">${escapeHtml(execution.title)}</h2>
          <p>${escapeHtml(execution.body)}</p>
        </div>
        <span class="growth-pill">${escapeHtml(execution.status||'active')}</span>
      </div>
      <div class="growth-active-offer-grid">
        <div><span>Offer value</span><strong>${escapeHtml(money(execution.valueCents,execution.currency))}</strong></div>
        <div><span>Customer CTA</span><strong>${escapeHtml(execution.ctaLabel)}</strong></div>
        <div><span>Offer expires</span><strong>${escapeHtml(expiresAt)}</strong><small>${escapeHtml(execution.timezone)}</small></div>
        <div><span>Measurement window ends</span><strong>${escapeHtml(windowEnd||'Not supplied')}</strong><small>${escapeHtml(execution.timezone)}</small></div>
      </div>
      <div class="growth-active-delivery">
        <div class="growth-section-heading">
          <div><h3>Delivery truth</h3>
          <p><strong>${escapeHtml(execution.delivery.delivered)}</strong> delivered; <strong>${escapeHtml(inProgress)}</strong> queued or in progress. Only delivered offers count as delivered.</p></div>
        </div>
        <ul>${deliveryItems}</ul>
      </div>
      <div class="growth-provisional-measurement" data-measurement-status="${escapeHtml(measurement?.status||'pending')}">
        <span class="growth-eyebrow">${escapeHtml(measurementStatusLabel)}</span>
        <h3>${measurementIsFinal?'Measured result':'Directional signal — not a final revenue or profit result'}</h3>
        ${measurement?`<div class="growth-measurement-arms">
          <div><span>Treatment</span><strong>${escapeHtml(buyers(treatment.buyers))} buyers / ${escapeHtml(members(treatment.members))} members</strong></div>
          <div><span>Holdout</span><strong>${escapeHtml(buyers(holdout.buyers))} buyers / ${escapeHtml(members(holdout.members))} members</strong></div>
        </div>`:'<p>Measurement evidence is not available yet.</p>'}
        ${estimate?`<p class="growth-measurement-estimate">Estimated incremental revenue range: <strong>${escapeHtml(money(estimate.lowCents,estimate.currency))}–${escapeHtml(money(estimate.highCents,estimate.currency))}</strong>${estimate.pointEstimateCents===null?'':` · point estimate ${escapeHtml(money(estimate.pointEstimateCents,estimate.currency))}`}</p>`:''}
        <p class="growth-privacy-note">${measurementIsFinal
          ?'Revenue is not gross profit. Incremental gross profit is not reported until cost evidence supports it.'
          :'Do not treat this early signal as final incremental revenue or profit. The holdout and full measurement window protect the comparison.'}</p>
      </div>
    </section>`;
  }

  function renderDeliveryStatus(state={}){
    const mode=text(state.mode||'idle');
    const data=state.data||null;
    if(mode==='idle'){
      return `<section class="growth-delivery-status">
        <button class="growth-button growth-button--secondary" type="button" data-growth-delivery-action="load">Load delivery status</button>
      </section>`;
    }
    if(mode==='loading'&&!data){
      return `<section class="growth-delivery-status" aria-busy="true" role="status">Loading verified delivery status…</section>`;
    }
    if(!data){
      return `<section class="growth-delivery-status">
        ${errorMarkup(state.error)}
        <button class="growth-button growth-button--secondary" type="button" data-growth-delivery-action="load">Try again</button>
      </section>`;
    }
    const summary=DELIVERY_STATUSES
      .filter(status=>Object.hasOwn(data.counts,status))
      .map(status=>`<li><strong>${escapeHtml(data.counts[status])}</strong> ${escapeHtml(deliveryStatusCopy(status))}</li>`)
      .join('');
    return `<section class="growth-delivery-status" aria-labelledby="growthDeliveryHeading">
      <div class="growth-section-heading"><div><span class="growth-eyebrow">Verified delivery lifecycle</span>
      <h4 id="growthDeliveryHeading">Live execution status</h4>
      <p>These states come from Peekaa's delivery service. A queued or delivering item is not a delivered offer.</p></div>
      <button class="growth-button growth-button--secondary" type="button" data-growth-delivery-action="load"${mode==='loading'?' disabled':''}>${mode==='loading'?'Refreshing…':'Refresh status'}</button></div>
      ${errorMarkup(state.error)}
      ${summary?`<ul class="growth-delivery-summary">${summary}</ul>`:''}
      <div class="growth-delivery-list">${data.deliveries.map(dispatch=>{
        const canCancel=['queued','scheduled','delivering','failed'].includes(dispatch.status);
        const canRetry=dispatch.status==='failed'&&dispatch.attemptCount!==null&&dispatch.attemptCount<5;
        const pending=state.pending?.dispatchId===dispatch.dispatchId;
        const timing=dispatch.status==='delivered'
          ?safeDate(dispatch.deliveredAt)
          :dispatch.status==='scheduled'
            ?safeDate(dispatch.scheduledFor)
            :'';
        const entitlementTruth=dispatch.status==='delivered'&&dispatch.entitlementSuppressed
          ?dispatch.suppressionReason
            ?`<strong class="growth-delivery-warning">Message delivered; offer not issued — ${escapeHtml(deliverySuppressionCopy(dispatch.suppressionReason))}.</strong>`
            :'<strong class="growth-delivery-warning">Message delivered; offer issuance status unavailable.</strong>'
          :dispatch.status==='delivered'&&dispatch.entitlementStatus==='issued'
            ?'<span>Message delivered; offer issued.</span>'
            :dispatch.status==='delivered'&&dispatch.entitlementStatus
              ?'<strong class="growth-delivery-warning">Message delivered; offer issuance status unavailable.</strong>'
            :'';
        return `<article class="growth-delivery-row" data-delivery-status="${escapeHtml(dispatch.status)}">
          <div><strong>${escapeHtml(deliveryStatusCopy(dispatch.status))}</strong>
          ${timing?`<span>${escapeHtml(timing)}</span>`:''}
          ${dispatch.attemptCount===null?'':`<span>Attempt ${escapeHtml(dispatch.attemptCount)} of 5</span>`}
          ${entitlementTruth}</div>
          ${canRetry?`<button class="growth-button growth-button--secondary" type="button" data-growth-delivery-action="retry" data-dispatch-id="${escapeHtml(dispatch.dispatchId)}"${pending?' disabled':''}>Retry</button>`:''}
          ${canCancel?`<button class="growth-button growth-button--secondary" type="button" data-growth-delivery-action="begin-cancel" data-dispatch-id="${escapeHtml(dispatch.dispatchId)}"${pending?' disabled':''}>Cancel</button>`:''}
          ${state.pending?.kind==='confirm-cancel'&&pending?`<div class="growth-delivery-cancel">
            <label>Cancellation reason<input type="text" minlength="2" maxlength="500" data-growth-delivery-reason="${escapeHtml(dispatch.dispatchId)}"></label>
            <button class="growth-button growth-button--danger" type="button" data-growth-delivery-action="confirm-cancel" data-dispatch-id="${escapeHtml(dispatch.dispatchId)}">Confirm cancellation</button>
          </div>`:''}
        </article>`;
      }).join('')}</div>
    </section>`;
  }

  function bindDeliveryStatus(container,{
    rpc,businessId,executionId,makeId=makeUuid
  }={}){
    if(!container||typeof container.querySelector!=='function')return {destroy(){}};
    const controller=createDeliveryController({rpc,businessId,executionId,makeId});
    let destroyed=false;
    const settle=promise=>promise.catch(()=>{}).finally(render);
    const render=()=>{
      if(destroyed)return;
      container.innerHTML=renderDeliveryStatus(controller.snapshot());
      container.querySelectorAll('[data-growth-delivery-action="load"]').forEach(button=>{
        button.onclick=()=>{settle(controller.load());render()};
      });
      container.querySelectorAll('[data-growth-delivery-action="retry"]').forEach(button=>{
        button.onclick=()=>{settle(controller.retry(button.dataset.dispatchId));render()};
      });
      container.querySelectorAll('[data-growth-delivery-action="begin-cancel"]').forEach(button=>{
        button.onclick=()=>{
          const state=controller.snapshot();
          state.pending={kind:'confirm-cancel',dispatchId:button.dataset.dispatchId};
          container.innerHTML=renderDeliveryStatus(state);
          const confirm=container.querySelector('[data-growth-delivery-action="confirm-cancel"]');
          if(confirm)confirm.onclick=()=>{
            const reason=container.querySelector(`[data-growth-delivery-reason="${confirm.dataset.dispatchId}"]`)?.value||'';
            settle(controller.cancel(confirm.dataset.dispatchId,reason));
          };
        };
      });
    };
    render();
    return Object.freeze({controller,destroy(){destroyed=true;container.replaceChildren?.()}});
  }

  function previewMarkup(preview){
    if(!preview)return '';
    const reasons=Object.entries(preview.excludedByReason);
    return `<section class="growth-audience" aria-labelledby="growthAudienceHeading">
      <div class="growth-section-heading"><div><span class="growth-eyebrow">Audience preview</span>
      <h4 id="growthAudienceHeading">Who is eligible before holdout assignment</h4></div>
      <span class="growth-pill">${escapeHtml(preview.status)}</span></div>
      <div class="growth-audience-grid">
        <div><strong>${preview.eligibleCount===null?'Not supplied':escapeHtml(preview.eligibleCount)}</strong><span>eligible</span></div>
        <div><strong>${preview.excludedCount===null?'Not supplied':escapeHtml(preview.excludedCount)}</strong><span>excluded</span></div>
      </div>
      ${reasons.length?`<details><summary>Why customers were excluded</summary><ul>
        ${reasons.map(([reason,count])=>`<li><span>${escapeHtml(reason.replaceAll('_',' '))}</span><strong>${escapeHtml(count)}</strong></li>`).join('')}
      </ul></details>`:''}
      <p class="growth-privacy-note">This preview does not contact customers, create an offer, or reveal contact details.</p>
    </section>`;
  }

  function ownerResultMarkup(state,model){
    if(state.mode==='approved'){
      return `<section class="growth-result growth-result--success" role="status" aria-live="polite">
        <span class="growth-eyebrow">Approved${state.result?.replayed?' · safely replayed':''}</span>
        <h4>Approval recorded</h4>
        <p>The measured bring-back is approved. Delivery is not confirmed on this approval receipt;
          refresh the live execution status before describing any offer as sent or delivered.</p>
        <p>Maximum approved credit: ${escapeHtml(money(state.result?.estimated_cost_cents,model.currency))}. No SMS is authorized by this action.</p>
        ${text(state.result?.execution_id)?'<div data-growth-delivery-status></div>':''}
        <button class="growth-button growth-button--secondary" type="button" data-growth-owner-action="refresh">Refresh briefing</button>
      </section>`;
    }
    if(state.mode==='dismissed'){
      return `<section class="growth-result" role="status" aria-live="polite">
        <span class="growth-eyebrow">Dismissed${state.result?.replayed?' · safely replayed':''}</span>
        <h4>No customers were contacted</h4>
        <p>This recommendation is closed. Refresh to look for the next evidence-backed action.</p>
        <button class="growth-button growth-button--secondary" type="button" data-growth-owner-action="refresh">Refresh briefing</button>
      </section>`;
    }
    return '';
  }

  function renderOwnerAction({model,state}={}){
    const action=model||null;
    const current=state||{mode:'idle'};
    if(!action)return '';
    if(current.mode==='approved'||current.mode==='dismissed'){
      return ownerResultMarkup(current,action);
    }
    if(current.mode==='permission'||current.mode==='stale'){
      return `<section class="growth-owner-console" data-growth-owner-console>
        ${errorMarkup(current.error||{
          kind:current.mode,
          message:current.mode==='stale'
            ?'This recommendation is no longer current. Refresh before acting.'
            :'Only the business owner can approve or dismiss this action.'
        })}
        <button class="growth-button growth-button--secondary" type="button" data-growth-owner-action="refresh">Refresh briefing</button>
      </section>`;
    }
    const preview=current.preview;
    const value=((current.confirmation?.valueCents??action.defaultValueCents)/100).toFixed(2);
    const offerTemplate=current.confirmation?.label||action.offerTemplate;
    const label=OFFER_TEMPLATES[offerTemplate]||action.defaultLabel;
    const approveConfirmation=current.mode==='confirm-approve';
    const dismissConfirmation=current.mode==='confirm-dismiss';
    const treatment=action.audience.treatment??preview?.eligibleCount??null;
    const holdout=action.audience.holdout??null;
    const approvedValue=current.confirmation?.valueCents??action.defaultValueCents;
    const maximumCost=treatment===null||approvedValue===null
      ?null
      :treatment*approvedValue;
    return `<section class="growth-owner-console" data-growth-owner-console aria-labelledby="growthOwnerHeading">
      <div class="growth-section-heading"><div><span class="growth-eyebrow">Owner decision</span>
      <h3 id="growthOwnerHeading">Review the audience before sending</h3>
      <p>Nothing is sent until you preview the audience, adjust the credit, and confirm twice.</p></div></div>
      ${errorMarkup(current.error)}
      ${previewMarkup(preview)}
      ${preview&&!approveConfirmation&&!dismissConfirmation?`<div class="growth-offer-form">
        <label>Credit per customer (${escapeHtml(action.currency||'workspace currency')})
          <input type="number" inputmode="decimal" min="1" step="0.01" value="${escapeHtml(value)}" data-growth-owner-field="credit">
        </label>
        <label>Message style
          <select data-growth-owner-field="template">
            ${Object.entries(OFFER_TEMPLATES).map(([identifier,title])=>`<option value="${escapeHtml(identifier)}"${identifier===offerTemplate?' selected':''}>${escapeHtml(title)}</option>`).join('')}
          </select>
        </label>
        <p class="growth-privacy-note">Peekaa writes the final title, message and CTA from this verified style. Credit, eligibility, expiry and conditions stay locked by the server; free-form claims are not accepted.</p>
        <p class="growth-cost-preview">Maximum issued credit before consent and frequency suppressions: <strong data-growth-cost>${escapeHtml(money(maximumCost,action.currency))}</strong>.</p>
      </div>`:''}
      ${approveConfirmation?`<section class="growth-confirmation" role="alertdialog" aria-labelledby="growthConfirmHeading">
        <span class="growth-eyebrow">Final confirmation</span>
        <h4 id="growthConfirmHeading">Approve ${escapeHtml(label)} for the measured treatment group?</h4>
        <ul><li>${treatment===null?'Not supplied':escapeHtml(treatment)} treatment customers may be queued or scheduled for the in-app offer.</li>
        <li>${holdout===null?'Not supplied':escapeHtml(holdout)} customers receive nothing and remain the measurement holdout.</li>
        <li>Maximum issued credit is ${escapeHtml(money(maximumCost,action.currency))}; consent and frequency limits still apply.</li></ul>
        <div class="growth-button-row"><button class="growth-button growth-button--primary" type="button" data-growth-owner-action="confirm-approve"${current.approving?' disabled':''}>${current.approving?'Approving…':'Confirm approval'}</button>
        <button class="growth-button growth-button--secondary" type="button" data-growth-owner-action="cancel"${current.approving?' disabled':''}>Go back</button></div>
      </section>`:''}
      ${dismissConfirmation?`<section class="growth-confirmation growth-confirmation--dismiss" role="alertdialog" aria-labelledby="growthDismissHeading">
        <span class="growth-eyebrow">Confirm dismissal</span>
        <h4 id="growthDismissHeading">Dismiss this recommendation?</h4>
        <p>No customer will be contacted and no offer will be created.</p>
        <label>Reason (optional)<input type="text" maxlength="500" value="${escapeHtml(current.confirmation?.reason||'')}" data-growth-owner-field="dismiss-reason"></label>
        <div class="growth-button-row"><button class="growth-button growth-button--danger" type="button" data-growth-owner-action="confirm-dismiss"${current.dismissing?' disabled':''}>${current.dismissing?'Dismissing…':'Confirm dismissal'}</button>
        <button class="growth-button growth-button--secondary" type="button" data-growth-owner-action="cancel"${current.dismissing?' disabled':''}>Go back</button></div>
      </section>`:''}
      ${!approveConfirmation&&!dismissConfirmation?`<div class="growth-button-row">
        ${preview
          ?'<button class="growth-button growth-button--primary" type="button" data-growth-owner-action="begin-approve">Review approval</button>'
          :`<button class="growth-button growth-button--primary" type="button" data-growth-owner-action="preview"${current.previewing?' disabled':''}>${current.previewing?'Loading audience…':'Preview audience'}</button>`}
        <button class="growth-button growth-button--secondary" type="button" data-growth-owner-action="begin-dismiss">Dismiss</button>
      </div>`:''}
      <div class="growth-owner-status" role="status" aria-live="polite"></div>
    </section>`;
  }

  function bindOwnerControls(container,{
    rpc,businessId,action,onRefresh,makeId=makeUuid
  }={}){
    if(!container||typeof container.querySelector!=='function')return {destroy(){}};
    const model=normalizeOwnerAction(action);
    if(!model){container.replaceChildren?.();return {destroy(){}}}
    const controller=createOwnerController({
      rpc,businessId,recommendationId:model.recommendationId,
      offerTemplate:model.offerTemplate,makeId
    });
    let destroyed=false;
    let deliveryBinding=null;
    const render=()=>{
      if(destroyed)return;
      deliveryBinding?.destroy?.();
      deliveryBinding=null;
      container.innerHTML=renderOwnerAction({model,state:controller.snapshot()});
      wire();
      const result=controller.snapshot().result;
      const deliveryMount=container.querySelector('[data-growth-delivery-status]');
      if(deliveryMount&&text(result?.execution_id)){
        deliveryBinding=bindDeliveryStatus(deliveryMount,{
          rpc,businessId,executionId:text(result.execution_id),makeId
        });
      }
    };
    const settle=promise=>promise.catch(()=>{}).finally(render);
    const wire=()=>{
      const query=selector=>container.querySelector(selector);
      const actionButton=name=>query(`[data-growth-owner-action="${name}"]`);
      const preview=actionButton('preview');
      if(preview)preview.onclick=()=>{settle(controller.preview())};
      const beginApprove=actionButton('begin-approve');
      if(beginApprove)beginApprove.onclick=()=>{
        const dollars=Number(query('[data-growth-owner-field="credit"]')?.value);
        const template=query('[data-growth-owner-field="template"]')?.value||model.offerTemplate;
        controller.beginApprove({valueCents:Math.round(dollars*100),template});render();
      };
      const confirmApprove=actionButton('confirm-approve');
      if(confirmApprove)confirmApprove.onclick=()=>{
        confirmApprove.disabled=true;settle(controller.confirmApprove());
      };
      const beginDismiss=actionButton('begin-dismiss');
      if(beginDismiss)beginDismiss.onclick=()=>{controller.beginDismiss();render()};
      const confirmDismiss=actionButton('confirm-dismiss');
      if(confirmDismiss)confirmDismiss.onclick=()=>{
        const reason=query('[data-growth-owner-field="dismiss-reason"]')?.value||'';
        controller.beginDismiss(reason);
        confirmDismiss.disabled=true;settle(controller.confirmDismiss());
      };
      const cancel=actionButton('cancel');
      if(cancel)cancel.onclick=()=>{controller.cancelConfirmation();render()};
      const refresh=actionButton('refresh');
      if(refresh)refresh.onclick=()=>{if(typeof onRefresh==='function')onRefresh()};
      const credit=query('[data-growth-owner-field="credit"]');
      if(credit)credit.oninput=()=>{
        const dollars=finite(credit.value);
        const treatmentCount=model.audience.treatment??controller.snapshot().preview?.eligibleCount??null;
        const cost=query('[data-growth-cost]');
        if(cost)cost.textContent=money(
          dollars===null||treatmentCount===null
            ?null
            :Math.round(dollars*100)*treatmentCount,
          model.currency
        );
      };
    };
    render();
    return Object.freeze({controller,destroy(){
      destroyed=true;deliveryBinding?.destroy?.();container.replaceChildren?.();
    }});
  }

  function normalizeCustomerOffers(payload={},now=Date.now()){
    const current=Number(now);
    return asArray(asObject(payload).offers).filter(offer=>{
      if(text(offer?.status)!=='issued')return false;
      const expires=Date.parse(offer?.expires_at||'');
      return Number.isFinite(expires)&&expires>current;
    }).map(offer=>{
      const valueCents=finite(offer.value_cents);
      return {
        entitlementId:text(offer.entitlement_id),
        label:text(offer.label||'Welcome-back credit'),
        type:text(offer.type||'credit_cents'),
        valueCents,
        currency:text(offer.currency).toUpperCase(),
        issuedAt:offer.issued_at||null,
        expiresAt:offer.expires_at||null
      };
    }).filter(offer=>offer.entitlementId&&offer.valueCents!==null&&offer.valueCents>=0&&offer.currency);
  }

  function renderCustomerOffers({state='ready',offers=[],error=null,businessName='this business'}={}){
    if(state==='empty'||state==='disabled'||state==='holdout')return '';
    if(state==='loading'){
      return '<section class="card wallet-section growth-customer-offers" id="walletGrowthOffers" aria-busy="true"><div class="wallet-skeleton"></div></section>';
    }
    if(state==='error'){
      return `<section class="card wallet-section growth-customer-offers" id="walletGrowthOffers" aria-busy="false">
        <div class="growth-section-heading"><div><h2>Offers</h2><p>Offers from ${escapeHtml(businessName)} could not be checked.</p></div>
        <button class="growth-button growth-button--secondary" type="button" data-growth-customer-action="retry">Try again</button></div>
        ${errorMarkup(error||{kind:'error',message:'Offers could not be loaded.'})}</section>`;
    }
    if(!offers.length)return '';
    return `<section class="card wallet-section growth-customer-offers" id="walletGrowthOffers" aria-busy="false" aria-labelledby="growthCustomerOffersHeading">
      <div class="growth-section-heading"><div><span class="growth-eyebrow">Just for you</span>
      <h2 id="growthCustomerOffersHeading">Welcome-back offers</h2>
      <p>Show a QR at the counter. The offer is used only after the business scans it.</p></div></div>
      <div class="growth-customer-offer-grid">${offers.map(offer=>`<article class="growth-customer-offer">
        <div><span class="growth-pill">In-app offer</span><h3>${escapeHtml(offer.label)}</h3>
        <strong>${escapeHtml(money(offer.valueCents,offer.currency))}</strong>
        <p>Use by ${escapeHtml(safeDate(offer.expiresAt)||'the stated expiry')}.</p></div>
        <button class="growth-button growth-button--primary" type="button" data-growth-customer-action="redeem" data-entitlement-id="${escapeHtml(offer.entitlementId)}">Redeem now</button>
        <p class="growth-offer-status" data-growth-offer-status="${escapeHtml(offer.entitlementId)}" role="status" aria-live="polite"></p>
      </article>`).join('')}</div>
    </section>`;
  }

  function createCustomerController({rpc,makeId=makeUuid}={}){
    if(typeof rpc!=='function')throw new TypeError('rpc is required');
    const attempts=new Map();
    const inflight=new Map();
    const errors=new Map();
    const prepare=async entitlementId=>{
      const id=text(entitlementId);
      if(!id)throw new Error('entitlementId is required');
      if(inflight.has(id))return inflight.get(id);
      if(!attempts.has(id))attempts.set(id,makeId());
      errors.delete(id);
      const request=(async()=>{
        try{
          return await invokeRpc(rpc,'customer_prepare_growth_offer_qr_v108',{
            p_entitlement:id,p_idempotency_key:attempts.get(id)
          });
        }catch(error){
          errors.set(id,classifyError(error));throw error;
        }finally{
          inflight.delete(id);
        }
      })();
      inflight.set(id,request);
      return request;
    };
    return Object.freeze({
      prepare,
      snapshot:()=>({
        inflight:[...inflight.keys()],
        errors:Object.fromEntries(errors),
        attemptKeys:Object.fromEntries(attempts)
      })
    });
  }

  function bindCustomerOffers(container,{
    rpc,onQr,onRetry,makeId=makeUuid
  }={}){
    if(!container||typeof container.querySelectorAll!=='function')return {destroy(){}};
    const controller=createCustomerController({rpc,makeId});
    let destroyed=false;
    container.querySelectorAll('[data-growth-customer-action="redeem"]').forEach(button=>{
      button.onclick=async()=>{
        const entitlementId=button.dataset.entitlementId;
        if(!entitlementId||button.disabled)return;
        button.disabled=true;button.textContent='Preparing QR…';
        const status=container.querySelector(`[data-growth-offer-status="${entitlementId}"]`);
        if(status)status.textContent='';
        try{
          const intent=await controller.prepare(entitlementId);
          if(destroyed||!button.isConnected)return;
          button.disabled=false;button.textContent='Show QR again';
          if(typeof onQr==='function')onQr({intent,entitlementId});
        }catch{
          if(destroyed||!button.isConnected)return;
          const error=controller.snapshot().errors[entitlementId]||{message:'The QR could not be prepared. Try again.'};
          button.disabled=false;button.textContent='Try again';
          if(status)status.textContent=error.message;
        }
      };
    });
    const retry=container.querySelector('[data-growth-customer-action="retry"]');
    if(retry)retry.onclick=()=>{if(typeof onRetry==='function')onRetry()};
    return Object.freeze({controller,destroy(){destroyed=true}});
  }

  function buildGrowthRedeemUrl(token,{origin='',pathname=''}={}){
    const base=`${text(origin)}${text(pathname)}`;
    return `${base}#/growth-redeem?token=${encodeURIComponent(text(token))}`;
  }

  return Object.freeze({
    bindDeliveryStatus,
    bindCustomerOffers,
    bindOwnerControls,
    bindRecommendationRefresh,
    buildGrowthRedeemUrl,
    classifyError,
    createCustomerController,
    createDeliveryController,
    createOwnerController,
    createRecommendationRefreshController,
    money,
    normalizeActiveExecution,
    normalizeCustomerOffers,
    normalizeDeliveryStatus,
    normalizeOwnerAction,
    normalizePreview,
    renderCustomerOffers,
    renderActiveExecution,
    renderDeliveryStatus,
    renderOwnerAction,
    renderRecommendationRefresh,
    validateApproval
  });
});

(function attachNestlyMediaSyncV95(root){
  const BUCKET='business-public';
  const message=error=>String(error?.message||error?.error||error||'Unknown storage error').slice(0,1000);

  async function queueCleanup({client,businessId,objectPath,reason,removeError}){
    const queued=await client.rpc('business_queue_media_cleanup_v95',{
      p_business:businessId,p_object_path:objectPath,p_reason:reason
    });
    if(queued.error)return {
      status:'cleanup_untracked',remove_error:message(removeError),
      queue_error:message(queued.error)
    };
    return {
      status:queued.data?.status==='completed'?'removed':'pending_cleanup',
      cleanup_id:queued.data?.id||null,remove_error:message(removeError)
    };
  }

  async function removeOrQueue({storage,client,businessId,objectPath,reason}){
    if(!objectPath)return {status:'not_required'};
    const removed=await storage.from(BUCKET).remove([objectPath]);
    if(!removed.error)return {status:'removed'};
    return queueCleanup({
      client,businessId,objectPath,reason,removeError:removed.error
    });
  }

  async function publish({storage,client,businessId,objectPath,file,publishArgs}){
    const uploaded=await storage.from(BUCKET).upload(
      objectPath,file,{contentType:file.type,upsert:false}
    );
    if(uploaded.error)return {
      ok:false,stage:'upload',error:uploaded.error,cleanup:{status:'not_required'}
    };
    const published=await client.rpc(
      'business_publish_media_replacement_v95',publishArgs
    );
    if(published.error){
      const cleanup=await removeOrQueue({
        storage,client,businessId,objectPath,
        reason:'uploaded object after atomic media publication failed'
      });
      return {ok:false,stage:'publish',error:published.error,cleanup};
    }
    const cleanup=await removeOrQueue({
      storage,client,businessId,
      objectPath:published.data?.previous_object_path||null,
      reason:'superseded customer media object'
    });
    return {ok:true,asset:published.data,cleanup};
  }

  async function retryPending({storage,client,businessId,limit=10}){
    const listed=await client.rpc('business_list_media_cleanup_queue_v95',{
      p_business:businessId,p_limit:limit
    });
    if(listed.error)return {ok:false,stage:'list',error:listed.error,outcomes:[]};
    const outcomes=[];
    for(const item of listed.data?.pending||[]){
      const removed=await storage.from(BUCKET).remove([item.object_path]);
      const succeeded=!removed.error;
      const marked=await client.rpc('business_mark_media_cleanup_result_v95',{
        p_business:businessId,p_cleanup:item.id,p_succeeded:succeeded,
        p_error:succeeded?null:message(removed.error)
      });
      outcomes.push({
        id:item.id,object_path:item.object_path,
        status:marked.error?'result_unconfirmed':(
          succeeded?'completed':'pending_cleanup'
        ),
        remove_error:removed.error?message(removed.error):null,
        mark_error:marked.error?message(marked.error):null
      });
    }
    return {
      ok:outcomes.every(item=>item.status==='completed'),
      stage:'retry',outcomes
    };
  }

  root.NestlyMediaSyncV95=Object.freeze({
    publish,removeOrQueue,retryPending
  });
})(typeof globalThis==='undefined'?window:globalThis);

import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source=readFileSync(
  new URL('../../app/v95-media-sync.js',import.meta.url),'utf8'
);

function loadApi(){
  const context={};
  vm.runInNewContext(source,context,{filename:'v95-media-sync.js'});
  return context.NestlyMediaSyncV95;
}

function storageMock({uploadError=null,removeResults=[]}={}){
  const calls=[];
  return {
    calls,
    from(bucket){
      assert.equal(bucket,'business-public');
      return {
        async upload(path,file,options){
          calls.push({operation:'upload',path,file,options});
          return {error:uploadError};
        },
        async remove(paths){
          calls.push({operation:'remove',paths});
          return removeResults.shift()||{error:null};
        }
      };
    }
  };
}

test('failed atomic publication never reports success and durably queues a failed upload cleanup',async()=>{
  const api=loadApi();
  const storage=storageMock({
    removeResults:[{error:{message:'Storage delete unavailable'}}]
  });
  const rpcCalls=[];
  const client={rpc:async(name,args)=>{
    rpcCalls.push({name,args});
    if(name==='business_publish_media_replacement_v95'){
      return {data:null,error:{message:'brand_version_conflict'}};
    }
    if(name==='business_queue_media_cleanup_v95'){
      return {data:{id:'cleanup-1',status:'pending'},error:null};
    }
    throw new Error(`unexpected RPC ${name}`);
  }};
  const result=await api.publish({
    storage,client,businessId:'business-1',
    objectPath:'business-1/logo/new.png',
    file:{type:'image/png'},publishArgs:{p_business:'business-1'}
  });

  assert.equal(result.ok,false);
  assert.equal(result.stage,'publish');
  assert.equal(result.cleanup.status,'pending_cleanup');
  assert.deepEqual(
    rpcCalls.map(call=>call.name),
    ['business_publish_media_replacement_v95','business_queue_media_cleanup_v95']
  );
  assert.equal(storage.calls.filter(call=>call.operation==='remove').length,1);
});

test('successful atomic replacement stays published while failed old-object cleanup is truthfully pending',async()=>{
  const api=loadApi();
  const storage=storageMock({
    removeResults:[{error:{message:'temporary delete failure'}}]
  });
  const client={rpc:async(name)=>{
    if(name==='business_publish_media_replacement_v95')return {
      data:{id:'asset-1',previous_object_path:'business-1/logo/old.png'},
      error:null
    };
    if(name==='business_queue_media_cleanup_v95')return {
      data:{id:'cleanup-2',status:'pending'},error:null
    };
    throw new Error(`unexpected RPC ${name}`);
  }};
  const result=await api.publish({
    storage,client,businessId:'business-1',
    objectPath:'business-1/logo/new.png',
    file:{type:'image/png'},publishArgs:{p_business:'business-1'}
  });

  assert.equal(result.ok,true);
  assert.equal(result.asset.id,'asset-1');
  assert.equal(result.cleanup.status,'pending_cleanup');
});

test('cleanup retry records failures, then confirms completion only after Storage succeeds',async()=>{
  const api=loadApi();
  const pending={id:'cleanup-3',object_path:'business-1/logo/old.png'};
  let storageFails=true;
  const storage={
    from(){
      return {
        async remove(){
          return storageFails
            ?{error:{message:'still unavailable'}}
            :{error:null};
        }
      };
    }
  };
  const marks=[];
  const client={rpc:async(name,args)=>{
    if(name==='business_list_media_cleanup_queue_v95')return {
      data:{pending:[pending]},error:null
    };
    if(name==='business_mark_media_cleanup_result_v95'){
      marks.push(args);return {data:{status:args.p_succeeded?'completed':'pending'},error:null};
    }
    throw new Error(`unexpected RPC ${name}`);
  }};

  const failed=await api.retryPending({storage,client,businessId:'business-1'});
  assert.equal(failed.ok,false);
  assert.equal(failed.outcomes[0].status,'pending_cleanup');
  assert.equal(marks[0].p_succeeded,false);
  assert.equal(marks[0].p_error,'still unavailable');

  storageFails=false;
  const completed=await api.retryPending({storage,client,businessId:'business-1'});
  assert.equal(completed.ok,true);
  assert.equal(completed.outcomes[0].status,'completed');
  assert.equal(marks[1].p_succeeded,true);
  assert.equal(marks[1].p_error,null);
});

test('cleanup scheduling failure is surfaced as untracked and never silently treated as removed',async()=>{
  const api=loadApi();
  const storage=storageMock({
    removeResults:[{error:{message:'delete failed'}}]
  });
  const result=await api.removeOrQueue({
    storage,businessId:'business-1',
    objectPath:'business-1/logo/orphan.png',reason:'publish failed',
    client:{rpc:async()=>({data:null,error:{message:'queue unavailable'}})}
  });
  assert.equal(result.status,'cleanup_untracked');
  assert.equal(result.remove_error,'delete failed');
  assert.equal(result.queue_error,'queue unavailable');
});

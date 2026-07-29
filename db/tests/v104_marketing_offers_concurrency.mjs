#!/usr/bin/env node

import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {spawn} from 'node:child_process';

const databaseUrl=process.env.NESTLY_TEST_DATABASE_URL
  ??'postgresql://postgres:postgres@127.0.0.1:54322/postgres';

const runPsql=(sql,{allowFailure=false}={})=>new Promise((resolve,reject)=>{
  const child=spawn(
    'psql',
    [databaseUrl,'-X','-v','ON_ERROR_STOP=1','-Atq'],
    {stdio:['pipe','pipe','pipe']}
  );
  let stdout='';
  let stderr='';
  child.stdout.on('data',chunk=>{stdout+=chunk;});
  child.stderr.on('data',chunk=>{stderr+=chunk;});
  child.on('error',reject);
  child.on('close',code=>{
    const result={code,stdout,stderr};
    if(code!==0&&!allowFailure){
      reject(new Error(`psql failed (${code})\n${stderr}\n${stdout}`));
      return;
    }
    resolve(result);
  });
  child.stdin.end(sql);
});

const businessId=randomUUID();
const ownerId=randomUUID();
const superId=randomUUID();
const branchId=randomUUID();
const firstDraftId=randomUUID();
const secondDraftId=randomUUID();
const firstAttemptId=randomUUID();
const secondAttemptId=randomUUID();
const firstPath=`${businessId}/offer/${randomUUID()}.png`;
const secondPath=`${businessId}/offer/${randomUUID()}.png`;
const seededOffers=Array.from({length:9},()=>({
  id:randomUUID(),
  path:`${businessId}/offer/${randomUUID()}.png`
}));

const jwtSql=userId=>`
select set_config('request.jwt.claim.sub','${userId}',true);
select set_config(
  'request.jwt.claims',
  json_build_object('sub','${userId}','role','authenticated')::text,
  true
);
set local role authenticated;
`;

const finalizeSql=({promotionId,attemptId,path,name})=>`
begin;
${jwtSql(ownerId)}
select public.business_finalize_promotion_v104(
  '${businessId}'::uuid,
  '${promotionId}'::uuid,
  null,
  '${name}',
  '30% off this month',
  'Book a selected signature treatment and enjoy thirty percent off.',
  'One redemption per customer while appointments remain.',
  now()-interval '1 minute',
  now()+interval '30 days',
  10,
  'book',
  'Book now',
  '30% off selected signature treatments',
  'Launch',
  true,
  '${path}',
  'image/png',
  1200,
  800,
  '${name} promotion',
  1,
  1,
  0,
  '${attemptId}'::uuid
);
commit;
`;

const seededContentValues=seededOffers.map(({id},index)=>`
  (
    '${id}'::uuid,'${businessId}'::uuid,'offer',null,true,${index+1},
    now()-interval '1 day',now()+interval '30 days',
    jsonb_build_object(
      'schema','nestly.promotion.v104',
      'cta',jsonb_build_object('kind','book','label','Book now'),
      'offer_facts','Seeded offer ${index+1}',
      'published_once_at',to_jsonb(now())
    ),
    '${ownerId}'::uuid
  )`).join(',\n');
const seededCopyValues=seededOffers.map(({id},index)=>`
  (
    '${businessId}'::uuid,'offer','${id}'::uuid,'en',
    'Seeded offer ${index+1}','Launch special',
    'A seeded promotion used only by the v104 concurrency acceptance.',
    'Testing only.','${ownerId}'::uuid
  )`).join(',\n');
const seededStorageValues=[
  ...seededOffers.map(({path})=>path),
  firstPath,
  secondPath
].map(path=>`
  (
    'business-public','${path}',
    '{"mimetype":"image/png","size":"4096"}'::jsonb
  )`).join(',\n');
const seededMediaValues=seededOffers.map(({id,path},index)=>`
  (
    '${businessId}'::uuid,'offer','${id}'::uuid,null,
    '${path}','image/png',1200,800,'Seeded offer ${index+1}',true,
    '${ownerId}'::uuid
  )`).join(',\n');
const draftContentValues=[firstDraftId,secondDraftId].map((id,index)=>`
  (
    '${id}'::uuid,'${businessId}'::uuid,'offer',null,false,${20+index},
    now()-interval '1 minute',now()+interval '30 days',
    jsonb_build_object(
      'schema','nestly.promotion.v104',
      'cta',jsonb_build_object('kind','book','label','Book now'),
      'offer_facts','Concurrent contender ${index+1}'
    ),
    '${ownerId}'::uuid
  )`).join(',\n');
const draftCopyValues=[firstDraftId,secondDraftId].map((id,index)=>`
  (
    '${businessId}'::uuid,'offer','${id}'::uuid,'en',
    'Concurrent contender ${index+1}','30% off this month',
    'Book a selected signature treatment and enjoy thirty percent off.',
    'One redemption per customer while appointments remain.',
    '${ownerId}'::uuid
  )`).join(',\n');

const setupSql=`
begin;
select set_config('app.v79_system_transition','on',true);
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,
  email_confirmed_at,created_at,updated_at
) values
  (
    '00000000-0000-0000-0000-000000000000',
    '${superId}'::uuid,'authenticated','authenticated',
    'v104-concurrency-super-${superId.slice(0,8)}@example.test',
    '',now(),now(),now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '${ownerId}'::uuid,'authenticated','authenticated',
    'v104-concurrency-owner-${ownerId.slice(0,8)}@example.test',
    '',now(),now(),now()
  );
insert into public.super_admins(user_id,email,note) values(
  '${superId}'::uuid,
  'v104-concurrency-super-${superId.slice(0,8)}@example.test',
  'v104 true two-session quota race'
);
insert into public.businesses(
  id,name,slug,industry,join_enabled,enabled_modules
) values(
  '${businessId}'::uuid,
  'V104 Quota Race',
  'v104-quota-race-${businessId.slice(0,8)}',
  'facial',
  true,
  array['dashboard','clients','sales','loyalty','retention']
);
insert into public.staff(
  business_id,user_id,role,full_name,active
) values(
  '${businessId}'::uuid,'${ownerId}'::uuid,'owner',
  'V104 Quota Owner',true
);
insert into public.branches(
  id,business_id,name,is_default,active
) values(
  '${branchId}'::uuid,'${businessId}'::uuid,'Main',true,true
);
select set_config('app.v79_system_transition','',true);

update app.platform_feature_flags
set enabled=true,changed_at=now()
where feature_key in(
  'customer_identity','customer_claims','customer_wallet'
);
${jwtSql(superId)}
select public.platform_decide_business_approval_v94(
  '${businessId}'::uuid,'approved',
  'v104 true two-session quota race',
  1
);
reset role;

insert into public.business_promotion_entitlements_v104(
  business_id,max_published_offers,complimentary_until,updated_by
) values(
  '${businessId}'::uuid,10,now()+interval '30 days','${superId}'::uuid
);

select set_config('app.v104_promotion_write','on',true);
select set_config('app.v104_promotion_copy_write','on',true);
select set_config('app.v104_promotion_media_write','on',true);
insert into public.business_customer_content_v95(
  id,business_id,content_type,branch_id,active,display_order,
  starts_at,ends_at,metadata,updated_by
) values
${seededContentValues},
${draftContentValues};
insert into public.business_localized_copy_v95(
  business_id,entity_type,entity_id,locale,name,tagline,description,terms,
  updated_by
) values
${seededCopyValues},
${draftCopyValues};
insert into storage.objects(bucket_id,name,metadata) values
${seededStorageValues};
insert into public.business_media_assets_v95(
  business_id,asset_kind,entity_id,branch_id,object_path,mime_type,
  width_px,height_px,alt_en,customer_visible,updated_by
) values
${seededMediaValues};
select set_config('app.v104_promotion_media_write','',true);
select set_config('app.v104_promotion_copy_write','',true);
select set_config('app.v104_promotion_write','',true);
commit;
`;

const cleanupSql=`
begin;
delete from public.businesses where id='${businessId}'::uuid;
delete from public.super_admins where user_id='${superId}'::uuid;
delete from auth.users where id in(
  '${ownerId}'::uuid,'${superId}'::uuid
);
commit;
`;

try{
  await runPsql(setupSql);

  const coordinator=runPsql(`
    begin;
    select app.v104_lock_promotion_business('${businessId}'::uuid);
    select pg_sleep(2);
    commit;
  `);
  await new Promise(resolve=>setTimeout(resolve,250));

  const contenders=await Promise.all([
    runPsql(finalizeSql({
      promotionId:firstDraftId,
      attemptId:firstAttemptId,
      path:firstPath,
      name:'Concurrent contender one'
    }),{allowFailure:true}),
    runPsql(finalizeSql({
      promotionId:secondDraftId,
      attemptId:secondAttemptId,
      path:secondPath,
      name:'Concurrent contender two'
    }),{allowFailure:true})
  ]);
  await coordinator;

  const winners=contenders.filter(result=>result.code===0);
  const losers=contenders.filter(result=>result.code!==0);
  assert.equal(winners.length,1,'exactly one competing publication must win');
  assert.equal(losers.length,1,'exactly one competing publication must lose');
  assert.match(
    losers[0].stderr,
    /promotion_publish_limit_reached/,
    'the losing transaction must fail at the immutable launch quota'
  );

  const verification=await runPsql(`
    select jsonb_build_object(
      'quota_limit',entitlement.max_published_offers,
      'quota_used',(
        select count(*) from public.business_customer_content_v95 content
        where content.business_id='${businessId}'::uuid
          and content.content_type='offer'
          and content.metadata->>'schema'='nestly.promotion.v104'
          and content.metadata ? 'published_once_at'
      ),
      'active_count',(
        select count(*) from public.business_customer_content_v95 content
        where content.business_id='${businessId}'::uuid
          and content.content_type='offer'
          and content.active
          and content.metadata ? 'published_once_at'
      ),
      'contender_active_count',(
        select count(*) from public.business_customer_content_v95 content
        where content.id in(
          '${firstDraftId}'::uuid,'${secondDraftId}'::uuid
        ) and content.active
      ),
      'contender_receipt_count',(
        select count(*)
        from public.business_promotion_attempt_receipts_v104 receipt
        where receipt.business_id='${businessId}'::uuid
          and receipt.attempt_key in(
            '${firstAttemptId}'::uuid,'${secondAttemptId}'::uuid
          )
      )
    )
    from public.business_promotion_entitlements_v104 entitlement
    where entitlement.business_id='${businessId}'::uuid;
  `);
  const result=JSON.parse(verification.stdout.trim());
  assert.deepEqual(result,{
    quota_limit:10,
    quota_used:10,
    active_count:10,
    contender_active_count:1,
    contender_receipt_count:1
  });
  process.stdout.write(
    `v104 concurrency acceptance passed: ${JSON.stringify(result)}\n`
  );
}finally{
  await runPsql(cleanupSql,{allowFailure:true});
}

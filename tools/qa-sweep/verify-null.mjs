/* For each candidate RPC, find its newest SQL definition and judge whether it can return NULL. */
import {readFile,readdir} from 'node:fs/promises';
const dir='/home/user/loyalty/supabase/migrations';
const files=(await readdir(dir)).filter(f=>f.endsWith('.sql')).sort();
const bodies=new Map();
for(const f of files){
  const sql=await readFile(`${dir}/${f}`,'utf8');
  const re=/create or replace function (?:public|app)\.([a-z_0-9]+)\s*\(([\s\S]*?)\)\s*\n?\s*returns\s+([a-z_ ]+)[\s\S]*?\n\$\$;/gi;
  let m;
  while((m=re.exec(sql))){ bodies.set(m[1],{ret:m[3].trim().toLowerCase(),body:m[0],file:f}); }
}
const cands=['decide_change','import_bookings','staff_create_client','issue_gift_card_at_branch_v117',
 'get_notifications','get_workspace_locale_preference_v97','create_loyalty_config_draft',
 'generate_retention_recommendation','create_retention_campaign','stage_import_rows','commit_import_job',
 'create_invite','validate_program_rule','lookup_client_by_phone','record_sale_by_phone',
 'reserve_checkout_sv_tender','get_pos_paynow_attempt_v142'];
const verdict=[];
for(const name of cands){
  const d=bodies.get(name);
  if(!d){ verdict.push([name,'NO SQL FOUND','—']); continue; }
  const b=d.body;
  const setof=/^(setof|table)/.test(d.ret);
  const isVoid=/^void/.test(d.ret);
  const bareReturn=/\n\s*return\s*;/.test(b);
  // a `return v;` where v is only ever assigned via select..into can be null
  const selectInto=/select[\s\S]{0,400}?\binto\s+(strict\s+)?v_result/i.test(b)&&/return\s+v_result\s*;/.test(b);
  let v;
  if(isVoid) v='CAN BE NULL (returns void)';
  else if(setof) v='safe (setof/table -> [] not null)';
  else if(bareReturn) v='CAN BE NULL (bare `return;`)';
  else if(selectInto) v='CAN BE NULL (select..into may not match)';
  else v='safe (all paths build a value)';
  verdict.push([name,v,d.ret]);
}
const w=Math.max(...verdict.map(v=>v[0].length));
verdict.forEach(([n,v,r])=>console.log(`${n.padEnd(w)}  ${r.padEnd(10)}  ${v}`));

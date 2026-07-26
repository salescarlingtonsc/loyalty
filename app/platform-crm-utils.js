(function platformCrmUtilsFactory(globalObject){
  'use strict';

  const importFields=Object.freeze([
    ['','Ignore'],
    ['company_name','Company name'],
    ['registration_number','UEN / registration number'],
    ['contact_name','Contact name'],
    ['job_title','Contact job title'],
    ['phone','Contact phone'],
    ['email','Contact email'],
    ['address','Registered address'],
    ['postal_code','Postal code'],
    ['directory_code','Directory code'],
    ['rating','Public rating'],
    ['review_count','Public review count'],
    ['region','Region'],
    ['website','Website'],
    ['industry','Industry'],
    ['employee_count','Employee count'],
    ['notes','Notes'],
    ['stage','Pipeline stage'],
  ].map(([key,label])=>Object.freeze({key,label})));

  const synonymGroups=Object.freeze({
    company_name:['company name','company','firm','legal name','registered name','trading name','brand name','brand'],
    registration_number:['uen','registration number','entity number','registration no','uen number'],
    contact_name:['contact name','contact person','primary contact','name of contact'],
    job_title:['job title','designation','position','contact title'],
    phone:['phone','mobile','contact number','tel','telephone','mobile number'],
    email:['email','email address','contact email','e-mail'],
    address:['address','registered address','company address'],
    postal_code:['postal code','postal','zip','zip code'],
    directory_code:['directory code','listing code'],
    rating:['rating','star rating','stars'],
    review_count:['reviews','review count','number of reviews'],
    region:['region','area','zone','territory'],
    website:['website','web site','url','domain'],
    industry:['industry','sector','business type'],
    employee_count:['employee count','headcount','team size','employees'],
    notes:['notes','remarks','comment','comments'],
    stage:['stage','status','pipeline stage']
  });

  const headerSynonyms=Object.freeze(Object.fromEntries(
    Object.entries(synonymGroups).flatMap(([field,labels])=>
      labels.map(label=>[normaliseHeader(label),field])
    )
  ));

  function normaliseHeader(value){
    return String(value||'').trim().toLowerCase()
      .replace(/&/g,' and ').replace(/[^a-z0-9]+/g,' ').trim();
  }

  function customFieldKey(header){
    let slug=normaliseHeader(header).replace(/\s+/g,'_');
    if(slug&&!/^[a-z]/.test(slug))slug=`field_${slug}`;
    slug=slug.slice(0,63);
    return `custom:${slug||'column'}`;
  }

  function delimiterCounts(text){
    const counts={',':0,'\t':0,';':0};
    let quoted=false;
    for(let index=0;index<text.length;index+=1){
      const character=text[index];
      if(character==='"'){
        if(quoted&&text[index+1]==='"'){index+=1;continue}
        quoted=!quoted;continue;
      }
      if(!quoted&&character==='\n')break;
      if(!quoted&&Object.hasOwn(counts,character))counts[character]+=1;
    }
    return counts;
  }

  function detectDelimiter(text){
    const counts=delimiterCounts(String(text||''));
    return Object.entries(counts).sort((a,b)=>b[1]-a[1])[0]?.[0]||',';
  }

  function parseDelimited(text,delimiter=detectDelimiter(text)){
    const source=String(text||'').replace(/^\uFEFF/,'');
    const matrix=[];let row=[],field='',quoted=false;
    for(let index=0;index<source.length;index+=1){
      const character=source[index];
      if(character==='"'){
        if(quoted&&source[index+1]==='"'){field+='"';index+=1}
        else quoted=!quoted;
        continue;
      }
      if(!quoted&&character===delimiter){row.push(field);field='';continue}
      if(!quoted&&(character==='\n'||character==='\r')){
        if(character==='\r'&&source[index+1]==='\n')index+=1;
        row.push(field);field='';
        if(row.some(value=>String(value).trim()))matrix.push(row);
        row=[];continue;
      }
      field+=character;
    }
    if(quoted)throw new Error('The import contains an unclosed quoted value.');
    row.push(field);
    if(row.some(value=>String(value).trim()))matrix.push(row);
    if(matrix.length<2)return{delimiter,headers:matrix[0]||[],rows:[]};
    const headers=matrix[0].map((value,index)=>String(value||'').trim()||`Column ${index+1}`);
    const rows=matrix.slice(1).map((values,rowIndex)=>({
      row_number:rowIndex+2,
      values:Object.fromEntries(headers.map((header,index)=>[header,String(values[index]??'').trim()]))
    }));
    return{delimiter,headers,rows};
  }

  function suggestMapping(headers){
    const used=new Set();
    return Object.fromEntries(headers.map(header=>{
      const suggested=headerSynonyms[normaliseHeader(header)]||customFieldKey(header);
      if(suggested&&!suggested.startsWith('custom:')&&used.has(suggested))return[header,customFieldKey(header)];
      if(suggested)used.add(suggested);
      return[header,suggested];
    }));
  }

  function mappingConflicts(mapping){
    const destinations=new Map();
    Object.entries(mapping||{}).forEach(([header,destination])=>{
      if(!destination||String(destination).startsWith('custom:'))return;
      const headers=destinations.get(destination)||[];
      headers.push(header);destinations.set(destination,headers);
    });
    return [...destinations.entries()]
      .filter(([,headers])=>headers.length>1)
      .map(([destination,headers])=>({destination,headers}));
  }

  function splitPhones(value){
    return String(value||'').split(/\s*(?:\/|;|\||,\s*(?=\+|\d{7,}))\s*/)
      .map(item=>item.trim()).filter(Boolean);
  }

  function normalisePhone(value){
    const first=splitPhones(value)[0]||'';
    const plus=first.trim().startsWith('+');
    const digits=first.replace(/\D/g,'');
    return digits?`${plus?'+':''}${digits}`:'';
  }

  function domainFromWebsite(value){
    const input=String(value||'').trim();
    if(!input)return'';
    try{return new URL(/^https?:\/\//i.test(input)?input:`https://${input}`).hostname.toLowerCase().replace(/^www\./,'')}
    catch{return''}
  }

  function emailDomain(value){
    return String(value||'').trim().toLowerCase().split('@')[1]||'';
  }

  function mapImportRows(sourceRows,mapping){
    const conflicts=mappingConflicts(mapping);
    if(conflicts.length)throw new Error('Two source columns cannot map to the same single-value field.');
    return sourceRows.map(sourceRow=>{
      const mapped={source_row_number:sourceRow.row_number,source_values:{...sourceRow.values},custom_fields:{}};
      Object.entries(sourceRow.values).forEach(([header,value])=>{
        const destination=mapping[header];
        if(!destination)return;
        if(destination.startsWith('custom:')){
          mapped.custom_fields[destination.slice('custom:'.length)]=value;
        }else{
          mapped[destination]=value;
        }
      });
      mapped.phone_original=mapped.phone||null;
      if(mapped.phone)mapped.phone=normalisePhone(mapped.phone);
      if(mapped.email)mapped.email=String(mapped.email).trim().toLowerCase();
      if(mapped.website)mapped.normalised_domain=domainFromWebsite(mapped.website);
      if(mapped.registration_number)mapped.registration_number=String(mapped.registration_number).trim().toUpperCase();
      return mapped;
    });
  }

  function validateImportRow(row){
    const errors=[],warnings=[];
    if(!row.company_name&&!row.registration_number)errors.push('Company name or registration number is required.');
    if(row.email&&!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(row.email))errors.push('Contact email is not valid.');
    const phoneDigits=String(row.phone||'').replace(/\D/g,'');
    if(row.phone&&(phoneDigits.length<8||phoneDigits.length>15))errors.push('Contact phone must contain 8 to 15 digits.');
    if(row.registration_number&&!/^[A-Z0-9-]{8,18}$/.test(row.registration_number))warnings.push('Review the registration number format.');
    if(row.postal_code&&!/^[A-Z0-9 -]{3,12}$/i.test(row.postal_code))errors.push('Postal code is not valid.');
    if(row.rating&&(Number(row.rating)<0||Number(row.rating)>5))errors.push('Rating must be between 0 and 5.');
    if(row.review_count&&(Number(row.review_count)<0||!Number.isInteger(Number(row.review_count))))errors.push('Review count must be a whole non-negative number.');
    if(!row.email&&!row.phone)warnings.push('No contact email or phone is mapped.');
    return{errors,warnings};
  }

  function rowIdentityKeys(row){
    const keys=[];
    if(row.registration_number)keys.push(`registration:${String(row.registration_number).toUpperCase()}`);
    const domain=row.normalised_domain||domainFromWebsite(row.website)||emailDomain(row.email);
    if(domain)keys.push(`domain:${domain}`);
    if(row.email)keys.push(`email:${String(row.email).toLowerCase()}`);
    if(row.phone)keys.push(`phone:${normalisePhone(row.phone)}`);
    const company=normaliseHeader(row.company_name);
    if(company)keys.push(`company:${company}:${normaliseHeader(row.postal_code)}`);
    return keys;
  }

  function analyseImportRows(rows){
    const seen=new Map();
    return rows.map(row=>{
      const validation=validateImportRow(row),duplicateRows=new Set();
      rowIdentityKeys(row).forEach(key=>{
        if(seen.has(key))duplicateRows.add(seen.get(key));
        else seen.set(key,row.source_row_number);
      });
      if(duplicateRows.size)validation.errors.push(`Possible duplicate of source row ${[...duplicateRows].join(', ')}.`);
      return{...row,...validation,status:validation.errors.length?'invalid':validation.warnings.length?'review':'ready'};
    });
  }

  function importSummary(rows){
    return rows.reduce((summary,row)=>{
      summary.total+=1;summary[row.status]=(summary[row.status]||0)+1;return summary;
    },{total:0,ready:0,review:0,invalid:0});
  }

  globalObject.NestlyPlatformCRMUtils=Object.freeze({
    importFields,headerSynonyms,normaliseHeader,customFieldKey,detectDelimiter,parseDelimited,
    suggestMapping,mappingConflicts,splitPhones,normalisePhone,domainFromWebsite,mapImportRows,
    validateImportRow,analyseImportRows,importSummary
  });
})(typeof window!=='undefined'?window:globalThis);

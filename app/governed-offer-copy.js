(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.NestlyGovernedOfferCopy=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';

  const CONTRACT_VERSION='governed_offer_copy_v1';
  const text=value=>String(value??'').trim();
  const finite=value=>{
    if(value===null||value===undefined||value==='')return null;
    const number=Number(value);
    return Number.isFinite(number)?number:null;
  };

  function money(cents,currency=''){
    const amount=finite(cents);
    const currencyCode=text(currency).toUpperCase();
    if(amount===null||amount<0)throw new TypeError('A locked non-negative offer value is required.');
    if(!currencyCode)throw new TypeError('A locked offer currency is required.');
    return `${currencyCode} ${(amount/100).toLocaleString('en-SG',{
      minimumFractionDigits:2,maximumFractionDigits:2
    })}`;
  }

  function shortDate(value){
    const date=new Date(value);
    if(Number.isNaN(date.getTime()))throw new TypeError('A locked offer expiry is required.');
    return new Intl.DateTimeFormat('en-SG',{
      day:'numeric',month:'short',year:'numeric',timeZone:'Asia/Singapore'
    }).format(date);
  }

  function safeContext(value){
    const source=text(value).normalize('NFKC').replace(/[\u0000-\u001f\u007f]/g,' ');
    if(!source)return '';
    // Prices, percentages, dates, links and instruction-like content are never
    // copied. Those facts come only from the server-authoritative contract.
    if(/[0-9]|[%$]|(?:https?:\/\/|www\.)|(?:ignore|system|prompt|instruction|override|jailbreak)/i.test(source)){
      return '';
    }
    return source.replace(/[<>`{}[\]\\]/g,' ').replace(/\s+/g,' ').slice(0,44).replace(/[.!?]+$/,'');
  }

  function improve({
    context='',offerValueCents,currency='',expiresAt,
    ctaLabel='Redeem now'
  }={}){
    const value=money(offerValueCents,currency);
    const expiry=shortDate(expiresAt);
    const safe=safeContext(context);
    const lead=safe?`${safe}. `:'We would love to welcome you back. ';
    const message=`${lead}Enjoy ${value} in welcome-back credit. Redeem in Peekaa by ${expiry}.`;
    const copy=message.length<=120
      ?message
      :`Enjoy ${value} in welcome-back credit. Redeem in Peekaa by ${expiry}.`;
    return Object.freeze({
      contractVersion:CONTRACT_VERSION,
      message:copy,
      ctaLabel:text(ctaLabel)||'Redeem now',
      lockedFacts:Object.freeze({
        offerValueCents:finite(offerValueCents),
        currency:text(currency).toUpperCase(),
        expiresAt
      }),
      contextUsed:message.length<=120&&!!safe
    });
  }

  return Object.freeze({CONTRACT_VERSION,improve,money,safeContext,shortDate});
});

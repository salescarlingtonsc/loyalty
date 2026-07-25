/* ============ Frenly Grow Program Recommender ============
   Deterministic, hand-verifiable heuristics that turn a firm's OWN catalogue prices into a
   suggested loyalty / membership / gift-card shape. There is NO model, NO network call, NO
   randomness and NO clock in this file: the same inputs always produce the same output, and
   every number carries a plain-English `reasoning` trail so an owner can check it by hand.

   House rules this file exists to honour:
   - Firms set their own figures. Nothing here blocks, caps or enforces anything; the UI only
     ever PREFILLS editable fields, and the owner still saves/publishes through the normal flow.
   - Retention-lift figures are labelled RANGES with a disclaimer, never predictions.
   - All money is integer cents. Percentages are plain numbers ("5" means 5%).

   Loads both as a browser script (sets window.FrenlyGrowRec) and under Node for unit tests.
*/
(function growRecommenderFactory(){
  'use strict';

  /* ---------- internal helpers (pure) ---------- */
  const isNum=value=>typeof value==='number'&&Number.isFinite(value);
  const isNonNegative=value=>isNum(value)&&value>=0;
  const isPositive=value=>isNum(value)&&value>0;
  const asObject=value=>(value&&typeof value==='object')?value:{};
  /* Contract helper: roundToNearest(x,n) = Math.round(x/n)*n */
  const roundToNearest=(x,n)=>Math.round(x/n)*n;
  const round2=value=>Math.round(value*100)/100;
  const clamp=(value,low,high)=>Math.min(Math.max(value,low),high);
  /* Reasoning strings are read by shop owners, so they speak dollars, not cents. */
  const dollars=cents=>'$'+(cents/100).toFixed(2);
  const percent=value=>value.toFixed(2)+'%';

  /* ---------- tuning constants (single source of truth for the reasoning text) ---------- */
  const EARN_POINTS_PER_DOLLAR=10;
  const REWARD_CREDIT_STEP_CENTS=100;
  const MIN_REWARD_CREDIT_CENTS=200;
  const MAX_REWARD_CREDIT_CENTS=2000;
  const REDEEM_POINTS_STEP=50;
  const MEMBERSHIP_TICKET_MULTIPLE=2.5;
  const MEMBERSHIP_PRICE_STEP_CENTS=500;
  const MIN_MEMBERSHIP_PRICE_CENTS=1000;
  const GIFT_CARD_MULTIPLES=[1,2,4];
  const GIFT_CARD_STEP_CENTS=500;
  const MIN_GIFT_CARD_CENTS=500;
  const RETENTION_LIFT_BANDS={
    points:{lowPct:5,highPct:15},
    membership:{lowPct:10,highPct:25},
    giftcard:{lowPct:2,highPct:8},
    bringback:{lowPct:5,highPct:20}
  };
  /* Must contain the word "estimate" — this is a labelled range, never a prediction. */
  const RETENTION_LIFT_DISCLAIMER='This is an estimate, not a promise — the result depends on how well you run it.';

  /* ---------- 1. give-back percentage ----------
     Cents returned for every 100 cents spent, which IS the percentage:
       earnPointsPerDollar × rewardCreditCents ÷ redeemPoints                              */
  function givebackPct(input){
    const {earnPointsPerDollar,redeemPoints,rewardCreditCents}=asObject(input);
    if(!isNonNegative(earnPointsPerDollar))return null;
    if(!isNonNegative(redeemPoints))return null;
    if(!isNonNegative(rewardCreditCents))return null;
    if(!(redeemPoints>0))return null;
    return round2(earnPointsPerDollar*rewardCreditCents/redeemPoints);
  }

  /* ---------- 2. points program ---------- */
  function emptyPointsRecommendation(){
    return {earnPointsPerDollar:null,redeemPoints:null,rewardCreditCents:null,
      actualGivebackPct:null,costPerVisitCents:null,costPer100VisitsCents:null,reasoning:[]};
  }

  function recommendPoints(input){
    const {avgTicketCents,targetGivebackPct}=asObject(input);
    if(!isPositive(avgTicketCents)||!isPositive(targetGivebackPct))return emptyPointsRecommendation();

    const earnPointsPerDollar=EARN_POINTS_PER_DOLLAR;
    const halfTicketCents=avgTicketCents/2;
    const roundedCreditCents=roundToNearest(halfTicketCents,REWARD_CREDIT_STEP_CENTS);
    const rewardCreditCents=clamp(roundedCreditCents,MIN_REWARD_CREDIT_CENTS,MAX_REWARD_CREDIT_CENTS);
    const rawRedeemPoints=earnPointsPerDollar*rewardCreditCents/targetGivebackPct;
    const redeemPoints=Math.max(roundToNearest(rawRedeemPoints,REDEEM_POINTS_STEP),REDEEM_POINTS_STEP);
    /* Recomputed AFTER rounding, so the number shown is the number the shop actually gives. */
    const actualGivebackPct=givebackPct({earnPointsPerDollar,redeemPoints,rewardCreditCents});
    const costPerVisitCents=Math.round(avgTicketCents*actualGivebackPct/100);
    const costPer100VisitsCents=costPerVisitCents*100;

    const reasoning=[
      `Your typical sale is ${dollars(avgTicketCents)}. That is the middle price of your own services and products — no outside data.`,
      `Points stay at ${earnPointsPerDollar} points for every $1 spent, so a customer can check the maths in their head.`,
      `Reward credit starts at half a typical sale: ${dollars(avgTicketCents)} ÷ 2 = ${dollars(halfTicketCents)}, rounded to the nearest ${dollars(REWARD_CREDIT_STEP_CENTS)} → ${dollars(roundedCreditCents)}.`
    ];
    if(rewardCreditCents!==roundedCreditCents){
      reasoning.push(`Reward credit is kept between ${dollars(MIN_REWARD_CREDIT_CENTS)} and ${dollars(MAX_REWARD_CREDIT_CENTS)}, so ${dollars(roundedCreditCents)} becomes ${dollars(rewardCreditCents)}.`);
    }else{
      reasoning.push(`${dollars(rewardCreditCents)} already sits inside the ${dollars(MIN_REWARD_CREDIT_CENTS)}–${dollars(MAX_REWARD_CREDIT_CENTS)} range, so it is used as-is.`);
    }
    reasoning.push(`Points needed to redeem = ${earnPointsPerDollar} points per $1 × ${dollars(rewardCreditCents)} credit ÷ your ${percent(targetGivebackPct)} target = ${round2(rawRedeemPoints)}, rounded to the nearest ${REDEEM_POINTS_STEP} → ${redeemPoints} points.`);
    reasoning.push(`Give-back after that rounding = ${earnPointsPerDollar} × ${rewardCreditCents}¢ ÷ ${redeemPoints} points = ${percent(actualGivebackPct)}. That is ${dollars(Math.round(actualGivebackPct*100))} back for every $100 spent.`);
    reasoning.push(`Cost per visit = ${dollars(avgTicketCents)} × ${percent(actualGivebackPct)} = ${dollars(costPerVisitCents)}.`);
    reasoning.push(`Cost per 100 visits = ${dollars(costPerVisitCents)} × 100 = ${dollars(costPer100VisitsCents)}.`);

    return {earnPointsPerDollar,redeemPoints,rewardCreditCents,actualGivebackPct,
      costPerVisitCents,costPer100VisitsCents,reasoning};
  }

  /* ---------- 3. membership plan ---------- */
  function emptyMembershipRecommendation(){
    return {monthlyPriceCents:null,breakevenVisits:null,reasoning:[]};
  }

  function recommendMembership(input){
    const {avgTicketCents}=asObject(input);
    if(!isPositive(avgTicketCents))return emptyMembershipRecommendation();

    const rawPriceCents=roundToNearest(avgTicketCents*MEMBERSHIP_TICKET_MULTIPLE,MEMBERSHIP_PRICE_STEP_CENTS);
    const monthlyPriceCents=Math.max(rawPriceCents,MIN_MEMBERSHIP_PRICE_CENTS);
    const breakevenVisits=+(monthlyPriceCents/avgTicketCents).toFixed(1);

    const reasoning=[
      `Your typical sale is ${dollars(avgTicketCents)}, taken from your own prices.`,
      `Monthly price starts at ${MEMBERSHIP_TICKET_MULTIPLE} typical sales: ${dollars(avgTicketCents)} × ${MEMBERSHIP_TICKET_MULTIPLE} = ${dollars(avgTicketCents*MEMBERSHIP_TICKET_MULTIPLE)}, rounded to the nearest ${dollars(MEMBERSHIP_PRICE_STEP_CENTS)} → ${dollars(rawPriceCents)}.`,
      monthlyPriceCents!==rawPriceCents
        ? `The smallest plan we suggest is ${dollars(MIN_MEMBERSHIP_PRICE_CENTS)}, so ${dollars(rawPriceCents)} becomes ${dollars(monthlyPriceCents)}.`
        : `${dollars(monthlyPriceCents)} is already at or above the ${dollars(MIN_MEMBERSHIP_PRICE_CENTS)} floor, so it is used as-is.`,
      `A member breaks even at ${dollars(monthlyPriceCents)} ÷ ${dollars(avgTicketCents)} = ${breakevenVisits} visits a month. Below that you keep the difference; above it they are getting the better deal — which is what keeps them coming back.`
    ];

    return {monthlyPriceCents,breakevenVisits,reasoning};
  }

  /* ---------- 4. gift card denominations ---------- */
  function recommendGiftCards(input){
    const {avgTicketCents}=asObject(input);
    if(!isPositive(avgTicketCents))return {denominationsCents:[],reasoning:[]};

    const roundedCents=GIFT_CARD_MULTIPLES
      .map(multiple=>Math.max(roundToNearest(avgTicketCents*multiple,GIFT_CARD_STEP_CENTS),MIN_GIFT_CARD_CENTS));
    const denominationsCents=[...new Set(roundedCents)].sort((a,b)=>a-b);

    const reasoning=[
      `Your typical sale is ${dollars(avgTicketCents)}, taken from your own prices.`,
      `Three easy sizes: one visit, two visits, four visits — ${GIFT_CARD_MULTIPLES.map(multiple=>`${multiple}× = ${dollars(avgTicketCents*multiple)}`).join(', ')}.`,
      `Each one is rounded to the nearest ${dollars(GIFT_CARD_STEP_CENTS)} (minimum ${dollars(MIN_GIFT_CARD_CENTS)}) so the amounts are easy to say out loud → ${roundedCents.map(dollars).join(', ')}.`,
      denominationsCents.length<roundedCents.length
        ? `After rounding, some sizes matched, so the list is ${denominationsCents.map(dollars).join(', ')}.`
        : `Final suggestion: ${denominationsCents.map(dollars).join(', ')}.`
    ];

    return {denominationsCents,reasoning};
  }

  /* ---------- 5. retention lift RANGE (never a prediction) ---------- */
  function estimateRetentionLift(programType){
    const key=typeof programType==='string'?programType.trim().toLowerCase():'';
    const band=Object.prototype.hasOwnProperty.call(RETENTION_LIFT_BANDS,key)?RETENTION_LIFT_BANDS[key]:null;
    return {
      lowPct:band?band.lowPct:null,
      highPct:band?band.highPct:null,
      disclaimer:RETENTION_LIFT_DISCLAIMER
    };
  }

  /* ---------- 6. catalogue metrics ----------
     Median, not mean: one $300 package must not drag a $6 kopi shop's "typical sale" upwards. */
  function catalogMetrics(items){
    const empty={avgTicketCents:null,sampleItems:[],count:0};
    if(!Array.isArray(items))return empty;

    const valid=items
      .filter(item=>item&&typeof item==='object'&&isNonNegative(item.price_cents))
      .map(item=>({name:String(item.name??''),price_cents:item.price_cents}));
    if(!valid.length)return empty;

    const prices=valid.map(item=>item.price_cents).sort((a,b)=>a-b);
    const middle=Math.floor(prices.length/2);
    const median=prices.length%2===1
      ? prices[middle]
      : (prices[middle-1]+prices[middle])/2;
    const sampleItems=[...valid].sort((a,b)=>b.price_cents-a.price_cents).slice(0,3)
      .map(item=>({name:item.name,price_cents:item.price_cents}));

    return {avgTicketCents:Math.round(median),sampleItems,count:valid.length};
  }

  const FrenlyGrowRec=Object.freeze({
    givebackPct,recommendPoints,recommendMembership,recommendGiftCards,estimateRetentionLift,catalogMetrics
  });

  if(typeof window!=='undefined')window.FrenlyGrowRec=FrenlyGrowRec;
  if(typeof module!=='undefined')module.exports=FrenlyGrowRec;
})();

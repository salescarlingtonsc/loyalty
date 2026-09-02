// nestly_v677 — the AI firm report's narrative is CHECKED against its evidence, not trusted.
//
// WHY THIS EXISTS. Section I of the Customer-Intelligence proof checklist (checks 82-89) asks for
// AI-safety *validation*. Before this file the entire section was prompt prose: the system prompt
// in ./index.ts tells the model "NEVER invent a number", and nothing ever read what came back.
// docs/qa/CI-PROOF-BASELINE-2026-09-01.md §6.1: "no numeric validator, no population validator, no
// causal-language blocker, no confidence ceiling, no limitation-preservation check, and no
// hallucination suite." An instruction is not a control. This file is the control.
//
// CONTRACT. One entry point:
//
//   validateNarrative(narrativeMd, evidencePack, opts) -> { ok, violations: [{rule, detail}] }
//
// Pure functions, no imports at all, so the SAME code runs in Deno (imported by index.ts as
// './validate.mjs', the pattern already used by _shared/whatsapp-send-boundaries.mjs) and in Node
// (`node --test tests/ai-reports/v677-evidence-safe-generation.test.mjs`). A validator that the
// tests exercise through a re-implementation would prove nothing; there is exactly one copy.
//
// A second, ADVISORY export — classifyCohortMentions — is documented at the bottom. It does not
// feed validateNarrative's verdict; see the honesty note there.
//
// THE EVIDENCE PACK it validates against is app.v176_evidence_pack as it stands after v179 (the
// `insights` block), v545 (loyalty.active_programme / historical_programmes, and the
// existing_customer_return_rate_pct rename), v548 (the `identification` block and
// scope:'identified_customers_only' markers), v551 (top1/top5 shares that name their denominator),
// v552 (evidence_completeness.unavailable_sections as [{section, sqlstate}]), and v713 (a new
// top-level `findings` key: `findings.ranked[]` — public.get_ci_opportunities_v1's own promoted
// candidates, each a plain object carrying its own string `evidence_class` ('ASSOCIATION' or
// 'DIRECT_FACT', never 'CAUSAL') alongside `id`/`domain`/`pattern`/`comparison`/`impact`/`action`/
// `evidence`/`confidence`/`limitation` — `findings.top_actions[]` (populated in extended mode), and
// `evidence_completeness.findings_version`). V10/V10b (below) do not key on that specific path by
// name; they walk the WHOLE pack for ANY object with its own `evidence_class`, so findings.ranked[]
// is simply the first REAL production location such an object lives — see
// tests/ai-reports/v713-findings-ranked-binding.test.mjs, which proves both rules bind against it.
//
// FAILURE MODE BY DESIGN. index.ts routes !ok to the existing status='failed' path. A false
// positive therefore costs a regenerated report, never a wrong report shown to an owner. Every
// heuristic below is tuned with that asymmetry in mind, and each one's honest limits are written
// down next to it rather than in a separate document nobody reads.

/* ------------------------------------------------------------------ rule ids */

export const RULES = {
  NUMERIC: 'V1_NUMERIC_CLAIM',
  POPULATION: 'V2_POPULATION_LABEL',
  CAUSAL: 'V3_CAUSAL_LANGUAGE',
  CONFIDENCE: 'V4_CONFIDENCE_CEILING',
  LIMITATION: 'V5_LIMITATION_PRESERVATION',
  ENTITY: 'V6_ENTITY_GROUNDING',
  STRUCTURE: 'V7_STRUCTURE',
  COHORT: 'V8_COHORT_CONTRADICTION',
  CAUSAL_BINDING: 'V10_CAUSAL_BINDING',
  // v706 (check 17, POSITIVE half): a refuter proved V10's causal-phrase BLACKLIST (above) is a
  // list that can always be evaded by one more idiom it does not yet name (27/27 ordinary causal
  // constructions - "boosts", "is behind", "so ... that", "this pushes" as a pronoun continuation,
  // a bare conditional, and more - passed V10 clean). V10b inverts the burden: for a sentence that
  // references an ASSOCIATION finding's own vocabulary, the sentence must POSITIVELY carry one of
  // a fixed, approved set of association-marker phrases (ASSOCIATION_MARKERS, below) - silence is
  // now a failure, not a pass. V10 (the blacklist) stays wired as a second line: a sentence can
  // carry a marker AND still use a blacklisted verb ("X tends to cause Y"), and V10 alone still
  // catches a causal sentence that names no ASSOCIATION finding's vocabulary at all (V10b never
  // fires without a keyword match, same abstention shape as V10 itself).
  // v707 (check 17, round 2): a SECOND refuter proved the inversion itself still had a laundering
  // gap - a sentence can carry BOTH an approved marker AND an unlisted causal construction in the
  // same breath ("we observe that weekends make customers return"), and the marker alone used to
  // satisfy V10b regardless. V10 and V10b now share ONE causal-construction list
  // (CAUSAL_CONSTRUCTIONS, below, exported once) instead of V10 keeping its own narrower one, and
  // V10b fails a referencing window that carries a marker AND a construction from that shared list,
  // not merely a window with no marker at all. The SAME refuter also proved the finding-attribution
  // step itself could false-positive: a DIRECT_FACT finding sharing two ordinary words with an
  // ASSOCIATION finding could make V10b flag a plain factual sentence. Both rules now attribute a
  // sentence to the best-scoring finding(s) on each finding's DISTINCTIVE keywords (typedFindings/
  // associationOwnersOf, below) - a DIRECT_FACT finding that ties or wins a sentence takes it away
  // from every ASSOCIATION finding, and a shared word can never manufacture that tie on its own.
  ASSOCIATION_MARKER: 'V10B_ASSOCIATION_MARKER',
};

// v684 (check 86): the three tiers app.evidence_block_v1 (nestly_v652) can ever return. Exported so
// index.ts and this file share one list instead of two string unions drifting apart.
export const CONFIDENCE_TIERS = ['insufficient', 'early_signal', 'strong_pattern'];
const CONFIDENCE_TIER_SET = new Set(CONFIDENCE_TIERS);

// v684 (check 86): where confidence_class comes from, honestly. v652's app.evidence_block_v1
// computes a capped verdict for the ONE comparative report that carries an evidence_block today
// (public.get_recovery_report_v550). The v176/v179 pack this worker sends has no comparative claim
// in it and carries no evidence_block of its own. index.ts therefore calls this with
// report.evidence, reads evidence.evidence_block.verdict IF a future pack ever adds one, and
// otherwise defaults to 'insufficient' — the strictest tier, so an absent signal can never unlock
// strong-pattern vocabulary by omission. This is the one place that line of reasoning lives; a
// future evidence_block on the v176 pack needs no other change.
export function resolveConfidenceClass(evidence) {
  const block = evidence && typeof evidence === 'object' ? evidence.evidence_block : null;
  const verdict = block && typeof block === 'object' ? block.verdict : null;
  return typeof verdict === 'string' && CONFIDENCE_TIER_SET.has(verdict) ? verdict : 'insufficient';
}

/* ------------------------------------------------- check 81: model-input assembly */

// v684 (check 81): the EXACT text sent to the model, extracted out of index.ts so a Node test can
// execute the real assembly path instead of a re-implementation. Pure string building, no
// Deno/npm imports — same file, same invariant as validateNarrative. Behaviour is byte-identical
// to the inline userPrompt()/periodLabel() this replaces in index.ts.
export function periodLabel(report) {
  const kind = report.period_kind === 'monthly'
    ? 'month'
    : report.period_kind === 'quarterly'
    ? 'quarter'
    : 'year';
  return `${kind} from ${report.period_start} to ${report.period_end}`;
}

// v705 (check 17, narrative half): findings the spine/readers already tag with their own
// evidence_class (v693/v695/v696: 'DIRECT_FACT' or 'ASSOCIATION', never 'CAUSAL' — see v696's own
// header) must be WRITTEN differently, not just felt differently. This block is the model-facing
// half of that contract; validateNarrative's V10 (checkAssociationCausalBinding, below) is the
// enforcement half, over the SAME two classes.
// v706: the ASSOCIATION bullet now also names the requirement V10b (checkAssociationPositiveMarker)
// enforces - use one of the listed observed-pattern phrases, not merely "not a cause". V10's own
// list of blocked causal words is unchanged and stays as a backstop; this bullet's new sentence is
// what closes the gap a blacklist alone cannot: it tells the model what TO write, not only what to
// avoid.
const EVIDENCE_CLASS_INSTRUCTION = [
  '',
  'Some evidence entries carry their own `evidence_class`. Respect it exactly:',
  '- "DIRECT_FACT" is this business\'s own recorded fact (its own sales, its own visits, its own',
  '  customers, its own coverage) - you may state it directly.',
  '- "ASSOCIATION" is a pattern observed across customers, staff, or segments, never a proven',
  '  cause. Phrase it as an observed pattern ("customers who X also tend to Y"), and NEVER as a',
  '  cause - not with an obvious word ("causes/drives/leads to/results in/because of/thanks to") and',
  '  not with a less obvious one either ("X boosts/fuels/triggers/prompts/spurs Y", "is why", "is',
  '  behind", "owing to", "stems from", "means that", "translates into", "accounts for", "explains",',
  '  "so X that Y", "as a consequence", "pushes", "sets up", "follows from", "is the reason",',
  '  "produces", "results from", "brings about", "if you keep X, Y will..."). Every sentence about',
  '  an ASSOCIATION finding must use one of these words: "tend to", "is associated with", "we',
  '  observe", "we see", "an observed pattern", "a pattern where", "correlate", "alongside", "in the',
  '  same period", "at the same time", "coincide", "more likely", "less likely", "more often", "less',
  '  often", "appears to", "seems to" - and using one of these words does NOT excuse a causal word',
  '  sitting in the same sentence: a sentence that both observes a pattern AND states a cause is',
  '  still wrong, because the causal half is still an invented cause.',
  '- No entry is ever "CAUSAL" - this product runs no controlled experiment, so a causal claim is',
  '  never supported here regardless of what an entry says.',
].join('\n');

export function assembleUserPrompt(report) {
  const evidence = JSON.stringify((report && report.evidence) ?? {}, null, 2);
  return [
    `Write the ${report.period_kind} business report for the ${periodLabel(report)}.`,
    '',
    'Evidence pack (the only facts you may use):',
    '```json',
    evidence,
    '```',
    EVIDENCE_CLASS_INSTRUCTION,
  ].join('\n');
}

/* ------------------------------------------------------------ pack traversal */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_DATE_RE = /^(\d{4})-(\d{2})-(\d{2})(?:[T ].*)?$/;
// Check 88 (numeric-ID coincidence): a pack key that names an identifier rather than a quantity.
// Matches "customer_id", "order_ref", "ticket_number", "invoice_no", "member_id", "ref" — "id",
// "ref" or "number" anywhere in the key, or "no" specifically at the end (anchored, so "none"/
// "normal" are not swept in by a bare substring match). Deliberately keyed on the FIELD NAME, not
// the value's shape: an id is still a fact about the pack's own record-keeping, but it is never a
// quantity a narrative should be doing arithmetic on or citing as a count.
//
// HONEST LIMIT, declared rather than hidden: "id"/"ref"/"number" are matched as bare SUBSTRINGS of
// the key, not whole words, so a key that merely CONTAINS one of them without naming an identifier
// ("identified_revenue_cents", "paid_amount", "avoid_charge") is swept into idNumbers too. That
// widens the grounding set for an ID-cued token (a false NEGATIVE for this specific check — a
// coincidental key match can still launder a fabricated id), never the other way around; it never
// takes anything OUT of the general `numbers` pool this same value is still grounded against for
// every ordinary (non-ID-cued) numeric claim.
const ID_KEY_RE = /id|ref|number|no$/i;

// Check 83 (date-derived grounding coincidence): a pack key that names a DATE, not a quantity.
// Matches a key ending in "_at"/"_date"/"_on" (generated_at, period_start... no — "period_start"
// does not end in those suffixes, which is why "period" is ALSO matched anywhere in the key, not
// just as a suffix: period_start, period_end, prior_period_start all carry it) or containing
// "period" anywhere. Deliberately keyed on the FIELD NAME, the same convention ID_KEY_RE already
// uses above — a date is a fact about WHEN the evidence was assembled or scoped, never a quantity
// a narrative should ground a percentage, ratio or currency claim against.
const DATE_KEY_RE = /(?:_at|_date|_on)$|period/i;

// Walks every leaf of the pack once. Everything the rules need is collected here so the rules
// themselves stay readable and the traversal cost is paid a single time.
function readPack(pack) {
  const numbers = new Set();      // every numeric leaf, plus |n| for negatives
  // Check 83: numbers that are date-SHAPED — a year, a month number, a day, or a numeric leaf
  // living under a *_at/*_date/*_on/period key — tracked separately from `numbers`. They stay IN
  // `numbers` too (a bare digit claim like "in 2026" or "the 15th" is still a legitimate date
  // mention this file should ground), but groundNumbers below excludes this subset specifically
  // when the CLAIM being checked is a percentage, ratio or currency figure — see its own note for
  // why: nothing in the pack's own date parts is ever "cents", and a coincidental year/month/day
  // match must not silently ground an unrelated rate claim (e.g. "revenue rose 20.26%" grounding
  // against the year 2026 via the cents-as-dollars heuristic, 2026 / 100 = 20.26).
  const dateNumbers = new Set();
  const strings = [];             // every string leaf, verbatim
  const dateStrings = new Set();  // leaves that are ISO dates / timestamps
  const objects = [];             // every plain object, for the sibling-ratio derivation
  // Check 88 (false-positive round 4): every OWN PROPERTY KEY the pack carries anywhere, lower-
  // cased. A field like `insights.retention.returning_customers` never puts the WORD "returning"
  // into packInfo.strings (it is a key, not a value), yet a report sentence that opens
  // "Returning customers..." is plainly talking about that field, not naming an invented person.
  // Kept separate from `strings` (values) rather than folded in, because a key is grounding a
  // WORD the pack's own schema uses, not a fact the pack asserts - the two are different kinds of
  // evidence and this file keeps them in different sets for the same reason it already keeps
  // idNumbers separate from numbers (see ID_KEY_RE above).
  const keys = new Set();
  const seen = new Set();

  const addNumber = (n) => {
    if (typeof n !== 'number' || !Number.isFinite(n)) return;
    numbers.add(n);
    if (n < 0) numbers.add(Math.abs(n));
  };

  // Check 83: same as addNumber, but ALSO records the value as date-shaped for groundNumbers'
  // pct/ratio/currency exclusion below.
  const addDateNumber = (n) => {
    addNumber(n);
    if (typeof n !== 'number' || !Number.isFinite(n)) return;
    dateNumbers.add(n);
    if (n < 0) dateNumbers.add(Math.abs(n));
  };

  const walk = (node) => {
    if (node === null || node === undefined) return;
    if (typeof node === 'number') { addNumber(node); return; }
    if (typeof node === 'boolean') return;
    if (typeof node === 'string') {
      strings.push(node);
      if (ISO_DATE_RE.test(node)) dateStrings.add(node);
      return;
    }
    if (typeof node !== 'object') return;
    if (seen.has(node)) return;   // cycles cannot occur in JSON, but a caller may hand us anything
    seen.add(node);
    if (Array.isArray(node)) {
      // An array's own length is a fact of the evidence: "your top 3 customers" is grounded when
      // the pack really carries three rows. Without this, list-size claims are false positives.
      addNumber(node.length);
      for (const item of node) walk(item);
      return;
    }
    objects.push(node);
    for (const [key, value] of Object.entries(node)) {
      keys.add(String(key).toLowerCase());
      walk(value);
    }
  };

  walk(pack);

  // Numbers that live INSIDE evidence strings are still evidence: at_risk.definition says
  // "2+ lifetime visits ... 45-180 days", weekday_pattern.note says "1=Monday .. 7=Sunday". A
  // narrative quoting those is quoting the pack. Strict boundaries here (no letter on either
  // side) keep UUID fragments and version tags like "v10.1" out.
  for (const s of strings) {
    if (UUID_RE.test(s) || ISO_DATE_RE.test(s)) continue;
    for (const tok of scanNumbers(s, true)) addNumber(tok.value);
  }

  // Date parts of the pack's own period fields are structural, not claims (check 83's whitelist).
  for (const d of dateStrings) {
    const m = ISO_DATE_RE.exec(d);
    if (!m) continue;
    addDateNumber(Number(m[1]));            // year
    addDateNumber(Number(m[2]));            // month, as written and unpadded
    addDateNumber(Number(m[3]));            // day
  }

  // Check 88 (numeric-ID coincidence): every numeric leaf that lives under an ID-shaped key
  // ("customer_id", "order_ref", "ticket_number", "invoice_no" ...). Kept SEPARATE from the
  // general `numbers` set above rather than folded into it - see ID_CUE_RE / groundNumbers below
  // for why a number introduced by an ID cue must ground against THIS set specifically, not any
  // numeric leaf in the pack.
  const idNumbers = new Set();
  // Check 83: every numeric leaf that lives under a date-shaped key (*_at/*_date/*_on/period) —
  // e.g. a hypothetical `period_days: 30` — is ALSO date-shaped, same reasoning as the year/month/
  // day parts above, even when it is not itself an ISO date string.
  for (const obj of objects) {
    for (const [key, value] of Object.entries(obj)) {
      if (typeof value !== 'number' || !Number.isFinite(value)) continue;
      if (ID_KEY_RE.test(key)) idNumbers.add(value);
      if (DATE_KEY_RE.test(key)) { dateNumbers.add(value); if (value < 0) dateNumbers.add(Math.abs(value)); }
    }
  }

  return {
    numbers: [...numbers], strings, dateStrings: [...dateStrings], objects,
    idNumbers: [...idNumbers], dateNumbers, keys,
  };
}

// round(100*a/b, 0|1) for numeric leaves a, b of the SAME object — the one derivation the model is
// allowed to perform without showing working, because every rate in the pack is built that way.
// Deliberately NOT cross-object: pairing across the pack would accept almost any percentage.
function derivedPercentages(objects) {
  const out = new Set();
  for (const obj of objects) {
    const vals = [];
    for (const v of Object.values(obj)) {
      if (typeof v === 'number' && Number.isFinite(v)) vals.push(v);
    }
    if (vals.length < 2) continue;
    for (const a of vals) {
      for (const b of vals) {
        if (b === 0 || a === b) continue;
        const pct = (100 * a) / b;
        if (Number.isFinite(pct) && Math.abs(pct) < 1e6) out.add(pct);
      }
    }
  }
  return [...out];
}

/* --------------------------------------------------------- number extraction */

// Matches: 1240 | 1,240 | 6,601.50 | 62.5% | S$4,820 | SGD 108.00 | $27.00 | 31 per cent.
// NOT matched, and out of scope by design: number WORDS ("four regulars", "half"). A model that
// spells a fabricated figure out in words defeats V1. This is the single largest known hole in
// check 83 and it is stated here rather than hidden.
// The trailing whitespace lives INSIDE the optional percent group on purpose: a bare "\s*" at the
// end would swallow the space after "180" in "45-180 days", making the token look welded to the
// following word and dropping it from the pack's grounded set.
const NUMBER_TOKEN_RE = /(?:S\$\s*|SGD\s+|\$)?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?(?:\s*(%|per\s?cent))?/gi;

function scanNumbers(text, strict) {
  const found = [];
  if (typeof text !== 'string' || !text) return found;
  NUMBER_TOKEN_RE.lastIndex = 0;
  let m;
  while ((m = NUMBER_TOKEN_RE.exec(text)) !== null) {
    const raw = m[0];
    const before = m.index > 0 ? text[m.index - 1] : '';
    const after = text[m.index + raw.length] || '';
    // "v179", "COVID19", "1b0d" — a number welded to a word is an identifier, not a claim.
    if (/[A-Za-z0-9]/.test(before)) continue;
    if (strict && /[A-Za-z]/.test(after)) continue;
    const digits = m[1].replace(/,/g, '');
    const decimals = m[2] ? m[2].length : 0;
    const value = Number(m[2] ? `${digits}.${m[2]}` : digits);
    if (!Number.isFinite(value)) continue;
    found.push({
      raw,
      digits,
      value,
      decimals,
      isPercent: Boolean(m[3]),
      index: m.index,
      end: m.index + raw.length,
    });
  }
  return found;
}

// A claim written to d decimal places is a correct rendering of `exact` when it is the value
// rounded (or floored, or ceiled) at that precision. "62%" for 62.5 passes; "63%" for 62.5 passes;
// "60%" does not. This one rule replaces a pile of special cases and is why the round-vs-truncate
// ambiguity in the SQL (round(100*a/b,1)) never produces a false positive.
function renders(claimed, decimals, exact) {
  if (!Number.isFinite(exact)) return false;
  const tol = 0.5 * Math.pow(10, -decimals) + 1e-9;
  return Math.abs(claimed - exact) <= tol;
}

/* ------------------------------------------------------------------ masking */

function blankSpan(chars, from, to) {
  for (let i = from; i < to && i < chars.length; i += 1) chars[i] = ' ';
}

// Produces a copy of the narrative with structural numbers blanked out (same length, so every
// index still points into the original text for context extraction).
function maskStructuralNumbers(narrative, packDates) {
  const chars = [...narrative];

  // 1. Dates the pack itself carries (the period fields, generated_at). Longest first so
  //    "2026-08-01T04:00:00+08:00" is consumed before its own "2026-08-01" prefix.
  for (const date of [...packDates].sort((a, b) => b.length - a.length)) {
    let at = narrative.indexOf(date);
    while (at !== -1) {
      blankSpan(chars, at, at + date.length);
      at = narrative.indexOf(date, at + date.length);
    }
  }

  // 2. Markdown ordered-list markers ("1.", "2)") for 1-10 at the start of a line. The prompt
  //    demands "Exactly three numbered actions", so these are formatting, not claims.
  const lineMarker = /^[ \t]*(\d{1,2})[.)][ \t]+/gm;
  let m;
  while ((m = lineMarker.exec(narrative)) !== null) {
    const n = Number(m[1]);
    if (n >= 1 && n <= 10) {
      const numStart = m.index + m[0].indexOf(m[1]);
      blankSpan(chars, numStart, numStart + m[1].length);
    }
  }

  // 3. Markdown heading LINES ("## Do these three things next") are fixed template text, not
  //    claims — including any number word inside them. Blanking the whole line (not just digits)
  //    is what keeps V7's own required heading text from being read as a V1 claim.
  const headingLine = /^[ \t]*#{1,6}[ \t].*$/gm;
  let hm;
  while ((hm = headingLine.exec(narrative)) !== null) {
    blankSpan(chars, hm.index, hm.index + hm[0].length);
  }

  return chars.join('');
}

/* --------------------------------------------------- V1 extension: number words */

// Check 83/88: a model that spells a fabricated figure out in words ("four regulars", "three
// hundred dollars") used to defeat V1 entirely — the digit-only NUMBER_TOKEN_RE never saw it. This
// is a CONSERVATIVE word-number parser: zero..twenty, the tens (thirty..ninety), hundred, thousand,
// joined by whitespace/hyphen and an optional "and". It does NOT understand fractions, ordinals
// ("third"), "dozen", or numbers above one million spelled out — those stay a known gap, same
// spirit as the digit scanner's own documented limits.
const NUM_WORDS = {
  zero: 0, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9,
  ten: 10, eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16,
  seventeen: 17, eighteen: 18, nineteen: 19, twenty: 20,
};
const TENS_WORDS = { thirty: 30, forty: 40, fifty: 50, sixty: 60, seventy: 70, eighty: 80, ninety: 90 };
const NUMBER_WORD_KEYS = ['hundred', 'thousand', ...Object.keys(TENS_WORDS), ...Object.keys(NUM_WORDS)]
  .sort((a, b) => b.length - a.length);
const NUMBER_WORD_RUN_RE = new RegExp(
  `\\b(?:${NUMBER_WORD_KEYS.join('|')})` +
    `(?:[\\s-]+(?:and[\\s-]+)?(?:${NUMBER_WORD_KEYS.join('|')}))*\\b`,
  'gi',
);

function wordsToNumber(words) {
  let total = 0;
  let current = 0;
  let matched = false;
  for (const raw of words) {
    const w = raw.toLowerCase();
    if (w === 'and') continue;
    if (w === 'hundred') {
      current = (current === 0 ? 1 : current) * 100;
      matched = true;
    } else if (w === 'thousand') {
      total += (current === 0 ? 1 : current) * 1000;
      current = 0;
      matched = true;
    } else if (Object.prototype.hasOwnProperty.call(NUM_WORDS, w)) {
      current += NUM_WORDS[w];
      matched = true;
    } else if (Object.prototype.hasOwnProperty.call(TENS_WORDS, w)) {
      current += TENS_WORDS[w];
      matched = true;
    } else {
      return null;
    }
  }
  if (!matched) return null;
  return total + current;
}

// Also check 83: digit-plus-"k" shorthand ("4k", "12k" -> 4000, 12000). Kept in its own regex
// rather than folded into NUMBER_TOKEN_RE so the money/percent grammar there stays untouched.
const NUMBER_K_RE = /\b(\d{1,3}(?:,\d{3})*)(?:\.(\d+))?[kK]\b/g;

function scanNumberWords(text) {
  const found = [];
  if (typeof text !== 'string' || !text) return found;
  NUMBER_WORD_RUN_RE.lastIndex = 0;
  let m;
  while ((m = NUMBER_WORD_RUN_RE.exec(text)) !== null) {
    const value = wordsToNumber(m[0].split(/[\s-]+/));
    if (value === null || !Number.isFinite(value)) continue;
    found.push({
      raw: m[0], value, decimals: 0, isPercent: false, index: m.index, end: m.index + m[0].length,
    });
  }
  NUMBER_K_RE.lastIndex = 0;
  while ((m = NUMBER_K_RE.exec(text)) !== null) {
    const base = Number(`${m[1].replace(/,/g, '')}${m[2] ? `.${m[2]}` : ''}`);
    if (!Number.isFinite(base)) continue;
    found.push({
      raw: m[0], value: base * 1000, decimals: 0, isPercent: false, index: m.index, end: m.index + m[0].length,
    });
  }
  return found;
}

/* --------------------------------------- V1 extension: fractions, ordinals, dozen, "X in Y" */

// Check 83: "a third of customers", "half of revenue", "three quarters", "a dozen regulars" and
// "one in five" each state a QUANTITY in words that scanNumberWords above cannot parse at all — it
// only understands CARDINAL number words (one, two, three...) chained together, never a fraction
// name ("third", "quarter"), the "dozen" idiom, or an "X in Y" ratio. A model that fabricates a
// figure this way used to defeat V1 completely, the same gap scanNumberWords itself closed for
// spelled-out cardinals ("seventeen"). Each phrase is converted to the SAME token shape
// scanNumberWords produces (value/decimals/isPercent) so groundNumbers grounds it exactly like any
// other number claim:
//   - a fraction ("a third", "half", "three quarters") states a PERCENT (100 * numerator /
//     denominator — "a third" -> 33.3, "half" -> 50, "three quarters" -> 75) and is checked against
//     the pack's own derived percentages, same as a digit percent claim (decimals:0, i.e. the
//     SAME +/-0.5 tolerance groundNumbers already applies to any percent, per renders()).
//   - "a dozen"/"two dozen" states a plain COUNT (numerator * 12, "a dozen" -> 12) and grounds
//     against the pack's ordinary numeric leaves, not a percent at all.
//   - "one in five" (or its digit form, "1 in 5", or mixed, "one in 12") states a RATIO, converted
//     the same way as a fraction (100 * a / b -> 20) since a rate expressed as "1 in 5" and "20%"
//     are the same claim about the evidence — EXCEPT when the denominator is itself a calendar
//     year ("1 in 2026"), which is refused outright as ungroundable rather than converted; see
//     DATE_SHAPED_RATIO_DENOMINATOR_RE below.
//
// STAYS OUT, declared rather than silently missing: a vague quantity word that names no number at
// all - "several", "many", "most", "a few", "plenty" - is not converted here and never will be;
// there is nothing to ground it against, and inventing a number for it would be this file
// hallucinating a claim the narrative never actually made. An ordinal used to rank rather than
// quantify ("the second visit", "first came in July") is also out of scope — FRACTION_NUMERATOR_
// WORDS below is cardinals-and-articles only (a/an/one/two/three...), never ordinals, so "second
// half" or "first quarter" (a real business term!) are NOT matched by design, only "<cardinal>
// <fraction-word>".
//
// KNOWN OVER-MATCH, declared rather than hidden: the fraction regex has no way to tell "a third of
// customers" (a quantity claim) from an unrelated "a third party" (not a quantity at all) — both
// are "a" immediately followed by "third". This is the same asymmetry as every other rule in this
// file: firing on the rare unrelated case costs a regenerated report, and is accepted rather than
// leaving the real quantity phrase unconvertable.
const FRACTION_NUMERATOR_WORDS = { a: 1, an: 1, ...NUM_WORDS };
const FRACTION_DENOMINATORS = {
  half: 2, halves: 2,
  third: 3, thirds: 3,
  quarter: 4, quarters: 4, fourth: 4, fourths: 4,
  fifth: 5, fifths: 5,
  sixth: 6, sixths: 6,
  seventh: 7, sevenths: 7,
  eighth: 8, eighths: 8,
  ninth: 9, ninths: 9,
  tenth: 10, tenths: 10,
};
const alternation = (words) => words.sort((a, b) => b.length - a.length).join('|');
const FRACTION_RE = new RegExp(
  `\\b(${alternation(Object.keys(FRACTION_NUMERATOR_WORDS))})\\s+` +
    `(${alternation(Object.keys(FRACTION_DENOMINATORS))})\\b`,
  'gi',
);
const DOZEN_RE = new RegExp(
  `\\b(${alternation(Object.keys(FRACTION_NUMERATOR_WORDS))})\\s+dozen\\b`, 'gi',
);
// Check 83 (v735 follow-up): a ratio's numerator and denominator are each EITHER a spelled-out
// cardinal ("one") OR a bare digit run ("5"), independently — "5 in 11", "one in 12" and
// "1 in 2026" all match, same as the all-words "one in five" the original rule covered. Digit
// support closes a gap the word-only rule left wide open: a model that writes the ratio in digits
// (the far more natural way to write "5 in 11 customers came back") produced no V1 numeric
// violation at all — the bare digits fell through as two unrelated, individually-groundable
// mentions, and a denominator that happened to equal some unrelated pack number (worse, a
// date-shaped one — see DATE_SHAPED_RATIO_DENOMINATOR_RE below) could ground the pair by
// coincidence.
const RATIO_SIDE_SRC = `(?:\\d+|${alternation(Object.keys(NUM_WORDS))})`;
const RATIO_RE = new RegExp(`\\b(${RATIO_SIDE_SRC})\\s+in\\s+(${RATIO_SIDE_SRC})\\b`, 'gi');

// A ratio side is either all-digits or a NUM_WORDS key (never both, and RATIO_RE cannot match
// anything else), so trying the digit form first and falling back to the word table is exhaustive.
function ratioSideValue(raw) {
  return /^\d+$/.test(raw) ? Number(raw) : NUM_WORDS[raw.toLowerCase()];
}

// Check 83: a digit-form denominator shaped like a calendar year (1900-2099) — "1 in 2026
// customers" — is not a population size; it is the report's own period year sitting one word away
// from an unrelated "in". A spelled-out denominator can never collide with this (NUM_WORDS tops
// out at "twenty"), so the check only needs to look at the digit form.
const DATE_SHAPED_RATIO_DENOMINATOR_RE = /^(?:19|20)\d{2}$/;

function scanQuantityPhrases(text) {
  const tokens = [];
  const spans = [];
  if (typeof text !== 'string' || !text) return { tokens, spans };

  FRACTION_RE.lastIndex = 0;
  let m;
  while ((m = FRACTION_RE.exec(text)) !== null) {
    const numerator = FRACTION_NUMERATOR_WORDS[m[1].toLowerCase()];
    const denominator = FRACTION_DENOMINATORS[m[2].toLowerCase()];
    if (!denominator) continue;
    const pct = Math.round((100 * numerator / denominator) * 10) / 10;
    if (!Number.isFinite(pct)) continue;
    tokens.push({
      raw: m[0], value: pct, decimals: 0, isPercent: true, index: m.index, end: m.index + m[0].length,
    });
    spans.push([m.index, m.index + m[0].length]);
  }

  DOZEN_RE.lastIndex = 0;
  while ((m = DOZEN_RE.exec(text)) !== null) {
    const numerator = FRACTION_NUMERATOR_WORDS[m[1].toLowerCase()];
    const value = numerator * 12;
    if (!Number.isFinite(value)) continue;
    tokens.push({
      raw: m[0], value, decimals: 0, isPercent: false, index: m.index, end: m.index + m[0].length,
    });
    spans.push([m.index, m.index + m[0].length]);
  }

  RATIO_RE.lastIndex = 0;
  while ((m = RATIO_RE.exec(text)) !== null) {
    const aRaw = m[1];
    const bRaw = m[2];
    const a = ratioSideValue(aRaw);
    const b = ratioSideValue(bRaw);
    if (!b) continue; // "... in zero" — nothing to divide by, and not a claim this file has seen
    const pct = Math.round((100 * a / b) * 10) / 10;
    if (!Number.isFinite(pct)) continue;
    // Check 83: a date-shaped denominator ("1 in 2026") never grounds, no matter what the pack
    // holds — see DATE_SHAPED_RATIO_DENOMINATOR_RE and groundedAgainstPack's forceUngrounded check.
    // The span is still recorded (below) either way so the digit/word scans don't ALSO fire on it.
    const forceUngrounded = DATE_SHAPED_RATIO_DENOMINATOR_RE.test(bRaw);
    tokens.push({
      raw: m[0], value: pct, decimals: 0, isPercent: true, index: m.index, end: m.index + m[0].length,
      forceUngrounded,
    });
    spans.push([m.index, m.index + m[0].length]);
  }

  return { tokens, spans };
}

/* ------------------------------------------- V1: every number is in evidence */

// Shown working: "SGD 108.00 / 4 customers = SGD 27.00 each". The system prompt in index.ts
// explicitly asks for arithmetic with the working shown, so a validator that refused all derived
// results would fail every well-formed report. Rather than permit it blindly, we CHECK it: the two
// operands must themselves be grounded, and the stated result must be the correct answer at the
// precision it is written to.
const OPERATORS = [
  { re: /^\s*(?:x|×|\*|times|multiplied by)\s*$/i, apply: (a, b) => a * b },
  { re: /^\s*(?:\/|÷|divided by)\s*$/i, apply: (a, b) => (b === 0 ? NaN : a / b) },
  { re: /^\s*(?:\+|plus)\s*$/i, apply: (a, b) => a + b },
  { re: /^\s*(?:-|–|—|minus|less)\s*$/i, apply: (a, b) => a - b },
];
// Allows "= SGD", "= about", "customers = SGD", "is about" — a short, digit-free bridge to the
// result. Kept tight so unrelated adjacent numbers are never read as an equation.
const EQUALS_BRIDGE = /^[^\d]{0,28}?(?:=|equals|is|gives|makes|comes to)[^\d]{0,14}$/i;

// Check 88 (numeric-ID coincidence): a numerals-only token introduced by one of these cue words
// names an IDENTIFIER, not a quantity - "customer #4471", "order 1092", "ticket no. 55". A model
// that writes such a number is making a record-lookup claim, not a count or an amount, so it must
// ground against the pack's own ID-typed fields (idNumbers, from readPack/ID_KEY_RE above), never
// against any numeric leaf in the pack. Without this, an invented "customer #4471" would pass
// clean any time 4471 happens to be SOME unrelated number in the pack (a revenue figure, a stamp
// count) that was never an identifier at all - the coincidence this rule closes.
const ID_CUE_RE = /\b(?:customer|order|ticket|invoice|receipt|member|ref)\s*#?\s*(\d+)/gi;

// The [start, end) character range of the DIGITS ONLY in each ID-cued match above (not the cue
// word itself) - used to line the cue up with the digit token scanNumbers() already produced at
// the same offset, rather than re-parsing the number a second, independent way.
function idCuedDigitRanges(masked) {
  const ranges = [];
  ID_CUE_RE.lastIndex = 0;
  let m;
  while ((m = ID_CUE_RE.exec(masked)) !== null) {
    const start = m.index + m[0].length - m[1].length;
    ranges.push([start, start + m[1].length]);
  }
  return ranges;
}

function overlapsAnyRange(ranges, from, to) {
  return ranges.some(([start, end]) => from < end && to > start);
}

function groundNumbers(narrative, packInfo, derivedPct) {
  const masked = maskStructuralNumbers(narrative, packInfo.dateStrings);
  // Check 83: fraction/ordinal/dozen/"X in Y" quantity phrases are extracted FIRST, from the same
  // masked text, and their spans excluded from BOTH the ordinary digit scan and the ordinary
  // cardinal-word scan that follow — "three quarters" would otherwise ALSO surface a bare
  // "three"=3 word-token (NUMBER_WORD_RUN_RE has no idea "quarters" changes what "three" means),
  // "one in five" would surface "one"=1 and "five"=5 as two unrelated word-claims alongside the
  // ratio's own 20%, and (since RATIO_RE now accepts digits too — v735 follow-up) "2 in 5" would
  // likewise surface bare DIGIT tokens 2 and 5 via scanNumbers unless those spans are excluded from
  // the digit scan as well. Excluding prevents the same phrase being counted twice under two
  // different, disagreeing interpretations.
  const { tokens: quantityTokens, spans: quantitySpans } = scanQuantityPhrases(masked);
  const digitTokens = scanNumbers(masked, false)
    .filter((t) => !overlapsAnyRange(quantitySpans, t.index, t.end));
  let maskedForWords = masked;
  if (quantitySpans.length) {
    const chars = [...masked];
    for (const [from, to] of quantitySpans) blankSpan(chars, from, to);
    maskedForWords = chars.join('');
  }
  const wordTokens = scanNumberWords(maskedForWords).concat(quantityTokens);
  // Word tokens are checked directly against the pack (never chained into shown-working — a
  // model spelling out an intermediate step is not something the prompt asks for, and chaining
  // word tokens into the digit-token arithmetic pass would let a spelled result launder a
  // fabricated digit operand). Kept as their own array; digit tokens keep the existing behaviour
  // byte-for-byte.
  const tokens = digitTokens;
  const grounded = new Array(tokens.length).fill(false);
  const idCuedRanges = idCuedDigitRanges(masked);
  const idNumbers = packInfo.idNumbers || [];

  // Check 83: a percentage, ratio (scanQuantityPhrases' RATIO_RE already emits these as
  // isPercent:true tokens) or currency claim must never ground against a date-shaped number — see
  // DATE_KEY_RE / dateNumbers above for what counts as one. A plain claim (a bare count, or an
  // actual date mention like "in 2026") is NOT restricted; only the pct/currency shape is, because
  // that is the shape the cents-as-dollars heuristic (n / 100) applies to, and a year is never
  // cents. isCurrency reads the token's own matched text: NUMBER_TOKEN_RE's optional S$/SGD/$
  // prefix survives into tok.raw verbatim.
  const CURRENCY_TOKEN_PREFIX_RE = /^\s*(?:S\$|SGD\s|\$)/;
  const dateNumbers = packInfo.dateNumbers || new Set();
  const groundedAgainstPack = (tok) => {
    // Check 83 (digit-form ratios): a "N in M" claim whose denominator M is itself a calendar year
    // (scanQuantityPhrases flags this on the token as forceUngrounded — see RATIO_RE there) is
    // refused outright, before any lookup runs. Nothing in the pack can ground it "correctly" —
    // even a coincidental match would be laundering a year the model misread as a headcount into a
    // rate claim, the same failure mode v735 already closed on the PACK side (a period year must
    // never ground a percentage via the cents-as-dollars heuristic); this closes the matching gap
    // on the CLAIM side.
    if (tok.forceUngrounded) return false;
    const excludeDateNumbers = tok.isPercent || CURRENCY_TOKEN_PREFIX_RE.test(tok.raw);
    for (const n of packInfo.numbers) {
      const isDateNumber = dateNumbers.has(n);
      if (excludeDateNumbers && isDateNumber) continue; // check 83: date parts never ground a rate
      if (renders(tok.value, tok.decimals, n)) return true;      // the value as the pack holds it
      if (isDateNumber) continue;                                 // a date is never "cents"
      if (renders(tok.value, tok.decimals, n / 100)) return true; // cents written as dollars
    }
    if (tok.isPercent) {
      for (const p of derivedPct) {
        if (renders(tok.value, tok.decimals, p)) return true;     // round(100*a/b) of siblings
      }
    }
    return false;
  };

  // A numeral introduced by an ID cue is judged ONLY against the pack's ID-typed fields, never
  // against the general `numbers` pool - see ID_CUE_RE above for why a coincidental match there
  // (a revenue figure, a stamp count) must not launder an invented ID.
  const groundedAsId = (tok) => idNumbers.some((n) => renders(tok.value, tok.decimals, n));

  for (let i = 0; i < tokens.length; i += 1) {
    const cued = overlapsAnyRange(idCuedRanges, tokens[i].index, tokens[i].end);
    grounded[i] = cued ? groundedAsId(tokens[i]) : groundedAgainstPack(tokens[i]);
  }

  // Second pass: a still-ungrounded token may be the RESULT of shown working whose operands are
  // grounded. Iterated so chained working ("a + b = c ... c x d = e") settles.
  for (let pass = 0; pass < 3; pass += 1) {
    let changed = false;
    for (let i = 0; i + 2 < tokens.length; i += 1) {
      const [a, b, c] = [tokens[i], tokens[i + 1], tokens[i + 2]];
      if (grounded[i + 2] || !grounded[i] || !grounded[i + 1]) continue;
      const opGap = masked.slice(a.end, b.index);
      const eqGap = masked.slice(b.end, c.index);
      if (!EQUALS_BRIDGE.test(eqGap)) continue;
      for (const op of OPERATORS) {
        if (!op.re.test(opGap)) continue;
        const exact = op.apply(a.value, b.value);
        if (Number.isFinite(exact) && renders(c.value, c.decimals, exact)) {
          grounded[i + 2] = true;
          changed = true;
        }
        break;
      }
    }
    if (!changed) break;
  }

  const wordGrounded = wordTokens.map(groundedAgainstPack);

  return { tokens, grounded, wordTokens, wordGrounded };
}

function contextAround(narrative, index, end) {
  const from = Math.max(0, index - 20);
  const to = Math.min(narrative.length, end + 20);
  return narrative.slice(from, to).replace(/\s+/g, ' ').trim().slice(0, 40);
}

/* --------------------------------------------- V2: period and population labels */

const MONTHS = [
  ['january', 'jan'], ['february', 'feb'], ['march', 'mar'], ['april', 'apr'],
  ['may', 'may'], ['june', 'jun'], ['july', 'jul'], ['august', 'aug'],
  ['september', 'sep'], ['october', 'oct'], ['november', 'nov'], ['december', 'dec'],
];
// CASE-SENSITIVE on the initial capital, and that is not fussiness. "may" and "march" are ordinary
// English words, and the confidence rule's own sanctioned phrasing is "revenue MAY increase" — a
// case-insensitive month match reads that as a claim about the month of May and fails a correct
// report. Models capitalise month names in prose; the cost of this choice is that a lower-cased
// month name ("in july") is not detected by V2.
const MONTH_NAME_RE = new RegExp(
  `\\b(${MONTHS.map(([full, abbr]) => {
    const cap = (w) => w[0].toUpperCase() + w.slice(1);
    return full === abbr ? cap(full) : `${cap(full)}|${cap(abbr)}`;
  }).join('|')})\\b\\.?`,
  'g',
);

function monthIndexOf(word) {
  const w = String(word).toLowerCase().replace(/\.$/, '');
  return MONTHS.findIndex(([full, abbr]) => w === full || w === abbr);
}

function monthsSpanned(fromISO, toISO) {
  const out = new Set();
  const a = ISO_DATE_RE.exec(String(fromISO || ''));
  const b = ISO_DATE_RE.exec(String(toISO || ''));
  if (!a || !b) return out;
  let year = Number(a[1]);
  let month = Number(a[2]);
  const endYear = Number(b[1]);
  const endMonth = Number(b[2]);
  for (let guard = 0; guard < 400; guard += 1) {
    if (year > endYear || (year === endYear && month > endMonth)) break;
    out.add(month - 1);
    month += 1;
    if (month > 12) { month = 1; year += 1; }
  }
  return out;
}

function periodBounds(pack) {
  const scope = (pack && pack.scope) || {};
  const sales = (pack && pack.sales) || {};
  const current = sales.current || {};
  const prior = sales.prior || {};
  return {
    from: scope.period_start || current.from || null,
    to: scope.period_end || current.to || null,
    priorFrom: scope.prior_period_start || prior.from || null,
    priorTo: scope.prior_period_end || prior.to || null,
  };
}

// "In July, sales grew" claims the report IS about July. "customers who first bought in July" and
// "compared with July" are legitimate references to the prior period. Two things separate them:
// the cue word, and POSITION - a period claim leads its sentence, a prior-period reference does
// not. Requiring both is what stops the honest mid-sentence mention being flagged. The cost is
// that a period claim buried mid-sentence ("sales in July were strong") is NOT caught; V2 guards
// the headline claim, which is the failure mode that misleads an owner about what they are reading.
const CURRENT_CUE = /\b(?:in|for|during|throughout|across|this)\s+$/i;
const CLAUSE_START = /(?:^|[\n\r])[\s>*#-]*$|[.!?][\s"')\]]*$/;
const COMPARISON_CUE =
  /\b(?:from|than|versus|vs\.?|against|compared\s+with|compared\s+to|since|before|after|last|prior\s+to|up\s+on|down\s+on|on)\s+$/i;

const ALL_CUSTOMERS_RE = /\b(?:all|every)\s+(?:of\s+)?(?:your\s+|the\s+)?customers?\b/i;
// Metrics that v548 marks scope:'identified_customers_only'. Weekday and item figures cover every
// sale, so they are deliberately absent from this list.
const IDENTIFIED_METRIC_RE =
  /\b(?:revenue|spend|spent|spending|returning|return rate|at[- ]risk|slipping|top customer|best customer|regulars?|concentrat)/i;

function sentencesOf(text) {
  // Splits on terminal punctuation followed by a capital, and on line breaks. The capital-letter
  // lookahead is what stops "Lee S. spent" being cut in half at the initial.
  return String(text || '')
    .split(/\n+|(?<=[.!?])\s+(?=[A-Z(])/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function checkPopulation(narrative, pack, violations) {
  const bounds = periodBounds(pack);
  const currentMonths = monthsSpanned(bounds.from, bounds.to);
  const priorMonths = monthsSpanned(bounds.priorFrom, bounds.priorTo);

  if (currentMonths.size > 0) {
    MONTH_NAME_RE.lastIndex = 0;
    let m;
    while ((m = MONTH_NAME_RE.exec(narrative)) !== null) {
      // Check 86: same modal-"May" exemption as checkLowercaseMonthClauseStart below (defined
      // further down the file, hoisted) — belt-and-suspenders in case a model capitalises "May"
      // as a modal ("This May reflect...", an unusual but not impossible capitalisation choice).
      if (isModalMayUsage(narrative, m[1], m.index, m.index + m[0].length)) continue;
      const idx = monthIndexOf(m[1]);
      if (idx < 0) continue;
      const lead = narrative.slice(0, m.index);
      const cue = CURRENT_CUE.exec(lead.slice(-24));
      const claimsCurrent = Boolean(cue) &&
        !COMPARISON_CUE.test(lead.slice(-24)) &&
        CLAUSE_START.test(lead.slice(0, lead.length - cue[0].length));
      const allowed = claimsCurrent
        ? currentMonths.has(idx)
        : currentMonths.has(idx) || priorMonths.has(idx);
      if (!allowed) {
        violations.push({
          rule: RULES.POPULATION,
          detail: `period "${m[0]}" is not the pack's period (${bounds.from} to ${bounds.to}` +
            `${bounds.priorFrom ? `, prior ${bounds.priorFrom} to ${bounds.priorTo}` : ''}) ` +
            `near "${contextAround(narrative, m.index, m.index + m[0].length)}"`,
        });
      }
    }
  }

  const identification = (pack && pack.insights && pack.insights.identification) ||
    (pack && pack.identification) || null;
  const share = identification ? identification.identified_revenue_share_pct : null;
  if (typeof share === 'number' && share < 100) {
    for (const sentence of sentencesOf(narrative)) {
      if (!ALL_CUSTOMERS_RE.test(sentence)) continue;
      if (!IDENTIFIED_METRIC_RE.test(sentence)) continue;
      violations.push({
        rule: RULES.POPULATION,
        detail: `"all/every customer" claimed for an identified-only metric while ` +
          `identified_revenue_share_pct is ${share}: "${sentence.slice(0, 80)}"`,
      });
    }
  }
}

/* -------------------------------------------------------- V2 extension: branch */

// Check 84: a report scoped to one branch must not name another. Conservative on purpose — it
// only fires when the narrative pairs a capitalised name with an explicit branch word ("the
// Orchard branch", "at Tampines outlet"), AND that name is introduced by an article/preposition
// ("the"/"at"/"your"/"our"). Without that second requirement a sentence that simply STARTS with a
// capitalised verb right before the word "branch" ("Confirm branch details...") reads as a branch
// name; requiring the article is what tells "the Orchard branch" apart from that. A bare place
// name with no such cue is never flagged either way — this file has no way to tell a legitimate
// aside ("near Orchard MRT") from a branch claim.
const BRANCH_MENTION_RE =
  /\b(?:[Tt]he|[Aa]t|[Yy]our|[Oo]ur)\s+([A-Z][A-Za-z']+(?:\s[A-Z][A-Za-z']+)?)\s+(?:branch|outlet|location|store)\b/g;

function checkBranch(narrative, pack, violations) {
  const scope = (pack && pack.scope) || {};
  const branchLabel = typeof scope.branch_label === 'string' ? scope.branch_label.trim() : '';
  BRANCH_MENTION_RE.lastIndex = 0;
  let m;
  while ((m = BRANCH_MENTION_RE.exec(narrative)) !== null) {
    const named = m[1].trim();
    if (branchLabel && named.toLowerCase() === branchLabel.toLowerCase()) continue;
    violations.push({
      rule: RULES.POPULATION,
      detail: `"${named}" is named as the report's branch, but ${branchLabel
        ? `the pack's branch is "${branchLabel}"`
        : 'the pack carries no branch scope for this report'}, near ` +
        `"${contextAround(narrative, m.index, m.index + m[0].length)}"`,
    });
  }
}

/* ---------------------------------------------- V2 extension: lowercase months */

// Check 84's second half. V2's primary month check is deliberately case-SENSITIVE (documented
// above at MONTH_NAME_RE) because "may"/"march" are ordinary English words and a blanket
// case-insensitive match would fail correct reports that use the sanctioned "may increase"
// phrasing. This second pass closes the gap the safe way: it only looks at the exact syntactic
// position V2 already treats as a leading period claim — a CURRENT_CUE word at clause start,
// immediately followed by the candidate month — so "Revenue may increase" (no cue before "may")
// is never touched, while "In july, sales grew" is caught even though "july" is lower-case.
const MONTH_NAME_CI_RE = new RegExp(MONTH_NAME_RE.source, 'gi');

// Check 86: "may" is BOTH the month name and English's most common modal auxiliary ("this may
// reflect...", "it may improve..."). checkLowercaseMonthClauseStart's own CURRENT_CUE list
// includes the bare word "this", so "This may reflect the school holidays." was misread as a
// leading period claim about the month of May: "this " matches CURRENT_CUE, the text before it is
// sentence-initial (CLAUSE_START), and "may" parses as monthIndexOf('may') >= 0 — the recommended
// hedging language this report's own honest-limitation notes elsewhere ask for was rejected by the
// very rule meant to police a DIFFERENT thing (a fabricated period). Modal usage is recognisable
// two ways, either enough to exempt the match:
//   (1) the word immediately BEFORE "may" is a modal SUBJECT — a pronoun or a noun a hedge
//       naturally attaches to ("this", "it", "that", "which", "customers", "clients", "members",
//       "guests", "shoppers", "they", "we", "you"). Deliberately NOT "sales" or any other noun this
//       report uses as the subject of a genuine month claim — "Sales in May were higher" has "in"
//       between "Sales" and "May", not a direct subject-verb adjacency, so it is untouched.
//   (2) the word immediately AFTER "may" is one of a short list of bare-infinitive verbs a hedge in
//       this report's own voice commonly takes ("reflect", "indicate", "suggest", "mean", "explain",
//       "increase", "decrease", "improve", "help", "need", "want", "affect", "change", "vary",
//       "grow", "shrink", "differ", "include", "require", "benefit"). A genuine month claim is never
//       followed by one of these — "Sales in May WERE higher" is followed by a past-tense BE-verb
//       describing what happened IN that month, not a hedge continuation — so this does not widen
//       the false-negative gap check 84 already accepts for month names in general.
// Scoped to the literal word "may" only (never "march"/"august"/etc, which have no comparable modal
// reading in this report's voice), so every other month name keeps its existing behaviour untouched.
const MODAL_MAY_SUBJECT_RE =
  /\b(?:this|it|that|which|customers?|clients?|members?|guests?|shoppers?|they|we|you)\s*$/i;
const MODAL_MAY_VERB_RE =
  /^\s*(?:reflect|indicate|suggest|mean|explain|increase|decrease|improve|help|need|want|affect|change|vary|grow|shrink|differ|include|require|benefit)\b/i;

function isModalMayUsage(narrative, monthWord, matchIndex, matchEnd) {
  if (String(monthWord).toLowerCase().replace(/\.$/, '') !== 'may') return false;
  const before = narrative.slice(Math.max(0, matchIndex - 24), matchIndex);
  if (MODAL_MAY_SUBJECT_RE.test(before)) return true;
  const after = narrative.slice(matchEnd, matchEnd + 24);
  return MODAL_MAY_VERB_RE.test(after);
}

function checkLowercaseMonthClauseStart(narrative, pack, violations) {
  const bounds = periodBounds(pack);
  const currentMonths = monthsSpanned(bounds.from, bounds.to);
  if (currentMonths.size === 0) return;

  MONTH_NAME_CI_RE.lastIndex = 0;
  let m;
  while ((m = MONTH_NAME_CI_RE.exec(narrative)) !== null) {
    if (/^[A-Z]/.test(m[1])) continue; // capitalised: the primary case-sensitive pass already covers it
    if (isModalMayUsage(narrative, m[1], m.index, m.index + m[0].length)) continue;
    const idx = monthIndexOf(m[1]);
    if (idx < 0 || currentMonths.has(idx)) continue;
    const lead = narrative.slice(0, m.index);
    const cue = CURRENT_CUE.exec(lead.slice(-24));
    if (!cue) continue;
    if (COMPARISON_CUE.test(lead.slice(-24))) continue;
    if (!CLAUSE_START.test(lead.slice(0, lead.length - cue[0].length))) continue;
    violations.push({
      rule: RULES.POPULATION,
      detail: `period "${m[0]}" (lower-case) is not the pack's period (${bounds.from} to ${bounds.to}), ` +
        `near "${contextAround(narrative, m.index, m.index + m[0].length)}"`,
    });
  }
}

/* ------------------------------------------------------- V3: causal language */

// The v179 pack contains no experiment, no holdout and no counterfactual — nothing in it can
// support a causal claim. v108's treatment/holdout engine is the only causal machinery in the
// product and it does not feed this report. The gate below therefore exists but is shut:
// opts.causalEvidence must be explicitly true, and nothing sets it today.
const CAUSAL_PATTERNS = [
  { label: 'caused', re: /\b(?:cause|causes|caused|causing)\b/i },
  { label: 'generated', re: /\b(?:generate|generates|generated|generating)\b/i },
  { label: 'lift', re: /\b(?:lift|lifts|lifted|lifting)\b/i },
  { label: 'incremental', re: /\b(?:incremental|incrementally)\b/i },
  { label: 'drove', re: /\b(?:drove|drives|driven|driving)\b/i },
  // Attribution to a marketing intervention. Narrower than a bare "because of", which has honest
  // uses in this report ("...because item coverage is low"); a generic causal "because of" is
  // therefore NOT caught, and that is a known gap.
  {
    label: 'because_of_intervention',
    re: /\bbecause of (?:your |the |this |that |our )?(?:\w+\s+)?(?:campaign|promotion|promo|offer|discount|marketing|message|reminder|voucher)\b/i,
  },
];

// Check 85: a refuter proved CAUSAL_PATTERNS above never grew to cover the SAME idioms
// CAUSAL_CONSTRUCTIONS (below, shared with V10/V10b) already knows about — "as a result" and a
// pronoun-continuation causal idiom ("This pushes customers to return sooner.") both validated
// clean on a pack that carries NO typed findings at all, because V10/V10b only ever look at a
// sentence that references a typed ASSOCIATION finding's own vocabulary (typedFindings, below) —
// most reports, and every pack with zero typed findings, never reach either of those two rules no
// matter what the narrative says. checkCausal now ALSO tests the one shared CAUSAL_CONSTRUCTIONS
// list, unconditionally — no typed finding required, no pack shape required — in addition to (not
// instead of) CAUSAL_PATTERNS above, which stays for because_of_intervention: a bare "because of
// the campaign" is a narrower, marketing-specific claim that is not on the shared list at all (the
// shared list only has a BARE "because", deliberately unqualified — see the exemption note below).
//
// EXEMPTION. CAUSAL_CONSTRUCTIONS includes a bare `/\bbecause\b/i`, and this report legitimately
// uses "because" to explain a LIMITATION, not assert a business cause ("the figure is incomplete
// because item coverage is low this month" — a fact about the evidence, not a claim about what
// made something happen). A causal construction whose OBJECT — the text immediately following the
// match — names a coverage/limitation concept (data, coverage, identified, recorded, sample,
// window, period) is exempted from THIS unconditional pass: the sentence is explaining a gap in
// the evidence, not claiming the gap caused a business outcome. Deliberately narrow (a short
// window right after the match, a fixed word list) — the same asymmetry as every other rule in
// this file, tuned so a false negative (a genuine causal claim that happens to mention one of
// these words nearby) is the accepted cost, never a false positive on the honest limitation case.
const CAUSAL_LIMITATION_OBJECT_RE = /\b(?:data|coverage|identified|recorded|sample|window|period)\b/i;
const CAUSAL_OBJECT_WINDOW = 60;

function checkCausalConstructionsUnconditional(narrative, violations) {
  for (const re of CAUSAL_CONSTRUCTIONS) {
    const hit = re.exec(narrative);
    if (!hit) continue;
    const object = narrative.slice(
      hit.index + hit[0].length,
      hit.index + hit[0].length + CAUSAL_OBJECT_WINDOW,
    );
    if (CAUSAL_LIMITATION_OBJECT_RE.test(object)) continue;
    violations.push({
      rule: RULES.CAUSAL,
      detail: `causal construction "${hit[0]}" with no causal evidence in the pack, near ` +
        `"${contextAround(narrative, hit.index, hit.index + hit[0].length)}"`,
    });
  }
}

function checkCausal(narrative, opts, violations) {
  if (opts.causalEvidence === true) return;   // the door exists; nothing opens it today
  for (const { label, re } of CAUSAL_PATTERNS) {
    const hit = re.exec(narrative);
    if (!hit) continue;
    violations.push({
      rule: RULES.CAUSAL,
      detail: `causal claim "${hit[0]}" (${label}) with no causal evidence in the pack, near ` +
        `"${contextAround(narrative, hit.index, hit.index + hit[0].length)}"`,
    });
  }
  checkCausalConstructionsUnconditional(narrative, violations);
}

/* ---------------------------------------------------- V4: confidence ceiling */

const OVERCONFIDENT_PATTERNS = [
  { label: 'definitely', re: /\bdefinitely\b/i },
  { label: 'certainly', re: /\b(?:certainly|for certain)\b/i },
  { label: 'guaranteed', re: /\b(?:guarantee|guarantees|guaranteed)\b/i },
  // A forecast stated as fact. "may increase" / "could increase" are the sanctioned forms. One
  // intervening adverb is allowed for, because "will definitely increase" is the natural phrasing
  // and a rule that only matched the bare form would miss the worst version of the claim.
  { label: 'will_increase', re: /\bwill\s+(?:\w+ly\s+)?(?:increase|grow|rise|improve|double|go up)\b/i },
];

function checkConfidence(narrative, opts, violations) {
  if (opts.allowStrongClaims === true) return;
  for (const { label, re } of OVERCONFIDENT_PATTERNS) {
    const hit = re.exec(narrative);
    if (!hit) continue;
    violations.push({
      rule: RULES.CONFIDENCE,
      detail: `over-confident claim "${hit[0]}" (${label}); the evidence supports "may" or ` +
        `"could", near "${contextAround(narrative, hit.index, hit.index + hit[0].length)}"`,
    });
  }
}

/* -------------------------------------------- V4 extension: confidence ceiling */

// Check 86: strong-pattern vocabulary is only earned at the pack's own confidence_class ceiling
// (v652's evidence_block tiers: insufficient | early_signal | strong_pattern). Below strong_pattern
// a "pattern/trend" claim must carry hedged wording nearby ("may", "early sign", "seems to" ...).
// This is separate from OVERCONFIDENT_PATTERNS above (definitely/certainly/guaranteed/"will
// increase" stay refused at every tier — no comparison in this product is ever THAT certain);
// this rule is about the language of PATTERN-RECOGNITION specifically, which v652 exists to cap.
const STRONG_CERTAINTY_RE =
  /\b(?:clearly|consistently|reliably|a strong (?:pattern|trend)|clear pattern|proven|definitively shows)\b/i;
const PATTERN_MENTION_RE = /\b(?:pattern|trend|tendency)\b/gi;
const HEDGE_NEARBY_RE =
  /\b(?:may|might|could|possibly|early sign|early indication|not (?:yet )?conclusive|not confirmed|preliminary|seems? to|appears? to)\b/i;

function checkConfidenceTier(narrative, pack, opts, violations) {
  if (opts.allowStrongClaims === true) return;
  const tierRaw = typeof opts.confidenceClass === 'string' ? opts.confidenceClass : pack.confidence_class;
  const tier = CONFIDENCE_TIER_SET.has(tierRaw) ? tierRaw : 'insufficient';
  if (tier === 'strong_pattern') return; // the ceiling is not exceeded; nothing left to check here

  const strongHit = STRONG_CERTAINTY_RE.exec(narrative);
  if (strongHit) {
    violations.push({
      rule: RULES.CONFIDENCE,
      detail: `"${strongHit[0]}" claims strong-pattern confidence but confidence_class is ` +
        `"${tier}"; use hedged wording ("may", "early sign") near ` +
        `"${contextAround(narrative, strongHit.index, strongHit.index + strongHit[0].length)}"`,
    });
  }

  PATTERN_MENTION_RE.lastIndex = 0;
  let m;
  while ((m = PATTERN_MENTION_RE.exec(narrative)) !== null) {
    const window = narrative.slice(Math.max(0, m.index - 40), Math.min(narrative.length, m.index + 40));
    if (HEDGE_NEARBY_RE.test(window)) continue;
    violations.push({
      rule: RULES.CONFIDENCE,
      detail: `"${m[0]}" claim has no hedged wording nearby while confidence_class is "${tier}", ` +
        `near "${contextAround(narrative, m.index, m.index + m[0].length)}"`,
    });
  }
}

/* ----------------------------------------------- V5: limitation preservation */

// v552 puts failures in evidence_completeness.unavailable_sections as [{section, sqlstate}].
// Plain strings are accepted too, because that is the shape a caller most naturally writes.
function unavailableSections(pack) {
  const direct = pack && pack.evidence_completeness &&
    pack.evidence_completeness.unavailable_sections;
  const found = Array.isArray(direct) ? direct : deepFindUnavailable(pack);
  const out = [];
  for (const entry of found || []) {
    if (typeof entry === 'string' && entry.trim()) out.push(entry.trim());
    else if (entry && typeof entry === 'object' && typeof entry.section === 'string') {
      out.push(entry.section.trim());
    }
  }
  return out;
}

function deepFindUnavailable(node, depth = 0) {
  if (!node || typeof node !== 'object' || depth > 6) return null;
  if (Array.isArray(node)) {
    for (const item of node) {
      const hit = deepFindUnavailable(item, depth + 1);
      if (hit) return hit;
    }
    return null;
  }
  if (Array.isArray(node.unavailable_sections)) return node.unavailable_sections;
  for (const value of Object.values(node)) {
    const hit = deepFindUnavailable(value, depth + 1);
    if (hit) return hit;
  }
  return null;
}

const SECTION_KEYWORDS = {
  consultant_brief: [/consultant/i, /advis(?:er|or|ory)/i, /\bbrief\b/i],
  catalogue_affinity: [/catalogue/i, /catalog/i, /affinity/i, /bought together/i, /pair(?:ing|ed)/i],
  recommendations: [/recommend/i, /suggested action/i, /advice/i],
  account_opens_report: [/account open/i, /account sign[- ]?up/i, /sign[- ]?up/i, /new account/i, /registration/i, /joined/i],
  account_opens: [/account open/i, /account sign[- ]?up/i, /sign[- ]?up/i, /new account/i, /registration/i, /joined/i],
};
// A section keyword only counts as PRESERVATION when the same sentence says the thing is missing.
// Merely mentioning "recommendations" while silently inventing them is the failure, not the fix.
const UNAVAILABLE_CUE =
  /\b(?:not available|unavailable|not delivered|not included|not in this report|no data|not shown|missing|could not be (?:shown|produced|read)|do not have|don't have|was withheld|withheld)\b/i;
// A blanket acknowledgement covers every withheld section. This is the spec's own escape hatch and
// its weakness: one generic sentence satisfies V5 for all sections at once.
const GENERIC_ACKNOWLEDGEMENT =
  /\b(?:some (?:data|information|figures|sections) (?:were|was) not available|data (?:was|is) unavailable|not available this time|was not available for this report|some information is missing from this report)\b/i;

function checkLimitations(narrative, pack, violations) {
  const sections = unavailableSections(pack);
  if (sections.length === 0) return;
  const generic = GENERIC_ACKNOWLEDGEMENT.test(narrative);
  const sentences = sentencesOf(narrative);
  for (const section of sections) {
    if (generic) continue;
    const keywords = SECTION_KEYWORDS[section] ||
      [new RegExp(section.replace(/_/g, '[ _-]?'), 'i')];
    const acknowledged = sentences.some(
      (s) => UNAVAILABLE_CUE.test(s) && keywords.some((k) => k.test(s)),
    );
    if (!acknowledged) {
      violations.push({
        rule: RULES.LIMITATION,
        detail: `evidence_completeness.unavailable_sections names "${section}" but the narrative ` +
          `never says it was unavailable`,
      });
    }
  }
}

/* ------------------------------------------------- V5 extension: other limitations */

// Check 87: three more limitations the pack can carry, each a fact that changes what a claim
// nearby actually means, and each requiring its own acknowledgement rather than the blanket
// GENERIC_ACKNOWLEDGEMENT above (that escape hatch is specifically for unavailable_sections).
const IDENTIFIED_CAVEAT_CUE = /\bidentified\b/i;
const ACCOUNT_OPENS_CLAMP_CUE =
  /\b(?:not the full period|only up to|only cover(?:s|ed)?|only includes?|partial(?:ly)?|does not cover the (?:full|whole) period)\b/i;
const ACCOUNT_OPENS_MENTION_CUE = /\baccount[\s-]?open|sign[\s-]?up|new account|registration|joined/i;
const ITEM_TOP_CLAIM_CUE = /\bitems?\b/i;
const ITEM_TOP_ACTION_CUE = /\btop|sell|sold|best|popular/i;
const ITEM_COVERAGE_CUE =
  /\b(?:of tracked items|tracked items only|only part of (?:revenue|sales)|coverage|partial item)\b/i;

function checkLimitationItems(narrative, pack, violations) {
  const sentences = sentencesOf(narrative);

  const identification = (pack && pack.insights && pack.insights.identification) ||
    (pack && pack.identification) || null;
  const share = identification ? identification.identified_revenue_share_pct : null;
  if (typeof share === 'number' && share < 100) {
    const acknowledged = sentences.some((s) => IDENTIFIED_CAVEAT_CUE.test(s));
    if (!acknowledged) {
      violations.push({
        rule: RULES.LIMITATION,
        detail: `identified_revenue_share_pct is ${share} (below 100) but the narrative never ` +
          `states an identified-only caveat`,
      });
    }
  }

  const accountOpens = (pack && pack.account_opens) || null;
  const range = accountOpens && accountOpens.report_range;
  if (range && range.clamped === true) {
    const acknowledged = sentences.some(
      (s) => ACCOUNT_OPENS_MENTION_CUE.test(s) && ACCOUNT_OPENS_CLAMP_CUE.test(s),
    );
    if (!acknowledged) {
      violations.push({
        rule: RULES.LIMITATION,
        detail: 'account_opens.report_range.clamped is true but the narrative never says the ' +
          'account-opens figures are partial',
      });
    }
  }

  const items = (pack && pack.insights && pack.insights.items) || (pack && pack.items) || null;
  const coverage = items ? items.coverage_pct : null;
  if (typeof coverage === 'number' && coverage < 90) {
    const mentionsTopItems = sentences.some(
      (s) => ITEM_TOP_CLAIM_CUE.test(s) && ITEM_TOP_ACTION_CUE.test(s),
    );
    if (mentionsTopItems) {
      const acknowledged = sentences.some((s) => ITEM_COVERAGE_CUE.test(s));
      if (!acknowledged) {
        violations.push({
          rule: RULES.LIMITATION,
          detail: `items.coverage_pct is ${coverage} (below 90) but a top-item claim is made ` +
            `without a coverage caveat`,
        });
      }
    }
  }
}

/* -------------------------------------------------------- V6: entity grounding */

// HONEST LIMITS. There is no name database here and there cannot be one: v177_person_label emits
// "First L." or "Guest AB12" from real customer names, which are unbounded. The heuristic is
// deliberately CONSERVATIVE - it fires only on a run of two or more capitalised words that is not
// led by a common English word, not a weekday or month, and not found anywhere in the pack's own
// strings. It therefore CANNOT catch, on its own:
//   * a single-word invented name ("Marcus") right after a direct-address cue — closed below by
//     checkSingleTokenEntities;
//   * a single-word invented name ANYWHERE ELSE in the sentence — closed further below by V9's
//     checkOrphanProperNouns;
//   * an invented name that happens to be a substring of a pack string.
// And it CAN misfire on an unusual proper noun the model legitimately introduces (a place, a
// public holiday). Misfires cost a regenerated report, so the trade is deliberate.
// AFTER V9 (below), what remains genuinely undetectable: a lowercase invented name ("marcus asked
// about his account" — no capital letter, nothing here or in V9 looks for it); a name that is
// itself an ordinary lowercase English word capitalised only because a model legitimately
// capitalised it for other reasons (rare, and the false-negative side of that trade is deliberate,
// same asymmetry as everywhere else in this file); and a name that collides letter-for-letter with
// a legitimate allowlisted word or an unrelated pack string substring (e.g. an invented "Sun" would
// be masked by a pack string containing "Sunday" or "Sunset Cafe").
const NAME_TOKEN_RE = /^(?:[A-Z][a-z]+|[A-Z]\.)$/;
const DAY_NAMES = new Set([
  'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
]);
const STOPWORDS = new Set([
  'the', 'a', 'an', 'this', 'that', 'these', 'those', 'your', 'you', 'yours', 'our', 'ours', 'we',
  'us', 'they', 'them', 'their', 'it', 'its', 'his', 'her', 'hers', 'he', 'she', 'i',
  'in', 'on', 'at', 'for', 'from', 'to', 'of', 'by', 'with', 'without', 'about', 'across', 'after',
  'before', 'during', 'since', 'until', 'against', 'between', 'through', 'throughout', 'into',
  'over', 'under', 'per', 'via', 'versus',
  'and', 'or', 'but', 'so', 'if', 'then', 'than', 'because', 'while', 'when', 'where', 'what',
  'which', 'who', 'whom', 'whose', 'why', 'how', 'both', 'either', 'neither',
  'is', 'are', 'was', 'were', 'be', 'been', 'being', 'do', 'does', 'did', 'done', 'has', 'have',
  'had', 'can', 'could', 'may', 'might', 'must', 'shall', 'should', 'will', 'would',
  'all', 'any', 'each', 'every', 'few', 'many', 'more', 'most', 'much', 'less', 'least', 'no',
  'none', 'not', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten',
  'only', 'other', 'others', 'same', 'some', 'such', 'own', 'just', 'even', 'still', 'yet',
  'first', 'second', 'third', 'last', 'next', 'new', 'old', 'best', 'worst', 'better', 'worse',
  'good', 'bad', 'big', 'small', 'high', 'low', 'top', 'bottom', 'up', 'down', 'out', 'off',
  'now', 'today', 'tomorrow', 'yesterday', 'here', 'there', 'again', 'also', 'once', 'always',
  'never', 'often', 'sometimes', 'usually', 'about',
  'summary', 'report', 'revenue', 'sales', 'customers', 'customer', 'visits', 'visit', 'points',
  'stamps', 'loyalty', 'send', 'ask', 'put', 'make', 'keep', 'try', 'run', 'check', 'call',
  'tracked', 'total', 'average', 'note', 'action', 'actions', 'week', 'month', 'year', 'day',
  'days', 'weeks', 'months', 'years',
]);

function nameCandidates(narrative) {
  const prose = narrative
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/[`*_>#|]/g, ' ');
  const out = [];
  for (const sentence of sentencesOf(prose)) {
    const rawTokens = sentence.split(/\s+/);
    let run = [];
    const flush = () => {
      // Drop leading common words: "Your Marcus Tan" must still surface "Marcus Tan".
      while (run.length && STOPWORDS.has(run[0].word.toLowerCase().replace(/\.$/, ''))) run.shift();
      if (run.length >= 2) out.push({ text: `${run[0].word} ${run[1].word}` });
      run = [];
    };
    for (const rawToken of rawTokens) {
      // Strip surrounding punctuation, but keep a lone initial's period: "S.," -> "S.", "Tan." -> "Tan".
      let word = rawToken.replace(/^[^A-Za-z]+/, '').replace(/[^A-Za-z.]+$/, '');
      if (!/^[A-Z]\.$/.test(word)) word = word.replace(/\.+$/, '');
      const plain = word.toLowerCase();
      if (!word || !NAME_TOKEN_RE.test(word) || DAY_NAMES.has(plain) || monthIndexOf(plain) >= 0) {
        flush();
        continue;
      }
      run.push({ word });
    }
    flush();
  }
  return out;
}

function checkEntities(narrative, packInfo, violations) {
  const haystack = packInfo.strings.join('  ').toLowerCase();
  const reported = new Set();
  for (const candidate of nameCandidates(narrative)) {
    const needle = candidate.text.toLowerCase();
    if (haystack.includes(needle)) continue;
    // "Lee S." in the pack, "Lee S" (period eaten by a sentence end) in the narrative.
    if (needle.endsWith('.') && haystack.includes(needle.slice(0, -1))) continue;
    if (haystack.includes(`${needle}.`)) continue;
    if (reported.has(needle)) continue;
    reported.add(needle);
    violations.push({
      rule: RULES.ENTITY,
      detail: `"${candidate.text}" is named as a person or entity but appears nowhere in the ` +
        `evidence pack (customer labels come from top_customers.rows[].label)`,
    });
  }
}

/* -------------------------------------------------------------- V6 extension: single-token names */

// Check 83/88's second half: a single invented proper noun ("Marcus") is invisible to the
// two-token rule above by design (one capitalised word is far too common to flag on its own). This
// closes ONE narrow, high-precision slice of that gap: a capitalised token immediately following a
// direct-address cue ("customer", "client", "Ms", "Mr", "Mrs") is exactly the position a name goes,
// so it is checked alone. A single name anywhere ELSE in the sentence is closed separately by V9's
// checkOrphanProperNouns, further below — kept as its own rule rather than folded in here because
// its allowlist and sentence-position logic are shaped differently (see V9's own comment).
const DIRECT_ADDRESS_CUE_RE = /\b(?:customer|client|Ms\.?|Mr\.?|Mrs\.?)\s+([A-Z][a-z]+)\b/g;

function checkSingleTokenEntities(narrative, packInfo, violations) {
  const haystack = packInfo.strings.join('  ').toLowerCase();
  const reported = new Set();
  DIRECT_ADDRESS_CUE_RE.lastIndex = 0;
  let m;
  while ((m = DIRECT_ADDRESS_CUE_RE.exec(narrative)) !== null) {
    const name = m[1];
    const plain = name.toLowerCase();
    if (DAY_NAMES.has(plain) || monthIndexOf(plain) >= 0 || STOPWORDS.has(plain)) continue;
    if (haystack.includes(plain)) continue;
    if (reported.has(plain)) continue;
    reported.add(plain);
    violations.push({
      rule: RULES.ENTITY,
      detail: `"${name}" is named right after "${m[0].slice(0, m[0].length - name.length).trim()}" ` +
        `but appears nowhere in the evidence pack, near ` +
        `"${contextAround(narrative, m.index, m.index + m[0].length)}"`,
    });
  }
}

/* ---------------------------------------------------- V9: orphan proper nouns */

// v701 closes the gap this file's own comments (above, and the old check-83/88 note) admitted was
// undetectable: a SINGLE invented proper noun with no direct-address cue in front of it at all —
// "Marcus returned twice last month" has no "customer"/"Ms"/"Mr" to anchor on, so
// checkSingleTokenEntities never sees it, and it is only one word, so checkEntities' two-token run
// never sees it either. This rule fires on ANY capitalised token of 4+ letters (one initial capital
// then two or more lowercase letters) that is:
//   (a) not sentence-initial — a capital letter starting a sentence, heading, or list item is
//       ordinary English, not a naming claim ("Revenue rose...", "## Summary", "1. Send...");
//   (b) not in a conservative allowlist (below) of words a legitimate report uses even mid-sentence
//       without being a claim about a person or place: weekday and month names (case-normalised,
//       independent of V2's own case-sensitive month check above — different purpose, same
//       months), the product's own name, common jurisdictions/currency/platform words this
//       product's reports legitimately mention, and the report's own fixed template heading words
//       (belt-and-suspenders: heading LINES are also excluded wholesale, below);
//   (c) not found, verbatim and case-SENSITIVE, anywhere among the pack's own string leaves — a
//       business name, branch label, customer label, item/category/campaign name genuinely in the
//       pack must ground the word it contains, same principle as V6's own haystack;
//   (d) not part of a multi-token capitalised run — "Chen H.", "Kaya Toast Set", "Marcus Tan" are
//       V6's territory (checkEntities/checkSingleTokenEntities already judge those runs); V9 only
//       ever looks at a capitalised word standing completely alone.
// Firing costs a regenerated report (see the file banner), so (a)-(d) are each deliberately narrow.
// A caller may extend the allowlist via opts.entityAllowlist for a business/report shape this file
// cannot anticipate (e.g. a firm whose own name is an ordinary English word used constantly in
// prose) — see resolveConfidenceClass above for the same "opts is the one legitimate override
// surface" pattern.
//
// v705: this shape used to be one capital then ONLY lowercase letters, which meant an internal
// capital ("JavaBrew") was invisible to V9 no matter how cleanly the token was isolated - not a
// tokeniser bug, a shape bug. CAPITALISED_TOKEN_RE below is now the SAME widened shape V9b
// (checkOrphanProperNounsSentenceInitial) already used for its own sentence-initial tokens: a
// Unicode capital letter (\p{Lu}) followed by two or more Unicode letters of either case (\p{L}).
// V9's own exemptions - (a)-(d) above, the allowlist, and the pack-grounding check - are
// unchanged; only the shape test widens, via isCapitalisedCandidate() below.
//
// v706 (check 88, refuter round 3): "O'Brien" was invisible for a THIRD reason, distinct from
// 1-5 above - an INTERNAL apostrophe. orphanWords() keeps it (only a TRAILING punctuation mark is
// trimmed, and stripTrailingPossessive only strips a trailing 's), so the isolated token really is
// "O'Brien" - but the shape test itself rejected it outright, because an apostrophe is not \p{L}
// and the old regex demanded every character after the first be a plain letter. Fixed by allowing
// an OPTIONAL apostrophe (straight or typographic) immediately before any letter in the run, so an
// internal apostrophe no longer breaks the shape test while a token with no apostrophe at all
// behaves byte-for-byte as before (the group is `['’]?` - optional).
const CAPITALISED_TOKEN_RE = /^\p{Lu}(?:['’]?\p{L}){2,}$/u;

// v705: a hyphenated token ("Mei-Ling") matches neither the plain shape above (a hyphen is not
// \p{L}) - it is a candidate when ANY of its hyphen-separated segments looks like a capitalised
// name segment on its own (a single capital letter, or a capital plus 2+ more letters). The token
// is judged and reported as a WHOLE, hyphen included: a fabricated "Mei-Ling" is one name, not
// two, and splitting it into "Mei" / "Ling" would both mis-report the finding and risk two
// separate, noisier violations for what is really one invented name.
function isCapitalisedCandidate(word) {
  if (CAPITALISED_TOKEN_RE.test(word)) return true;
  if (!word.includes('-')) return false;
  const segments = word.split('-').filter(Boolean);
  if (segments.length < 2) return false;
  return segments.some((seg) => CAPITALISED_TOKEN_RE.test(seg) || /^\p{Lu}$/u.test(seg));
}

const ORPHAN_TOKEN_RE = CAPITALISED_TOKEN_RE;

// Reasons, so this list is never "just vibes":
//   Peekaa            — the product's own name, said in almost every report ("Peekaa recorded...").
//   Singapore/Malaysia — the product's declared jurisdictions (CLAUDE.md: "Singapore-first"); a
//                        report legitimately says "customers across Singapore" with no per-report
//                        evidence-pack leaf to ground it against.
//   SGD               — the currency code; already excluded from ORPHAN_TOKEN_RE in practice (all
//                        three letters are capitals, so it never matches [A-Z][a-z]{2,}), listed
//                        anyway so the allowlist is legible on its own without relying on that
//                        regex accident.
//   WhatsApp/Google/Stripe/Facebook/Instagram — channel/platform names this product's automations
//                        and comms integrate with or reference (CLAUDE.md: "WhatsApp-native");
//                        legitimately named in a report ("sent via WhatsApp") with nothing in the
//                        v176 evidence pack to ground the word against.
//   Summary/Do        — first words of two of the five REQUIRED_HEADINGS (`## Summary`, `## Do
//                        these three things next`). Heading LINES are excluded wholesale below
//                        (headingRanges), so this only matters if a heading's own wording is ever
//                        echoed back mid-sentence elsewhere; listed for that belt-and-suspenders
//                        case rather than relying solely on the line-range exclusion.
const ORPHAN_ALLOWLIST_BASE = new Set([
  'Peekaa', 'Singapore', 'Malaysia', 'SGD', 'WhatsApp', 'Google', 'Stripe', 'Facebook', 'Instagram',
  'Summary', 'Do',
]);

function orphanMonthNameSet() {
  const out = new Set();
  const cap = (w) => w[0].toUpperCase() + w.slice(1);
  for (const [full, abbr] of MONTHS) {
    out.add(cap(full));
    if (abbr !== full) out.add(cap(abbr));
  }
  return out;
}
const ORPHAN_MONTH_NAMES = orphanMonthNameSet();

function orphanDayNameSet() {
  const out = new Set();
  for (const d of DAY_NAMES) out.add(d[0].toUpperCase() + d.slice(1));
  return out;
}
const ORPHAN_DAY_NAMES = orphanDayNameSet();

function buildOrphanAllowlist(opts) {
  const extra = opts && Array.isArray(opts.entityAllowlist) ? opts.entityAllowlist : [];
  return new Set([...ORPHAN_ALLOWLIST_BASE, ...ORPHAN_MONTH_NAMES, ...ORPHAN_DAY_NAMES, ...extra]);
}

// Fenced code blocks and heading LINES are template/formatting, not claims about the business —
// same rationale as maskStructuralNumbers' heading-line blanking for V1. Unlike that function this
// one only needs to know WHERE to skip, not to preserve the narrative's length.
function orphanSkipRanges(narrative) {
  const ranges = [];
  const codeFence = /```[\s\S]*?```/g;
  let m;
  while ((m = codeFence.exec(narrative)) !== null) ranges.push([m.index, m.index + m[0].length]);
  const heading = /^[ \t]*#{1,6}[ \t].*$/gm;
  while ((m = heading.exec(narrative)) !== null) ranges.push([m.index, m.index + m[0].length]);
  return ranges;
}

function inOrphanSkipRange(ranges, index) {
  return ranges.some(([from, to]) => index >= from && index < to);
}

// v705 (check 88, refuter round 2 — five bypasses proved against 01-normal-firm.json's own
// known-good narrative, all in the shared tokeniser orphanWords()/isCapitalisedCandidate() build
// on):
//   1. EM-DASH/EN-DASH/SLASH GLUING. A plain \S+ split treats "month—Marcus—and" (no surrounding
//      space around the dash) as ONE token, so "Marcus" was never its own token at all - not
//      merely mis-shaped, invisible to every rule that walks orphanWords()'s output. Fixed by
//      splitting on U+2013/U+2014/"/" as token boundaries, same as whitespace, below.
//   2. POSSESSIVE 'S. "Melissa's" kept its apostrophe (the old end-trim loop only strips a
//      TRAILING character that is neither a letter nor a dot; the "s" after the apostrophe IS a
//      letter, so the apostrophe sat protected in the middle of the token forever). A token
//      shape that requires ONLY letters after the first capital then failed on the untouched
//      apostrophe. Fixed by stripping a trailing 's/'s (straight or typographic apostrophe) once
//      the raw token is isolated, before any shape test ever sees it.
//   3. UNICODE LETTERS. "Zoë" lost its "ë" outright: the old trim loops tested [A-Za-z] only, so
//      a non-ASCII letter at the token's edge read as "not a letter" and was trimmed away like
//      punctuation, leaving "Zo" - too short for the shape regex even before Unicode was
//      considered. Fixed by testing \p{L} (any Unicode letter) with the `u` flag throughout.
//   4. INTERNAL CAPITALS, MID-SENTENCE. "JavaBrew" was invisible to V9 for a DIFFERENT reason from
//      1-3: V9's own shape regex (one capital, then ONLY lowercase) rejects an internal capital
//      outright, no matter how cleanly the token was isolated. V9b already accepted internal
//      capitals, but only at sentence-initial position. Fixed by giving V9 the SAME widened shape
//      V9b already used (CAPITALISED_TOKEN_RE, below) - V9's own position/allowlist/pack-
//      grounding/run-partner exemptions are unchanged, only the SHAPE test widens.
//   5. HYPHENATED NAMES. "Mei-Ling" matches neither shape (a hyphen is not \p{L}) even after
//      1-4. Fixed by isCapitalisedCandidate(), below: a hyphenated token is ALSO a candidate when
//      any one of its hyphen-separated segments looks like a capitalised name segment on its own
//      - the token is judged and reported as a WHOLE, hyphen included, because a fabricated
//      "Mei-Ling" is one name, not two.
// Plain punctuation that BELONGS to a word (an internal hyphen, a trailing full stop) is
// deliberately NOT a token boundary - only whitespace, dash and slash split tokens apart; a lone
// initial's period still survives ("S." stays "S."); anything else has trailing dots stripped
// ("Tan." -> "Tan").
const ORPHAN_TOKEN_SPLIT_RE = /[^\s–—/]+/g;

// A trailing possessive is the SAME name with a grammatical suffix glued on with no space -
// stripped once, here, so it never has to be re-derived by every caller of orphanWords().
function stripTrailingPossessive(word) {
  return word.replace(/['’]s$/i, '');
}

// v706 (check 88, refuter round 3): an honorific glued directly onto a name with NO space at all
// ("Mr.Tan") is invisible to every existing rule for two INDEPENDENT reasons at once - the shape
// test rejects the internal period outright (same class of problem as the apostrophe fix above),
// and DIRECT_ADDRESS_CUE_RE (checkSingleTokenEntities) requires a space after the honorific, which
// this text does not have. Rather than widen either shape test to tolerate an embedded period
// (which would then also swallow a genuine sentence-final "Mr." followed immediately by a new
// sentence with no space - a real, if rare, typo shape this file should not start silently
// accepting as one token), this is fixed at the SOURCE: the token this word is glued to is split
// into its two real words - "Mr." and "Tan" - each carrying its own correct offset into the
// ORIGINAL narrative, before any shape test ever runs. Every downstream rule then sees exactly
// what it would have seen had the model written "Mr. Tan": "Mr." itself is never a capitalised
// candidate (the period still breaks CAPITALISED_TOKEN_RE, correctly - an honorism is not a name),
// and "Tan" is judged as an ordinary standalone token as normal.
const GLUED_HONORIFIC_RE = /^(Mr|Ms|Mrs|Dr)\.(\p{Lu}[\p{L}]*)$/u;

// Every word in the ORIGINAL narrative, split at whitespace/dash/slash boundaries and stripped of
// surrounding punctuation the same way nameCandidates() strips it above (kept as a SEPARATE pass,
// not a shared helper, because nameCandidates needs sentence-scoped runs and this needs
// whole-document positions for the sentence-initial check below).
function orphanWords(narrative) {
  const out = [];
  ORPHAN_TOKEN_SPLIT_RE.lastIndex = 0;
  let m;
  while ((m = ORPHAN_TOKEN_SPLIT_RE.exec(narrative)) !== null) {
    const raw = m[0];
    let start = 0;
    while (start < raw.length && !/\p{L}/u.test(raw[start])) start += 1;
    let end = raw.length;
    while (end > start && !/[\p{L}.]/u.test(raw[end - 1])) end -= 1;
    let word = raw.slice(start, end);
    if (!/^\p{Lu}\.$/u.test(word)) word = word.replace(/\.+$/, '');
    word = stripTrailingPossessive(word);
    const index = m.index + start;

    const glued = GLUED_HONORIFIC_RE.exec(word);
    if (glued) {
      const honorific = `${glued[1]}.`;
      const name = glued[2];
      out.push({ word: honorific, index, end: index + honorific.length });
      out.push({ word: name, index: index + honorific.length, end: index + honorific.length + name.length });
      continue;
    }

    out.push({ word, index, end: index + word.length });
  }
  return out;
}

// (d): a capitalised, non-stopword neighbour immediately before or after means this token is part
// of a run V6 already owns. Stopwords are excluded from counting as a "partner" so a stopword that
// happens to be capitalised at a clause start (e.g. an orphan name right after "The") does not
// smuggle the orphan out of V9's reach — "The Marcus arrived" must still be checked, because "The"
// is not itself a name.
//
// v706 (check 88, refuter round 3): "Tan/Wong" was a DOUBLE exemption, not a missed one. V6's own
// tokeniser (nameCandidates, above) splits a sentence on WHITESPACE ONLY, so "Tan/Wong" is one
// unbreakable non-name token to V6 - it is dropped by nameCandidates' own shape test and V6 never
// forms a two-word run out of it at all. orphanWords() (this function's own caller), by contrast,
// DOES split on "/" (ORPHAN_TOKEN_SPLIT_RE, above) - so "Tan" and "Wong" arrive here as two
// SEPARATE, array-adjacent tokens. The old version of this function only checked array adjacency,
// so it saw two capitalised non-stopword neighbours and concluded "this is a run, V6's territory" -
// exactly backwards, because V6 never actually claimed it. The result: neither rule ever looked at
// "Tan" or "Wong" on its own. Fixed by requiring the ACTUAL text between the two token spans, in
// the original narrative, to be whitespace-only before counting them as a run partner - a "/" (or
// any other punctuation the split regex consumed as a boundary) between two array-adjacent tokens
// means they were never written as a whitespace-joined two-word name and V9 must judge each alone.
// v(check 88, refuter round 4): "Last Tuesday Marcus returned twice" evaded V9 entirely. "Tuesday"
// sits immediately before "Marcus", is capitalised, is not a stopword, and the gap between them is
// plain whitespace — so the OLD isPartner() below counted it as a genuine run partner and V9's own
// exemption (d) ("part of a multi-token capitalised run — V6's territory") skipped "Marcus" as
// already-someone-else's-problem. It never was: V6's own run-builder (nameCandidates, above) FLUSHES
// its run the instant it sees a weekday or month name (`DAY_NAMES.has(plain) ||
// monthIndexOf(plain) >= 0` at that function's own continue-and-flush line) — "Tuesday Marcus" is
// never treated as a two-word name by V6, because V6 deliberately refuses to let a weekday/month
// word anchor one end of a run. hasCapitalisedRunPartner disagreed with V6 about what counts as a
// run, which is exactly backwards: it exists ONLY to detect "this token is V6's territory", so it
// must use V6's own definition of a run partner, not a looser one. Fixed by excluding a weekday, a
// month name, or an allowlisted word (Peekaa, WhatsApp, ...) from counting as a partner here too —
// a capitalised token whose ONLY neighbour is one of those is judged ALONE, same as V6 already does.
// `allowlist` is optional (existing callers outside this file's two, if any were ever added, keep
// working with day/month-only exclusion) so this stays backward compatible in shape.
function hasCapitalisedRunPartner(narrative, words, i, allowlist) {
  const isNonPartnerWord = (word) => {
    const plain = word.toLowerCase().replace(/\.$/, '');
    if (STOPWORDS.has(plain)) return true;
    if (DAY_NAMES.has(plain)) return true;
    if (monthIndexOf(plain) >= 0) return true;
    if (allowlist && allowlist.has(word)) return true;
    return false;
  };
  const isPartner = (self, neighbour) => {
    if (!neighbour || !NAME_TOKEN_RE.test(neighbour.word)) return false;
    if (isNonPartnerWord(neighbour.word)) return false;
    const [first, second] = self.index < neighbour.index ? [self, neighbour] : [neighbour, self];
    const gap = narrative.slice(first.end, second.index);
    return gap.length > 0 && /^\s+$/.test(gap);
  };
  return isPartner(words[i], words[i - 1]) || isPartner(words[i], words[i + 1]);
}

// (a): sentence-initial in the broad sense — start of the document, start of a line (which in this
// report's markdown is always a new paragraph, heading, or numbered/bulleted action), or right
// after sentence-ending punctuation. A leading list/blockquote marker ("- ", "1. ", "> ") is
// stripped first so the word right after it is still judged as a line start.
const ORPHAN_LINE_MARKER_RE = /^[ \t]*(?:[-*+>]|\d{1,3}[.)])[ \t]+/;
function isOrphanSentenceInitial(narrative, index) {
  const lineStart = narrative.lastIndexOf('\n', index - 1) + 1;
  let lead = narrative.slice(lineStart, index);
  const marker = ORPHAN_LINE_MARKER_RE.exec(lead);
  if (marker) lead = lead.slice(marker[0].length);
  if (lead.trim() === '') return true;
  return /[.!?:]["')\]]*\s+$/.test(lead);
}

function checkOrphanProperNouns(narrative, packInfo, violations, opts) {
  const allowlist = buildOrphanAllowlist(opts);
  const ranges = orphanSkipRanges(narrative);
  const rawHaystack = packInfo.strings.join(' '); // case-sensitive, unlike V6's haystack
  const words = orphanWords(narrative);
  const reported = new Set();

  for (let i = 0; i < words.length; i += 1) {
    const tok = words[i];
    if (!isCapitalisedCandidate(tok.word)) continue;
    if (allowlist.has(tok.word)) continue;                          // (b)
    if (inOrphanSkipRange(ranges, tok.index)) continue;              // (b) heading/code lines
    if (hasCapitalisedRunPartner(narrative, words, i, allowlist)) continue; // (d)
    if (isOrphanSentenceInitial(narrative, tok.index)) continue;     // (a)
    if (rawHaystack.includes(tok.word)) continue;                    // (c)
    if (reported.has(tok.word)) continue;
    reported.add(tok.word);
    violations.push({
      rule: RULES.ENTITY,
      detail: `"${tok.word}" is a capitalised word, not sentence-initial, and matches no evidence` +
        `-pack string; check it is not an invented name, near ` +
        `"${contextAround(narrative, tok.index, tok.end)}"`,
    });
  }
}

/* -------------------------------------------------- V9b: sentence-initial orphans */

// An independent refuter broke V9 by exploiting condition (a) directly: V9 exempts EVERY
// sentence/line-initial capitalised token unconditionally, on the reasoning that a capital
// letter starting a sentence is "ordinary English, not a naming claim". That reasoning holds for
// "Revenue rose..." and "Saturday was the strongest day..." — it does not hold for
// "Melissa spent more than usual this period." or "JavaBrew is a popular add-on many customers
// choose." inserted as their own sentence: both are fabricated-entity claims, and both slipped
// through V9 clean purely because of WHERE they sit in the sentence, not what they say.
//
// V9b closes that hole WITHOUT reverting V9's own exemption (V9 still never flags a
// sentence-initial token; this is a separate, additive rule so the two stay easy to reason about
// independently). It also widens the SHAPE of token it looks at, on purpose: V9's own
// ORPHAN_TOKEN_RE (one capital then only lowercase letters) never matches "JavaBrew" at all — an
// internal capital breaks that regex outright, mid-sentence or not — so closing only the
// sentence-initial gap while keeping V9's narrower shape would still let "JavaBrew" through.
// SENTENCE_INITIAL_TOKEN_RE below therefore accepts any run of letters starting with a capital
// (internal capitals allowed), scoped to sentence-initial position only — V9's own mid-sentence
// behaviour is untouched.
//
// It looks at exactly the tokens V9 skips — sentence/line-initial, non-heading, non-code, not
// part of a multi-token run (still V6's territory) — and flags one UNLESS its lowercase form is:
//   (a) found anywhere (case-INSENSITIVE — unlike V9's own case-sensitive haystack, because a
//       word's capitalisation at the start of a sentence is a position artefact, not evidence of
//       a proper noun; "Revenue" leading a sentence should ground against a pack string that says
//       "revenue" in lowercase) among the pack's own string leaves;
//   (b) on the same conservative allowlist V9 uses (buildOrphanAllowlist — product name,
//       jurisdictions, channel names, month/day names, opts.entityAllowlist);
//   (c) in COMMON_SENTENCE_STARTERS (below) — the deliberately-built set of ordinary English
//       function words and report vocabulary that legitimately start a sentence in this product's
//       reports, PLUS every sentence-initial token that actually appears in the six golden-pack
//       known-good narratives and the v677 FAITHFUL fixture AND is NOT itself present anywhere in
//       those same packs' own evidence strings. That pruning step matters: a harvested word that
//       ALSO happens to be present in the pack it was harvested from (a customer surname, a
//       business name, an item name — "Chen", "Tan", "Wong", "Kaya", "Whale", "Mystery", "Sparse",
//       "Odd", "High", "Unavail" all showed up in the first harvest before pruning) already passes
//       condition (a) for THAT pack on its own; shipping it as a global starter would ALSO exempt
//       it for every OTHER pack that has no such name, silently weakening V9b everywhere except
//       where it was harvested from. Pruning keeps the harvested half to genuinely ordinary,
//       fixture-independent words. This was harvested ONCE by a throwaway script (not shipped, not
//       run at validation time — this file has no filesystem access and must not gain one) that
//       replicated orphanWords()/isOrphanSentenceInitial() over
//       tests/ai-reports/fixtures/golden-packs/*.json's "good" field and the v677 test file's
//       FAITHFUL constant, checked each result against the same packs' own string leaves, and
//       pasted only the survivors below as a literal. The set is therefore fixed at review time,
//       not read from fixtures at runtime.
//
// HONEST LIMITS, stated plainly because firing a false positive costs a regenerated report and
// missing a true positive costs an owner reading a fabricated claim:
//   * An invented name that COLLIDES with a MONTH name is NOT caught by V9b — it reads as the
//     ordinary month word, same false-negative shape V9's own comment already accepts for V6.
//     "May", "June", "March" and "August" are the false negatives here, because MONTHS is folded
//     into COMMON_SENTENCE_STARTERS (below) unconditionally. (This comment previously named
//     "Grace", "Summer", "Faith" and "Will" alongside them as if they shared the same exemption —
//     they do not. None of those four is a month name, a day name, or in COMMON_SENTENCE_STARTERS
//     at all, so an invented "Grace"/"Summer"/"Faith"/"Will" opening a sentence IS caught by V9b,
//     proven by a dedicated test pinning exactly this so the claim cannot silently drift back to
//     the wrong one. "Will" has one narrow, DELIBERATE exemption of a different kind, unrelated to
//     COMMON_SENTENCE_STARTERS: check 17/88's isInterrogativeModalOpening (below) treats a
//     sentence-initial modal — "Will", "Would", "Could", "Should", "Can", "May", "Might", "Do",
//     "Does", "Did", "Is", "Are" — followed within two tokens by "you"/"we"/"they"/"customers"/
//     "clients"/"it"/"this" as an ordinary QUESTION, not a naming claim: "Will you visit us again
//     this month?" must validate clean. "Will" used as an invented PERSON name — no such
//     question shape around it — is still caught.)
//   * A pruned word (see above) is exempted ONLY for the pack it came from, via condition (a),
//     never globally — an invented "Tan" in a pack that has no Tan is now caught (proven by a
//     dedicated test against 01-normal-firm.json, which names no Tan).
//   * Everything V9's own banner already states stays true here unchanged: a lowercase invented
//     name is invisible (a capital start is required), and a multi-token run is V6's territory,
//     not this rule's.
//   * v705's own widening (isCapitalisedCandidate, orphanWords) still has edges: a possessive
//     other than a trailing 's/'s ("Melissa'll") is not stripped; a token boundary other than
//     whitespace/dash/slash (a colon glued with no space, "thanked:Marcus") is not split; and a
//     hyphenated token needs at least one segment that ITSELF looks capitalised ("mei-Ling" with
//     only the second segment capitalised still matches, but "abc-def" with neither does, by
//     design — nothing here can tell a genuinely all-lowercase invented name from an ordinary
//     hyphenated word without a name database, same limit V9's own banner already states above).
// v705: V9b now judges tokens with isCapitalisedCandidate() (declared with V9, above) - the SAME
// shape and hyphenated-token widener V9 uses. The two rules differ in POSITION and allowlist
// strictness, not in the shape of token they look at; there is no separate "sentence-initial"
// regex any more.
const COMMON_SENTENCE_STARTERS_HAND = new Set([
  // Ordinary English function words a report sentence legitimately opens with.
  'the', 'this', 'these', 'those', 'your', 'our', 'their', 'its', 'a', 'an', 'every', 'each',
  'in', 'on', 'at', 'over', 'during', 'across', 'among', 'after', 'before', 'since',
  'while', 'when', 'where', 'if', 'although', 'because', 'however', 'overall', 'meanwhile',
  // Ordinary report vocabulary this product's own narratives use to open a sentence.
  'revenue', 'customers', 'customer', 'visits', 'visit', 'sales', 'trade', 'repeat', 'new',
  'returning', 'loyal', 'lapsed', 'most', 'many', 'some', 'few', 'no', 'none', 'only', 'about',
  'roughly', 'around', 'nearly', 'almost', 'compared', 'versus', 'weekday', 'weekend', 'morning',
  'afternoon', 'evening',
]);
// Harvested once (see the block comment above) from tests/ai-reports/fixtures/golden-packs/
// {01-normal,02-sparse,03-high-anonymous,04-unavailable-sections,05-whale,06-adversarial}-firm.json
// ("good" field) and tests/ai-reports/v677-evidence-safe-generation.test.mjs's FAITHFUL constant,
// 2026-09-02, THEN PRUNED (2026-09-02, same day) of every word that is itself present in any of
// those same packs' evidence strings (case-insensitive substring, matching condition (a)'s own
// test): "chen", "cruz", "high", "kaya", "mystery", "odd", "one", "only", "revenue", "sales",
// "sparse", "tan", "the", "unavail", "whale", "with", "wong" were removed by that rule (several are
// fixture proper nouns — customer/business/item names; "revenue"/"sales"/"the"/"only"/"with"/"one"
// survive anyway via COMMON_SENTENCE_STARTERS_HAND above, which lists them for their own,
// fixture-independent reason, not because they were harvested). Re-run the harvest-then-prune pass
// and re-paste if either corpus's known-good narratives change.
const COMMON_SENTENCE_STARTERS_HARVESTED = new Set([
  'about', 'account', 'ask', 'build', 'check', 'confirm', 'double', 'keep', 'put', 'review',
  'saturday', 'send', 'that', 'track', 'tracked', 'tuesday', 'watch', 'your',
]);
// Check 88 (false-positive round 4): a refuter proved the hand-built + harvested lists above are
// still too narrow — ordinary English discourse/function words that open a sentence all the time
// in prose of this shape ("There were more visits this month.", "Regulars returned sooner.") were
// simply never on either list, because both were built by watching THIS product's own six fixed
// golden narratives rather than by naming the general vocabulary a report legitimately opens a
// sentence with. Two more sets, kept separate from the hand-built/harvested ones above so each
// one's own provenance stays legible (a discourse word is a fact about English; a product-noun is
// a fact about Peekaa; neither was harvested from a fixture and pruned the way
// COMMON_SENTENCE_STARTERS_HARVESTED was):
//   BROAD_DISCOURSE_STARTERS - ordinary transition/discourse/quantifier words ("there", "here",
//   "then", "however", "finally", "please", "consider", ...) that open a sentence in any register
//   of plain English, independent of this product's own vocabulary.
//   PRODUCT_VOCABULARY (exported - check 88 names it as a first-class list of its own, not merely
//   folded silently in here) - the concrete nouns this product's OWN reports use constantly
//   ("customers", "stamps", "tiers", "referrals", "branch", ...). A report that opens a sentence
//   with one of these is talking about the business, not naming an invented person.
// Both stay honestly narrow: a genuinely invented name ("Melissa", "Marcus") is not on either list,
// so "Melissa spent more than usual this month." is still caught exactly as before - these two
// lists only ever REMOVE a false positive, they add no new blind spot for a fabricated proper noun.
const BROAD_DISCOURSE_STARTERS = new Set([
  'there', 'here', 'these', 'those', 'this', 'that', 'then', 'next', 'also', 'still', 'yet',
  'however', 'overall', 'meanwhile', 'finally', 'first', 'second', 'third', 'last', 'later',
  'earlier', 'today', 'yesterday', 'tomorrow', 'currently', 'recently', 'now', 'again', 'instead',
  'otherwise', 'likewise', 'similarly', 'notably', 'importantly', 'unfortunately',
  'encouragingly', 'together', 'both', 'each', 'either', 'neither', 'none', 'nobody', 'everyone',
  'anyone', 'someone', 'something', 'nothing', 'everything', 'please', 'consider', 'note',
  'remember', 'keep', 'focus', 'expect', 'plan', 'try', 'watch', 'avoid', 'protect', 'reward',
  'invite', 'ask', 'offer', 'thank',
]);
export const PRODUCT_VOCABULARY = new Set([
  'regulars', 'customers', 'clients', 'visits', 'visitors', 'stamps', 'stamp', 'tiers', 'tier',
  'rewards', 'reward', 'redemptions', 'referrals', 'referral', 'bookings', 'booking',
  'appointments', 'staff', 'branch', 'branches', 'package', 'packages', 'sessions', 'campaigns',
  'campaign', 'promotions', 'promotion', 'discounts', 'discount', 'members', 'membership',
  'loyalty', 'points', 'gift', 'gifts', 'vouchers', 'newcomers', 'lapsed', 'returning',
  'identified', 'anonymous', 'weekday', 'weekend', 'mornings', 'afternoons', 'evenings', 'peak',
  'quiet',
]);
// Numbers spelled as words ("One returned visit...") and month/weekday names (independent of V2's
// own case-sensitive month check — different purpose, same words), lower-cased, reusing this
// file's existing single source of truth for each list rather than retyping them.
const COMMON_SENTENCE_STARTERS = new Set([
  ...COMMON_SENTENCE_STARTERS_HAND,
  ...COMMON_SENTENCE_STARTERS_HARVESTED,
  ...BROAD_DISCOURSE_STARTERS,
  ...PRODUCT_VOCABULARY,
  ...Object.keys(NUM_WORDS),
  ...Object.keys(TENS_WORDS),
  'hundred', 'thousand',
  ...MONTHS.flatMap(([full, abbr]) => (full === abbr ? [full] : [full, abbr])),
  ...DAY_NAMES,
]);

// Check 17/88 (false-positive fix): a sentence-initial modal is not always a naming claim's
// missing subject - "Will you visit us again this month?" is an ordinary QUESTION, and "Will"
// there is the modal auxiliary, not an invented person. Scoped narrowly on purpose: ONLY these
// eleven modal/auxiliary words, ONLY when one of a fixed set of question subjects follows within
// two tokens. "Will Marcus visit again?" still needs a different subject to read as interrogative
// under this rule and is NOT exempted by it - it falls back to V9b's ordinary judgement of
// "Marcus" (a separate, later token in that sentence), same as today.
const INTERROGATIVE_MODALS = new Set([
  'will', 'would', 'could', 'should', 'can', 'may', 'might', 'do', 'does', 'did', 'is', 'are',
]);
const INTERROGATIVE_SUBJECT_RE =
  /^\s*(?:[A-Za-z']+\s+){0,2}(?:you|we|they|customers?|clients?|it|this)\b/i;

function isInterrogativeModalOpening(narrative, tok) {
  if (!INTERROGATIVE_MODALS.has(tok.word.toLowerCase())) return false;
  const after = narrative.slice(tok.end, tok.end + 40);
  return INTERROGATIVE_SUBJECT_RE.test(after);
}

function checkOrphanProperNounsSentenceInitial(narrative, packInfo, violations, opts) {
  const allowlist = buildOrphanAllowlist(opts);
  const ranges = orphanSkipRanges(narrative);
  const haystackLower = packInfo.strings.join(' ').toLowerCase(); // case-INSENSITIVE, see banner
  // Check 88 (false-positive round 4): the pack's own field NAMES, not only its values - joined the
  // SAME way haystackLower joins string VALUES, and tested the SAME way (substring, case-
  // insensitive) so a sentence opening "Returning customers made up..." grounds against the key
  // `insights.retention.returning_customers` even though the word "returning" never appears as a
  // pack STRING value anywhere. Kept as its own haystack (not merged into haystackLower) because a
  // key is grounding a WORD the pack's own schema uses, not a fact the pack asserts.
  const keysLower = packInfo.keys ? [...packInfo.keys].join(' ') : '';
  const words = orphanWords(narrative);
  const reported = new Set();

  for (let i = 0; i < words.length; i += 1) {
    const tok = words[i];
    if (!isCapitalisedCandidate(tok.word)) continue;
    if (inOrphanSkipRange(ranges, tok.index)) continue;              // heading/code lines
    if (hasCapitalisedRunPartner(narrative, words, i, allowlist)) continue; // (d), still V6's territory
    if (!isOrphanSentenceInitial(narrative, tok.index)) continue;    // V9b only judges what V9 skips
    if (isInterrogativeModalOpening(narrative, tok)) continue;       // check 17/88: a question, not a name
    if (allowlist.has(tok.word)) continue;                           // (b)
    const plain = tok.word.toLowerCase();
    if (COMMON_SENTENCE_STARTERS.has(plain)) continue;                // (c)
    if (haystackLower.includes(plain)) continue;                     // (a)
    if (keysLower.includes(plain)) continue;                         // (a), the pack's own KEYS
    if (reported.has(plain)) continue;
    reported.add(plain);
    violations.push({
      rule: RULES.ENTITY,
      detail: `V9b: "${tok.word}" opens a sentence, is capitalised, is not a common sentence-` +
        `starter word, and matches no evidence-pack string (case-insensitive); check it is not ` +
        `an invented name, near "${contextAround(narrative, tok.index, tok.end)}"`,
    });
  }
}

/* ----------------------------------------------------------- V11: CJK entities */

// Check 88 (tokeniser gap #4): every rule above - V6, V9, V9b - is built on a LATIN-script idea of
// "capitalised". A CJK name ("美玲") has no case at all, so it is invisible to all of them: it
// never matches NAME_TOKEN_RE, CAPITALISED_TOKEN_RE, or any allowlist built around Latin letters.
// This is not a shape bug to widen the existing regexes for - a script with no capitalisation
// needs its own, independent test, not a capitalisation test taught to ignore capitalisation.
//
// V11 fires on any RUN of two or more Han, Hangul, Hiragana or Katakana characters that does not
// appear, verbatim, anywhere among the pack's own string leaves - the same "found in the pack"
// grounding principle V6/V9 already use, applied to a different alphabet. Unicode script property
// escapes (\p{Script=Han} etc, with the `u` flag) are used rather than a fixed code-point range so
// this does not silently drift as Unicode adds characters to those scripts.
//
// HONEST LIMIT, declared rather than hidden: a run of 2+ characters is the floor this rule can
// reason about. A ONE-character CJK name (a real, if less common, shape - a single-character
// Chinese given name) is indistinguishable from a one-character common word or particle without a
// name database, the same limit V6's own banner already states for Latin script; a single
// character therefore never fires V11, by design, not by oversight.
//
// (check 88, round 3): grounding used to be a raw SUBSTRING test (`haystack.includes(run)`), and a
// refuter proved that collides two different people who share characters. A pack customer named
// "陈美玲" grounds ANY substring of it under the old test, including "美玲" written in the narrative
// to mean a DIFFERENT person the pack never names - the narrative's own run is real Chinese text,
// two-plus Han characters, invented as far as the pack is concerned, and the substring test passed
// it clean anyway. Grounding is now a WHOLE-TOKEN match against the set of CJK runs the pack's own
// strings actually contain (buildCjkTokenSet, below) - "美玲" is only grounded when the pack itself
// contains "美玲" as its own bounded run (equal to a whole pack string, or bounded by non-CJK
// characters/string edges on both sides within a pack string), not merely as a piece of a longer
// pack run like "陈美玲".
//
// HONEST LIMIT, declared rather than hidden, because whole-token matching is stricter than the old
// substring test in the OTHER direction too: this file has no way to know that "美玲" in the
// narrative and "陈美玲" in the pack denote the SAME real person (a nickname, a given-name-only
// reference, a family name dropped in casual prose) versus two different people who happen to
// share the same two characters. Firing on a genuine same-person nickname reference costs a
// regenerated report - the same asymmetry as every other rule in this file - and is accepted
// deliberately rather than reverting to the substring test that let a genuinely different,
// invented person hide behind a real one's name.
const CJK_RUN_RE = /[\p{Script=Han}\p{Script=Hangul}\p{Script=Hiragana}\p{Script=Katakana}]{2,}/gu;

// The pack's own CJK runs, extracted the same way CJK_RUN_RE finds them in a narrative: a maximal
// run of 2+ Han/Hangul/Kana characters, bounded by non-CJK characters or the string's own edges.
// Reusing CJK_RUN_RE against each pack string leaf means "a whole pack string" and "a run bounded
// by non-CJK on both sides within a longer pack string" are the SAME extraction - there is no
// separate boundary-finding logic to keep in step with the one the regex already expresses.
function buildCjkTokenSet(strings) {
  const tokens = new Set();
  for (const s of strings) {
    CJK_RUN_RE.lastIndex = 0;
    let hit;
    while ((hit = CJK_RUN_RE.exec(s)) !== null) tokens.add(hit[0]);
  }
  return tokens;
}

function checkCjkEntities(narrative, packInfo, violations) {
  const packCjkTokens = buildCjkTokenSet(packInfo.strings);
  const reported = new Set();
  CJK_RUN_RE.lastIndex = 0;
  let m;
  while ((m = CJK_RUN_RE.exec(narrative)) !== null) {
    const run = m[0];
    if (packCjkTokens.has(run)) continue;
    if (reported.has(run)) continue;
    reported.add(run);
    violations.push({
      rule: RULES.ENTITY,
      detail: `V11: "${run}" is a run of 2+ Han/Hangul/Kana characters naming a person or entity ` +
        `but matches no whole CJK token in the evidence pack (a single-character name, and a ` +
        `narrative nickname that is a true substring of a longer pack name, are known limits of ` +
        `this check - see the file's own note on CJK), near ` +
        `"${contextAround(narrative, m.index, m.index + run.length)}"`,
    });
  }
}

/* --------------------------------------------------------- V11b: caseless-script entities */

// Check 88 (tokeniser gap #5). V11 (above) closes the CJK case, but Han/Hangul/Hiragana/Katakana
// are not the only scripts with no letter case: Thai ("สมชาย"), Arabic, Devanagari, Tamil, Bengali,
// Hebrew and others have none either, and none of V6/V9/V9b/V11's tests catch a name in any of
// them - V6/V9/V9b look for a Latin capital letter, V11 looks for a Han/Hangul/Kana run, and a
// Thai or Arabic word matches neither.
//
// V11b fires on a RUN OF 3+ letters (or combining marks, so a base letter plus its own attached
// vowel/tone sign in a script like Thai counts as one run, not several) that is NOT Latin, Han,
// Hangul, Hiragana or Katakana script (the negated check the task itself sanctions as an
// alternative to naming every caseless script individually) and does not appear, verbatim,
// anywhere among the pack's own string leaves - the same "found in the pack" grounding principle
// V6/V9/V11 already use.
//
// GATED to a narrative that is PREDOMINANTLY LATIN-SCRIPT (>=80% of its own letters): this
// product's reports are written in English, so a name from a caseless script sitting inside an
// otherwise-English report is exactly the shape V6/V9's Latin-capitalisation tests were built to
// catch and structurally cannot. A narrative that is NOT predominantly Latin - i.e. one actually
// WRITTEN in Thai, Tamil, Arabic etc, a declared product goal (CLAUDE.md: "EN/ZH/MS/TA") - is a
// different problem V11b does not attempt: this file has no pack-grounded vocabulary for those
// languages' own ORDINARY words (the same "no name database" limit V6's own banner states for
// Latin script), so a blanket "any caseless-script run not in the pack" test over a wholly Tamil
// or Thai narrative would flag the narrative's own ordinary prose, not an invented name.
//
// HONEST LIMIT, declared rather than hidden: a Tamil (or Thai, Arabic, ...) narrative disables V11b
// entirely, by the 80% gate above. Shipping AI reports in those languages - a real product goal,
// not a hypothetical - will need its own pack-grounded vocabulary (a list of ordinary words in that
// language this file can treat the way STOPWORDS treats English) before V11b, or something like
// it, can apply to them. That work is not done here and is not pretended to be.
const ANY_LETTER_RE = /\p{L}/gu;
const LATIN_LETTER_RE = /\p{Script=Latin}/gu;
const LATIN_SCRIPT_THRESHOLD = 0.8;

function isPredominantlyLatinScript(narrative) {
  const totalLetters = (narrative.match(ANY_LETTER_RE) || []).length;
  if (totalLetters === 0) return false;
  const latinLetters = (narrative.match(LATIN_LETTER_RE) || []).length;
  return latinLetters / totalLetters >= LATIN_SCRIPT_THRESHOLD;
}

const CASELESS_SCRIPT_RUN_RE =
  /(?:(?!\p{Script=Latin})(?!\p{Script=Han})(?!\p{Script=Hangul})(?!\p{Script=Hiragana})(?!\p{Script=Katakana})[\p{L}\p{M}]){3,}/gu;

function checkCaselessScriptEntities(narrative, packInfo, violations) {
  if (!isPredominantlyLatinScript(narrative)) return; // declared limit — see the note above
  const haystack = packInfo.strings.join('\n');
  const reported = new Set();
  CASELESS_SCRIPT_RUN_RE.lastIndex = 0;
  let m;
  while ((m = CASELESS_SCRIPT_RUN_RE.exec(narrative)) !== null) {
    const run = m[0];
    if (haystack.includes(run)) continue;
    if (reported.has(run)) continue;
    reported.add(run);
    violations.push({
      rule: RULES.ENTITY,
      detail: `V11b: "${run}" is a run of 3+ letters in a non-Latin, non-CJK script (e.g. Thai, ` +
        `Arabic, Devanagari, Tamil, Bengali, Hebrew) but appears nowhere in the evidence pack ` +
        `(this check only applies when the narrative is predominantly Latin-script - see the ` +
        `file's own note on caseless scripts), near ` +
        `"${contextAround(narrative, m.index, m.index + run.length)}"`,
    });
  }
}

/* -------------------------------------------------------------- V7: structure */

// Check 82: the report is a fixed template, not free-form prose. SYSTEM_PROMPT (index.ts) spells
// out five headings in this exact order, and "exactly three numbered actions" under the last one.
// This checks the OUTPUT against that spec — a prompt asking for structure is not a guarantee of
// structure, same rationale as every other rule in this file.
const REQUIRED_HEADINGS = [
  '## Summary',
  '## What went well',
  '## What needs attention',
  '## Your customers',
  '## Do these three things next',
];

// (check 82, gap closed) The old version of this check used `narrative.indexOf(heading)` — a bare
// SUBSTRING search, not a search over actual level-2 heading LINES. That has two holes at once:
// (1) an injected heading the model was never asked for ("## Sponsored by BrewCo") was invisible —
//     nothing here ever looked at what OTHER `## ` lines exist, only whether the five required
//     strings happen to appear somewhere in the document; (2) a required heading's text embedded
//     mid-sentence, not as its own heading line, would satisfy indexOf() without the report having
//     that section at all.
// Fixed by reading every ACTUAL level-2 heading line (`^##[ \t]+...$`, which does not match `###`
// or deeper — a line starting "###" has a third "#" immediately after "##", not a space/tab, so
// the regex below never matches it) and requiring the found set to equal REQUIRED_HEADINGS EXACTLY:
// same five headings, in the same order, nothing extra. An injected "## Sponsored ..." now fails on
// its own heading text (not one of the five); a required heading rewritten even slightly ("##
// Summary!") now fails BOTH as "missing" (its exact text is absent) and as "unexpected" (the
// rewritten line is not one of the five) — the double signal is deliberate, not a bug, and matches
// this file's own asymmetry: a false positive here costs a regenerated report, not a wrong one.
const HEADING_LINE_RE = /^##[ \t]+(.+?)[ \t]*$/gm;

// (check 82, subsections) SYSTEM_PROMPT (index.ts) never asks for a THIRD-level heading anywhere —
// it defines exactly five level-2 sections and, under the last one, three numbered list items. The
// v179/v684 evidence pack has no field that declares a section's own subsections either (no
// `subsections` key on any of the five, checked against readPack.keys below), so there is nothing
// for a model-written H3 to legitimately be ABOUT. Given that, this file makes the conservative
// choice explicitly rather than leaving the gap open: H3 (or deeper) is FORBIDDEN outright, not
// "allowed only when the pack declares subsections" — because today the pack never does, so the
// two policies are behaviourally identical, and forbidding outright is simpler to audit than a
// conditional gate on a key that does not exist. If a future pack version adds a per-section
// `subsections` declaration, this comment (and the check below) is where that conditional belongs —
// it is not implemented here because implementing a gate against a key nothing ever sets would be
// coverage theatre, the same reasoning the file applies everywhere else (e.g. checkCausal's
// currently-shut opts.causalEvidence door).
const SUBHEADING_LINE_RE = /^#{3,6}[ \t]+.*$/gm;

function checkStructure(narrative, violations) {
  const found = [];
  HEADING_LINE_RE.lastIndex = 0;
  let hm;
  while ((hm = HEADING_LINE_RE.exec(narrative)) !== null) {
    found.push({ text: `## ${hm[1].trim()}`, index: hm.index });
  }
  const requiredSet = new Set(REQUIRED_HEADINGS);

  // Missing: a required heading whose exact text never appears as its own heading line.
  for (const heading of REQUIRED_HEADINGS) {
    if (found.some((f) => f.text === heading)) continue;
    violations.push({
      rule: RULES.STRUCTURE,
      detail: `required heading "${heading}" is missing from the report`,
    });
  }

  // Unexpected: any level-2 heading line that is not one of the five required headings — this is
  // what catches an injected "## Sponsored by BrewCo" that substring-matching used to miss entirely.
  for (const f of found) {
    if (requiredSet.has(f.text)) continue;
    violations.push({
      rule: RULES.STRUCTURE,
      detail: `heading "${f.text}" is not one of the report's five required headings`,
    });
  }

  // Duplicate: a required heading repeated is still wrong even though its text is exact — each of
  // the five must appear exactly once.
  const requiredCounts = new Map();
  for (const f of found) {
    if (!requiredSet.has(f.text)) continue;
    requiredCounts.set(f.text, (requiredCounts.get(f.text) || 0) + 1);
  }
  for (const [heading, count] of requiredCounts) {
    if (count <= 1) continue;
    violations.push({
      rule: RULES.STRUCTURE,
      detail: `required heading "${heading}" appears ${count} times; it must appear exactly once`,
    });
  }

  // Out of order: same pairwise check as before, now driven off the exact heading-line index
  // (first occurrence) rather than a substring search.
  const positions = REQUIRED_HEADINGS.map((heading) => {
    const hit = found.find((f) => f.text === heading);
    return hit ? hit.index : -1;
  });
  for (let i = 1; i < positions.length; i += 1) {
    if (positions[i] === -1 || positions[i - 1] === -1) continue;
    if (positions[i] <= positions[i - 1]) {
      violations.push({
        rule: RULES.STRUCTURE,
        detail: `heading "${REQUIRED_HEADINGS[i]}" must come after "${REQUIRED_HEADINGS[i - 1]}" ` +
          `but appears out of order`,
      });
    }
  }

  // Check 82 (subsections): H3+ is forbidden outright — see SUBHEADING_LINE_RE's own note above for
  // why "allowed only when the pack declares subsections" and "forbidden" are the same policy today.
  SUBHEADING_LINE_RE.lastIndex = 0;
  let sm;
  while ((sm = SUBHEADING_LINE_RE.exec(narrative)) !== null) {
    violations.push({
      rule: RULES.STRUCTURE,
      detail: `heading "${sm[0].trim()}" is a level-3-or-deeper heading; the report's five ` +
        `required headings declare no subsections and none are permitted`,
    });
  }

  const lastIdx = positions[positions.length - 1];
  if (lastIdx === -1) return;
  const lastHeading = REQUIRED_HEADINGS[REQUIRED_HEADINGS.length - 1];
  const rest = narrative.slice(lastIdx + lastHeading.length);
  const nextHeading = /^[ \t]*#{1,6}[ \t]/m.exec(rest);
  const section = nextHeading ? rest.slice(0, nextHeading.index) : rest;
  const items = section.match(/^[ \t]*\d{1,2}[.)][ \t]+\S/gm) || [];
  if (items.length !== 3) {
    violations.push({
      rule: RULES.STRUCTURE,
      detail: `"${lastHeading}" must have exactly three numbered actions, found ${items.length}`,
    });
  }
}

/* -------------------------------------------------------------- entry point */

/**
 * Validate one model-written narrative against the evidence pack it was given.
 *
 * @param {string} narrativeMd   the markdown the model returned
 * @param {object} evidencePack  the SAME object handed to the model (app.v176_evidence_pack)
 * @param {object} [opts]        { causalEvidence?: boolean, allowStrongClaims?: boolean,
 *                                 confidenceClass?: string, entityAllowlist?: string[] }
 *                               entityAllowlist extends V9's conservative orphan-proper-noun
 *                               allowlist (checkOrphanProperNouns, below) for a business/report
 *                               shape this file cannot anticipate on its own.
 * @returns {{ok: boolean, violations: Array<{rule: string, detail: string}>}}
 */
export function validateNarrative(narrativeMd, evidencePack, opts = {}) {
  const violations = [];
  // v707 (check 88, tokeniser gap #4): NFKC-normalise the narrative before ANY check runs, so a
  // fullwidth character a model may write (U+FF0F fullwidth solidus, "Tan／Wong"; fullwidth digits,
  // parens, etc) collapses to its ordinary ASCII form before every regex above ever sees it -
  // v705/v706 already taught the tokeniser to split "Tan/Wong" on an ASCII slash; a fullwidth one
  // was invisible to that fix for the same reason a fullwidth digit is invisible to NUMBER_TOKEN_RE.
  // Offsets stay meaningful because every check that uses one (contextAround, maskStructuralNumbers)
  // slices THIS SAME normalised string - there is no second, unnormalised copy to keep in step with
  // it, so mapping back to the model's raw bytes is deliberately not attempted (the file's own
  // check-88 notes already treat "violations name tokens, not offsets" as the working contract).
  const narrative = typeof narrativeMd === 'string' ? narrativeMd.normalize('NFKC') : '';
  const pack = evidencePack && typeof evidencePack === 'object' ? evidencePack : {};
  const options = opts && typeof opts === 'object' ? opts : {};

  if (!narrative.trim()) {
    return { ok: false, violations: [{ rule: RULES.NUMERIC, detail: 'empty narrative' }] };
  }

  const packInfo = readPack(pack);
  const derivedPct = derivedPercentages(packInfo.objects);

  // V1
  const { tokens, grounded, wordTokens, wordGrounded } = groundNumbers(narrative, packInfo, derivedPct);
  for (let i = 0; i < tokens.length; i += 1) {
    if (grounded[i]) continue;
    const tok = tokens[i];
    violations.push({
      rule: RULES.NUMERIC,
      detail: `${tok.value} (written "${tok.raw.trim()}") is not in the evidence pack, near ` +
        `"${contextAround(narrative, tok.index, tok.end)}"`,
    });
  }
  for (let i = 0; i < wordTokens.length; i += 1) {
    if (wordGrounded[i]) continue;
    const tok = wordTokens[i];
    violations.push({
      rule: RULES.NUMERIC,
      detail: `${tok.value} (written "${tok.raw.trim()}") is not in the evidence pack, near ` +
        `"${contextAround(narrative, tok.index, tok.end)}"`,
    });
  }

  checkPopulation(narrative, pack, violations);         // V2
  checkBranch(narrative, pack, violations);             // V2 (check 84)
  checkLowercaseMonthClauseStart(narrative, pack, violations); // V2 (check 84)
  checkCausal(narrative, options, violations);          // V3
  checkConfidence(narrative, options, violations);      // V4
  checkConfidenceTier(narrative, pack, options, violations); // V4 (check 86)
  checkLimitations(narrative, pack, violations);        // V5
  checkLimitationItems(narrative, pack, violations);    // V5 (check 87)
  checkEntities(narrative, packInfo, violations);       // V6
  checkSingleTokenEntities(narrative, packInfo, violations); // V6 (check 83/88)
  checkOrphanProperNouns(narrative, packInfo, violations, options); // V9 (check 83/88 gap closure)
  checkOrphanProperNounsSentenceInitial(narrative, packInfo, violations, options); // V9b (sentence-initial gap)
  checkCjkEntities(narrative, packInfo, violations);    // V11 (check 88, CJK/Hangul/Kana gap)
  checkCaselessScriptEntities(narrative, packInfo, violations); // V11b (check 88, caseless-script gap)
  checkStructure(narrative, violations);                // V7 (check 82)
  checkCohortContradiction(narrative, pack, violations); // V8 (check 89)
  checkAssociationCausalBinding(narrative, packInfo, violations); // V10 (check 17, causal blacklist, second line)
  checkAssociationPositiveMarker(narrative, packInfo, violations); // V10b (check 17, positive marker, primary)

  return { ok: violations.length === 0, violations };
}

/* ------------------------------------------- advisory: cohort label bindings */

// CHECK 89 (cross-report contradiction), honestly scoped.
//
// A general contradiction detector between two free-text narratives is not something this file can
// do without inventing semantics, and inventing it would be coverage theatre. What IS deterministic
// is the binding between a COUNT and the COHORT LABEL it is attached to: the v179 pack defines
// at_risk.customers, retention.new_customers and retention.returning_customers as disjoint,
// separately computed quantities. If one report says "4 customers are at risk" and another says
// "4 loyal regulars", at most one can be right, and the pack decides which.
//
// classifyCohortMentions itself stays exported and ADVISORY — general phrase coverage is still
// thin, so its full output is not something validateNarrative should fail a report on wholesale.
// v684 (check 89) wires ONE narrow slice of it into the hard verdict as V8, below: a claimed count
// that does not match its own cohort but DOES match a DIFFERENT tracked cohort's count exactly.
// That specific shape — "4 loyal regulars" when returning_customers is 5 but at_risk.customers is
// 4 — cannot be explained by phrasing noise; the number the model wrote belongs to a cohort it
// didn't name. Anything looser than that (inconsistent but matching nothing else) still abstains.
// Each pattern binds a COUNT to a COHORT only when the cohort's cue follows the number within a
// few words. Anything looser mis-binds: "4 regulars with 2 or more past visits have not been seen
// for 45 to 180 days" offers three numbers and only one of them is the cohort's size. When the
// wording is ambiguous this ABSTAINS rather than guessing - a classifier that guesses would
// manufacture contradictions that are artefacts of its own parser.
const COHORT_PHRASES = [
  {
    cohort: 'at_risk',
    path: ['insights', 'at_risk', 'customers'],
    re: /(\d[\d,]*)\s+(?:\w+\s+){0,4}?(?:at[- ]risk|slipping away|slipped away|stopped coming|lapsed|not been seen)/i,
  },
  {
    cohort: 'returning_customers',
    path: ['insights', 'retention', 'returning_customers'],
    re: /(\d[\d,]*)\s+(?:\w+\s+){0,4}?(?:loyal regulars?|returning customers?|came back|returned)/i,
  },
  {
    cohort: 'new_customers',
    path: ['insights', 'retention', 'new_customers'],
    re: /(\d[\d,]*)\s+(?:\w+\s+){0,4}?new customers?/i,
  },
  // Check 89 (nestly_v684_metric_dictionary, db/migrations/20260920_nestly_v684_metric_dictionary.sql
  // -> app.ci_customer_classes_v1): the dictionary defines five DISJOINT-by-construction classes -
  // loyal, frequent, retained, high_ltv, at_risk. The three entries above already cover at_risk and
  // the loyal/returning vocabulary (the "loyal regulars?" alternative in returning_customers' own
  // regex). Only `frequent` and the dictionary's `high_ltv` class (this cohort's own English word is
  // "valuable" - "4 valuable customers", never the machine slug) were undeclared here, so a claimed
  // count for either cohort could silently match a DIFFERENT tracked cohort's number and nothing
  // caught it - the exact gap checkCohortContradiction exists to close for every other cohort.
  // PACK PATH, honestly noted: app.ci_customer_classes_v1 returns per-CUSTOMER booleans
  // (classes.frequent, classes.high_ltv), not a business-wide COUNT the way insights.at_risk.
  // customers or insights.retention.new_customers already are - no AI-report evidence-pack reader
  // aggregates either class into a count yet. The paths below follow the exact naming convention
  // the three cohorts above already use (insights.retention.<cohort>_customers) for the day a reader
  // does add that aggregate; until then this entry simply never binds (readPath returns undefined,
  // classifyCohortMentions abstains, same as any other cohort phrase whose path resolves to nothing)
  // - it does not fabricate a number to check against, only widens the vocabulary the moment the
  // pack starts carrying one.
  {
    cohort: 'frequent_customers',
    path: ['insights', 'retention', 'frequent_customers'],
    re: /(\d[\d,]*)\s+(?:\w+\s+){0,4}?frequent (?:customers?|shoppers?|visitors?|regulars?)/i,
  },
  {
    // "valuable" is this file's English rendering of the dictionary's `high_ltv` class (a customer
    // at/above the business's own 80th percentile of lifetime spend) - the cohort's machine slug is
    // never the word a narrative would use.
    cohort: 'high_ltv_customers',
    path: ['insights', 'retention', 'high_ltv_customers'],
    re: /(\d[\d,]*)\s+(?:\w+\s+){0,4}?(?:valuable|high[- ]spending|high[- ]ltv|top[- ]spending) customers?/i,
  },
];

function readPath(pack, path) {
  let node = pack;
  for (const key of path) {
    if (!node || typeof node !== 'object') return undefined;
    node = node[key];
  }
  return typeof node === 'number' ? node : undefined;
}

/**
 * Report every "<count> ... <cohort label>" binding the narrative makes, and whether the count
 * matches the pack's own figure for that cohort.
 *
 * @returns {Array<{cohort: string, claimed: number, expected: number|undefined,
 *                  consistent: boolean, context: string}>}
 */
export function classifyCohortMentions(narrativeMd, evidencePack) {
  const narrative = typeof narrativeMd === 'string' ? narrativeMd : '';
  const pack = evidencePack && typeof evidencePack === 'object' ? evidencePack : {};
  const out = [];
  for (const sentence of sentencesOf(narrative)) {
    for (const { cohort, path, re } of COHORT_PHRASES) {
      const hit = re.exec(sentence);
      if (!hit) continue;
      const claimed = Number(hit[1].replace(/,/g, ''));
      if (!Number.isFinite(claimed)) continue;
      const expected = readPath(pack, path);
      out.push({
        cohort,
        claimed,
        expected,
        consistent: expected !== undefined && claimed === expected,
        context: sentence.slice(0, 90),
      });
    }
  }
  return out;
}

/* --------------------------------------- V10: causal language tied to ASSOCIATION findings */

// Check 17 (typed verdicts, narrative half). v693/v695/v696 tag each finding a reader or the
// spine emits with its own evidence_class: 'DIRECT_FACT' | 'ASSOCIATION' (never 'CAUSAL' - see
// v696's app.ci_verdict_class_v696, whose only two branches are those two strings, and whose
// ELSE branch raises rather than shipping a third). V3 above already refuses a short, fixed list
// of causal verbs/adverbs UNCONDITIONALLY, anywhere in the narrative, regardless of what backs
// them - that rule is untouched by this one. V10 is a SEPARATE, narrower rule: it does not care
// whether the narrative uses causal wording in general; it cares whether a sentence writes a
// causal construction ABOUT a finding the pack itself has already classed as ASSOCIATION - the
// shape "customers who X also tend to Y" (observed) rewritten as "X causes/leads to Y" (asserted).
// A DIRECT_FACT finding may be stated flatly (v696's own note for that bucket: "built from this
// business's own recorded facts"), so this rule never looks at those, and a CAUSAL class never
// ships at all, so there is nothing to exempt for it.
//
// GENERIC BY DESIGN, on purpose - this file has no fixed list of finding shapes to expect. It
// walks the WHOLE pack once (readPack has already done that walk; this reuses its own `objects`
// list, the same list V1's derivedPercentages reuses, rather than a second traversal) and treats
// ANY plain object carrying its own string `evidence_class` as a "finding" - no matter which
// reader or spine generator produced it, and with no assumption about what ELSE that object
// carries. The finding's identifying text is whichever of `label`, `pattern`, `name` it has
// (checked in that order; a finding may carry more than one, and every one it has contributes
// keywords). `id` is deliberately NOT used for matching - ids are machine slugs
// ('lapsed_regulars'), not English a narrative would ever echo back.
//
// ENTITY MATCH, conservatively - reusing this file's own sentence tokeniser (sentencesOf, the
// same primitive V2/V5/V6/V9 already build their own sentence-scoped checks on) and its STOPWORDS
// set (the same set V6's nameCandidates already uses to decide what is "just an ordinary word").
// A finding's identifying text is reduced to its "significant" words: split on non-letters,
// lower-cased, kept only when 4+ letters and not a stopword. A sentence is judged to be "about" a
// finding when it contains at least two such words (or the finding's only one, if it has just
// one) - requiring more than one word where possible is the same trade this file makes
// everywhere else (V6's two-token run, V9's multi-signal gate): a single common word appearing
// near an unrelated causal sentence is not enough to accuse the narrative of misstating THIS
// finding.
//
// HONEST LIMITS. A finding whose identifying text is entirely short words (<4 letters) or entirely
// stopwords contributes no keywords and can never be matched - this rule silently abstains for it;
// V3's own unconditional causal gate is still the backstop for the bare PRESENCE of causal
// language regardless of entity. A paraphrase that describes the SAME finding using none of its
// own keywords is invisible here for the same reason V6's entity grounding cannot catch a fully
// invented name with no resemblance to anything in the pack - there is no way to bind free English
// prose to a machine record without a shared vocabulary between them. And the causal-construction
// list below is fixed and cannot enumerate every way English expresses causation; it is not meant
// to replace V3, only to narrow one specific, checkable slice of it to the right findings.
//
// v707 (check 17, round 2): this used to be V10's OWN short list (V10_CAUSAL_RE), separate from
// V10b's approved-marker list below. A refuter proved that split let a sentence launder a causal
// claim past V10b simply by ALSO carrying an approved marker ("we observe that weekends make
// customers return") - V10b's own blacklist-free design means it never looked for a causal
// construction at all, so nothing stopped the marker from covering for it. CAUSAL_CONSTRUCTIONS is
// now the ONE list both V10 and V10b test against - V10's original phrases plus every idiom a prior
// refuter proved could evade a narrower list (see v706's own note, preserved below the marker list)
// - so the two rules can never quietly diverge on what counts as a causal construction, the same
// discipline this file already applies to "what counts as a finding" (typedFindings, below).
//
// (check 17, round 3): a THIRD refuter proved a still-narrower gap in the list above: several
// entries only matched ONE inflection of an ordinary English verb or a single fixed copula, so a
// plain tense change or number change slipped past clean - "It appears to be the case that weekend
// visits ARE WHY customers come back sooner" evaded the old bare /\bis\s+why\b/i entirely (the
// copula was "are", not "is"), and nothing on the list caught "accounted for" (only "accounts for"),
// "explained" (only "explains"), "produces" without "produced", "led to" without only "leads to",
// and several more of the same shape. Every entry that was a FIXED copula ("is X") or a single
// verb inflection is now generalised to every ordinary inflection of the same construction
// (present/past/participle, singular/plural, is/are/was/were) - not a new idiom, the SAME idiom
// written the way English actually conjugates it. A round-3 refuter also proved a causal
// construction the prompt explicitly forbids (EVIDENCE_CLASS_INSTRUCTION's own "if you keep X, Y
// will...") was never actually CHECKED here: a conditional ("if you keep pushing weekend visits,
// returns may rise") and the "the more X, the more/faster/sooner Y" comparative construction both
// state a cause without using any word on the list above. Both are added below, narrowly - the
// conditional only fires when the modal sits within a short window of the "if you/we/they keep/
// continue/stop/start/push/run" opener, so an unrelated "if" elsewhere in the sentence is not
// swept in.
export const CAUSAL_CONSTRUCTIONS = [
  // The original V10 blacklist, unchanged, folded into the one shared constant.
  /\bbecause\b/i,
  /\bdue\s+to\b/i,
  /\bcauses?\b/i,
  /\bcaused\b/i,
  /\bcausing\b/i,
  /\bdrive\b/i,
  /\bdrives\b/i,
  /\bdriven\b/i,
  /\bdriving\b/i,
  // round 3: "leads to"/"leading to" generalised to include the past tense "led to".
  /\bleads?\s+to\b/i,
  /\bleading\s+to\b/i,
  /\bled\s+to\b/i,
  // round 3: "results in"/"resulting in" generalised to include "resulted in".
  /\bresults?\s+in\b/i,
  /\bresulting\s+in\b/i,
  /\bresulted\s+in\b/i,
  /\bthanks\s+to\b/i,
  /\bas\s+a\s+result\b/i,
  /\bwhich\s+means\s+(?:customers|clients)\s+will\b/i,
  // v706/v707: idioms a refuter proved evade a narrower blacklist entirely.
  /\bmakes?\b[\s\S]{0,30}?\b(?:return|come\s+back)\b/i,
  /\bmade\b[\s\S]{0,30}?\b(?:return|come\s+back)\b/i,
  // round 3 (check 17, item 1): "is why" was a FIXED copula - "are why"/"was why"/"were why"/"'s
  // why" (e.g. "that's why") state the exact same construction and evaded it entirely. Every
  // copula inflection is listed once here instead of "is why" plus a hand-written "that is why"
  // special case, because "that is why"/"that are why"/etc are already substrings this single
  // pattern matches.
  /\b(?:is|are|was|were)\s+why\b/i,
  /\w's\s+why\b/i,
  // round 3: "accounts for" generalised to "accounted for" (past tense of the same verb).
  /\baccounts?(?:ed)?\s+for\b/i,
  // round 3: "explains" generalised to "explained"/"explaining".
  /\bexplain(?:s|ed|ing)?\b/i,
  // round 3: "is behind" was a fixed copula, same shape as "is why" above.
  /\b(?:is|are|was|were)\s+behind\b/i,
  /\bowing\s+to\b/i,
  // round 3: "stems from" generalised to "stemmed from".
  /\bstems?\s+from\b/i,
  /\bstemmed\s+from\b/i,
  // round 3: "means that" generalised to "meant that".
  /\bmeans?\s+that\b/i,
  /\bmeant\s+that\b/i,
  // round 3: "translates into" generalised to "translated into".
  /\btranslates?\s+into\b/i,
  /\btranslated\s+into\b/i,
  // "so ... that" with anything between the two words, not just the adjacent "so that" above.
  /\bso\b[\s\S]{1,40}?\bthat\b/i,
  /\bas\s+a\s+consequence\b/i,
  // round 3: "paves the way" generalised to "paved the way".
  /\bpaves?\s+the\s+way\b/i,
  /\bpaved\s+the\s+way\b/i,
  /\bsets?\s+up\b/i,
  // round 3: "follows from" generalised to "followed from".
  /\bfollows?\s+from\b/i,
  /\bfollowed\s+from\b/i,
  // round 3: "is the reason" was a fixed copula, same shape as "is why"/"is behind" above.
  /\b(?:is|are|was|were)\s+the\s+reason\b/i,
  // round 3: "produces" generalised to "produced"/"producing".
  /\bproduc(?:e|es|ed|ing)\b/i,
  // round 3: "results from" generalised to "resulted from".
  /\bresults?\s+from\b/i,
  /\bresulted\s+from\b/i,
  /\bon\s+account\s+of\b/i,
  // round 3: "brings about" generalised to "brought about".
  /\bbrings?\s+about\b/i,
  /\bbrought\s+about\b/i,
  // round 3: "spurs" generalised to "spurred".
  /\bspurs?\b/i,
  /\bspurred\b/i,
  // round 3: "prompts" generalised to "prompted".
  /\bprompts?\b/i,
  /\bprompted\b/i,
  // round 3: "boosts" generalised to "boosted".
  /\bboosts?\b/i,
  /\bboosted\b/i,
  // round 3: "fuels" generalised to "fuelled"/"fueled" (both spellings).
  /\bfuels?\b/i,
  /\bfuell?ed\b/i,
  // round 3: "triggers" generalised to "triggered".
  /\btriggers?\b/i,
  /\btriggered\b/i,
  // round 3: "pushes" generalised to "pushed".
  /\bpushes?\b/i,
  /\bpushed\b/i,
  // round 3 (check 17, item 2): a conditional causal claim the prompt itself forbids
  // (EVIDENCE_CLASS_INSTRUCTION's own "if you keep X, Y will...") but that nothing here actually
  // checked - "if you keep pushing weekend visits, returns may rise" states a cause with no word
  // from the list above at all. Narrow on purpose: only fires when a modal follows the "if you/we/
  // they keep/continue/stop/start/push/run" opener within a short window, so an unrelated "if"
  // elsewhere in the sentence is not swept in.
  /\bif\s+(?:you|we|they)\s+(?:keep|continue|stop|start|push|run)\b[\s\S]{0,60}?\b(?:will|would|may|might|should)\b/i,
  // round 3: the comparative "the more X, the more/faster/sooner Y" construction states the same
  // kind of cause without any causal verb at all.
  /\bthe\s+more\b[\s\S]{0,60}?\bthe\s+(?:more|faster|sooner)\b/i,
];

function hasCausalConstruction(text) {
  return CAUSAL_CONSTRUCTIONS.some((re) => re.test(text));
}

function findingKeywords(finding) {
  const texts = [];
  for (const key of ['label', 'pattern', 'name']) {
    if (typeof finding[key] === 'string' && finding[key].trim()) texts.push(finding[key]);
  }
  const words = new Set();
  for (const text of texts) {
    for (const raw of text.split(/[^A-Za-z]+/)) {
      const w = raw.toLowerCase();
      if (w.length >= 4 && !STOPWORDS.has(w)) words.add(w);
    }
  }
  return [...words];
}

// v707 (check 17, false-positive half): a refuter proved the OLD naive "does this sentence mention
// >=2 (or, for a one-word finding, >=1) of ITS keywords" test (the prior sentenceMentionsFinding)
// could misattribute a sentence: a DIRECT_FACT finding sharing two ordinary words with an
// ASSOCIATION finding made V10b flag a plain, factual DIRECT_FACT sentence for carrying no
// "association marker" it was never making an association claim in the first place.
//
// Fixed by SCORING every sentence against EVERY typed finding in the pack - both classes, not just
// ASSOCIATION, so a DIRECT_FACT finding is in the running to WIN a sentence, not merely invisible -
// on each finding's DISTINCTIVE keywords only: a keyword shared by 2+ findings is dropped before
// scoring starts, so a common word neither finding uniquely owns can never manufacture a tie. The
// sentence "belongs" only to whichever finding(s) score highest; a DIRECT_FACT finding that ties or
// beats every ASSOCIATION finding for a sentence means the sentence is judged to be about that
// fact, and neither V10 nor V10b look at it further for any ASSOCIATION finding.
//
// The match threshold is now a FLAT two distinctive keywords, dropping the old "a one-keyword
// finding only needs its one keyword" exception - a finding left with a single distinctive word
// (either because it only ever had one, or because sharing dropped the rest) can never be
// referenced by either rule any more. That is the conservative side of the same trade this file
// makes everywhere else: a stricter attribution rule abstains more, it never asserts more.
function typedFindings(packInfo) {
  const findings = [];
  for (const obj of packInfo.objects) {
    const evidenceClass = obj.evidence_class;
    if (evidenceClass !== 'ASSOCIATION' && evidenceClass !== 'DIRECT_FACT') continue;
    const keywords = findingKeywords(obj);
    if (keywords.length === 0) continue;
    const label = obj.label || obj.pattern || obj.name || obj.id || 'unlabelled finding';
    findings.push({ label, evidenceClass, keywords });
  }
  // Words shared by 2+ findings are not DISTINCTIVE to any one of them - dropped from every
  // finding's own scoring set up front, so a common word can never manufacture a tie neither
  // finding actually owns.
  const counts = new Map();
  for (const f of findings) {
    for (const kw of new Set(f.keywords)) counts.set(kw, (counts.get(kw) || 0) + 1);
  }
  return findings.map((f) => ({
    ...f,
    distinctive: [...new Set(f.keywords)].filter((kw) => counts.get(kw) === 1),
  }));
}

const MIN_DISTINCTIVE_KEYWORD_MATCH = 2;

function distinctiveScore(sentenceLower, distinctiveKeywords) {
  let hits = 0;
  for (const kw of distinctiveKeywords) {
    if (sentenceLower.includes(kw)) hits += 1;
  }
  return hits;
}

// The ASSOCIATION finding(s), if any, that best explain this sentence - [] when nothing scores
// high enough to count as a reference at all, or when a DIRECT_FACT finding ties or beats every
// ASSOCIATION finding for it (see the honesty note above typedFindings).
function associationOwnersOf(sentenceLower, findings) {
  let best = 0;
  const scored = [];
  for (const f of findings) {
    const score = distinctiveScore(sentenceLower, f.distinctive);
    if (score > 0) scored.push({ f, score });
    if (score > best) best = score;
  }
  if (best < MIN_DISTINCTIVE_KEYWORD_MATCH) return [];
  const winners = scored.filter((s) => s.score === best).map((s) => s.f);
  if (winners.some((f) => f.evidenceClass === 'DIRECT_FACT')) return [];
  return winners.filter((f) => f.evidenceClass === 'ASSOCIATION');
}

function checkAssociationCausalBinding(narrative, packInfo, violations) {
  const findings = typedFindings(packInfo);
  if (!findings.some((f) => f.evidenceClass === 'ASSOCIATION')) return;

  for (const sentence of sentencesOf(narrative)) {
    if (!hasCausalConstruction(sentence)) continue;
    const lower = sentence.toLowerCase();
    for (const finding of associationOwnersOf(lower, findings)) {
      violations.push({
        rule: RULES.CAUSAL_BINDING,
        detail: `causal construction used for an ASSOCIATION finding ("${String(finding.label).slice(0, 80)}") ` +
          `which must be phrased as an observed pattern, not a cause, near "${sentence.slice(0, 90)}"`,
      });
    }
  }
}

/* ------------------------------------------ V10b: ASSOCIATION positive marker */

// Check 17 (typed verdicts, POSITIVE half). A refuter proved V10's original causal-phrase
// BLACKLIST is a fixed list that can always be evaded by one more idiom it does not yet name -
// 27/27 of "boosts", "fuels", "triggers", "explains", "is behind", "owing to", "stems from", "is
// why", "means that", "translates into", "so ... that" (with words between "so" and "that" - the
// blacklist's own "so\s+that" only matches the two words adjacent), "as a consequence of", a
// pronoun continuation ("Weekend visits build momentum. This pushes customers to return sooner."),
// a bare conditional ("If you keep encouraging weekend visits, customers will return sooner"),
// "pave the way", "sets up", "follows from", "accounts for", "is the reason" and "produces" all
// passed the narrower blacklist clean. A blacklist of English causal idioms can never be
// exhaustive.
//
// V10b inverts the burden instead of extending the list further: for a sentence that references an
// ASSOCIATION finding's own vocabulary (the SAME keyword-extraction and sentence-attribution V10
// already uses - typedFindings/associationOwnersOf, above - so the two rules can never disagree on
// WHICH sentences are "about" a finding), the sentence (plus the immediately following sentence, if
// IT opens with a pronoun continuation - "This/That/It/Which" - referring back to the same claim)
// must POSITIVELY carry at least one of the approved ASSOCIATION_MARKERS below, AND must carry NO
// construction from the SAME CAUSAL_CONSTRUCTIONS list V10 tests (see the v707 note above
// typedFindings): a marker does not launder a causal claim sitting in the same window ("we observe
// that weekends make customers return" carries "we observe" AND "make ... return" at once, and the
// marker must not excuse the causal half). Silence, and laundering-by-marker, are now BOTH
// failures - the opposite failure mode from a blacklist, which only ever fails on presence.
// V10 stays wired as a SECOND, independent line (validateNarrative runs both): a causal sentence
// that names no ASSOCIATION finding's vocabulary at all is out of V10b's reach (V10b never fires
// without a keyword match, same abstention shape as V10 itself), and V10 alone still catches it.
//
// HONEST LIMIT, stated plainly because this is the inverse failure mode from every other rule in
// this file: a sentence that PARAPHRASES the same finding using NONE of its own vocabulary (no
// word findingKeywords() would extract from the finding's label/pattern/name) is invisible to
// associationOwnersOf and therefore invisible to V10b - exactly the same "no shared vocabulary, no
// way to bind free English to a machine record" limit V6's own entity-grounding banner and V10's
// own header already state for their respective jobs. V10's unconditional causal-word list is what
// still catches a causal paraphrase that keeps none of the finding's own words; V10b narrows one
// specific, checkable slice (a referencing window with no marker, or a marker riding alongside an
// unlisted-to-the-model-but-listed-here causal construction), it does not replace V10's
// unconditional check, which is why both stay wired into validateNarrative independently.
//
// THE MARKER LIST is the single source of truth for what counts as an approved association phrase,
// used nowhere else and duplicated nowhere else - the prompt instruction (EVIDENCE_CLASS_INSTRUCTION,
// above) tells the model to use one of these words in its own prose, in English, rather than
// quoting this list verbatim (a model does not read regexes) - but every phrase named there is
// present here, so a model that follows the instruction always passes, and this list is the one
// place to add a marker if the model's own phrasing drifts.
//
// v707 (check 17, round 2): bare "pattern" is REMOVED from this list - it is common enough English
// that "Weekend visiting accounts for the sooner return pattern we see" satisfied the old marker
// test on the word "pattern" alone while "accounts for" (now on CAUSAL_CONSTRUCTIONS) laundered the
// actual cause right next to it. "an observed pattern" and "a pattern where" replace it: specific
// enough that a model following EVIDENCE_CLASS_INSTRUCTION still passes easily, too specific to be
// satisfied by an unrelated "pattern" sitting near an invented cause.
export const ASSOCIATION_MARKERS = [
  /\btend(?:s)?\s+to\b/i,
  /\bis\s+associated\s+with\b/i,
  /\bassociated\s+with\b/i,
  // "customers who ... also" - the gap between the cue and "also" is deliberately generous (a
  // relative clause commonly sits between them: "customers who visit on a weekend also tend...").
  /\bcustomers?\s+who\b[\s\S]{0,80}?\balso\b/i,
  /\bclients?\s+who\b[\s\S]{0,80}?\balso\b/i,
  /\balso\s+tend/i,
  /\bwe\s+observe/i,
  /\bwe\s+see\b/i,
  /\bobserved\s+pattern\b/i,
  /\ba\s+pattern\s+where\b/i,
  /\bcorrelat/i,
  /\bgoes\s+together\s+with\b/i,
  /\balongside\b/i,
  /\bin\s+the\s+same\s+period\b/i,
  /\bat\s+the\s+same\s+time\b/i,
  /\bcoincide/i,
  /\bmore\s+often\b/i,
  /\bless\s+often\b/i,
  /\bmore\s+likely\b/i,
  /\bless\s+likely\b/i,
  /\bappears?\s+to\b/i,
  /\bseems?\s+to\b/i,
];

function hasAssociationMarker(text) {
  return ASSOCIATION_MARKERS.some((re) => re.test(text));
}

// A sentence opening with one of these pronouns, right after a sentence that named the finding, is
// read as continuing the SAME claim ("Weekend visits build momentum. This pushes customers to
// return sooner.") - so the marker (and, as of v707, a laundering causal construction) may live in
// either sentence and the pair is judged together. Anything looser (a pronoun three sentences
// later, or one that opens a genuinely new topic) is out of scope, the same conservative-window
// trade this file makes everywhere else.
const PRONOUN_CONTINUATION_RE = /^(?:This|That|It|Which)\b/;

function checkAssociationPositiveMarker(narrative, packInfo, violations) {
  const findings = typedFindings(packInfo);
  if (!findings.some((f) => f.evidenceClass === 'ASSOCIATION')) return;

  const sentences = sentencesOf(narrative);
  const reported = new Set();

  for (let i = 0; i < sentences.length; i += 1) {
    const sentence = sentences[i];
    const lower = sentence.toLowerCase();
    const owners = associationOwnersOf(lower, findings);
    if (owners.length === 0) continue;

    let window = sentence;
    if (i + 1 < sentences.length && PRONOUN_CONTINUATION_RE.test(sentences[i + 1])) {
      window = `${sentence} ${sentences[i + 1]}`;
    }
    const marker = hasAssociationMarker(window);
    // v707: a marker no longer saves the window if an unlisted-by-the-model-but-listed-here causal
    // construction rides along in it - see the file-level note above this function.
    const laundered = hasCausalConstruction(window);
    if (marker && !laundered) continue;

    for (const finding of owners) {
      const key = `${finding.label}::${i}`;
      if (reported.has(key)) continue;
      reported.add(key);
      violations.push({
        rule: RULES.ASSOCIATION_MARKER,
        detail: marker
          ? `sentence references ASSOCIATION finding ("${String(finding.label).slice(0, 80)}") with ` +
            `an approved association marker AND a causal construction in the same window - the ` +
            `marker does not launder the causal claim, near "${sentence.slice(0, 90)}"`
          : `sentence references ASSOCIATION finding ("${String(finding.label).slice(0, 80)}") ` +
            `but carries no approved association marker (e.g. "tend to", "is associated with", ` +
            `"we observe", "more likely"), near "${sentence.slice(0, 90)}"`,
      });
    }
  }
}

/* ------------------------------------------------------ V8: cohort contradiction */

// Check 89, the hard-verdict slice described above. Fires ONLY when a binding is inconsistent with
// its own cohort AND the claimed count equals a different cohort's count exactly — the case where
// the pack itself proves the number belongs elsewhere. Every other inconsistency (a count that
// matches nothing at all) still abstains, exactly as classifyCohortMentions does on its own.
function checkCohortContradiction(narrative, pack, violations) {
  const bindings = classifyCohortMentions(narrative, pack);
  if (bindings.length === 0) return;
  const expectedByCohort = {};
  for (const { cohort, path } of COHORT_PHRASES) {
    const value = readPath(pack, path);
    if (typeof value === 'number') expectedByCohort[cohort] = value;
  }
  for (const binding of bindings) {
    if (binding.consistent || binding.expected === undefined) continue;
    for (const [otherCohort, otherValue] of Object.entries(expectedByCohort)) {
      if (otherCohort === binding.cohort) continue;
      if (otherValue !== binding.claimed) continue;
      violations.push({
        rule: RULES.COHORT,
        detail: `cohort count contradicts the pack: "${binding.claimed}" is bound to ` +
          `${binding.cohort} (pack says ${binding.expected}) but matches ${otherCohort}'s own ` +
          `count (${otherValue}) instead, near "${binding.context}"`,
      });
      break;
    }
  }
}

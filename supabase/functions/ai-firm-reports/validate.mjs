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
// scope:'identified_customers_only' markers), v551 (top1/top5 shares that name their denominator)
// and v552 (evidence_completeness.unavailable_sections as [{section, sqlstate}]).
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

export function assembleUserPrompt(report) {
  const evidence = JSON.stringify((report && report.evidence) ?? {}, null, 2);
  return [
    `Write the ${report.period_kind} business report for the ${periodLabel(report)}.`,
    '',
    'Evidence pack (the only facts you may use):',
    '```json',
    evidence,
    '```',
  ].join('\n');
}

/* ------------------------------------------------------------ pack traversal */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_DATE_RE = /^(\d{4})-(\d{2})-(\d{2})(?:[T ].*)?$/;

// Walks every leaf of the pack once. Everything the rules need is collected here so the rules
// themselves stay readable and the traversal cost is paid a single time.
function readPack(pack) {
  const numbers = new Set();      // every numeric leaf, plus |n| for negatives
  const strings = [];             // every string leaf, verbatim
  const dateStrings = new Set();  // leaves that are ISO dates / timestamps
  const objects = [];             // every plain object, for the sibling-ratio derivation
  const seen = new Set();

  const addNumber = (n) => {
    if (typeof n !== 'number' || !Number.isFinite(n)) return;
    numbers.add(n);
    if (n < 0) numbers.add(Math.abs(n));
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
    for (const value of Object.values(node)) walk(value);
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
    addNumber(Number(m[1]));            // year
    addNumber(Number(m[2]));            // month, as written and unpadded
    addNumber(Number(m[3]));            // day
  }

  return { numbers: [...numbers], strings, dateStrings: [...dateStrings], objects };
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

function groundNumbers(narrative, packInfo, derivedPct) {
  const masked = maskStructuralNumbers(narrative, packInfo.dateStrings);
  const digitTokens = scanNumbers(masked, false);
  const wordTokens = scanNumberWords(masked);
  // Word tokens are checked directly against the pack (never chained into shown-working — a
  // model spelling out an intermediate step is not something the prompt asks for, and chaining
  // word tokens into the digit-token arithmetic pass would let a spelled result launder a
  // fabricated digit operand). Kept as their own array; digit tokens keep the existing behaviour
  // byte-for-byte.
  const tokens = digitTokens;
  const grounded = new Array(tokens.length).fill(false);

  const groundedAgainstPack = (tok) => {
    for (const n of packInfo.numbers) {
      if (renders(tok.value, tok.decimals, n)) return true;      // the value as the pack holds it
      if (renders(tok.value, tok.decimals, n / 100)) return true; // cents written as dollars
    }
    if (tok.isPercent) {
      for (const p of derivedPct) {
        if (renders(tok.value, tok.decimals, p)) return true;     // round(100*a/b) of siblings
      }
    }
    return false;
  };

  for (let i = 0; i < tokens.length; i += 1) grounded[i] = groundedAgainstPack(tokens[i]);

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

function checkLowercaseMonthClauseStart(narrative, pack, violations) {
  const bounds = periodBounds(pack);
  const currentMonths = monthsSpanned(bounds.from, bounds.to);
  if (currentMonths.size === 0) return;

  MONTH_NAME_CI_RE.lastIndex = 0;
  let m;
  while ((m = MONTH_NAME_CI_RE.exec(narrative)) !== null) {
    if (/^[A-Z]/.test(m[1])) continue; // capitalised: the primary case-sensitive pass already covers it
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
const ORPHAN_TOKEN_RE = /^[A-Z][a-z]{2,}$/;

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

// Every whitespace-delimited word in the ORIGINAL narrative, stripped of surrounding punctuation
// the same way nameCandidates() strips it above (kept as a SEPARATE pass, not a shared helper,
// because nameCandidates needs sentence-scoped runs and this needs whole-document positions for
// the sentence-initial check below). A lone initial's period survives ("S." stays "S."); anything
// else has trailing dots stripped ("Tan." -> "Tan").
function orphanWords(narrative) {
  const out = [];
  const re = /\S+/g;
  let m;
  while ((m = re.exec(narrative)) !== null) {
    const raw = m[0];
    let start = 0;
    while (start < raw.length && !/[A-Za-z]/.test(raw[start])) start += 1;
    let end = raw.length;
    while (end > start && !/[A-Za-z.]/.test(raw[end - 1])) end -= 1;
    let word = raw.slice(start, end);
    if (!/^[A-Z]\.$/.test(word)) word = word.replace(/\.+$/, '');
    const index = m.index + start;
    out.push({ word, index, end: index + word.length });
  }
  return out;
}

// (d): a capitalised, non-stopword neighbour immediately before or after means this token is part
// of a run V6 already owns. Stopwords are excluded from counting as a "partner" so a stopword that
// happens to be capitalised at a clause start (e.g. an orphan name right after "The") does not
// smuggle the orphan out of V9's reach — "The Marcus arrived" must still be checked, because "The"
// is not itself a name.
function hasCapitalisedRunPartner(words, i) {
  const isPartner = (w) => {
    if (!w || !NAME_TOKEN_RE.test(w.word)) return false;
    return !STOPWORDS.has(w.word.toLowerCase().replace(/\.$/, ''));
  };
  return isPartner(words[i - 1]) || isPartner(words[i + 1]);
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
    if (!ORPHAN_TOKEN_RE.test(tok.word)) continue;
    if (allowlist.has(tok.word)) continue;                          // (b)
    if (inOrphanSkipRange(ranges, tok.index)) continue;              // (b) heading/code lines
    if (hasCapitalisedRunPartner(words, i)) continue;                // (d)
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

function checkStructure(narrative, violations) {
  const positions = REQUIRED_HEADINGS.map((heading) => narrative.indexOf(heading));
  positions.forEach((idx, i) => {
    if (idx !== -1) return;
    violations.push({
      rule: RULES.STRUCTURE,
      detail: `required heading "${REQUIRED_HEADINGS[i]}" is missing from the report`,
    });
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
  const narrative = typeof narrativeMd === 'string' ? narrativeMd : '';
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
  checkStructure(narrative, violations);                // V7 (check 82)
  checkCohortContradiction(narrative, pack, violations); // V8 (check 89)

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

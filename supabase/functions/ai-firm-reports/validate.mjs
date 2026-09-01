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
};

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

  return chars.join('');
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
  const tokens = scanNumbers(masked, false);
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

  return { tokens, grounded };
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

/* -------------------------------------------------------- V6: entity grounding */

// HONEST LIMITS. There is no name database here and there cannot be one: v177_person_label emits
// "First L." or "Guest AB12" from real customer names, which are unbounded. The heuristic is
// deliberately CONSERVATIVE - it fires only on a run of two or more capitalised words that is not
// led by a common English word, not a weekday or month, and not found anywhere in the pack's own
// strings. It therefore CANNOT catch:
//   * a single-word invented name ("Marcus"), because one capitalised word is far too common;
//   * an invented name that happens to be a substring of a pack string.
// And it CAN misfire on an unusual proper noun the model legitimately introduces (a place, a
// public holiday). Misfires cost a regenerated report, so the trade is deliberate.
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

/* -------------------------------------------------------------- entry point */

/**
 * Validate one model-written narrative against the evidence pack it was given.
 *
 * @param {string} narrativeMd   the markdown the model returned
 * @param {object} evidencePack  the SAME object handed to the model (app.v176_evidence_pack)
 * @param {object} [opts]        { causalEvidence?: boolean, allowStrongClaims?: boolean }
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
  const { tokens, grounded } = groundNumbers(narrative, packInfo, derivedPct);
  for (let i = 0; i < tokens.length; i += 1) {
    if (grounded[i]) continue;
    const tok = tokens[i];
    violations.push({
      rule: RULES.NUMERIC,
      detail: `${tok.value} (written "${tok.raw.trim()}") is not in the evidence pack, near ` +
        `"${contextAround(narrative, tok.index, tok.end)}"`,
    });
  }

  checkPopulation(narrative, pack, violations);   // V2
  checkCausal(narrative, options, violations);    // V3
  checkConfidence(narrative, options, violations);// V4
  checkLimitations(narrative, pack, violations);  // V5
  checkEntities(narrative, packInfo, violations); // V6

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
// This is exported for the suite to execute, and deliberately NOT wired into validateNarrative's
// verdict: the phrase list below is small, and failing a real report on a phrasing miss is a worse
// outcome than an advisory signal. Promoting it to a hard rule needs broader phrase coverage first.
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

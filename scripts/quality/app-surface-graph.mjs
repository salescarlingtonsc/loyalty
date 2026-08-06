/**
 * Partition app/app.js into surface chunks WITHOUT rewriting any code.
 *
 * app/app.js stays the single editable source (every parallel session keeps editing it). This
 * module segments it into top-level blocks, works out which surface each block belongs to, and
 * hands back byte ranges. The generator writes the chunks; a test regenerates and compares, so
 * the shipped chunks can never drift from the source.
 *
 * The segmentation is byte-exact: every line of app.js lands in exactly one chunk, in its
 * original order, so the concatenation core+customer+business is app.js with nothing added,
 * removed or reordered within a surface.
 */

/* Per-line-start scanner state. Only the depth and the "are we inside a string/comment" flags at
   each line start matter, which is exactly what a character walk gives us for free. Template
   literals nest (`${`), so the string state is a stack. */
export function lineStates(source) {
  const states = [{ depth: 0, quiet: true }];
  const stack = [];
  let depth = 0;
  let mode = 'code'; // code | line-comment | block-comment | ' | " | `
  let previousMeaningful = '';
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    const next = source[index + 1];
    if (char === '\n') {
      states.push({ depth, quiet: mode === 'code' && stack.length === 0 });
      if (mode === 'line-comment') mode = 'code';
      continue;
    }
    if (mode === 'line-comment') continue;
    if (mode === 'block-comment') {
      if (char === '*' && next === '/') { mode = 'code'; index += 1; }
      continue;
    }
    if (mode === "'" || mode === '"') {
      if (char === '\\') { index += 1; continue; }
      if (char === mode) mode = 'code';
      continue;
    }
    if (mode === '`') {
      if (char === '\\') { index += 1; continue; }
      if (char === '`') { mode = 'code'; continue; }
      if (char === '$' && next === '{') { stack.push(depth); depth += 1; mode = 'code'; index += 1; }
      continue;
    }
    // mode === 'code'
    if (char === '/' && next === '/') { mode = 'line-comment'; index += 1; continue; }
    if (char === '/' && next === '*') { mode = 'block-comment'; index += 1; continue; }
    if (char === '/' && regexAllowedAfter(previousMeaningful)) {
      index = skipRegex(source, index);
      previousMeaningful = '/';
      continue;
    }
    if (char === "'" || char === '"' || char === '`') { mode = char; previousMeaningful = char; continue; }
    if (char === '{' || char === '(' || char === '[') depth += 1;
    else if (char === '}' || char === ')' || char === ']') {
      /* A `${` recorded the depth it opened at; the matching `}` is the one that brings us back
         down to it, and it returns us to the template body rather than to code. */
      if (char === '}' && stack.length && depth - 1 === stack[stack.length - 1]) {
        stack.pop();
        depth -= 1;
        mode = '`';
        continue;
      }
      depth -= 1;
    }
    if (char.trim()) previousMeaningful = char;
  }
  return states;
}

const REGEX_ALLOWED_AFTER = new Set(['', '(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '^', '~', '<', '>', 'n' /* return */]);
function regexAllowedAfter(previous) {
  return REGEX_ALLOWED_AFTER.has(previous);
}
function skipRegex(source, start) {
  let index = start + 1;
  let inClass = false;
  while (index < source.length) {
    const char = source[index];
    if (char === '\\') { index += 2; continue; }
    if (char === '\n') return start; // not a regex after all
    if (char === '[') inClass = true;
    else if (char === ']') inClass = false;
    else if (char === '/' && !inClass) return index;
    index += 1;
  }
  return start;
}

const DECLARATION = /^(?:export\s+)?(?:async\s+)?(?:function\s*\*?\s*([A-Za-z_$][\w$]*)|(?:const|let|var)\s+([A-Za-z_$][\w$]*)|class\s+([A-Za-z_$][\w$]*))/;

/** Segment the source into top-level blocks, each a contiguous run of whole lines. */
export function topLevelBlocks(source) {
  const lines = source.split('\n');
  const states = lineStates(source);
  const starts = [];
  for (let index = 0; index < lines.length; index += 1) {
    const state = states[index];
    const line = lines[index];
    if (!state || !state.quiet || state.depth !== 0) continue;
    if (!line || /^\s/.test(line)) continue;
    starts.push(index);
  }
  const blocks = [];
  for (let index = 0; index < starts.length; index += 1) {
    const from = starts[index];
    const to = index + 1 < starts.length ? starts[index + 1] : lines.length;
    const text = lines.slice(from, to).join('\n');
    const declaration = DECLARATION.exec(lines[from]);
    blocks.push({
      from,
      to,
      text,
      name: declaration ? (declaration[1] || declaration[2] || declaration[3]) : null,
      /* A block that is not a declaration RUNS at load time, so it and everything it needs must
         be in the always-loaded core. */
      executes: !declaration && !/^\s*(?:\/\/|\/\*|\*)/.test(lines[from])
    });
  }
  return blocks;
}

/* Comment blocks immediately above a declaration belong to it. Merging them keeps the generated
   chunks readable and keeps the byte-exactness assertion simple. */
export function mergeLeadingComments(blocks) {
  const merged = [];
  let pending = [];
  for (const block of blocks) {
    const isComment = !block.name && !block.executes;
    if (isComment) { pending.push(block); continue; }
    if (pending.length) {
      block.text = `${pending.map((item) => item.text).join('\n')}\n${block.text}`;
      block.from = pending[0].from;
      pending = [];
    }
    merged.push(block);
  }
  if (pending.length) {
    merged.push({ ...pending[0], text: pending.map((item) => item.text).join('\n'), name: null, executes: false });
  }
  return merged;
}

/**
 * Blank out comments and string BODIES, keeping code and template `${...}` expressions.
 *
 * Without this, `nav('#/dashboard')` and a prose comment mentioning settingsPage both read as
 * references, which drags most of the workspace into the shared core. Template expressions are
 * real code and must survive.
 */
export function codeOnly(text) {
  const out = new Array(text.length).fill(' ');
  const stack = [];
  let depth = 0;
  let mode = 'code';
  let previousMeaningful = '';
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    const next = text[index + 1];
    if (char === '\n') { out[index] = '\n'; if (mode === 'line-comment') mode = 'code'; continue; }
    if (mode === 'line-comment') continue;
    if (mode === 'block-comment') {
      if (char === '*' && next === '/') { mode = 'code'; index += 1; }
      continue;
    }
    if (mode === "'" || mode === '"') {
      if (char === '\\') { index += 1; continue; }
      if (char === mode) mode = 'code';
      continue;
    }
    if (mode === '`') {
      if (char === '\\') { index += 1; continue; }
      if (char === '`') { mode = 'code'; continue; }
      if (char === '$' && next === '{') { stack.push(depth); depth += 1; mode = 'code'; index += 1; }
      continue;
    }
    if (char === '/' && next === '/') { mode = 'line-comment'; index += 1; continue; }
    if (char === '/' && next === '*') { mode = 'block-comment'; index += 1; continue; }
    if (char === '/' && REGEX_ALLOWED_AFTER.has(previousMeaningful)) {
      const end = skipRegex(text, index);
      if (end > index) { index = end; previousMeaningful = '/'; continue; }
    }
    if (char === "'" || char === '"' || char === '`') { mode = char; previousMeaningful = char; continue; }
    if (char === '{' || char === '(' || char === '[') depth += 1;
    else if (char === '}' || char === ')' || char === ']') {
      if (char === '}' && stack.length && depth - 1 === stack[stack.length - 1]) {
        stack.pop(); depth -= 1; mode = '`'; continue;
      }
      depth -= 1;
    }
    out[index] = char;
    if (char.trim()) previousMeaningful = char;
  }
  return out.join('');
}

const WORD = /[A-Za-z_$][\w$]*/g;
/**
 * Identifiers a block actually references — comments and string bodies excluded, and two kinds of
 * look-alike skipped:
 *   `obj.dashboard`      a property on some other object, not the top-level function;
 *   `{dashboard: x}`     an object KEY, which is why the nav metadata table used to drag every
 *                        workspace page into the shared core.
 * Shorthand (`{dashboard, till: tillPage}`) is a real reference and is kept.
 */
export function referencedNames(block, known) {
  const code = codeOnly(block.text);
  const names = new Set();
  /* Scan for the neighbouring characters directly — slicing the block per identifier turns this
     into an O(n^2) walk over a 1.8MB file. */
  const nonSpaceBefore = (index) => {
    for (let cursor = index - 1; cursor >= 0; cursor -= 1) if (code[cursor].trim()) return code[cursor];
    return '';
  };
  const nonSpaceAfter = (index) => {
    for (let cursor = index; cursor < code.length; cursor += 1) if (code[cursor].trim()) return code[cursor];
    return '';
  };
  for (const match of code.matchAll(WORD)) {
    const word = match[0];
    if (word === block.name || !known.has(word)) continue;
    const previous = nonSpaceBefore(match.index);
    if (previous === '.') continue;
    const end = match.index + word.length;
    if (nonSpaceAfter(end) === ':' && (previous === '{' || previous === ',')) continue;
    names.add(word);
  }
  return names;
}

/**
 * Markup this block emits with an inline handler — `onclick="wlSeat(...)"`. The browser resolves
 * those against the GLOBAL OBJECT when the user clicks, long after load, and the name lives in a
 * string, so it is invisible to the code scan. Recording it as a real edge is what keeps a
 * handler in the same chunk as the page that renders it.
 */
const INLINE_HANDLER = /\bon[a-z]+="\s*([A-Za-z_$][\w$]*)\s*\(/g;
export function inlineHandlerNames(block, known) {
  const names = new Set();
  for (const match of block.text.matchAll(INLINE_HANDLER)) {
    if (match[1] !== block.name && known.has(match[1])) names.add(match[1]);
  }
  return names;
}

export function buildGraph(source) {
  const blocks = mergeLeadingComments(topLevelBlocks(source));
  const byName = new Map();
  for (const block of blocks) if (block.name) byName.set(block.name, block);
  const known = new Set(byName.keys());
  for (const block of blocks) {
    block.refs = referencedNames(block, known);
    for (const name of inlineHandlerNames(block, known)) block.refs.add(name);
  }
  return { blocks, byName, known };
}

/** Everything reachable from `seeds`, never traversing an edge listed in `severed`. */
export function closure(seeds, byName, severed = new Map()) {
  const seen = new Set();
  const queue = [...seeds];
  while (queue.length) {
    const name = queue.pop();
    if (seen.has(name) || !byName.has(name)) continue;
    seen.add(name);
    const cut = severed.get(name);
    for (const ref of byName.get(name).refs) {
      if (cut?.has(ref)) continue;
      if (!seen.has(ref)) queue.push(ref);
    }
  }
  return seen;
}

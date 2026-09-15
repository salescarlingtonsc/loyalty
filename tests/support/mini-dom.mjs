/* A DOM small enough to read, built for the two localisation walkers in app/app.js.
 *
 * WHY THIS EXISTS. Both walkers are DOM code: they read text nodes, climb with closest(), and
 * write attributes. Until now nothing in the suite EXECUTED either of them — the v97 acceptance
 * test reads their source and matches it — so "the walker translates this node" was an assertion
 * nobody had ever run. There is no jsdom in this repo and adding one for two functions is a poor
 * trade, so this implements exactly the API surface those two functions use, and nothing else.
 *
 * WHY YOU CAN TRUST IT. A hand-written DOM is a measuring tool, and a measuring tool that is wrong
 * makes every reading wrong in the same direction. So the test that uses it runs the SHIPPED
 * workspace walker through it first and checks the behaviour that walker is already known to have
 * — translating inside .main, refusing .wallet-shell, remembering the English source. If this file
 * were broken, that cross-check fails before any claim about the customer walker is made.
 *
 * Supported selectors: '*', 'tag', '.class', '[attr]', '[attr="value"]', and comma-separated lists
 * of those. No combinators — neither walker uses one.
 */
const TEXT_NODE = 3, ELEMENT_NODE = 1;

function matchesSimple(element, selector) {
  const s = selector.trim();
  if (!s) return false;
  if (s === '*') return true;
  if (s.startsWith('.')) return element.classList.has(s.slice(1));
  if (s.startsWith('[')) {
    const m = /^\[([A-Za-z0-9_-]+)(?:=(?:"([^"]*)"|'([^']*)'))?\]$/.exec(s);
    if (!m) throw new Error(`mini-dom: unsupported attribute selector ${s}`);
    const [, name, dq, sq] = m;
    if (!element.attributes.has(name)) return false;
    const want = dq ?? sq;
    return want === undefined || element.attributes.get(name) === want;
  }
  if (/^[A-Za-z][A-Za-z0-9]*$/.test(s)) return element.tagName === s.toUpperCase();
  throw new Error(`mini-dom: unsupported selector ${s}`);
}

class MiniText {
  constructor(value) { this.nodeType = TEXT_NODE; this.nodeValue = value; this.parentElement = null; }
}

class MiniElement {
  constructor(tagName, attributes = {}) {
    this.nodeType = ELEMENT_NODE;
    this.tagName = String(tagName).toUpperCase();
    this.attributes = new Map(Object.entries(attributes).map(([k, v]) => [k, String(v)]));
    this.classList = new Set(String(attributes.class || '').split(/\s+/).filter(Boolean));
    this.childNodes = [];
    this.parentElement = null;
  }
  append(...nodes) {
    for (const node of nodes) { node.parentElement = this; this.childNodes.push(node); }
    return this;
  }
  get descendants() {
    const out = [];
    for (const node of this.childNodes) {
      if (node.nodeType !== ELEMENT_NODE) continue;
      out.push(node, ...node.descendants);
    }
    return out;
  }
  matches(selector) { return String(selector).split(',').some(part => matchesSimple(this, part)); }
  closest(selector) {
    let node = this;
    while (node) { if (node.matches(selector)) return node; node = node.parentElement; }
    return null;
  }
  querySelectorAll(selector) { return this.descendants.filter(element => element.matches(selector)); }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  hasAttribute(name) { return this.attributes.has(name); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  setAttribute(name, value) {
    this.attributes.set(name, String(value));
    if (name === 'class') this.classList = new Set(String(value).split(/\s+/).filter(Boolean));
  }
  /* The visible words of this element and its descendants, in document order. */
  get textContent() {
    return this.childNodes
      .map(node => (node.nodeType === TEXT_NODE ? node.nodeValue : node.textContent))
      .join('');
  }
}

export const element = (tagName, attributes, ...children) =>
  new MiniElement(tagName, attributes).append(...children.map(child =>
    typeof child === 'string' ? new MiniText(child) : child));
export const text = (value) => new MiniText(value);
export const Node = Object.freeze({ TEXT_NODE, ELEMENT_NODE });
export { MiniElement, MiniText };

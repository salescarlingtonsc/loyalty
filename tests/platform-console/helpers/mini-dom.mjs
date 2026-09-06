/* A small, genuine (not regex-on-source) HTML mini-DOM used to execute
 * platform-console.js's real modal()/accessGrantModal()-style DOM code
 * against real parsed markup, since this repo has no jsdom dependency.
 * It supports exactly the subset these modal templates use: element
 * creation, innerHTML parsing into a real child tree, setAttribute/dataset,
 * simple querySelector(All) forms (#id, .class, [data-x], [data-x="y"],
 * bare tag name), select/option value semantics, and connectedness via a
 * single shared document.body root.
 */

const VOID_TAGS=new Set(['input','br','hr','img','meta','link']);
const TAG_RE=/<\/?([a-zA-Z][a-zA-Z0-9-]*)((?:\s+[a-zA-Z_:][-a-zA-Z0-9_:.]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*\/?>/g;
const ATTR_RE=/([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*("([^"]*)"|'([^']*)'|[^\s"'=<>`]+))?/g;

function camelCaseData(name){
  return name.slice(5).replace(/-([a-z0-9])/g,(_,c)=>c.toUpperCase());
}

export class MiniElement{
  constructor(tagName){
    this.tagName=String(tagName).toUpperCase();
    this.attributes=new Map();
    this.children=[];
    this.parentNode=null;
    this.dataset={};
    this._value=undefined;
    this.disabled=false;
    this.tabIndex=0;
    this.onclick=null;
    this.onsubmit=null;
    this.onchange=null;
    this._html='';
  }
  setAttribute(name,value){
    this.attributes.set(name,String(value));
    if(name.startsWith('data-'))this.dataset[camelCaseData(name)]=String(value);
    if(name==='id')this.id=String(value);
  }
  getAttribute(name){
    return this.attributes.has(name)?this.attributes.get(name):null;
  }
  removeAttribute(name){this.attributes.delete(name)}
  appendChild(child){child.parentNode=this;this.children.push(child);return child}
  remove(){
    if(this.parentNode){
      this.parentNode.children=this.parentNode.children.filter(c=>c!==this);
      this.parentNode=null;
    }
  }
  addEventListener(event,handler){
    const prop=`on${event}`;
    const previous=this[prop];
    this[prop]=e=>{if(previous)previous(e);handler(e)};
  }
  focus(){}
  querySelector(selector){
    return queryAll(this,selector)[0]||null;
  }
  querySelectorAll(selector){
    return queryAll(this,selector);
  }
}

Object.defineProperty(MiniElement.prototype,'className',{
  get(){return this.getAttribute('class')||''},
  set(v){this.setAttribute('class',v)}
});

Object.defineProperty(MiniElement.prototype,'innerHTML',{
  get(){return this._html},
  set(html){
    this._html=String(html);
    this.children.forEach(child=>{child.parentNode=null});
    this.children=[];
    const frag=parseFragment(this._html);
    frag.children.forEach(child=>this.appendChild(child));
  }
});

Object.defineProperty(MiniElement.prototype,'value',{
  get(){
    if(this.tagName==='SELECT'){
      const options=this.children.filter(c=>c.tagName==='OPTION');
      const selected=options.find(o=>o.attributes.has('selected'));
      if(selected)return selected.getAttribute('value')||'';
      return options[0]?options[0].getAttribute('value')||'':'';
    }
    return this._value!==undefined?this._value:(this.getAttribute('value')||'');
  },
  set(v){
    if(this.tagName==='SELECT'){
      const options=this.children.filter(c=>c.tagName==='OPTION');
      let found=false;
      options.forEach(o=>{
        if(o.getAttribute('value')===String(v)){o.setAttribute('selected','');found=true}
        else o.removeAttribute('selected');
      });
      if(!found)options.forEach(o=>o.removeAttribute('selected'));
    }else{
      this._value=v;
    }
  }
});

Object.defineProperty(MiniElement.prototype,'isConnected',{
  get(){
    let node=this;
    while(node){if(node.__root)return true;node=node.parentNode}
    return false;
  }
});

function matchesSelector(el,selector){
  selector=selector.trim();
  if(selector.startsWith('#'))return el.getAttribute('id')===selector.slice(1);
  if(selector.startsWith('.')){
    const cls=selector.slice(1);
    return (el.getAttribute('class')||'').split(/\s+/).includes(cls);
  }
  const attrMatch=selector.match(/^\[([a-zA-Z0-9_-]+)(?:="([^"]*)")?\]$/);
  if(attrMatch){
    const [,name,value]=attrMatch;
    if(!el.attributes.has(name))return false;
    return value===undefined?true:el.attributes.get(name)===value;
  }
  return el.tagName.toLowerCase()===selector.toLowerCase();
}

function queryAll(root,selector,results=[]){
  for(const child of root.children){
    if(matchesSelector(child,selector))results.push(child);
    queryAll(child,selector,results);
  }
  return results;
}

export function parseFragment(html){
  const root=new MiniElement('#fragment');
  const stack=[root];
  TAG_RE.lastIndex=0;
  let match;
  while((match=TAG_RE.exec(html))){
    const raw=match[0];
    const tagName=match[1].toLowerCase();
    const isClosing=raw[1]==='/';
    if(isClosing){
      for(let i=stack.length-1;i>0;i--){
        if(stack[i].tagName.toLowerCase()===tagName){stack.length=i;break}
      }
      continue;
    }
    const selfClose=raw.endsWith('/>')||VOID_TAGS.has(tagName);
    const el=new MiniElement(tagName);
    ATTR_RE.lastIndex=0;
    let attrMatch;
    while((attrMatch=ATTR_RE.exec(match[2]))){
      const name=attrMatch[1];
      let value='';
      if(attrMatch[2]!==undefined){
        value=attrMatch[3]!==undefined?attrMatch[3]:attrMatch[4]!==undefined?attrMatch[4]:attrMatch[2];
      }
      el.setAttribute(name,value);
    }
    stack[stack.length-1].appendChild(el);
    if(!selfClose)stack.push(el);
  }
  return root;
}

export function createFakeDocument(){
  const body=new MiniElement('body');
  body.__root=true;
  const document={
    body,
    createElement:tag=>new MiniElement(tag),
    documentElement:new MiniElement('html')
  };
  return {document};
}

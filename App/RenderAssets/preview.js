'use strict';
const root = document.getElementById('content');
let mathTokens = [];
let interfaceLanguage = 'zh-Hans';
const options = {trust:false, maxSize:20, maxExpand:1000, throwOnError:true, strict:'ignore'};
function mathHTML(token) {
  const index = mathTokens.push({source:token.text,display:token.display}) - 1;
  return `<${token.display?'div':'span'} data-math-token="${index}"></${token.display?'div':'span'}>`;
}
marked.use({extensions:[
  {name:'blockMath',level:'block',start:src=>{const i=src.search(/\$\$|\\\[/);return i<0?undefined:i;},
   tokenizer(src){const m=/^(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\])(?:\n|$)/.exec(src);if(m)return {type:'blockMath',raw:m[0],text:m[1]??m[2],display:true};}, renderer:mathHTML},
  {name:'inlineMath',level:'inline',start:src=>{const i=src.search(/\$|\\[([]/);return i<0?undefined:i;},
   tokenizer(src){const m=/^(?:\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|\$\$([\s\S]+?)\$\$|\$(?!\$)([^$\n]+?)\$)/.exec(src);if(m)return {type:'inlineMath',raw:m[0],text:m[1]??m[2]??m[3]??m[4],display:m[1]!==undefined||m[3]!==undefined};}, renderer:mathHTML}
]});
function renderMath(node, source, display) {
  source=source.replace(/(?<=\\)[\p{M}\p{Cf}\uFFFD]+/gu,'').replace(/[\u200B-\u200F\u202A-\u202E\u2060\uFEFF\uFFFD]/gu,'').replace(/(?<!\\)\\\s*$/u,'');
  try { katex.render(source,node,{...options,displayMode:display}); }
  catch(error) { node.classList.add('math-error'); node.textContent=(interfaceLanguage==='en'?'Equation syntax error: ':'公式语法错误：')+error.message; }
}
function unwrapEquation(source){
  const s=source.trim();
  for(const [left,right] of [['$$','$$'],['\\[','\\]'],['\\(','\\)']])
    if(s.startsWith(left)&&s.endsWith(right))return s.slice(left.length,-right.length).trim();
  return s;
}
function reportHeight(){
  window.webkit?.messageHandlers.layout.postMessage(Math.ceil(root.getBoundingClientRect().height));
}
let renderSequence=0,renderQueue=Promise.resolve();
window.renderContent=function(source,equation,dark,fontSize,language='zh-Hans'){
  const version=++renderSequence;
  const task=renderQueue.then(()=>renderPage(source,equation,dark,fontSize,language,version));
  renderQueue=task.catch(()=>{});return task;
};
async function renderPage(source,equation,dark,fontSize,language='zh-Hans',version){
  interfaceLanguage=language;
  document.documentElement.lang=language;
  document.documentElement.classList.toggle('dark',dark);
  document.getElementById('code-theme').setAttribute('href',dark?'highlight-dark.css':'highlight-light.css');
  document.body.style.fontSize=Math.max(12,Math.min(28,fontSize))+'px';
  root.className=equation?'equation':'';
  if(equation){root.replaceChildren();renderMath(root,unwrapEquation(source),true);}
  else {
    mathTokens=[];
    root.innerHTML=DOMPurify.sanitize(marked.parse(source,{gfm:true,breaks:false}),{
      FORBID_TAGS:['style','iframe','object','embed','form','script','svg','math'],
      FORBID_ATTR:['style'],ADD_ATTR:['data-math-token']
    });
    root.querySelectorAll('img').forEach(img=>{
      if(!/^(data:image\/(png|jpeg|gif|webp);base64,|https?:)/i.test(img.getAttribute('src')||''))img.replaceWith(document.createTextNode(img.alt||(language==='en'?'[Image]':'[图片]')));
    });
    root.querySelectorAll('[data-math-token]').forEach(node=>{
      const token=mathTokens[Number(node.dataset.mathToken)];
      node.removeAttribute('data-math-token');if(token)renderMath(node,token.source,token.display);
    });
    for(const code of Array.from(root.querySelectorAll('pre>code'))){
      const original=code.textContent;
      if(Array.from(code.classList).some(c=>/^language-mermaid$/i.test(c))){
        await renderMermaid(code,original,dark,language);
        if(version!==renderSequence)return false;
        continue;
      }
      if(original.length<100000){try{hljs.highlightElement(code);}catch{}}
      const header=document.createElement('div');header.className='code-header';
      const label=document.createElement('span');label.textContent=(code.className.match(/language-([\w+#.-]+)/)||[])[1]||(language==='en'?'Code':'代码');
      const copy=document.createElement('button');const copyLabel=language==='en'?'Copy code':'复制代码';copy.textContent=copyLabel;copy.setAttribute('aria-label',copyLabel);
      copy.onclick=()=>{window.webkit?.messageHandlers.copy.postMessage({text:original,language:(code.className.match(/language-([\w+#.-]+)/)||[])[1]||"Plain Text"});copy.textContent=language==='en'?'Copied':'已复制';setTimeout(()=>copy.textContent=copyLabel,1800);};
      header.append(label,copy);code.parentElement.prepend(header);
    }
    root.querySelectorAll('table').forEach(table=>{const scroll=document.createElement('div');scroll.className='table-scroll';table.replaceWith(scroll);scroll.append(table);});
    root.querySelectorAll('input').forEach(input=>input.disabled=true);
  }
  reportHeight();document.fonts.ready.then(reportHeight);return true;
}
new ResizeObserver(reportHeight).observe(root);

// A text selection inside code is text, even if it happens to contain Markdown.
document.addEventListener('copy',event=>{
  const selection=window.getSelection();
  if(!selection||selection.isCollapsed)return;
  const element=node=>node?.nodeType===Node.ELEMENT_NODE?node:node?.parentElement;
  const pre=element(selection.anchorNode)?.closest('pre');
  if(!pre||!pre.contains(selection.focusNode))return;
  event.preventDefault();
  window.webkit?.messageHandlers.copy.postMessage({text:selection.toString(),selection:true});
});

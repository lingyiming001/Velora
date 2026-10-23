'use strict';
// Convert detached clipboard/file HTML into semantic Markdown, before anything is displayed.
window.htmlToMarkdown = function(input) {
  const doc=new DOMParser().parseFromString(input,'text/html');
  // Exported diagrams keep source alongside their static SVG. Never flatten labels into prose.
  doc.querySelectorAll('.mermaid-diagram[data-mermaid-source]').forEach(node=>{
    const pre=doc.createElement('pre'),code=doc.createElement('code');code.className='language-mermaid';
    code.textContent=node.getAttribute('data-mermaid-source');pre.append(code);node.replaceWith(pre);
  });
  const formulas=[];
  const cleanTeX=source=>source
    .replace(/(?<=\\)[\p{M}\p{Cf}\uFFFD]+/gu,'')
    .replace(/[\u200B-\u200F\u202A-\u202E\u2060\uFEFF\uFFFD]/gu,'')
    .replace(/(?<!\\)\\\s*(?=(?:$|\$|\\\]|\\\)))/gu,'');
  const protect=source=>'VELORAHTMLMATH'+(formulas.push(source)-1)+'TOKEN';
  doc.querySelectorAll('.katex').forEach(node=>{
    const annotation=node.querySelector('annotation[encoding="application/x-tex"]');
    if(annotation){const display=node.closest('.katex-display');(display||node).replaceWith(doc.createTextNode(protect((display?'\n\n$$\n':'\\(')+cleanTeX(annotation.textContent)+(display?'\n$$\n\n':'\\)'))));}
  });
  doc.querySelectorAll('script,style,button,nav,iframe,object,embed,.katex-html,[aria-hidden="true"]').forEach(n=>n.remove());
  const clean=DOMPurify.sanitize(doc.body.innerHTML,{RETURN_DOM:true,FORBID_TAGS:['style','script','iframe','object','embed','form'],FORBID_ATTR:['style']});
  const children=node=>Array.from(node.childNodes).map(walk).join('');
  function list(node,depth=0){let index=Number(node.getAttribute('start'))||1;return Array.from(node.children).filter(n=>n.tagName==='LI').map(li=>{
    const nested=Array.from(li.children).filter(n=>n.matches('ul,ol'));
    const clone=li.cloneNode(true);clone.querySelectorAll(':scope>ul,:scope>ol').forEach(n=>n.remove());
    const check=clone.querySelector('input[type=checkbox]');let prefix=node.tagName==='OL'?`${index++}. `:'- ';
    if(check){prefix=`- [${check.checked?'x':' '}] `;check.remove();}
    return '    '.repeat(depth)+prefix+children(clone).trim().replace(/\n\n/g,'\n'+'    '.repeat(depth+1))+nested.map(n=>'\n'+list(n,depth+1)).join('');
  }).join('\n');}
  function codeSource(node){
    const clone=node.cloneNode(true);clone.querySelectorAll('br').forEach(n=>n.replaceWith(doc.createTextNode('\n')));
    clone.querySelectorAll('div').forEach(n=>{if(n.nextSibling)n.append(doc.createTextNode('\n'));});
    return clone.textContent.replace(/\r\n?/g,'\n').replace(/\n$/,'');
  }
  function walk(n){if(n.nodeType===3)return n.textContent.replace(/\\\([\s\S]+?\\\)|\\\[[\s\S]+?\\\]|\$\$[\s\S]+?\$\$|\$[^\n$]+?\$/g,protect).replace(/([*_`])/g,'\\$1');if(n.nodeType!==1)return '';const text=()=>children(n);
    switch(n.tagName){
      case 'H1':case 'H2':case 'H3':case 'H4':case 'H5':case 'H6':return '\n\n'+'#'.repeat(Number(n.tagName[1]))+' '+text().trim()+'\n\n';
      case 'P':case 'DIV':case 'SECTION':case 'ARTICLE':return '\n\n'+text().trim()+'\n\n';
      case 'BR':return '  \n';
      case 'STRONG':case 'B':return '**'+text()+'**';case 'EM':case 'I':return '*'+text()+'*';case 'DEL':case 'S':return '~~'+text()+'~~';
      case 'CODE':{const t=n.textContent;const fence='`'.repeat(Math.max(1,...(t.match(/`+/g)||[]).map(s=>s.length+1)));return fence+' '+t+' '+fence;}
      case 'PRE':{const code=n.querySelector('code')||n;const t=codeSource(code);const fence='`'.repeat(Math.max(3,...(t.match(/`+/g)||[]).map(s=>s.length+1)));
        const lang=(code.className.match(/language-([\w+#.-]+)/i)||[])[1]||code.getAttribute('data-language')||n.getAttribute('data-language')||
          (n.classList.contains('mermaid')||/^(?:flowchart|graph)\s+(?:TD|TB|BT|LR|RL)\b|^(?:sequenceDiagram|classDiagram|stateDiagram|erDiagram|mindmap|gantt|pie|journey|timeline)\b/.test(t.trimStart())?'mermaid':'');
        return '\n\n'+fence+lang+'\n'+t+'\n'+fence+'\n\n';}
      case 'UL':case 'OL':return '\n\n'+list(n)+'\n\n';
      case 'BLOCKQUOTE':return '\n\n'+text().trim().split('\n').map(s=>'> '+s).join('\n')+'\n\n';
      case 'HR':return '\n\n---\n\n';
      case 'A':{const href=n.getAttribute('href')||'';return /^(https?:|mailto:)/i.test(href)?'['+text()+'](<'+href.replace(/>/g,'%3E')+'>)':text();}
      case 'IMG':{const src=n.getAttribute('src')||'';return /^(https?:|data:image\/)/i.test(src)?'!['+(n.alt||'图片')+'](<'+src+'>)':'';}
      case 'TABLE':{const rows=Array.from(n.rows).map(r=>Array.from(r.cells).map(c=>children(c).trim().replace(/\|/g,'\\|').replace(/\n+/g,'<br>')));if(!rows.length)return '';const width=Math.max(...rows.map(r=>r.length));const row=r=>'| '+Array.from({length:width},(_,i)=>r[i]||'').join(' | ')+' |';return '\n\n'+[row(rows[0]),row(Array(width).fill('---')),...rows.slice(1).map(row)].join('\n')+'\n\n';}
      case 'SUP':case 'SUB':return '<'+n.tagName.toLowerCase()+'>'+text()+'</'+n.tagName.toLowerCase()+'>';
      default:return text();
    }
  }
  return children(clean).replace(/VELORAHTMLMATH([0-9]+)TOKEN/g,(_,i)=>formulas[Number(i)]||'').trim();
};
window.prepareExport = async function(){
  document.documentElement.classList.remove('dark');
  const style=document.createElement('style');style.textContent='html,body{overflow:visible!important}#content{padding:0}pre code{white-space:pre-wrap!important;overflow-wrap:anywhere}table{table-layout:fixed}td,th{min-width:0!important;overflow-wrap:anywhere}img{max-width:100%;height:auto}.code-header button,.mermaid-source{display:none}';document.head.append(style);
  await document.fonts.ready;
  await prepareDiagramExports();
  root.querySelectorAll('.mermaid-canvas svg').forEach(svg=>{svg.style.maxWidth='100%';svg.style.width='100%';svg.style.height='auto';});
  await Promise.all(Array.from(root.querySelectorAll('img')).map(img=>img.complete?Promise.resolve():new Promise(resolve=>{img.onload=img.onerror=resolve;setTimeout(resolve,4000);}))); 
  root.querySelectorAll('.katex-display').forEach(n=>{if(n.scrollWidth>root.clientWidth)n.style.fontSize=(root.clientWidth/n.scrollWidth*.97)+'em';});
  await new Promise(resolve=>setTimeout(resolve,30));
  return root.getBoundingClientRect().height;
};
window.exportCuts=function(height){
  const protectedRects=[];
  root.querySelectorAll('h1,h2,h3,h4,h5,h6,tr,.katex-display,img,.mermaid-diagram').forEach(n=>{const r=n.getBoundingClientRect();if(r.height<height*.8)protectedRects.push([r.top+scrollY,r.bottom+scrollY]);});
  const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);let n;
  while(n=walker.nextNode()){const range=document.createRange();range.selectNodeContents(n);for(const r of range.getClientRects())if(r.height<height*.5)protectedRects.push([r.top+scrollY,r.bottom+scrollY]);}
  const end=Math.ceil(root.getBoundingClientRect().bottom+scrollY);const cuts=[0];
  while(cuts.at(-1)<end){const start=cuts.at(-1);let next=Math.min(end,start+height);let changed;
    do{changed=false;for(const [top,bottom] of protectedRects)if(top<next-.5&&bottom>next+.5&&top>start+height*.15){next=top-1;changed=true;}}while(changed);
    if(next<=start+1)next=Math.min(end,start+height);cuts.push(next);
  }return cuts;
};
window.wordContent=function(){
  const clone=root.cloneNode(true), math={};
  clone.querySelectorAll('.code-header').forEach(n=>n.remove());
  clone.querySelectorAll('.katex').forEach((node,i)=>{const key='VELORAMATH'+String(i).padStart(8,'0');const m=node.querySelector('math');if(m)math[key]=m.outerHTML;const display=node.closest('.katex-display');if(display){const p=document.createElement('p');p.dataset.equationToken='true';p.textContent=key;display.replaceWith(p);}else node.replaceWith(document.createTextNode(key));});
  const blocks=[];
  function inline(node,prefix=''){
    let text=prefix,runs=[];
    function walk(n,style={}){if(n.nodeType===3){if(/^\s+$/.test(n.textContent)&&n.textContent.includes('\n'))return;let value=n.textContent.replace(/\s+/g,' ');if(!text||text===prefix)value=value.replace(/^ +/,'');const start=text.length;text+=value;if(Object.keys(style).length&&text.length>start)runs.push({location:start,length:text.length-start,style});return;}if(n.nodeType!==1)return;
      const s={...style};if(n.matches('strong,b'))s.bold=true;if(n.matches('em,i'))s.italic=true;if(n.matches('s,del'))s.strikethrough=true;if(n.matches('code')){s.fontFamily='Menlo';s.code=true;}if(n.matches('a')&&/^(https?:|mailto:)/i.test(n.getAttribute('href')||''))s.link=n.getAttribute('href');
      if(n.tagName==='BR')text+='\n';else Array.from(n.childNodes).forEach(c=>walk(c,s));}
    Array.from(node.childNodes).forEach(n=>walk(n));text=text.trimEnd();runs=runs.map(r=>({...r,length:Math.min(r.length,text.length-r.location)})).filter(r=>r.length>0);return {text,formatting:runs};
  }
  function add(node,prefix='',kind='paragraph'){const value=inline(node,prefix);if(value.text.trim())blocks.push({kind,...value});}
  function list(node,depth=0){let index=Number(node.getAttribute('start'))||1;Array.from(node.children).filter(n=>n.tagName==='LI').forEach(li=>{const nested=Array.from(li.children).filter(n=>n.matches('ul,ol'));const own=li.cloneNode(true);own.querySelectorAll(':scope>ul,:scope>ol').forEach(n=>n.remove());add(own,'    '.repeat(depth)+(node.tagName==='OL'?`${index++}. `:'• '));nested.forEach(n=>list(n,depth+1));});}
  function visit(n){if(n.nodeType===3){if(n.textContent.trim())blocks.push({kind:'paragraph',text:n.textContent});return;}if(n.nodeType!==1)return;
    if(n.classList.contains('mermaid-diagram')){if(n.dataset.exportPng)blocks.push({kind:'image',text:n.dataset.exportPng});else blocks.push({kind:'code',language:'mermaid',text:n.dataset.mermaidSource||''});return;}
    if(/^H[1-6]$/.test(n.tagName)){add(n,'',n.tagName==='H1'?'heading':n.tagName==='H2'?'heading2':'heading3');return;}
    if(n.tagName==='PRE'){blocks.push({kind:'code',text:(n.querySelector('code')||n).textContent});return;}
    if(n.tagName==='TABLE'){blocks.push({kind:'table',text:JSON.stringify(Array.from(n.rows).map(r=>Array.from(r.cells).map(c=>htmlToMarkdown(c.innerHTML))))});return;}
    if(n.matches('ul,ol')){list(n);return;}if(n.tagName==='IMG'){blocks.push({kind:'image',text:n.getAttribute('src')||''});return;}
    if(n.tagName==='HR'){blocks.push({kind:'divider',text:''});return;}
    if(n.matches('p,blockquote')){if(n.querySelector('img')){Array.from(n.childNodes).forEach(visit);return;}add(n,'',n.hasAttribute('data-equation-token')?'equation':n.tagName==='BLOCKQUOTE'?'quote':'paragraph');return;}
    Array.from(n.childNodes).forEach(visit);
  }
  Array.from(clone.childNodes).forEach(visit);return {blocks,math};
};

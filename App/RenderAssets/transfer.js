'use strict';
// Convert detached clipboard/file HTML into semantic Markdown, before anything is displayed.
// Rasterize static SVG clipboard illustrations before the semantic converter
// drops unsupported SVG nodes. Use an explicit geometry-only allowlist: no
// scripts, CSS, external references, foreignObject, animation, or event handlers.
window.clipboardHTMLToMarkdown = async function(input,plainText='') {
  const doc=new DOMParser().parseFromString(input,'text/html');
  const tags=new Set(['svg','g','path','circle','ellipse','rect','line','polyline','polygon']);
  const attributes=new Set(['viewBox','d','cx','cy','r','rx','ry','x','y','x1','x2','y1','y2','width','height','points','transform','fill','stroke','stroke-width','stroke-linecap','stroke-linejoin','fill-rule','clip-rule','opacity','fill-opacity','stroke-opacity']);
  for(const source of Array.from(doc.querySelectorAll('svg'))){
    if(source.closest('button,nav,.katex,.mermaid-diagram')||source.querySelector('svg,text')||!source.querySelector('path,circle,ellipse,rect,line,polyline,polygon'))continue;
    const box=source.getAttribute('viewBox')||'0 0 24 24';
    const dims=box.trim().split(/[ ,]+/).map(Number);
    if(dims.length!==4||!dims.every(Number.isFinite)||dims[2]<=0||dims[3]<=0||source.outerHTML.length>200000)continue;
    const clone=document.createElementNS('http://www.w3.org/2000/svg','svg');
    clone.setAttribute('xmlns','http://www.w3.org/2000/svg');clone.setAttribute('viewBox',box);
    const width=Math.min(1024,Math.max(16,Number.parseFloat(source.getAttribute('width'))||dims[2]));
    const height=Math.min(1024,Math.max(16,width*dims[3]/dims[2]));
    clone.setAttribute('width',width);clone.setAttribute('height',height);
    function copy(from,to){
      for(const attr of Array.from(from.attributes)){
        if(!attributes.has(attr.name)||/url\s*\(|[<>]|javascript:|data:/i.test(attr.value))continue;
        to.setAttribute(attr.name,attr.value.replace(/currentColor/gi,'#666666'));
      }
      for(const child of Array.from(from.children)){
        if(!tags.has(child.localName)||child.localName==='svg')continue;
        const element=document.createElementNS('http://www.w3.org/2000/svg',child.localName);copy(child,element);to.append(element);
      }
    }
    copy(source,clone);clone.setAttribute('width',width);clone.setAttribute('height',height);
    const url='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(new XMLSerializer().serializeToString(clone));
    try{
      const picture=new Image();
      await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(new Error('SVG decode timeout')),2000);picture.onload=()=>{clearTimeout(timer);resolve()};picture.onerror=()=>{clearTimeout(timer);reject(new Error('SVG decode failed'))};picture.src=url;});
      const canvas=document.createElement('canvas');canvas.width=Math.ceil(width);canvas.height=Math.ceil(height);
      canvas.getContext('2d').drawImage(picture,0,0,canvas.width,canvas.height);
      const image=doc.createElement('img');image.src=canvas.toDataURL('image/png');image.alt=source.getAttribute('aria-label')||'图标';
      // Hidden SVG icons are decorative for accessibility, but still visible.
      // Replace the icon wrapper so its aria-hidden does not discard the image.
      const wrapper=source.parentElement;
      if(wrapper&&wrapper.getAttribute('aria-hidden')==='true'&&wrapper.children.length===1&&!wrapper.textContent.trim())wrapper.replaceWith(image);
      else source.replaceWith(image);
    }catch(error){
      const label=source.getAttribute('aria-label');
      if(label)source.replaceWith(doc.createTextNode(label));
      else throw error;
    }
  }
  return htmlToMarkdown(doc.body.innerHTML,plainText);
};
window.htmlToMarkdown = function(input,plainText='') {
  const doc=new DOMParser().parseFromString(input,'text/html');
  // Clipboard DOM may represent visual code lines as block-styled spans.
  // Record only line boundaries before source CSS is stripped.
  doc.querySelectorAll('pre').forEach(pre=>{
    pre.querySelectorAll('span,div,p').forEach(line=>{
      const display=line.style.display.toLowerCase();
      if(display==='block'||line.classList.contains('line')){
        if(line.nextSibling&&line.lastChild?.nodeName!=='BR'&&!line.textContent.endsWith('\n'))line.append(doc.createTextNode('\n'));
        if(!line.textContent&&line.nextSibling)line.append(doc.createTextNode('\n'));
      }
    });
    if(!pre.getAttribute('data-language')){
      let language=pre.closest('[data-language]')?.getAttribute('data-language');
      if(!language){
        const known=new Set(['python','javascript','typescript','java','swift','kotlin','go','rust','ruby','php','c','c++','c#','bash','shell','sql','json','yaml','html','css','xml','markdown','mermaid','plain text']);
        for(let node=pre,depth=0;node&&depth<3&&!language;node=node.parentElement,depth++){
          const header=node.previousElementSibling?.cloneNode(true);
          if(!header)continue;
          header.querySelectorAll('button,svg,[role=button]').forEach(n=>n.remove());
          const label=header.textContent.trim().toLowerCase();
          if(known.has(label))language=label;
          else if(header.matches('p')&&/\b[\w.-]+\.py\b/.test(label))language='python';
        }
      }
      if(language)pre.setAttribute('data-language',language);
    }
  });
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
  // Capture a small, inert set of layout hints before sanitizing all CSS.
  // Never execute source styles or flatten semantic lists/code/tables/headings.
  const hardBlocks='h1,h2,h3,h4,h5,h6,pre,table,ul,ol,img,video,audio,hr';
  doc.querySelectorAll('[data-velora-inline],[data-velora-row]').forEach(n=>{n.removeAttribute('data-velora-inline');n.removeAttribute('data-velora-row');});
  doc.querySelectorAll('[style]').forEach(n=>{
    const display=n.style.display.toLowerCase(),direction=n.style.flexDirection.toLowerCase();
    if(['inline','inline-block','inline-flex','inline-grid'].includes(display)&&!n.querySelector(hardBlocks))n.dataset.veloraInline='true';
    if(['flex','inline-flex'].includes(display)&&!direction.startsWith('column')&&n.children.length<=8&&n.textContent.length<=1000&&!n.querySelector(hardBlocks)){
      n.dataset.veloraRow='true';
      n.querySelectorAll('p,div,section,blockquote').forEach(c=>c.dataset.veloraInline='true');
    }
  });
  // Browser clipboard plain text reflects visible line boundaries even when
  // CSS classes were not copied. Join only an exact same-line pair of small
  // text containers; never infer rows from words such as “difficulty”.
  const lineKey=s=>s.replace(/[`*_~]/g,'').replace(/\s+/g,'');
  const visibleLines=new Set(plainText.split(/\r?\n/).map(lineKey).filter(Boolean));
  const simple=n=>n&&['P','DIV','BLOCKQUOTE'].includes(n.tagName)&&!n.querySelector(hardBlocks)&&n.querySelectorAll('p,blockquote').length<=1&&n.textContent.trim().length>0&&n.textContent.length<=240;
  if(visibleLines.size)Array.from(doc.body.querySelectorAll('p,div,blockquote')).forEach(a=>{
    const b=a.nextElementSibling;
    if(!simple(a)||!simple(b)||a.closest('[data-velora-row]')||!visibleLines.has(lineKey(a.textContent+b.textContent)))return;
    const row=doc.createElement('div');row.dataset.veloraRow='true';a.before(row);row.append(a,b);
    [a,b,...row.querySelectorAll('p,div,blockquote')].forEach(n=>n.dataset.veloraInline='true');
  });
  const clean=DOMPurify.sanitize(doc.body.innerHTML,{RETURN_DOM:true,FORBID_TAGS:['style','script','iframe','object','embed','form'],FORBID_ATTR:['style']});
  const children=node=>Array.from(node.childNodes).map(walk).join('');
  function list(node,depth=0){const start=Number.parseInt(node.getAttribute('start'),10);let index=Number.isFinite(start)?start:1;return Array.from(node.children).filter(n=>n.tagName==='LI').map(li=>{
    const nested=Array.from(li.children).filter(n=>n.matches('ul,ol'));
    const clone=li.cloneNode(true);clone.querySelectorAll(':scope>ul,:scope>ol').forEach(n=>n.remove());
    const itemValue=Number.parseInt(li.getAttribute('value'),10);if(node.tagName==='OL'&&Number.isFinite(itemValue))index=itemValue;
    const check=clone.querySelector('input[type=checkbox]');let prefix=node.tagName==='OL'?`${index++}. `:'- ';
    if(check){prefix=`- [${check.checked?'x':' '}] `;check.remove();}
    return '    '.repeat(depth)+prefix+children(clone).trim().replace(/\n\n/g,'\n'+'    '.repeat(depth+1))+nested.map(n=>'\n'+list(n,depth+1)).join('');
  }).join('\n');}
  function codeSource(node){
    const clone=node.cloneNode(true);clone.querySelectorAll('br').forEach(n=>n.replaceWith(doc.createTextNode('\n')));
    clone.querySelectorAll('div').forEach(n=>{if(n.nextSibling)n.append(doc.createTextNode('\n'));});
    const source=clone.textContent.replace(/\r\n?/g,'\n').replace(/\n$/,'');
    // Some rich clipboard HTML drops all visual line breaks. Plain text still
    // carries them: use it only when the exact non-whitespace source occurs once.
    const plain=plainText.replace(/\r\n?/g,'\n'),key=source.replace(/\s/g,'');
    if(key.length>=12&&key.length<=200000&&plain.length<=1000000){
      let compact='',positions=[];
      for(let i=0;i<plain.length;i++)if(!/\s/.test(plain[i])){compact+=plain[i];positions.push(i);}
      const match=compact.indexOf(key);
      if(match>=0&&compact.indexOf(key,match+1)<0){
        const first=positions[match],last=positions[match+key.length-1]+1;
        const lineStart=plain.lastIndexOf('\n',first-1)+1;
        const start=/^[ \t]*$/.test(plain.slice(lineStart,first))?lineStart:first;
        const candidate=plain.slice(start,last);
        if(candidate.includes('\n')&&candidate.replace(/\s/g,'')===key)return candidate;
      }
    }
    return source;
  }
  function walk(n){if(n.nodeType===3)return n.textContent.replace(/\\\([\s\S]+?\\\)|\\\[[\s\S]+?\\\]|\$\$[\s\S]+?\$\$|\$[^\n$]+?\$/g,protect).replace(/[ \t\r\n\f]+/g,' ').replace(/([*_`])/g,'\\$1');if(n.nodeType!==1)return '';const text=()=>children(n);
    // A compact card is the smallest semantic container holding one image
    // and a short title/description/caption, never a whole article/list.
    if(['DIV','SECTION','ARTICLE'].includes(n.tagName)){
      const resources=Array.from(n.querySelectorAll('img,a')).filter(e=>e.tagName==='IMG'||(!e.querySelector('img')&&/^https?:\/\/images\.openai\.com\/static-rsc-\d+\//i.test(e.getAttribute('href')||'')));
      const paragraphs=Array.from(n.querySelectorAll('p,h1,h2,h3,h4')).filter(p=>!p.querySelector('p,h1,h2,h3,h4,img')&&p.textContent.trim());
      const smaller=Array.from(n.children).some(c=>c.querySelector('img,a[href*="images.openai.com/static-rsc-"]')&&c.querySelectorAll('p,h1,h2,h3,h4').length>=2);
      const headingLike=paragraphs[0]&&(paragraphs[0].matches('h1,h2,h3,h4')||paragraphs[0].querySelector('strong,b')||resources[0]?.tagName==='A'||n.classList.contains('velora-image-card'));
      if(resources.length===1&&paragraphs.length>=2&&paragraphs.length<=4&&headingLike&&paragraphs[0].textContent.length<=100&&!smaller&&n.textContent.length<2000&&!n.querySelector('pre,table,ul,ol')){
        const resource=resources[0],image=resource.getAttribute(resource.tagName==='IMG'?'src':'href')||'';
        if(/^(https?:|data:image\/)/i.test(image)){
          const title=paragraphs[0].textContent.trim(),rest=paragraphs.slice(1).map(p=>p.textContent.trim());
          const card={image,title,body:rest.slice(0,rest.length>1?-1:1).join('\n'),caption:rest.length>1?rest.at(-1):''};
          return '\n\n```velora-image-card\n'+JSON.stringify(card)+'\n```\n\n';
        }
      }
    }
    if(n.dataset.veloraRow==='true')return (n.dataset.veloraInline==='true'?'':'\n\n')+Array.from(n.childNodes).map(walk).map(s=>s.trim()).filter(Boolean).join(' ')+(n.dataset.veloraInline==='true'?'':'\n\n');
    if(n.dataset.veloraInline==='true'&&['P','DIV','SECTION','ARTICLE','BLOCKQUOTE'].includes(n.tagName))return text();
    switch(n.tagName){
      case 'H1':case 'H2':case 'H3':case 'H4':case 'H5':case 'H6':return '\n\n'+'#'.repeat(Number(n.tagName[1]))+' '+text().trim()+'\n\n';
      case 'P':case 'DIV':case 'SECTION':case 'ARTICLE':return '\n\n'+text().trim()+'\n\n';
      case 'BR':return '  \n';
      case 'STRONG':case 'B':return '**'+text()+'**';case 'EM':case 'I':return '*'+text()+'*';case 'DEL':case 'S':return '~~'+text()+'~~';
      case 'CODE':{const t=n.textContent;const fence='`'.repeat(Math.max(1,...(t.match(/`+/g)||[]).map(s=>s.length+1)));return fence+' '+t+' '+fence;}
      case 'PRE':{const code=n.querySelector('code')||n;const t=codeSource(code);const fence='`'.repeat(Math.max(3,...(t.match(/`+/g)||[]).map(s=>s.length+1)));
        const lang=(code.className.match(/language-([\w+#.-]+)/i)||[])[1]||code.getAttribute('data-language')||n.getAttribute('data-language')||
          (n.classList.contains('mermaid')||/^(?:flowchart|graph)\s+(?:TD|TB|BT|LR|RL)\b|^(?:sequenceDiagram|classDiagram|stateDiagram|erDiagram|mindmap|gantt|pie|journey|timeline)\b/.test(t.trimStart())?'mermaid':
            /^(?:from [\w.]+ import |(?:async )?def \w+\([^\n]*\):)/.test(t.trimStart())?'python':'');
        const damaged=lang.toLowerCase()==='python'&&!t.includes('\n')&&/\bfrom [\w.]+ import \w+from [\w.]+ import /.test(t);
        const warning=damaged?'\n> [!WARNING]\n> 来源剪贴板中的 Python 代码已缺少换行。请使用 ChatGPT 代码块自身的“复制代码”按钮重新复制，再粘贴到此处；原文暂予保留，未自动猜测重排。\n':'';
        return '\n\n'+fence+lang+'\n'+t+'\n'+fence+'\n\n'+warning;}
      case 'UL':case 'OL':return '\n\n'+list(n)+'\n\n';
      case 'BLOCKQUOTE':return '\n\n'+text().trim().split('\n').map(s=>'> '+s).join('\n')+'\n\n';
      case 'HR':return '\n\n---\n\n';
      case 'A':{
        const href=n.getAttribute('href')||'';
        // Browser clipboard represents some ChatGPT image cards as an image
        // resource link with a source-page title, without an actual IMG node.
        let imageResource=false;
        try{
          const url=new URL(href);
          imageResource=['http:','https:'].includes(url.protocol)&&(
            (url.hostname==='images.openai.com'&&/^\/static-rsc-\d+\//.test(url.pathname))||
            /\.(?:png|jpe?g|gif|webp|avif|heic)$/i.test(url.pathname));
        }catch{}
        if(n.querySelector('img'))return text();
        if(imageResource)return '\n\n![图片](<'+href.replace(/>/g,'%3E')+'>)\n\n';
        return /^(https?:|mailto:)/i.test(href)?'['+text()+'](<'+href.replace(/>/g,'%3E')+'>)':text();
      }
      case 'IMG':{const src=n.getAttribute('src')||'';return /^(https?:|data:image\/)/i.test(src)?'\n\n!['+(n.alt||'图片')+'](<'+src+'>)\n\n':'';}
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
  function list(node,depth=0){const start=Number.parseInt(node.getAttribute('start'),10);let index=Number.isFinite(start)?start:1;Array.from(node.children).filter(n=>n.tagName==='LI').forEach(li=>{const nested=Array.from(li.children).filter(n=>n.matches('ul,ol'));const own=li.cloneNode(true);own.querySelectorAll(':scope>ul,:scope>ol').forEach(n=>n.remove());const itemValue=Number.parseInt(li.getAttribute('value'),10);if(node.tagName==='OL'&&Number.isFinite(itemValue))index=itemValue;add(own,'    '.repeat(depth)+(node.tagName==='OL'?`${index++}. `:'• '));nested.forEach(n=>list(n,depth+1));});}
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

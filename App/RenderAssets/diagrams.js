'use strict';
let mermaidLoader;
let diagramID=0;
function loadMermaid(){
  if(window.mermaid)return Promise.resolve(window.mermaid);
  if(!mermaidLoader)mermaidLoader=new Promise((resolve,reject)=>{
    const script=document.createElement('script');script.src='mermaid.min.js';
    script.onload=()=>window.mermaid?resolve(window.mermaid):reject(new Error('Mermaid unavailable'));
    script.onerror=()=>reject(new Error('Mermaid unavailable'));document.head.append(script);
  });
  return mermaidLoader;
}
function safeDiagramSVG(svg){
  const clean=DOMPurify.sanitize(svg,{USE_PROFILES:{svg:true,svgFilters:true},FORBID_TAGS:['foreignObject','image','script','a']});
  const container=document.createElement('div');container.innerHTML=clean;
  container.querySelectorAll('*').forEach(node=>{
    for(const attr of Array.from(node.attributes)){
      if(/^(?:href|xlink:href)$/i.test(attr.name)&&!attr.value.startsWith('#'))node.removeAttribute(attr.name);
      else if(/url\(/i.test(attr.value))node.setAttribute(attr.name,localURLs(attr.value));
    }
  });
  container.querySelectorAll('style').forEach(node=>node.textContent=localURLs(node.textContent).replace(/@import[^;]*;?/gi,''));
  return container.querySelector('svg');
}
function localURLs(text){return text.replace(/url\(\s*(['"]?)(.*?)\1\s*\)/gi,(_,q,url)=>url.startsWith('#')?'url('+url+')':'none');}
window.renderMermaid = async function(code,source,dark,language){
  const pre=code.parentElement,figure=document.createElement('figure');figure.className='mermaid-diagram';
  figure.dataset.mermaidSource=source;
  const header=document.createElement('div');header.className='code-header';
  const title=document.createElement('span');title.textContent='Mermaid';
  const actions=document.createElement('span');
  const copy=document.createElement('button');const copyLabel=language==='en'?'Copy source':'复制源码';
  copy.textContent=copyLabel;copy.onclick=()=>{window.webkit?.messageHandlers.copy.postMessage({text:source,language:"mermaid"});copy.textContent=language==='en'?'Copied':'已复制';setTimeout(()=>copy.textContent=copyLabel,1800);};
  const details=document.createElement('details');details.className='mermaid-source';
  const summary=document.createElement('summary');summary.textContent=language==='en'?'Show source':'查看源码';
  const sourcePre=document.createElement('pre'),sourceCode=document.createElement('code');sourceCode.textContent=source;
  sourcePre.append(sourceCode);details.append(summary,sourcePre);
  actions.append(copy);header.append(title,actions);figure.append(header);pre.replaceWith(figure);
  const canvas=document.createElement('div');canvas.className='mermaid-canvas';figure.append(canvas,details);
  try{
    const api=await loadMermaid();
    await document.fonts.ready;
    api.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,
      maxTextSize:50000,maxEdges:500,htmlLabels:false,theme:dark?'dark':'default',
      fontFamily:'-apple-system, BlinkMacSystemFont, Helvetica Neue, PingFang SC, sans-serif',
      secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','suppressErrorRendering','htmlLabels','fontFamily','dompurifyConfig','themeCSS'],
      flowchart:{htmlLabels:false,useMaxWidth:false},sequence:{useMaxWidth:false}});
    const result=await api.render('velora-diagram-'+(++diagramID),source);
    const svg=safeDiagramSVG(result.svg);
    if(!svg)throw new Error('Invalid SVG');
    svg.setAttribute('role','img');
    if(!svg.hasAttribute('aria-label'))svg.setAttribute('aria-label',language==='en'?'Mermaid diagram':'Mermaid 图表');
    const box=svg.viewBox.baseVal;
    if(box.width>0&&box.height>0){svg.style.width=Math.ceil(box.width)+'px';svg.style.maxWidth='none';svg.style.height='auto';svg.setAttribute('width',String(box.width));svg.setAttribute('height',String(box.height));}
    canvas.append(svg);
  }catch(error){
    const message=document.createElement('div');message.className='mermaid-error';
    message.textContent=(language==='en'?'Diagram could not be rendered. Check the source.':'图表无法渲染，请检查源码。')+'\n'+String(error.message||error).slice(0,1200);
    canvas.append(message);details.open=true;
  }
  reportHeight();return figure;
};
window.prepareDiagramExports=async function(){
  for(const figure of root.querySelectorAll('.mermaid-diagram')){
    const svg=figure.querySelector('.mermaid-canvas svg');if(!svg)continue;
    const clone=svg.cloneNode(true),box=svg.viewBox.baseVal;
    const width=box.width||800,height=box.height||400;
    const scale=Math.min(2,4096/Math.max(width,height),Math.sqrt(8000000/(width*height)));
    clone.setAttribute('xmlns','http://www.w3.org/2000/svg');clone.setAttribute('width',String(width));clone.setAttribute('height',String(height));
    clone.removeAttribute('style');
    const data='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(new XMLSerializer().serializeToString(clone));
    const image=new Image();
    await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=()=>reject(new Error('Diagram image export failed'));image.src=data;});
    const canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.ceil(width*scale));canvas.height=Math.max(1,Math.ceil(height*scale));
    const ctx=canvas.getContext('2d');ctx.fillStyle='#ffffff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(image,0,0,canvas.width,canvas.height);
    figure.dataset.exportPng=canvas.toDataURL('image/png');
  }
};

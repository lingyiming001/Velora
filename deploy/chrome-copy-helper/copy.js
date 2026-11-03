/* Local copy-event adapter. No network, storage, clipboard polling or AI calls. */
(() => {
  'use strict';
  const editorSelector = '.cm-editor,.cm-content';
  const lineSelector = '.cm-line';
  const blockTags = new Set(['DIV', 'P', 'LI']);

  function codeText(node) {
    const lines = Array.from(node.querySelectorAll(lineSelector));
    if (lines.length) return lines.map(line => line.textContent).join('\n');
    function read(n) {
      if (n.nodeType === 3) return n.textContent;
      if (n.nodeType !== 1 && n.nodeType !== 11) return '';
      if (n.nodeName === 'BR') return '\n';
      let text = '';
      for (const child of n.childNodes) {
        const block = child.nodeType === 1 && (blockTags.has(child.tagName) || child.classList.contains('line') || child.style.display === 'block');
        if (block && text && !text.endsWith('\n')) text += '\n';
        const value = read(child); text += value;
        if (block && (!text.endsWith('\n') || !value)) text += '\n';
      }
      return text;
    }
    return read(node);
  }

  function pre(doc, source, language = '') {
    const result = doc.createElement('pre'), code = doc.createElement('code');
    if (language) result.setAttribute('data-language', language);
    code.textContent = source; result.append(code); return result;
  }

  // A selection wholly inside an editor may omit the .cm-content wrapper when
  // cloned. Intersect each original line with the selection to retain partial
  // first/last lines, indentation, blank rows and repeated identical lines.
  function selectedEditorText(range, editor) {
    const lines = Array.from(editor.querySelectorAll(lineSelector)).filter(line => range.intersectsNode(line));
    return lines.map(line => {
      const part = range.cloneRange(); part.selectNodeContents(line);
      if (range.compareBoundaryPoints(0, part) > 0) part.setStart(range.startContainer, range.startOffset);
      if (range.compareBoundaryPoints(2, part) < 0) part.setEnd(range.endContainer, range.endOffset);
      return part.toString();
    }).join('\n');
  }

  function plainText(node) {
    if (node.nodeType === 3) return node.textContent.replace(/[\t\r\n ]+/g, ' ');
    if (node.nodeType !== 1) return '';
    if (node.tagName === 'PRE') return '\n\n' + node.textContent + '\n\n';
    if (node.tagName === 'BR') return '\n';
    const text = Array.from(node.childNodes, plainText).join('');
    if (/^(?:P|DIV|SECTION|ARTICLE|H[1-6]|BLOCKQUOTE|UL|OL|TABLE)$/.test(node.tagName)) return '\n\n' + text + '\n\n';
    if (node.tagName === 'LI' || node.tagName === 'TR') return text + '\n';
    if (node.tagName === 'TD' || node.tagName === 'TH') return text + '\t';
    return text;
  }

  function serialize(selection) {
    if (!selection || selection.isCollapsed || selection.rangeCount !== 1) return null;
    const range = selection.getRangeAt(0), doc = range.startContainer.ownerDocument;
    const fragment = range.cloneContents(), root = doc.createElement('div'); root.append(fragment);
    // CodeMirror virtual gaps stand for source lines absent from the DOM.
    // Leave native copy in charge rather than silently outputting partial code.
    if (root.querySelector('.cm-gap')) return null;
    const start = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement;
    const end = range.endContainer.nodeType === 1 ? range.endContainer : range.endContainer.parentElement;
    const editor = start?.closest('.cm-content');
    if (editor && editor === end?.closest('.cm-content')) {
      root.replaceChildren(pre(doc, selectedEditorText(range, editor)));
    } else {
      if (!root.querySelector('pre,' + editorSelector + ',' + lineSelector)) return null;
      // Normalize PRE first so editor wrappers do not create nested PRE nodes.
      for (const node of Array.from(root.querySelectorAll('pre'))) {
        const language = node.getAttribute('data-language') || (node.querySelector('code')?.className.match(/language-([\w+#.-]+)/) || [])[1] || '';
        node.replaceWith(pre(doc, codeText(node), language));
      }
      for (const node of Array.from(root.querySelectorAll(editorSelector))) {
        if (root.contains(node)) node.replaceWith(pre(doc, codeText(node)));
      }
      // Selections whose common ancestor is a code editor contain bare rows.
      for (const parent of [root, ...root.querySelectorAll('*')]) {
        if (parent.closest?.('pre') || !Array.from(parent.children).some(n => n.matches(lineSelector))) continue;
        const children = Array.from(parent.childNodes);
        let rows = [];
        const flush = () => {
          if (!rows.length) return;
          const replacement = pre(doc, rows.map(n => n.textContent).join('\n'));
          rows[0].before(replacement); rows.forEach(n => n.remove()); rows = [];
        };
        for (const child of children) {
          if (child.nodeType === 1 && child.matches(lineSelector)) rows.push(child);
          else flush();
        }
        flush();
      }
    }
    root.querySelectorAll('button,script,style,.cm-gutters,.cm-announced,.cm-tooltip').forEach(n => n.remove());
    const html = root.innerHTML;
    if (html.length > 2_000_000) return null;
    // Trim only outer prose separators; PRE text itself is never trimmed.
    return {html, plain: Array.from(root.childNodes, plainText).join('').replace(/^\n\n|\n\n$/g, '')};
  }

  window.addEventListener('copy', event => {
    if (!event.clipboardData) return;
    try {
      const result = serialize(window.getSelection());
      if (!result) return;
      event.clipboardData.setData('text/html', result.html);
      event.clipboardData.setData('text/plain', result.plain);
      event.preventDefault();
      event.stopImmediatePropagation();
    } catch (_) { /* Leave normal copy intact if the page structure changes. */ }
  }, true);
})();

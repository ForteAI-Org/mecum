/// BrowserScripts contains fixed, audited DOM operations. Model-supplied JavaScript is never evaluated.
enum BrowserScripts {
    static let clickPoint = #"""
    function() {
      const text = this.nodeType === 3;
      const element = text ? this.parentElement : this.nodeType === 1 ? this : null;
      if (!this.isConnected || !element) return null;
      const parent = e => e.parentElement || (e.getRootNode() && e.getRootNode().host);
      for (let e=element; e; e=parent(e)) {
        if (e.disabled || e.matches(':disabled') || e.inert || e.getAttribute('aria-disabled') === 'true') return null;
        if (e.tagName === 'LABEL' && e.control && e.control.matches(':disabled')) return null;
      }
      const doc=element.ownerDocument, w=doc.defaultView;
      if (w.getComputedStyle(element).visibility !== 'visible') return null;
      element.scrollIntoView({block:'center', inline:'center', behavior:'instant'});
      // AX StaticText can identify a DOM Text node. Its range, not its parent's box, is the target.
      let range;
      if (text) { range=doc.createRange(); range.selectNodeContents(this); }
      const rects = text ? range.getClientRects() : element.getClientRects();
      for (const r of rects) {
        const left=Math.max(0,r.left), right=Math.min(w.innerWidth,r.right);
        const top=Math.max(0,r.top), bottom=Math.min(w.innerHeight,r.bottom);
        if (right<=left || bottom<=top) continue;
        const x=(left+right)/2, y=(top+bottom)/2;
        let hit=doc.elementFromPoint(x,y);
        while (hit && hit.shadowRoot) {
          const next=hit.shadowRoot.elementFromPoint(x,y);
          if (!next || next===hit) break;
          hit=next;
        }
        if (text) { if (hit===element) return {x,y}; }
        else { for (let e=hit; e; e=parent(e)) if (e===element) return {x,y}; }
      }
      return null;
    }
    """#

    static let framePoint = #"""
    function(x,y) {
      if (!this.isConnected) return null;
      const r=this.getBoundingClientRect(), w=this.ownerDocument.defaultView;
      if (Math.abs(r.width-this.offsetWidth)>1 || Math.abs(r.height-this.offsetHeight)>1) return null;
      x += r.left + this.clientLeft; y += r.top + this.clientTop;
      if (x<0 || y<0 || x>=w.innerWidth || y>=w.innerHeight || this.ownerDocument.elementFromPoint(x,y)!==this) return null;
      return {x,y};
    }
    """#

    static let prepareFill = #"""
    function() {
      if (this.nodeType !== 1 || !this.isConnected || this.disabled || this.readOnly || this.getAttribute('aria-disabled')==='true') return false;
      const w=this.ownerDocument.defaultView, r=this.getBoundingClientRect();
      if (r.width<=0 || r.height<=0 || w.getComputedStyle(this).visibility!=='visible') return false;
      const native=this.tagName==='TEXTAREA' || (this.tagName==='INPUT' && ['text','search','email','url','tel','password','number'].includes(this.type));
      if (!native && !this.isContentEditable) return false;
      this.focus();
      if (native) { if (this.type==='number') return false; this.select(); }
      else { const range=this.ownerDocument.createRange(); range.selectNodeContents(this); const sel=w.getSelection(); sel.removeAllRanges(); sel.addRange(range); }
      let focused=this.ownerDocument.activeElement; while(focused && focused.shadowRoot && focused.shadowRoot.activeElement) focused=focused.shadowRoot.activeElement;
      return focused===this;
    }
    """#

    static let verifyFill = #"""
    function(text) { return this.isConnected && (this.isContentEditable ? this.textContent : this.value)===text; }
    """#

    static let selectOption = #"""
    function(value) {
      if (!this.isConnected || this.tagName!=='SELECT' || this.disabled || this.multiple) return {accepted:false};
      const options=Array.from(this.options), matches=options.filter(o=>o.value===value || o.label===value);
      if (matches.length!==1 || matches[0].disabled || (matches[0].parentElement.tagName==='OPTGROUP' && matches[0].parentElement.disabled)) return {accepted:false};
      const chosen=matches[0]; this.value=chosen.value;
      this.dispatchEvent(new Event('input',{bubbles:true})); this.dispatchEvent(new Event('change',{bubbles:true}));
      return {accepted:true,verified:this.isConnected && this.value===chosen.value && chosen.selected};
    }
    """#

    static let readChecked = #"""
    function() { return this.isConnected && !this.disabled && this.tagName==='INPUT' && ['checkbox','radio'].includes(this.type) ? this.checked : null; }
    """#
}

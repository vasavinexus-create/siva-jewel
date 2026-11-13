export function enableImageViewer(img) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'view-image';
  button.setAttribute('aria-label', 'View ' + (img.alt || 'shop logo'));
  img.before(button);
  button.append(img);
  button.onclick = () => {
    const dialog = document.createElement('dialog');
    dialog.className = 'image-viewer';
    dialog.setAttribute('aria-label', img.alt || 'Shop logo');
    dialog.innerHTML = '<div class="image-tools"><button type="button" data-zoom="-1">Zoom out</button><button type="button" data-zoom="1">Zoom in</button><button type="button" autofocus>Close</button></div><div class="image-stage" tabindex="0" aria-label="Drag or scroll to move the zoomed image"></div>';
    const stage = dialog.querySelector('.image-stage');
    const full = img.cloneNode();
    full.removeAttribute('class');
    stage.append(full);
    document.body.append(dialog);
    dialog.addEventListener('close', () => { dialog.remove(); button.focus(); });
    dialog.querySelector('[autofocus]').onclick = () => dialog.close();
    dialog.showModal();
    let zoom = 1;
    function resize() {
      if (!full.naturalWidth) return;
      const fit = Math.min(stage.clientWidth / full.naturalWidth, stage.clientHeight / full.naturalHeight);
      full.style.width = full.naturalWidth * fit * zoom + 'px';
      full.style.height = full.naturalHeight * fit * zoom + 'px';
    }
    full.onload = resize;
    resize();
    const observer = new ResizeObserver(resize);
    observer.observe(stage);
    dialog.addEventListener('close', () => observer.disconnect());
    function setZoom(value) {
      zoom = Math.max(1, Math.min(8, value));
      resize();
    }
    dialog.querySelectorAll('[data-zoom]').forEach(control => {
      control.onclick = () => {
        setZoom(zoom * 1.5 ** Number(control.dataset.zoom));
      };
    });
    const pointers = new Map();
    stage.onpointerdown = event => {
      if (pointers.size >= 2) return;
      if (event.pointerType !== 'touch' && (event.button !== 0 || zoom === 1 || pointers.size)) return;
      if ([...pointers.values()].some(pointer => pointer.pointerType !== 'touch')) return;
      stage.setPointerCapture(event.pointerId);
      pointers.set(event.pointerId, event);
    };
    stage.onpointermove = event => {
      const previous = pointers.get(event.pointerId);
      if (!previous) return;
      pointers.set(event.pointerId, event);
      if (pointers.size === 1) {
        if (zoom > 1) stage.scrollBy(previous.clientX - event.clientX, previous.clientY - event.clientY);
        return;
      }
      const other = [...pointers.values()].find(pointer => pointer.pointerId !== event.pointerId);
      const previousDistance = Math.hypot(previous.clientX - other.clientX, previous.clientY - other.clientY);
      const distance = Math.hypot(event.clientX - other.clientX, event.clientY - other.clientY);
      const image = full.getBoundingClientRect();
      if (!previousDistance || !image.width || !image.height) return;
      const x = ((previous.clientX + other.clientX) / 2 - image.left) / image.width;
      const y = ((previous.clientY + other.clientY) / 2 - image.top) / image.height;
      setZoom(zoom * distance / previousDistance);
      const scaled = full.getBoundingClientRect();
      stage.scrollBy(
        scaled.left + x * scaled.width - (event.clientX + other.clientX) / 2,
        scaled.top + y * scaled.height - (event.clientY + other.clientY) / 2
      );
    };
    stage.onpointerup = stage.onpointercancel = stage.onlostpointercapture = event => {
      pointers.delete(event.pointerId);
    };
  };
}

export function keepFocusedInputVisible() {
  const viewport = window.visualViewport;
  let frame;
  function schedule() {
    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(() => {
      const input = document.activeElement;
      const editing = input?.matches('textarea, input:not([type]), input[type="text"], input[type="number"], input[type="search"], input[type="tel"], input[type="email"], input[type="password"], input[type="url"], [contenteditable="true"]');
      const bottom = (viewport?.offsetTop || 0) + (viewport?.height || window.innerHeight);
      const inset = editing && (!viewport || viewport.scale === 1) ? Math.max(0, window.innerHeight - bottom) : 0;
      document.documentElement.style.setProperty('--keyboard-inset', inset + 'px');
      if (!editing || (viewport && viewport.scale !== 1)) return;
      const rect = input.getBoundingClientRect();
      if (rect.bottom > bottom - 72 || rect.top < (viewport?.offsetTop || 0) + 16) {
        input.scrollIntoView({ block: 'center', inline: 'nearest' });
        const overflow = input.getBoundingClientRect().bottom - bottom + 72;
        if (overflow > 0) window.scrollBy(0, overflow);
      }
    });
  }
  document.addEventListener('focusin', schedule);
  document.addEventListener('focusout', schedule);
  viewport?.addEventListener('resize', schedule);
  window.addEventListener('resize', schedule);
}

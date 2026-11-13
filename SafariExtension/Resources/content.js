// Tells Pergola where the playing video sits on screen, so it can mirror exactly that rectangle.
// Nothing about the page itself (no address, no content) leaves this Mac or goes anywhere but Pergola.
(() => {
  if (window.top !== window) return;
  let lastSent = "";
  let lastTime = 0;
  let queued = false;

  function pick() {
    const vs = Array.from(document.querySelectorAll("video"));
    if (!vs.length) return null;
    return vs.find(v => !v.paused && v.readyState > 1)
      || vs.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
  }

  function measure() {
    const v = pick();
    if (!v) return null;
    const r = v.getBoundingClientRect();
    if (r.width < 40 || r.height < 30) return null;
    // The picture inside the element (letterboxing taken off).
    const vw = v.videoWidth || r.width, vh = v.videoHeight || r.height;
    const s = Math.min(r.width / vw, r.height / vh);
    const w = vw * s, h = vh * s;
    return {
      x: r.left + (r.width - w) / 2, y: r.top + (r.height - h) / 2, w, h,
      innerWidth, innerHeight, outerWidth, outerHeight, screenX, screenY,
      dpr: devicePixelRatio,
      playing: !v.paused,
      protected: !!(v.mediaKeys || v.webkitKeys),
      visible: document.visibilityState === "visible",
      fullscreen: !!(document.fullscreenElement || document.webkitFullscreenElement),
    };
  }

  function report(force) {
    queued = false;
    const m = measure();
    const now = Date.now();
    const body = m ? m : { gone: true };
    const key = JSON.stringify(body);
    if (!force && key === lastSent && now - lastTime < 2000) return;
    if (!m && lastSent === key) return;
    lastSent = key; lastTime = now;
    browser.runtime.sendMessage(body).then(reply => {
      if (reply && reply.command === "pip") enterPictureInPicture();
    }).catch(() => {});
  }

  function soon() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => report(false));
  }

  function enterPictureInPicture() {
    const v = pick();
    if (!v) return;
    if (v.webkitSetPresentationMode) v.webkitSetPresentationMode("picture-in-picture");
    else if (v.requestPictureInPicture) v.requestPictureInPicture().catch(() => {});
  }

  for (const e of ["scroll", "resize"]) window.addEventListener(e, soon, { passive: true });
  for (const e of ["play", "pause", "playing", "loadedmetadata", "resize", "emptied"]) {
    document.addEventListener(e, soon, { capture: true, passive: true });
  }
  document.addEventListener("visibilitychange", () => report(true));
  document.addEventListener("fullscreenchange", soon);
  // Window moves don't fire events; a light heartbeat catches them (and tells Pergola we're here).
  setInterval(() => { if (pick()) report(false); }, 1000);
  report(true);
})();

// Passes what the page reports about its video on to Pergola, which runs on this Mac only
// (127.0.0.1), and hands any reply (such as "open the browser's own picture in picture") back.
const ports = [47600, 47601, 47602];
let port = ports[0];

async function send(body, path = "video") {
  let last = "";
  for (const p of [port, ...ports.filter(x => x !== port)]) {
    try {
      const r = await fetch(`http://127.0.0.1:${p}/${path}`, {
        method: "POST",
        // Plain text keeps it a "simple" request (no preflight).
        headers: { "Content-Type": "text/plain" },
        body: typeof body === "string" ? body : JSON.stringify(body),
      });
      if (!r.ok) continue;
      port = p;
      const j = await r.json();
      j.port = p;
      return j;
    } catch (e) { last = String(e); /* Pergola isn't running on this port */ }
  }
  return { error: last };
}

browser.runtime.onMessage.addListener((msg, sender) => {
  const tab = sender.tab || {};
  // Frames go as the bare JPEG data URL, prefixed with which tab they're from.
  if (msg.frame) return send(`${tab.id}|${msg.frame}`, "video/frame");
  if (msg.still || msg.frameError) return send({ ...msg, tab: tab.id }, "video/frame");
  return send({ ...msg, tab: tab.id, active: !!tab.active, window: tab.windowId });
});

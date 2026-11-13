// Passes what the page reports about its video on to Pergola, which runs on this Mac only
// (127.0.0.1), and hands any reply (such as "open the browser's own picture in picture") back.
const ports = [47600, 47601, 47602];
let port = ports[0];

async function send(body) {
  for (const p of [port, ...ports.filter(x => x !== port)]) {
    try {
      const r = await fetch(`http://127.0.0.1:${p}/video`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!r.ok) continue;
      port = p;
      return await r.json();
    } catch (e) { /* Pergola isn't running on this port */ }
  }
  return {};
}

browser.runtime.onMessage.addListener((msg, sender) => {
  const tab = sender.tab || {};
  return send({ ...msg, tab: tab.id, active: !!tab.active, window: tab.windowId });
});

"use strict";
const csrf = document.querySelector("meta[name='csrf-token']").content;
const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
  params: { _csrf_token: csrf }
});
const status = document.getElementById("connection-status");
window.addEventListener("phx:page-loading-start", () => document.body.setAttribute("aria-busy", "true"));
window.addEventListener("phx:page-loading-stop", () => document.body.removeAttribute("aria-busy"));
liveSocket.socket.onError(() => { status.hidden = false; });
liveSocket.socket.onOpen(() => { status.hidden = true; });
window.addEventListener("phx:download-query-result", (event) => {
  const content = event.detail && event.detail.content;
  if (typeof content !== "string") return;
  const url = URL.createObjectURL(new Blob([content], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "wotex-query-result.json";
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
});
liveSocket.connect();

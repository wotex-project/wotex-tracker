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
liveSocket.connect();

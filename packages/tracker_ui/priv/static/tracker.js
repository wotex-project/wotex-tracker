"use strict";
const csrf = document.querySelector("meta[name='csrf-token']").content;
let nativeMob = null;
const MobHook = {
  mounted() {
    if (window.mob && typeof window.mob.send === "function" && !window.mob._liveview) {
      nativeMob = window.mob;
    }
    window.mob = {
      send: (data) => this.pushEvent("mob_message", data),
      onMessage: (handler) => this.handleEvent("mob_push", handler),
      _dispatch: () => {},
      _liveview: true
    };
  }
};
const TargetBLEHook = {
  mounted() {
    this._receiveBLE = (event) => this.pushEvent("eye-ble-event", event.detail);
    window.addEventListener("wotex:ble-central", this._receiveBLE);
    this.handleEvent("eye-ble-command", (command) => {
      if (nativeMob && command && typeof command === "object" && !Array.isArray(command)) {
        try {
          nativeMob.send(command);
          return;
        } catch (_) {
          nativeMob = null;
        }
      }
      this.pushEvent("eye-ble-event", {
        schema: "wtr.mobile-ble-central-event.v1",
        request_id: command.request_id,
        event: "rejected",
        data: { reason: "unsupported" }
      });
    });
  },
  destroyed() {
    window.removeEventListener("wotex:ble-central", this._receiveBLE);
  }
};
let socketOpened = false;
const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
  params: () => ({
    _csrf_token: csrf,
    wotex_reconnect: socketOpened ? "1" : "0"
  }),
  hooks: { MobHook, TargetBLEHook }
});
const status = document.getElementById("connection-status");
window.addEventListener("phx:page-loading-start", () => document.body.setAttribute("aria-busy", "true"));
window.addEventListener("phx:page-loading-stop", () => document.body.removeAttribute("aria-busy"));
liveSocket.socket.onError(() => { status.hidden = false; });
liveSocket.socket.onOpen(() => {
  status.hidden = true;
  socketOpened = true;
});
const downloadJson = (event, filename) => {
  const content = event.detail && event.detail.content;
  if (typeof content !== "string") return;
  if (nativeMob) {
    try {
      nativeMob.send({
        schema: "wtr.mobile-share.v1",
        filename,
        media_type: "application/json",
        content
      });
      return;
    } catch (_) {
      nativeMob = null;
    }
  }
  const url = URL.createObjectURL(new Blob([content], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
};
window.addEventListener("wotex:ble-central-command", (event) => {
  const command = event.detail;
  if (!nativeMob || !command || typeof command !== "object" || Array.isArray(command)) return;
  if (command.schema !== "wtr.mobile-ble-central-command.v1") return;
  try {
    nativeMob.send(command);
  } catch (_) {
    nativeMob = null;
  }
});
window.addEventListener("phx:download-query-result", (event) => downloadJson(event, "wotex-query-result.json"));
window.addEventListener("phx:download-history-page", (event) => downloadJson(event, "wotex-history-page.json"));
window.addEventListener("phx:download-history", (event) => downloadJson(event, "wotex-retained-history.json"));
window.addEventListener("phx:download-route-page", (event) => downloadJson(event, "wotex-route-page.json"));
window.addEventListener("phx:download-trip-page", (event) => downloadJson(event, "wotex-trip-events.json"));
window.addEventListener("phx:download-trip-summary", (event) => downloadJson(event, "wotex-trip-summary.json"));
window.addEventListener("phx:download-raw-observation", (event) => downloadJson(event, "wotex-native-observation.json"));
window.addEventListener("phx:download-raw-evidence", (event) => downloadJson(event, "wotex-raw-evidence.json"));
liveSocket.connect();

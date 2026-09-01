import {Socket} from "phoenix";
import {LiveSocket} from "phoenix_live_view";

const hooks = globalThis.OpalLiveViewHooks || {};
const root = document.querySelector("[data-phx-session][data-opal-socket]");
const socketPath = root?.dataset.opalSocket || "/_opal/live";
const liveSocket = new LiveSocket(socketPath, Socket, {
  bindingPrefix: "data-opal-",
  hooks,
});

liveSocket.connect();

// Expose the upstream socket for application diagnostics and deliberate
// connect/disconnect controls. Application code should otherwise use hooks.
globalThis.OpalLiveSocket = liveSocket;

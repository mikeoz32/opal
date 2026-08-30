const DEFAULT_RECONNECT_DELAYS = [100, 500, 1000, 2000, 5000];
const HEARTBEAT_INTERVAL = 30000;

export class OpalLiveView {
  constructor(root) {
    this.root = root;
    this.token = root.dataset.opalToken;
    this.socketPath = root.dataset.opalSocket;
    this.version = 0;
    this.socket = null;
    this.reconnectAttempt = 0;
    this.heartbeatRef = 0;
    this.lastHeartbeatAck = 0;
    this.stopped = false;
    this.bindEvents();
  }

  connect() {
    if (this.stopped) return;
    const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
    const url = new URL(this.socketPath, `${scheme}//${window.location.host}`);
    this.socket = new WebSocket(url);
    this.root.dataset.opalStatus = "connecting";

    this.socket.addEventListener("open", () => {
      this.reconnectAttempt = 0;
      this.lastHeartbeatAck = Date.now();
      this.send({type: "join", protocol: 1, token: this.token});
      this.startHeartbeat();
    });

    this.socket.addEventListener("message", event => this.onMessage(event));
    this.socket.addEventListener("close", event => {
      this.stopHeartbeat();
      this.root.dataset.opalStatus = "disconnected";
      if (!this.stopped && event.code !== 1008) this.scheduleReconnect();
    });
  }

  disconnect() {
    this.stopped = true;
    this.stopHeartbeat();
    if (this.socket) this.socket.close(1000, "page unload");
  }

  bindEvents() {
    this.root.addEventListener("click", event => {
      const target = event.target.closest("[data-opal-click]");
      if (!target || !this.root.contains(target)) return;
      event.preventDefault();
      this.pushEvent(target.dataset.opalClick, this.eventValue(target));
    });

    this.root.addEventListener("submit", event => {
      const form = event.target.closest("form[data-opal-submit]");
      if (!form) return;
      event.preventDefault();
      this.pushEvent(form.dataset.opalSubmit, this.formValue(form));
    });

    const pushChange = event => {
      const target = event.target;
      const owner = target.closest("[data-opal-change]") || target.form?.closest("[data-opal-change]");
      if (!owner || !this.root.contains(owner)) return;
      const value = owner instanceof HTMLFormElement ? this.formValue(owner) : this.eventValue(owner);
      this.pushEvent(owner.dataset.opalChange, value);
    };
    this.root.addEventListener("change", pushChange);
    this.root.addEventListener("input", event => {
      const target = event.target;
      const owner = target.closest("[data-opal-change]") || target.form?.closest("[data-opal-change]");
      if (!owner || !owner.dataset.opalDebounce) return;
      window.clearTimeout(owner.__opalDebounceTimer);
      owner.__opalDebounceTimer = window.setTimeout(
        () => pushChange(event),
        Number(owner.dataset.opalDebounce) || 0,
      );
    });
  }

  pushEvent(event, value = {}) {
    if (!event || !this.socket || this.socket.readyState !== WebSocket.OPEN) return false;
    this.send({type: "event", event, value, version: this.version});
    return true;
  }

  onMessage(event) {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch (_) {
      this.socket.close(1002, "invalid server message");
      return;
    }

    if (message.type === "render") {
      if (message.protocol !== 1) {
        this.socket.close(1002, "unsupported protocol");
        return;
      }
      this.applyRender(message);
    } else if (message.type === "heartbeat") {
      this.lastHeartbeatAck = Date.now();
    } else if (message.type === "error") {
      this.root.dispatchEvent(new CustomEvent("opal:error", {detail: message}));
    }
  }

  applyRender(message) {
    const active = document.activeElement;
    const focusKey = active && this.root.contains(active)
      ? active.id || active.getAttribute("name")
      : null;
    const selection = active && "selectionStart" in active
      ? [active.selectionStart, active.selectionEnd]
      : null;

    this.root.innerHTML = message.html;
    this.version = message.version;
    this.root.dataset.opalStatus = "connected";
    if (message.title) document.title = message.title;

    if (focusKey) {
      const escaped = CSS.escape(focusKey);
      const next = this.root.querySelector(`#${escaped}, [name="${escaped}"]`);
      if (next) {
        next.focus({preventScroll: true});
        if (selection && "setSelectionRange" in next) {
          next.setSelectionRange(selection[0], selection[1]);
        }
      }
    }
    this.root.dispatchEvent(new CustomEvent("opal:render", {detail: message}));
  }

  eventValue(element) {
    const value = {};
    for (const [key, item] of Object.entries(element.dataset)) {
      if (key.startsWith("opalValue")) {
        const name = key.slice("opalValue".length);
        value[name.charAt(0).toLowerCase() + name.slice(1)] = item;
      }
    }
    if ("value" in element && element.name) value[element.name] = element.value;
    return value;
  }

  formValue(form) {
    const value = {};
    for (const [name, item] of new FormData(form).entries()) {
      if (Object.prototype.hasOwnProperty.call(value, name)) {
        value[name] = Array.isArray(value[name]) ? [...value[name], item] : [value[name], item];
      } else {
        value[name] = item;
      }
    }
    return value;
  }

  send(message) {
    this.socket.send(JSON.stringify(message));
  }

  startHeartbeat() {
    this.stopHeartbeat();
    this.heartbeatTimer = window.setInterval(() => {
      if (Date.now() - this.lastHeartbeatAck > HEARTBEAT_INTERVAL * 2) {
        this.socket.close(1001, "heartbeat timeout");
        return;
      }
      this.send({type: "heartbeat", ref: ++this.heartbeatRef});
    }, HEARTBEAT_INTERVAL);
  }

  stopHeartbeat() {
    if (this.heartbeatTimer) window.clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = null;
  }

  scheduleReconnect() {
    const delay = DEFAULT_RECONNECT_DELAYS[
      Math.min(this.reconnectAttempt, DEFAULT_RECONNECT_DELAYS.length - 1)
    ];
    this.reconnectAttempt += 1;
    window.setTimeout(() => this.connect(), delay + Math.floor(Math.random() * 100));
  }
}

export function connectAll(root = document) {
  return Array.from(root.querySelectorAll("[data-opal-live-root]"), element => {
    const liveView = new OpalLiveView(element);
    liveView.connect();
    return liveView;
  });
}

const instances = connectAll();
window.addEventListener("pagehide", () => instances.forEach(instance => instance.disconnect()));

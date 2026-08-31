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
    this.reconnectTimer = null;
    this.connectionGeneration = 0;
    this.heartbeatRef = 0;
    this.lastHeartbeatAck = 0;
    this.nextEventRef = 0;
    this.eventQueue = [];
    this.inFlightEvent = null;
    this.stopped = false;
    this.bindEvents();
  }

  connect() {
    if (this.stopped) return;
    if (this.socket && [WebSocket.CONNECTING, WebSocket.OPEN].includes(this.socket.readyState)) return;
    const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
    const url = new URL(this.socketPath, `${scheme}//${window.location.host}`);
    const generation = ++this.connectionGeneration;
    const socket = new WebSocket(url);
    this.socket = socket;
    this.root.dataset.opalStatus = "connecting";

    socket.addEventListener("open", () => {
      if (!this.currentConnection(socket, generation)) return;
      this.lastHeartbeatAck = Date.now();
      if (!this.send({type: "join", protocol: 1, token: this.token})) {
        socket.close(1001, "join send failed");
        return;
      }
      this.startHeartbeat();
    });

    socket.addEventListener("message", event => {
      if (this.currentConnection(socket, generation)) this.onMessage(event);
    });
    socket.addEventListener("close", event => {
      if (!this.currentConnection(socket, generation)) return;
      this.stopHeartbeat();
      this.root.dataset.opalStatus = "disconnected";
      this.failPendingEvents(event.code);
      if (!this.stopped && this.shouldReconnect(event.code)) this.scheduleReconnect();
    });
  }

  disconnect() {
    this.stopped = true;
    this.connectionGeneration += 1;
    if (this.reconnectTimer) window.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
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
      const value = this.formValue(form, event.submitter);
      if (value) this.pushEvent(form.dataset.opalSubmit, value);
    });

    const pushChange = target => {
      const owner = target.closest("[data-opal-change]") || target.form?.closest("[data-opal-change]");
      if (!owner || !this.root.contains(owner)) return;
      const value = owner instanceof HTMLFormElement ? this.formValue(owner) : this.eventValue(owner);
      if (value) this.pushEvent(owner.dataset.opalChange, value);
    };
    this.root.addEventListener("change", event => {
      const target = event.target;
      const owner = target.closest("[data-opal-change]") || target.form?.closest("[data-opal-change]");
      if (!owner || Object.prototype.hasOwnProperty.call(owner.dataset, "opalDebounce")) return;
      pushChange(target);
    });
    this.root.addEventListener("input", event => {
      const target = event.target;
      const owner = target.closest("[data-opal-change]") || target.form?.closest("[data-opal-change]");
      if (!owner || !Object.prototype.hasOwnProperty.call(owner.dataset, "opalDebounce")) return;
      window.clearTimeout(owner.__opalDebounceTimer);
      owner.__opalDebounceTimer = window.setTimeout(
        () => pushChange(target),
        Number(owner.dataset.opalDebounce) || 0,
      );
    });
  }

  pushEvent(event, value = {}) {
    if (!event || this.root.dataset.opalStatus !== "connected") return false;
    this.eventQueue.push({event, value, ref: ++this.nextEventRef});
    this.flushEvents();
    return true;
  }

  flushEvents() {
    if (this.inFlightEvent || this.eventQueue.length === 0) return;
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return;

    const pending = this.eventQueue.shift();
    this.inFlightEvent = pending;
    if (!this.send({
      type: "event",
      event: pending.event,
      value: pending.value,
      version: this.version,
      ref: pending.ref,
    })) {
      this.inFlightEvent = null;
      this.eventQueue.unshift(pending);
    }
  }

  onMessage(event) {
    if (typeof event.data !== "string") {
      this.socket.close(1003, "text messages required");
      return;
    }
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
      this.reconnectAttempt = 0;
      if (this.inFlightEvent && message.ref === this.inFlightEvent.ref) {
        const pending = this.inFlightEvent;
        this.inFlightEvent = null;
        if (message.status === "stale") this.eventQueue.unshift(pending);
      }
      this.flushEvents();
    } else if (message.type === "heartbeat") {
      if (message.ref === this.heartbeatRef) this.lastHeartbeatAck = Date.now();
    } else if (message.type === "error") {
      if (this.inFlightEvent && message.ref === this.inFlightEvent.ref) {
        this.inFlightEvent = null;
        this.flushEvents();
      }
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

    this.clearDebounceTimers();
    this.root.innerHTML = message.html;
    this.version = message.version;
    this.root.dataset.opalStatus = "connected";
    if (Object.prototype.hasOwnProperty.call(message, "title")) document.title = message.title;

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

  formValue(form, submitter = null) {
    const value = {};
    for (const [name, item] of new FormData(form).entries()) {
      if (item instanceof File) {
        if (item.name === "" && item.size === 0) continue;
        this.root.dispatchEvent(new CustomEvent("opal:error", {
          detail: {type: "error", reason: "uploads_unsupported"},
        }));
        return null;
      }
      if (Object.prototype.hasOwnProperty.call(value, name)) {
        value[name] = Array.isArray(value[name]) ? [...value[name], item] : [value[name], item];
      } else {
        value[name] = item;
      }
    }
    if (submitter && submitter.name) value[submitter.name] = submitter.value;
    return value;
  }

  send(message) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return false;
    try {
      this.socket.send(JSON.stringify(message));
      return true;
    } catch (_) {
      return false;
    }
  }

  startHeartbeat() {
    this.stopHeartbeat();
    this.heartbeatTimer = window.setInterval(() => {
      if (Date.now() - this.lastHeartbeatAck > HEARTBEAT_INTERVAL * 2) {
        if (this.socket) this.socket.close(1001, "heartbeat timeout");
        return;
      }
      if (!this.send({type: "heartbeat", ref: ++this.heartbeatRef}) && this.socket) {
        this.socket.close(1001, "heartbeat send failed");
      }
    }, HEARTBEAT_INTERVAL);
  }

  stopHeartbeat() {
    if (this.heartbeatTimer) window.clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = null;
  }

  scheduleReconnect() {
    if (this.reconnectTimer) return;
    const delay = DEFAULT_RECONNECT_DELAYS[
      Math.min(this.reconnectAttempt, DEFAULT_RECONNECT_DELAYS.length - 1)
    ];
    this.reconnectAttempt += 1;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay + Math.floor(Math.random() * 100));
  }

  currentConnection(socket, generation) {
    return this.socket === socket && this.connectionGeneration === generation;
  }

  shouldReconnect(code) {
    return ![1000, 1002, 1003, 1008, 1009].includes(code);
  }

  failPendingEvents(code) {
    const pending = [this.inFlightEvent, ...this.eventQueue].filter(Boolean);
    this.inFlightEvent = null;
    this.eventQueue = [];
    for (const event of pending) {
      this.root.dispatchEvent(new CustomEvent("opal:event-error", {
        detail: {event: event.event, ref: event.ref, code},
      }));
    }
  }

  clearDebounceTimers() {
    for (const element of this.root.querySelectorAll("[data-opal-debounce]")) {
      if (element.__opalDebounceTimer) window.clearTimeout(element.__opalDebounceTimer);
    }
  }
}

export function connectAll(root = document) {
  return Array.from(root.querySelectorAll("[data-opal-live-root]"), element => {
    const liveView = new OpalLiveView(element);
    Object.defineProperty(element, "__opalLiveView", {value: liveView, configurable: true});
    liveView.connect();
    return liveView;
  });
}

const instances = connectAll();
window.addEventListener("pagehide", () => instances.forEach(instance => instance.disconnect()));

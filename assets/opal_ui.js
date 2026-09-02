(() => {
  const hooks = globalThis.OpalLiveViewHooks || {};
  if (hooks.OpalDialog) {
    globalThis.OpalLiveViewHooks = hooks;
    return;
  }

  hooks.OpalDialog = {
    mounted() {
      this.dialogWasOpen = false;
      this.dialogOpener = null;
      this.dialogOpenerId = null;
      this.dialogClosePending = false;
      this.onDialogCancel = event => {
        event.preventDefault();
        if (this.dialogFlag("closeEscape")) this.requestDialogClose("escape");
      };
      this.onDialogClick = event => {
        if (!this.dialogFlag("closeBackdrop")) return;
        const target = event.target;
        const panel = target instanceof Element && target.closest('[data-opal-ui="dialog-panel"]');
        if (!panel) this.requestDialogClose("backdrop");
      };
      this.el.addEventListener("cancel", this.onDialogCancel);
      this.el.addEventListener("click", this.onDialogClick);
      this.syncDialogOpen();
    },

    beforeUpdate(toEl) {
      if (!this.dialogWasOpen && toEl.dataset.opalDialogOpen === "true") {
        this.captureDialogOpener();
      }
      // Keep the browser-owned `open` attribute through the DOM morph. The
      // updated callback closes it after the server's open state is applied,
      // avoiding premature native focus changes in the middle of a patch.
      if (this.el.open) {
        toEl.setAttribute("open", "");
      }
    },

    updated() {
      this.syncDialogOpen();
    },

    reconnected() {
      this.syncDialogOpen();
    },

    destroyed() {
      this.el.removeEventListener("cancel", this.onDialogCancel);
      this.el.removeEventListener("click", this.onDialogClick);
      if (this.el.open) this.el.close();
      this.restoreDialogFocus();
    },

    dialogFlag(name) {
      const suffix = `${name[0].toUpperCase()}${name.slice(1)}`;
      return this.el.dataset[`opalDialog${suffix}`] === "true";
    },

    syncDialogOpen() {
      const shouldOpen = this.el.dataset.opalDialogOpen === "true";
      if (shouldOpen) {
        if (!this.dialogWasOpen && !this.dialogOpener) this.captureDialogOpener();
        if (!this.el.open) this.el.showModal();
        this.dialogWasOpen = true;
        return;
      }

      if (this.el.open) this.el.close();
      if (this.dialogWasOpen) this.restoreDialogFocus();
      this.dialogWasOpen = false;
    },

    requestDialogClose(reason) {
      const event = this.el.dataset.opalDialogCloseEvent;
      if (!event || this.dialogClosePending) return;
      this.dialogClosePending = true;
      Promise.resolve(this.pushEventTo(this.el, event, {reason}))
        .catch(() => {})
        .finally(() => { this.dialogClosePending = false; });
    },

    captureDialogOpener() {
      const active = document.activeElement;
      if (!(active instanceof HTMLElement) || this.el.contains(active)) return;
      this.dialogOpener = active;
      this.dialogOpenerId = active.id || null;
    },

    restoreDialogFocus() {
      const opener = this.dialogOpener;
      const openerId = this.el.dataset.opalDialogReturnFocus || this.dialogOpenerId;
      this.dialogOpener = null;
      this.dialogOpenerId = null;
      requestAnimationFrame(() => {
        const current = openerId ? document.getElementById(openerId) : opener;
        if (current instanceof HTMLElement && current.isConnected) current.focus();
      });
    }
  };

  globalThis.OpalLiveViewHooks = hooks;
})();

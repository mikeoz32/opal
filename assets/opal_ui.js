(() => {
  const hooks = globalThis.OpalLiveViewHooks || {};
  if (!hooks.OpalDialog) hooks.OpalDialog = {
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

  if (!hooks.OpalDropdown) hooks.OpalDropdown = {
    mounted() {
      this.dropdownOpen = false;
      this.onDropdownClick = event => {
        const target = event.target;
        if (!(target instanceof Element)) return;
        const trigger = target.closest("[data-opal-dropdown-trigger]");
        if (trigger && this.el.contains(trigger)) {
          this.dropdownOpen ? this.closeDropdown() : this.openDropdown();
          return;
        }
        const item = target.closest("[data-opal-dropdown-item]");
        if (item && this.el.contains(item) && !this.dropdownItemDisabled(item)) {
          this.closeDropdown(true);
        }
      };
      this.onDropdownKeydown = event => this.handleDropdownKeydown(event);
      this.onDropdownOutsideClick = event => {
        if (this.dropdownOpen && !this.el.contains(event.target)) this.closeDropdown();
      };
      this.el.addEventListener("click", this.onDropdownClick);
      this.el.addEventListener("keydown", this.onDropdownKeydown);
      document.addEventListener("click", this.onDropdownOutsideClick);
      this.applyDropdownState();
    },

    beforeUpdate(toEl) {
      toEl.dataset.opalDropdownOpen = this.dropdownOpen ? "true" : "false";
    },

    updated() {
      this.applyDropdownState();
    },

    reconnected() {
      this.applyDropdownState();
    },

    destroyed() {
      this.el.removeEventListener("click", this.onDropdownClick);
      this.el.removeEventListener("keydown", this.onDropdownKeydown);
      document.removeEventListener("click", this.onDropdownOutsideClick);
    },

    dropdownParts() {
      return {
        trigger: this.el.querySelector("[data-opal-dropdown-trigger]"),
        menu: this.el.querySelector("[data-opal-dropdown-menu]")
      };
    },

    dropdownItems() {
      return Array.from(this.el.querySelectorAll("[data-opal-dropdown-item]"))
        .filter(item => !this.dropdownItemDisabled(item));
    },

    dropdownItemDisabled(item) {
      return item.hasAttribute("disabled") || item.getAttribute("aria-disabled") === "true";
    },

    applyDropdownState() {
      const {trigger, menu} = this.dropdownParts();
      if (!(trigger instanceof HTMLElement) || !(menu instanceof HTMLElement)) return;
      trigger.setAttribute("aria-expanded", this.dropdownOpen ? "true" : "false");
      menu.hidden = !this.dropdownOpen;
      this.el.dataset.opalDropdownOpen = this.dropdownOpen ? "true" : "false";
    },

    openDropdown(position = "first") {
      this.dropdownOpen = true;
      this.applyDropdownState();
      if (!position) return;
      const items = this.dropdownItems();
      const item = position === "last" ? items[items.length - 1] : items[0];
      if (item instanceof HTMLElement) item.focus();
    },

    closeDropdown(restoreFocus = false) {
      if (!this.dropdownOpen) return;
      this.dropdownOpen = false;
      this.applyDropdownState();
      if (restoreFocus) {
        const {trigger} = this.dropdownParts();
        if (trigger instanceof HTMLElement) trigger.focus();
      }
    },

    handleDropdownKeydown(event) {
      const target = event.target;
      if (!(target instanceof Element)) return;
      const {trigger} = this.dropdownParts();
      if (target === trigger) {
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          this.openDropdown(event.key === "ArrowUp" ? "last" : "first");
        } else if (event.key === "Escape") {
          event.preventDefault();
          this.closeDropdown(true);
        }
        return;
      }

      const current = target.closest("[data-opal-dropdown-item]");
      if (!current || !this.el.contains(current)) return;
      const items = this.dropdownItems();
      const index = items.indexOf(current);
      let next = null;
      if (event.key === "ArrowDown") next = items[(index + 1) % items.length];
      if (event.key === "ArrowUp") next = items[(index - 1 + items.length) % items.length];
      if (event.key === "Home") next = items[0];
      if (event.key === "End") next = items[items.length - 1];
      if (next) {
        event.preventDefault();
        next.focus();
      } else if (event.key === "Escape") {
        event.preventDefault();
        this.closeDropdown(true);
      } else if (event.key === "Tab") {
        this.closeDropdown();
      }
    }
  };

  if (!hooks.OpalTabs) hooks.OpalTabs = {
    mounted() {
      this.onTabsKeydown = event => {
        const tab = event.target instanceof Element && event.target.closest('[role="tab"]');
        if (!tab || !this.el.contains(tab)) return;
        const list = tab.closest('[role="tablist"]');
        if (!list) return;
        const tabs = Array.from(list.querySelectorAll('[role="tab"]'))
          .filter(candidate => !candidate.hasAttribute("disabled"));
        const index = tabs.indexOf(tab);
        const vertical = list.getAttribute("aria-orientation") === "vertical";
        let next = null;
        if (event.key === "Home") next = tabs[0];
        if (event.key === "End") next = tabs[tabs.length - 1];
        if ((!vertical && event.key === "ArrowRight") || (vertical && event.key === "ArrowDown")) {
          next = tabs[(index + 1) % tabs.length];
        }
        if ((!vertical && event.key === "ArrowLeft") || (vertical && event.key === "ArrowUp")) {
          next = tabs[(index - 1 + tabs.length) % tabs.length];
        }
        if (!(next instanceof HTMLElement)) return;
        event.preventDefault();
        next.focus();
        next.click();
      };
      this.el.addEventListener("keydown", this.onTabsKeydown);
    },

    destroyed() {
      this.el.removeEventListener("keydown", this.onTabsKeydown);
    }
  };

  if (!hooks.OpalToast) hooks.OpalToast = {
    mounted() {
      this.toastTimer = null;
      this.toastDuration = null;
      this.toastIdentity = this.el.id;
      this.toastDismissPending = false;
      this.toastRestoreFocus = false;
      this.onToastClick = event => {
        const target = event.target;
        if (target instanceof Element && target.closest("[data-opal-toast-dismiss]")) {
          this.clearToastTimer();
          this.toastRestoreFocus = true;
          this.requestToastDismiss("button");
        }
      };
      this.el.addEventListener("click", this.onToastClick);
      this.scheduleToast();
    },

    updated() {
      const duration = this.readToastDuration();
      if (this.el.id !== this.toastIdentity || duration !== this.toastDuration) {
        this.toastIdentity = this.el.id;
        this.toastDismissPending = false;
        this.toastRestoreFocus = false;
        this.scheduleToast();
      }
    },

    reconnected() {
      if (!this.toastTimer && !this.toastDismissPending) this.scheduleToast();
    },

    destroyed() {
      this.el.removeEventListener("click", this.onToastClick);
      this.clearToastTimer();
      if (this.toastRestoreFocus) {
        const id = this.el.dataset.opalToastReturnFocus;
        requestAnimationFrame(() => {
          const target = id && document.getElementById(id);
          if (target instanceof HTMLElement) target.focus();
        });
      }
    },

    readToastDuration() {
      const value = Number.parseInt(this.el.dataset.opalToastDuration || "", 10);
      return Number.isFinite(value) && value > 0 ? value : null;
    },

    scheduleToast() {
      this.clearToastTimer();
      this.toastDuration = this.readToastDuration();
      if (!this.toastDuration) return;
      this.toastTimer = window.setTimeout(() => {
        this.toastTimer = null;
        this.requestToastDismiss("timeout");
      }, this.toastDuration);
    },

    clearToastTimer() {
      if (this.toastTimer) window.clearTimeout(this.toastTimer);
      this.toastTimer = null;
    },

    requestToastDismiss(reason) {
      const event = this.el.dataset.opalToastDismissEvent;
      if (!event || this.toastDismissPending) return;
      this.toastDismissPending = true;
      Promise.resolve(this.pushEventTo(this.el, event, {reason}))
        .catch(() => {})
        .finally(() => { this.toastDismissPending = false; });
    }
  };

  globalThis.OpalLiveViewHooks = hooks;
})();

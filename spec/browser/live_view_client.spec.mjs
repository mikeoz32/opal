import {expect, test} from "@playwright/test";

test.beforeEach(async ({page}) => {
  await page.goto("/?start=0");
  await expect(page.locator("[data-opal-live-root]")).toHaveAttribute("data-opal-status", "connected");
});

test("delivers rapid events in order without losing clicks", async ({page}) => {
  const increment = page.getByRole("button", {name: "Increment", exact: true});
  const counter = page.locator("#counter-value");
  await counter.evaluate(element => { window.__opalCounterNode = element; });

  await increment.evaluate(button => {
    button.click();
    button.click();
  });

  await expect(counter).toHaveText("2");
  await expect.poll(() => counter.evaluate(element => element === window.__opalCounterNode)).toBe(true);
  await expect(page).toHaveTitle("Counter 2 · Opal");
});

test("debounces form changes once and preserves focused input", async ({page}) => {
  const input = page.getByLabel("Name");
  await input.evaluate(element => { window.__opalNameInput = element; });
  await input.fill("Alice");

  await expect(page.getByTestId("validation-count")).toHaveText("1");
  await expect(input).toBeFocused();
  await expect(input).toHaveValue("Alice");
  await expect.poll(() => input.evaluate(element => element === window.__opalNameInput)).toBe(true);

  await page.getByRole("heading", {level: 1}).click();
  await page.waitForTimeout(250);
  await expect(page.getByTestId("validation-count")).toHaveText("1");

  await page.getByRole("button", {name: "Save"}).click();
  await expect(page.getByText("Hello, Alice.")).toBeVisible();
});

test("serializes timer updates on the connection", async ({page}) => {
  await page.getByRole("button", {name: "+1 later"}).click();
  await expect(page.locator("#counter-value")).toHaveText("1");
});

test("moves keyed elements without recreating their DOM nodes", async ({page}) => {
  const first = page.locator("#item-first");
  await first.evaluate(element => { window.__opalFirstItem = element; });

  await page.getByRole("button", {name: "Reverse keyed items"}).click();

  await expect(page.locator("#keyed-items > li")).toHaveText([
    "Third keyed item",
    "Second keyed item",
    "First keyed item",
  ]);
  await expect.poll(() => first.evaluate(element => element === window.__opalFirstItem)).toBe(true);
});

test("keeps component state isolated and targets only its instance", async ({page}) => {
  const left = page.locator("#left-component-value");
  const right = page.locator("#right-component-value");
  await right.evaluate(element => { window.__opalRightComponentNode = element; });

  const incrementLeft = page.getByRole("button", {name: "Increment Left component"});
  await incrementLeft.evaluate(button => {
    button.click();
    button.click();
  });

  await expect(left).toHaveText("2");
  await expect(right).toHaveText("0");
  await expect.poll(
    () => right.evaluate(element => element === window.__opalRightComponentNode),
  ).toBe(true);

  await page.getByRole("button", {name: "Increment Right component"}).click();
  await expect(left).toHaveText("2");
  await expect(right).toHaveText("1");
});

test("runs hook updates after DOM patches and delivers server events before replies", async ({page}) => {
  const hook = page.locator("#counter-hook");
  await expect(hook).toHaveAttribute("data-client-state", "preserved");
  expect(await page.evaluate(() => window.__opalHookLog)).toEqual(["mounted"]);
  await page.evaluate(() => {
    window.addEventListener("opal:counter_notice", event => {
      window.__opalWindowNotice = event.detail;
    }, {once: true});
  });

  await page.getByRole("button", {name: "Ping view from hook"}).click();

  await expect(page.locator("#hook-server-state")).toHaveText("hello from hook");
  await expect(page.locator("#hook-client-notice")).toHaveText("hello from hook");
  await expect(hook).toHaveAttribute("data-client-state", "preserved");
  await expect.poll(() => page.evaluate(() => window.__opalHookReplies.length)).toBe(1);

  const result = await page.evaluate(() => ({
    log: window.__opalHookLog,
    reply: window.__opalHookReplies[0],
    notice: window.__opalHookNotices[0],
    windowNotice: window.__opalWindowNotice,
  }));
  expect(result.reply.reply).toEqual({accepted: true, message: "hello from hook", count: 0});
  expect(result.notice).toEqual({message: "hello from hook", count: 0});
  expect(result.windowNotice).toEqual({message: "hello from hook", count: 0});
  expect(result.log.indexOf("beforeUpdate")).toBeLessThan(result.log.indexOf("updated"));
  expect(result.log.indexOf("updated")).toBeLessThan(result.log.indexOf("notice"));
  expect(result.log.indexOf("notice")).toBeLessThan(result.log.indexOf("reply"));

  const callbackReply = await hook.evaluate(element => new Promise(resolve => {
    const liveView = element.closest("[data-opal-live-root]").__opalLiveView;
    liveView.hooks.get(element).pushEvent(
      "hook_ping",
      {message: "callback reply"},
      (reply, ref) => resolve({reply, ref}),
    );
  }));
  expect(callbackReply.reply).toEqual({accepted: true, message: "callback reply", count: 0});
  expect(callbackReply.ref).toBeGreaterThan(0);
  await expect(page.locator("#hook-server-state")).toHaveText("callback reply");
});

test("targets components from hooks and cleans up hook event handlers", async ({page}) => {
  await page.getByRole("button", {name: "Ping left component from hook"}).click();
  await expect.poll(() => page.evaluate(() => window.__opalHookReplies.length)).toBe(1);

  const componentResult = await page.evaluate(() => ({
    log: window.__opalHookLog,
    reply: window.__opalHookReplies[0],
    notice: window.__opalHookNotices[0],
  }));
  expect(componentResult.reply.reply).toEqual({id: "left", count: 0});
  expect(componentResult.notice).toEqual({id: "left", count: 0});
  expect(componentResult.log).toContain("component-notice");
  expect(componentResult.log).toContain("component-reply");

  await page.getByRole("button", {name: "Toggle hook"}).click();
  await expect(page.locator("#counter-hook")).toHaveCount(0);
  await expect.poll(() => page.evaluate(() => window.__opalHookLog.includes("destroyed"))).toBe(true);

  await page.getByRole("button", {name: "Toggle hook"}).click();
  await expect(page.locator("#counter-hook")).toBeVisible();
  await expect.poll(
    () => page.evaluate(() => window.__opalHookLog.filter(item => item === "mounted").length),
  ).toBe(2);
});

test("notifies hooks across disconnect and reconnect without remounting them", async ({page}) => {
  const root = page.locator("[data-opal-live-root]");
  const hook = page.locator("#counter-hook");
  await hook.evaluate(element => { window.__opalHookElement = element; });
  const generation = await root.evaluate(element => element.__opalLiveView.connectionGeneration);

  await root.evaluate(element => element.__opalLiveView.socket.close(4001, "hook reconnect"));
  await expect.poll(
    () => root.evaluate(element => element.__opalLiveView.connectionGeneration),
  ).toBeGreaterThan(generation);
  await expect(root).toHaveAttribute("data-opal-status", "connected", {timeout: 10_000});
  await expect.poll(() => hook.evaluate(element => element === window.__opalHookElement)).toBe(true);

  const lifecycle = await page.evaluate(() => window.__opalHookLog);
  expect(lifecycle.filter(item => item === "mounted")).toHaveLength(1);
  expect(lifecycle).toContain("disconnected");
  expect(lifecycle).toContain("reconnected");
  expect(lifecycle.indexOf("disconnected")).toBeLessThan(lifecycle.indexOf("reconnected"));
});

test("isolates hook callback failures from the live connection", async ({page}) => {
  const root = page.locator("[data-opal-live-root]");
  const error = await root.evaluate(element => new Promise(resolve => {
    element.addEventListener("opal:hook-error", event => resolve({
      hook: event.detail.hook,
      callback: event.detail.callback,
      message: event.detail.error.message,
    }), {once: true});
    element.__opalLiveView.hookDefinitions.BrokenHook = {
      mounted() { throw new Error("broken hook callback"); },
    };
    const broken = document.createElement("div");
    broken.id = "broken-hook";
    broken.dataset.opalHook = "BrokenHook";
    element.appendChild(broken);
    element.__opalLiveView.reconcileHooks();
  }));

  expect(error).toEqual({
    hook: "BrokenHook",
    callback: "mounted",
    message: "broken hook callback",
  });

  const invalid = await root.evaluate(element => new Promise(resolve => {
    element.addEventListener("opal:hook-error", event => resolve({
      hook: event.detail.hook,
      message: event.detail.error.message,
    }), {once: true});
    const missingId = document.createElement("div");
    missingId.dataset.opalHook = "CounterHook";
    element.appendChild(missingId);
    element.__opalLiveView.reconcileHooks();
  }));
  expect(invalid).toEqual({
    hook: "CounterHook",
    message: "LiveView hook elements require a unique id",
  });
  await expect(root).toHaveAttribute("data-opal-status", "connected");
  await page.getByRole("button", {name: "Increment", exact: true}).click();
  await expect(page.locator("#counter-value")).toHaveText("1");
});

test("applies bounded stream inserts and deletes without replacing retained items", async ({page}) => {
  const first = page.locator("#activity-1");
  await first.evaluate(element => { window.__opalFirstActivityNode = element; });

  const prepend = page.getByRole("button", {name: "Prepend activity"});
  await prepend.click();
  await prepend.click();

  await expect(page.locator("#activity-stream > li span")).toHaveText([
    "Activity 4",
    "Activity 3",
    "Activity 1",
  ]);
  await expect(page.locator("#activity-2")).toHaveCount(0);
  await expect.poll(
    () => first.evaluate(element => element === window.__opalFirstActivityNode),
  ).toBe(true);

  const validationError = await page.locator("[data-opal-live-root]").evaluate(root => {
    try {
      root.__opalLiveView.applyStreams([
        {op: "reset", container: "activity-stream"},
        {
          op: "insert",
          container: "activity-stream",
          id: "declared-id",
          html: '<li id="different-id">invalid</li>',
          at: -1,
        },
      ]);
      return null;
    } catch (error) {
      return error.message;
    }
  });
  expect(validationError).toBe("stream item id mismatch");
  await expect(page.locator("#activity-stream > li span")).toHaveText([
    "Activity 4",
    "Activity 3",
    "Activity 1",
  ]);

  await page.getByRole("button", {name: "Remove Activity 3"}).click();
  await expect(page.locator("#activity-stream > li span")).toHaveText([
    "Activity 4",
    "Activity 1",
  ]);
});

test("applies an explicitly empty document title", async ({page}) => {
  await page.getByRole("button", {name: "Clear title"}).click();
  await expect(page).toHaveTitle("");
});

test("patches history without remounting and reconnects from the refreshed token", async ({page}) => {
  const root = page.locator("[data-opal-live-root]");
  await root.evaluate(element => {
    window.__opalNavigationRoot = element;
    window.__opalNavigationGeneration = element.__opalLiveView.connectionGeneration;
    window.__opalNavigationToken = element.dataset.opalToken;
  });

  await page.getByRole("link", {name: "Next page"}).click();
  await expect(page).toHaveURL(/\?start=0&page=2$/);
  await expect(page.getByTestId("page-value")).toHaveText("2");
  await expect.poll(
    () => root.evaluate(element => element === window.__opalNavigationRoot),
  ).toBe(true);
  await expect.poll(
    () => root.evaluate(element => element.__opalLiveView.connectionGeneration),
  ).toBe(await root.evaluate(() => window.__opalNavigationGeneration));
  await expect.poll(
    () => root.evaluate(element => element.dataset.opalToken === window.__opalNavigationToken),
  ).toBe(false);

  await page.goBack();
  await expect(page).toHaveURL(/\?start=0$/);
  await expect(page.getByTestId("page-value")).toHaveText("1");
  await expect.poll(
    () => root.evaluate(element => element === window.__opalNavigationRoot),
  ).toBe(true);

  await page.goForward();
  await expect(page).toHaveURL(/\?start=0&page=2$/);
  await expect(page.getByTestId("page-value")).toHaveText("2");
  await expect.poll(
    () => root.evaluate(element => element === window.__opalNavigationRoot),
  ).toBe(true);

  await page.goBack();
  await expect(page.getByTestId("page-value")).toHaveText("1");

  await page.getByRole("button", {name: "Next page from server"}).click();
  await expect(page).toHaveURL(/\?start=0&page=2$/);
  await expect(page.getByTestId("page-value")).toHaveText("2");

  const historyLength = await page.evaluate(() => window.history.length);
  await page.getByRole("button", {name: "Replace page from server"}).click();
  await expect(page).toHaveURL(/\?start=0&page=3$/);
  await expect(page.getByTestId("page-value")).toHaveText("3");
  expect(await page.evaluate(() => window.history.length)).toBe(historyLength);

  const generation = await root.evaluate(element => element.__opalLiveView.connectionGeneration);
  await root.evaluate(element => element.__opalLiveView.socket.close(4001, "navigation reconnect"));
  await expect.poll(
    () => root.evaluate(element => element.__opalLiveView.connectionGeneration),
  ).toBeGreaterThan(generation);
  await expect(root).toHaveAttribute("data-opal-status", "connected", {timeout: 10_000});
  await expect(page.getByTestId("page-value")).toHaveText("3");
});

test("uses a fresh document mount for navigation outside the current LiveView", async ({page}) => {
  await page.getByRole("link", {name: "About this example"}).click();

  await expect(page).toHaveURL(/\/about$/);
  await expect(page.getByRole("heading", {name: "About Opal LiveView"})).toBeVisible();
  await expect(page).toHaveTitle("About · Opal LiveView");
  await expect(page.locator("[data-opal-live-root]")).toHaveAttribute("data-opal-status", "connected");
});

test("reconnects after a transient socket interruption", async ({page}) => {
  const root = page.locator("[data-opal-live-root]");
  const generation = await root.evaluate(element => element.__opalLiveView.connectionGeneration);

  await root.evaluate(element => element.__opalLiveView.socket.close(4001, "browser test"));
  await expect.poll(
    () => root.evaluate(element => element.__opalLiveView.connectionGeneration),
  ).toBeGreaterThan(generation);
  await expect(root).toHaveAttribute("data-opal-status", "connected", {timeout: 10_000});
});

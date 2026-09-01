import {expect, test} from "@playwright/test";

test.beforeEach(async ({page}) => {
  await page.goto("/?start=0");
  await expect(page.locator("[data-opal-live-root]")).toHaveClass(/phx-connected/);
});

test("delivers acknowledged events in order", async ({page}) => {
  const increment = page.getByRole("button", {name: "Increment", exact: true});
  const counter = page.locator("#counter-value");
  await counter.evaluate(element => { window.__opalCounterNode = element; });

  await increment.click();
  await expect(counter).toHaveText("1");
  await increment.click();

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

test("moves stable-id elements without recreating their DOM nodes", async ({page}) => {
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
  await incrementLeft.click();
  await expect(left).toHaveText("1");
  await incrementLeft.click();

  await expect(left).toHaveText("2");
  await expect(right).toHaveText("0");
  await expect.poll(
    () => right.evaluate(element => element === window.__opalRightComponentNode),
  ).toBe(true);

  await page.getByRole("button", {name: "Increment Right component"}).click();
  await expect(left).toHaveText("2");
  await expect(right).toHaveText("1");
});

test("scopes nested component state to each parent and remounts removed children", async ({page}) => {
  const left = page.locator("#left-nested-component-value");
  const right = page.locator("#right-nested-component-value");
  await right.evaluate(element => { window.__opalRightNestedNode = element; });

  await page.getByRole("button", {name: "Increment Left nested component"}).click();
  await expect(left).toHaveText("1");
  await expect(right).toHaveText("0");
  await expect.poll(
    () => right.evaluate(element => element === window.__opalRightNestedNode),
  ).toBe(true);

  await page.getByRole("button", {name: "Increment Left component"}).click();
  await expect(page.locator("#left-component-value")).toHaveText("1");
  await expect(page.locator("#left-nested-parent-value")).toHaveText("1");
  await expect(left).toHaveText("1");

  await page.getByRole("button", {name: "Toggle Left nested component"}).click();
  await expect(page.locator("#left-nested-component")).toHaveCount(0);
  await expect(page.locator("#right-nested-component")).toBeVisible();

  await page.getByRole("button", {name: "Toggle Left nested component"}).click();
  await expect(page.locator("#left-nested-component-value")).toHaveText("0");
  await expect(page.locator("#left-component-value")).toHaveText("1");
});

test("runs hook updates after DOM patches and delivers server events before replies", async ({page}) => {
  const hook = page.locator("#counter-hook");
  await expect(hook).toHaveAttribute("data-client-state", "preserved");
  expect(await page.evaluate(() => window.__opalHookLog)).toEqual(["mounted"]);
  await page.evaluate(() => {
    window.addEventListener("phx:counter_notice", event => {
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
  expect(result.reply).toEqual({accepted: true, message: "hello from hook", count: 0});
  expect(result.notice).toEqual({message: "hello from hook", count: 0});
  expect(result.windowNotice).toEqual({message: "hello from hook", count: 0});
  expect(result.log.indexOf("beforeUpdate")).toBeLessThan(result.log.indexOf("updated"));
  expect(result.log.indexOf("updated")).toBeLessThan(result.log.indexOf("notice"));
  expect(result.log.indexOf("notice")).toBeLessThan(result.log.indexOf("reply"));

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
  await page.evaluate(() => { window.__opalConnection = window.OpalLiveSocket.socket.conn; });
  await page.evaluate(() => window.OpalLiveSocket.socket.conn.close(4001, "hook reconnect"));
  await expect.poll(
    () => page.evaluate(() => window.OpalLiveSocket.socket.conn !== window.__opalConnection),
  ).toBe(true);
  await expect(root).toHaveClass(/phx-connected/, {timeout: 10_000});
  await expect.poll(() => hook.evaluate(element => element === window.__opalHookElement)).toBe(true);

  const lifecycle = await page.evaluate(() => window.__opalHookLog);
  expect(lifecycle.filter(item => item === "mounted")).toHaveLength(1);
  expect(lifecycle).toContain("disconnected");
  expect(lifecycle).toContain("reconnected");
  expect(lifecycle.indexOf("disconnected")).toBeLessThan(lifecycle.indexOf("reconnected"));
});

test("applies bounded stream inserts and deletes without replacing retained items", async ({page}) => {
  const first = page.locator("#activity-1");
  await expect(first).toHaveAttribute("data-phx-stream", "0");
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
  await expect(page.locator("#activity-4")).toHaveAttribute("data-phx-stream", "0");
  await expect.poll(
    () => first.evaluate(element => element === window.__opalFirstActivityNode),
  ).toBe(true);

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

test("patches history without remounting and reconnects from the current URL", async ({page}) => {
  const root = page.locator("[data-opal-live-root]");
  await root.evaluate(element => {
    window.__opalNavigationRoot = element;
    window.__opalNavigationToken = element.getAttribute("data-phx-session");
  });

  await page.getByRole("link", {name: "Next page"}).click();
  await expect(page).toHaveURL(/\?start=0&page=2$/);
  await expect(page.getByTestId("page-value")).toHaveText("2");
  await expect.poll(
    () => root.evaluate(element => element === window.__opalNavigationRoot),
  ).toBe(true);
  await expect.poll(
    () => root.evaluate(element => element.getAttribute("data-phx-session") === window.__opalNavigationToken),
  ).toBe(true);

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

  await page.evaluate(() => { window.__opalConnection = window.OpalLiveSocket.socket.conn; });
  await page.evaluate(() => window.OpalLiveSocket.socket.conn.close(4001, "navigation reconnect"));
  await expect.poll(
    () => page.evaluate(() => window.OpalLiveSocket.socket.conn !== window.__opalConnection),
  ).toBe(true);
  await expect(root).toHaveClass(/phx-connected/, {timeout: 10_000});
  await expect(page.getByTestId("page-value")).toHaveText("3");
});

test("uses a fresh document mount for navigation outside the current LiveView", async ({page}) => {
  await page.getByRole("link", {name: "About this example"}).click();

  await expect(page).toHaveURL(/\/about$/);
  await expect(page.getByRole("heading", {name: "About Opal LiveView"})).toBeVisible();
  await expect(page).toHaveTitle("About · Opal LiveView");
  await expect(page.locator("[data-opal-live-root]")).toHaveClass(/phx-connected/);
});

test("restores a working connection after Back from a non-LiveView page", async ({page}) => {
  const root = page.locator("[data-opal-live-root]");

  await page.getByRole("link", {name: "Plain page"}).click();
  await expect(page.getByText("Plain non-LiveView page")).toBeVisible();
  await page.goBack();

  await expect(page).toHaveURL(/\?start=0$/);
  await expect(root).toHaveClass(/phx-connected/, {timeout: 10_000});
  await page.getByRole("button", {name: "Increment", exact: true}).click();
  await expect(page.locator("#counter-value")).toHaveText("1");
});

test("reconnects after a transient socket interruption", async ({page}) => {
  const root = page.locator("[data-opal-live-root]");
  await page.evaluate(() => { window.__opalConnection = window.OpalLiveSocket.socket.conn; });
  await page.evaluate(() => window.OpalLiveSocket.socket.conn.close(4001, "browser test"));
  await expect.poll(
    () => page.evaluate(() => window.OpalLiveSocket.socket.conn !== window.__opalConnection),
  ).toBe(true);
  await expect(root).toHaveClass(/phx-connected/, {timeout: 10_000});
});

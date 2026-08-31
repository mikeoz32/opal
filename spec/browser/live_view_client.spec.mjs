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

  await page.getByRole("heading").click();
  await page.waitForTimeout(250);
  await expect(page.getByTestId("validation-count")).toHaveText("1");

  await page.getByRole("button", {name: "Save"}).click();
  await expect(page.getByText("Hello, Alice.")).toBeVisible();
});

test("serializes timer updates on the connection", async ({page}) => {
  await page.getByRole("button", {name: "+1 later"}).click();
  await expect(page.locator("output[aria-live]")).toHaveText("1");
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

test("applies an explicitly empty document title", async ({page}) => {
  await page.getByRole("button", {name: "Clear title"}).click();
  await expect(page).toHaveTitle("");
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

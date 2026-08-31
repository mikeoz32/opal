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

test("reconnects after a transient socket interruption", async ({page}) => {
  const root = page.locator("[data-opal-live-root]");
  const generation = await root.evaluate(element => element.__opalLiveView.connectionGeneration);

  await root.evaluate(element => element.__opalLiveView.socket.close(4001, "browser test"));
  await expect.poll(
    () => root.evaluate(element => element.__opalLiveView.connectionGeneration),
  ).toBeGreaterThan(generation);
  await expect(root).toHaveAttribute("data-opal-status", "connected", {timeout: 10_000});
});

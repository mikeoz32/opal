import {expect, test} from "@playwright/test";

test.use({baseURL: "http://127.0.0.1:8085"});

test("renders the compiled UI theme and primitive families", async ({page}) => {
  await page.goto("/");

  await expect(page).toHaveTitle("Opal UI showcase");
  await expect(page.locator("#opal-live-root")).toHaveClass(/phx-connected/);
  await expect(page.locator('[data-opal-ui="card"]')).toHaveCount(5);
  await expect(page.locator('[data-opal-ui="button"]')).toHaveCount(9);
  await expect(page.locator('[data-opal-ui="dropdown-item"]')).toHaveCount(3);
  await expect(page.locator('[data-opal-ui="tab"]')).toHaveCount(3);
  await expect(page.locator('[data-opal-ui="table"]')).toBeVisible();
  await expect(page.locator('[data-opal-ui="input"]')).toBeVisible();

  const button = page.locator("#deployment-toggle");
  await expect(button).toHaveAttribute("phx-click", "toggle_deployment");
  await expect(button).not.toHaveAttribute("data-opal-click");
  await expect(page.locator("#release-dialog")).toHaveAttribute("phx-hook", "OpalDialog");
  await expect(page.locator("#release-actions")).toHaveAttribute("phx-hook", "OpalDropdown");
  await expect(page.locator("#release-tabs")).toHaveAttribute("phx-hook", "OpalTabs");
  // Flex/grid items blockify inline-level display values in computed style.
  await expect(button).toHaveCSS("display", "flex");
  await expect(button).toHaveCSS("background-color", "oklch(0.546 0.245 262.881)");
  await expect(page.locator('[data-opal-ui-theme]')).toHaveCount(1);

  await page.emulateMedia({colorScheme: "dark"});
  await expect(page.locator("body")).toHaveCSS("background-color", "rgb(2, 6, 23)");
});

test("keeps dialog state on the server and handles modal focus semantics", async ({page}) => {
  await page.goto("/");

  const opener = page.locator("#open-release-dialog");
  const dialog = page.locator("#release-dialog");
  const close = page.locator("#close-release-dialog");

  await expect(dialog).not.toBeVisible();
  await opener.click();
  await expect(dialog).toBeVisible();
  await expect(dialog).toHaveAttribute("aria-labelledby", "release-dialog-title");
  await expect(dialog).toHaveAttribute("aria-describedby", "release-dialog-description");
  await expect(close).toBeFocused();

  await page.locator("#refresh-release-dialog").click();
  await expect(dialog).toBeVisible();
  await expect(page.locator("#dialog-revision")).toHaveText("Dialog update 1");

  await page.keyboard.press("Escape");
  await expect(dialog).not.toBeVisible();
  await expect(page.locator("#dialog-close-reason")).toHaveText("Closed by escape");
  await expect(opener).toBeFocused();

  await opener.click();
  await expect(dialog).toBeVisible();
  await page.mouse.click(4, 4);
  await expect(dialog).not.toBeVisible();
  await expect(page.locator("#dialog-close-reason")).toHaveText("Closed by backdrop");
  await expect(opener).toBeFocused();
});

test("updates alert and switch state through LiveView", async ({page}) => {
  await page.goto("/");

  const status = page.locator("#deployment-status");
  const toggle = page.locator("#deployment-toggle");
  const notifications = page.locator("#notifications-switch");

  await expect(status).toContainText("Deployment pending");
  await toggle.click();
  await expect(status).toContainText("Ready to deploy");
  await expect(toggle).toContainText("Mark pending");

  await expect(notifications).toHaveAttribute("aria-checked", "true");
  await notifications.click();
  await expect(notifications).toHaveAttribute("aria-checked", "false");
});

test("operates a dropdown menu with roving keyboard focus", async ({page}) => {
  await page.goto("/");

  const trigger = page.locator("#release-actions-trigger");
  const menu = page.locator("#release-actions-menu");
  const checks = page.locator("#menu-run-checks");
  const tag = page.locator("#menu-create-tag");

  await expect(trigger).toHaveAttribute("aria-expanded", "false");
  await expect(menu).toBeHidden();
  await trigger.click();
  await expect(trigger).toHaveAttribute("aria-expanded", "true");
  await expect(menu).toBeVisible();
  await expect(checks).toBeFocused();

  await page.locator("#profile-name").evaluate(element => {
    element.value = "Morph update";
    element.dispatchEvent(new Event("input", {bubbles: true}));
  });
  await expect(page.locator("#profile-role-error")).toHaveText("Choose a role");
  await expect(menu).toBeVisible();
  await expect(checks).toBeFocused();

  await page.keyboard.press("ArrowDown");
  await expect(tag).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(menu).toBeHidden();
  await expect(trigger).toHaveAttribute("aria-expanded", "false");
  await expect(trigger).toBeFocused();
  await expect(page.locator("#menu-action-result")).toHaveText("Selected tag");

  await trigger.click();
  await expect(checks).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(menu).toBeHidden();
  await expect(trigger).toBeFocused();
});

test("keeps tab selection on the server and supports arrow navigation", async ({page}) => {
  await page.goto("/");

  const overview = page.locator("#overview-tab");
  const activity = page.locator("#activity-tab");
  const settings = page.locator("#settings-tab");

  await expect(overview).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#overview-panel")).toBeVisible();
  await expect(page.locator("#activity-panel")).toBeHidden();

  await overview.focus();
  await page.keyboard.press("ArrowRight");
  await expect(activity).toHaveAttribute("aria-selected", "true");
  await expect(activity).toBeFocused();
  await expect(page.locator("#activity-panel")).toBeVisible();

  await page.keyboard.press("End");
  await expect(settings).toHaveAttribute("aria-selected", "true");
  await expect(settings).toBeFocused();
  await expect(page.locator("#settings-panel")).toBeVisible();
});

test("dismisses server-owned toast notifications manually and on timeout", async ({page}) => {
  await page.goto("/");

  const show = page.locator("#show-release-toast");
  await show.click();
  let toast = page.locator('[data-opal-ui="toast"]');
  await expect(toast).toBeVisible();
  await expect(toast).toContainText("Release ready");
  await toast.locator('[data-opal-toast-dismiss]').click();
  await expect(toast).toHaveCount(0);
  await expect(page.locator("#toast-dismiss-result")).toHaveText("Toast dismissed by button");
  await expect(show).toBeFocused();

  await show.click();
  toast = page.locator('[data-opal-ui="toast"]');
  await expect(toast).toBeVisible();
  await expect(toast).toHaveCount(0, {timeout: 7_000});
  await expect(page.locator("#toast-dismiss-result")).toHaveText("Toast dismissed by timeout");
});

test("renders server validation and submits an accessible form", async ({page}) => {
  await page.goto("/");

  const name = page.locator("#profile-name");
  const role = page.locator("#profile-role");

  await name.fill("x");
  await name.fill("");
  await expect(page.locator("#profile-name-error")).toContainText("Name is required");
  await expect(name).toHaveAttribute("aria-invalid", "true");

  await name.fill("Mike");
  await role.selectOption("admin");
  await page.locator("#save-profile").click();
  await expect(page.locator("#saved-status")).toContainText("Saved");
  await expect(name).toHaveValue("Mike");
});

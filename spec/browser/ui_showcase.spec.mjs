import {expect, test} from "@playwright/test";

test.use({baseURL: "http://127.0.0.1:8085"});

test("renders the compiled UI theme and primitive families", async ({page}) => {
  await page.goto("/");

  await expect(page).toHaveTitle("Opal UI showcase");
  await expect(page.locator("#opal-live-root")).toHaveClass(/phx-connected/);
  await expect(page.locator('[data-opal-ui="card"]')).toHaveCount(4);
  await expect(page.locator('[data-opal-ui="button"]')).toHaveCount(5);
  await expect(page.locator('[data-opal-ui="table"]')).toBeVisible();
  await expect(page.locator('[data-opal-ui="input"]')).toBeVisible();

  const button = page.locator("#deployment-toggle");
  // Flex/grid items blockify inline-level display values in computed style.
  await expect(button).toHaveCSS("display", "flex");
  await expect(button).toHaveCSS("background-color", "oklch(0.546 0.245 262.881)");
  await expect(page.locator('[data-opal-ui-theme]')).toHaveCount(1);

  await page.emulateMedia({colorScheme: "dark"});
  await expect(page.locator("body")).toHaveCSS("background-color", "rgb(2, 6, 23)");
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

import {defineConfig} from "@playwright/test";

export default defineConfig({
  testDir: "./spec/browser",
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "github" : "line",
  use: {
    baseURL: "http://127.0.0.1:8084",
    browserName: "chromium",
    launchOptions: {
      ignoreDefaultArgs: ["--disable-back-forward-cache"],
    },
    trace: "retain-on-failure",
  },
  webServer: {
    command: "./bin/live_view_counter_example",
    cwd: "./examples/live_view_counter",
    url: "http://127.0.0.1:8084/",
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
});

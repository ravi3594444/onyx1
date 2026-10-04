// Browser evidence for the deployed 22nd X AI product.
//
// Runs with the `playwright` npm package and Chromium. It opens the public
// pages, signs up test accounts, and saves screenshots to OUT_DIR. Each step
// prints one PASS or FAIL line. The script exits with 1 when a step fails.
//
// Env: BASE_URL, OUT_DIR, TAG, PASSWORD, MODE (single|saas), LOGIN_EMAIL
// (single mode), EMAIL_DOMAIN (default example.com). PASSWORD is never printed.
//
// See product/test-corpus/README.md, section "UI evidence".

import { chromium } from "playwright";
import fs from "node:fs";
import path from "node:path";

const BASE_URL = (process.env.BASE_URL ?? "").replace(/\/+$/, "");
const OUT_DIR = process.env.OUT_DIR ?? "ui-evidence";
const TAG = (process.env.TAG ?? `${Date.now()}`)
  .toLowerCase()
  .replace(/[^a-z0-9-]/g, "")
  .slice(0, 24);
const PASSWORD = process.env.PASSWORD ?? "";
const MODE = process.env.MODE ?? "saas";
const LOGIN_EMAIL = process.env.LOGIN_EMAIL ?? "";
const EMAIL_DOMAIN = process.env.EMAIL_DOMAIN ?? "example.com";

const BRAND_NAME = "22nd X AI";
const BRAND_TAGLINE = "More growth. Less busywork.";
const CHAT_PROMPT = "Reply with the single word OK";
const CHAT_TIMEOUT_MS = 90_000;
const NAV_TIMEOUT_MS = 60_000;

const DESKTOP = { width: 1366, height: 800 };
const PHONE = { width: 390, height: 844 };

const ACCOUNTS = {
  ownerA: `owner-a-${TAG}@${EMAIL_DOMAIN}`,
  memberA: `member-a-${TAG}@${EMAIL_DOMAIN}`,
  ownerB: `owner-b-${TAG}@${EMAIL_DOMAIN}`,
};

/** @type {{ step: string, status: "PASS" | "FAIL" | "INFO", detail: string }[]} */
const results = [];
/** @type {string[]} */
const screenshots = [];

function record(status, step, detail = "") {
  results.push({ step, status, detail });
  const suffix = detail ? `: ${detail}` : "";
  console.log(`${status} ${step}${suffix}`);
}

function pass(step, detail) {
  record("PASS", step, detail);
}

function fail(step, detail) {
  record("FAIL", step, detail);
}

function info(step, detail) {
  record("INFO", step, detail);
}

function redact(text) {
  if (!PASSWORD) return text;
  return String(text).split(PASSWORD).join("[PASSWORD]");
}

function url(p) {
  return `${BASE_URL}${p}`;
}

function fileNameSafe(step) {
  return step.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

async function shot(page, name) {
  const file = path.join(OUT_DIR, name);
  await page.screenshot({ path: file, fullPage: false });
  screenshots.push(name);
  return file;
}

/**
 * Runs one step. A failure takes an error screenshot, prints FAIL, and
 * returns null so the next step can run.
 */
async function step(name, page, fn) {
  try {
    const value = await fn();
    return value === undefined ? true : value;
  } catch (error) {
    const message = redact(error instanceof Error ? error.message : error);
    const firstLine = String(message).split("\n")[0];
    if (page && !page.isClosed()) {
      try {
        await shot(page, `error-${fileNameSafe(name)}.png`);
      } catch {
        // The page may be gone. The FAIL line is still printed.
      }
    }
    fail(name, firstLine);
    return null;
  }
}

async function settle(page, timeout = 20_000) {
  await page.waitForLoadState("domcontentloaded").catch(() => {});
  await page.waitForLoadState("networkidle", { timeout }).catch(() => {});
}

async function goto(page, p, timeout = NAV_TIMEOUT_MS) {
  await page.goto(url(p), { waitUntil: "domcontentloaded", timeout });
  await settle(page);
}

async function isVisible(locator, timeout = 3_000) {
  try {
    await locator.first().waitFor({ state: "visible", timeout });
    return true;
  } catch {
    return false;
  }
}

async function bodyText(page) {
  return page.evaluate(() => document.body?.innerText ?? "");
}

// --- Branding -----------------------------------------------------------

async function checkBranding(page, label) {
  const title = await page.title();
  const nameVisible = await isVisible(page.getByText(BRAND_NAME, { exact: false }));
  const taglineVisible = await isVisible(
    page.getByText(BRAND_TAGLINE, { exact: false })
  );
  const text = await bodyText(page);
  const heroStartsWithOnyx = /^\s*Onyx\b/.test(text);
  info(`${label} document.title`, JSON.stringify(title));
  if (title.includes(BRAND_NAME)) {
    pass(`${label} title contains "${BRAND_NAME}"`);
  } else {
    fail(`${label} title contains "${BRAND_NAME}"`, `title=${JSON.stringify(title)}`);
  }
  if (nameVisible) {
    pass(`${label} shows "${BRAND_NAME}"`);
  } else {
    fail(`${label} shows "${BRAND_NAME}"`, "text not visible");
  }
  if (taglineVisible) {
    pass(`${label} shows tagline`);
  } else {
    fail(`${label} shows tagline`, `"${BRAND_TAGLINE}" not visible`);
  }
  if (heroStartsWithOnyx) {
    fail(`${label} hero is not Onyx branded`, "body text starts with Onyx");
  } else {
    pass(`${label} hero is not Onyx branded`);
  }
}

// --- Auth ----------------------------------------------------------------

function emailInput(page) {
  return page.locator('[data-testid="email"], input[name="email"]').first();
}

function passwordInput(page) {
  return page.locator('[data-testid="password"], input[name="password"]').first();
}

async function fillAuthForm(page, email) {
  await emailInput(page).waitFor({ state: "visible", timeout: NAV_TIMEOUT_MS });
  await emailInput(page).fill(email);
  await passwordInput(page).fill(PASSWORD);
  // Formik validates on change. Wait until the submit button is enabled.
  const submit = page.locator('button[type="submit"]').first();
  await submit.waitFor({ state: "visible", timeout: 15_000 });
  await page
    .waitForFunction(
      () => {
        const button = document.querySelector('button[type="submit"]');
        return button instanceof HTMLButtonElement && !button.disabled;
      },
      undefined,
      { timeout: 15_000 }
    )
    .catch(() => {});
  await submit.click();
}

async function waitForAppPage(page) {
  await page.waitForURL(/\/(app|chat)(\/|\?|$)/, { timeout: NAV_TIMEOUT_MS });
  await settle(page);
}

async function readToastError(page) {
  const toast = page.locator('[role="status"], [role="alert"], [data-sonner-toast]');
  if (await isVisible(toast, 1_500)) {
    return (await toast.first().innerText().catch(() => "")).trim();
  }
  return "";
}

/** Dismisses the "We found an existing team" modal when it appears. */
async function dismissNewTeamModal(page, shotName) {
  const button = page.getByRole("button", { name: "Continue with new team" });
  if (await isVisible(button, 6_000)) {
    if (shotName) await shot(page, shotName);
    info("new team modal", "dismissed with 'Continue with new team'");
    await button.click();
    await page.waitForTimeout(1_000);
  }
}

async function signup(page, email) {
  await goto(page, "/auth/signup");
  await fillAuthForm(page, email);
  try {
    await waitForAppPage(page);
  } catch {
    const toast = await readToastError(page);
    throw new Error(
      `signup did not reach the app page (url=${page.url()}${
        toast ? `, notice=${JSON.stringify(toast)}` : ""
      })`
    );
  }
}

async function login(page, email) {
  await goto(page, "/auth/login?autoRedirectToSignup=false");
  await fillAuthForm(page, email);
  try {
    await waitForAppPage(page);
  } catch {
    const toast = await readToastError(page);
    throw new Error(
      `login did not reach the app page (url=${page.url()}${
        toast ? `, notice=${JSON.stringify(toast)}` : ""
      })`
    );
  }
}

// --- App pages -----------------------------------------------------------

async function openAccountMenu(page, email) {
  const trigger = page.locator("#onyx-user-dropdown").first();
  if (await isVisible(trigger, 15_000)) {
    await trigger.click();
  } else {
    // Fallback: the sidebar tab that shows the account initial.
    const initial = email.slice(0, 1).toUpperCase();
    await page
      .locator("aside, nav")
      .getByText(initial, { exact: true })
      .first()
      .click();
  }
  const menu = page.getByText(email, { exact: false });
  await menu.first().waitFor({ state: "visible", timeout: 10_000 });
}

async function adminUsersPage(page) {
  await goto(page, "/admin/users");
  const marker = page.getByRole("button", { name: "Invite Users" });
  await marker.first().waitFor({ state: "visible", timeout: 30_000 });
  await settle(page, 10_000);
}

async function inviteUser(page, email) {
  await page.getByRole("button", { name: "Invite Users" }).first().click();
  const dialog = page.getByRole("dialog");
  await dialog.first().waitFor({ state: "visible", timeout: 10_000 });
  const input = dialog
    .locator('input[placeholder*="emails to invite"], textarea, input')
    .first();
  await input.waitFor({ state: "visible", timeout: 10_000 });
  await input.fill(email);
  await input.press("Enter");
  const submit = dialog.getByRole("button", { name: "Invite", exact: true });
  await submit.waitFor({ state: "visible", timeout: 5_000 });
  await page
    .waitForFunction(
      () => {
        const dialogElement = document.querySelector('[role="dialog"]');
        const buttons = dialogElement?.querySelectorAll("button") ?? [];
        return Array.from(buttons).some(
          (button) =>
            button.textContent?.trim() === "Invite" && !button.disabled
        );
      },
      undefined,
      { timeout: 10_000 }
    )
    .catch(() => {});
  await submit.click();
  await Promise.race([
    page.getByText(/Invited \d+ user/).first().waitFor({ timeout: 15_000 }),
    dialog.first().waitFor({ state: "hidden", timeout: 15_000 }),
  ]).catch(() => {});
  await settle(page, 10_000);
}

async function sendChatMessage(page) {
  for (const p of ["/app", "/chat"]) {
    await goto(page, p);
    if (/\/auth\//.test(page.url())) continue;
    break;
  }
  await dismissNewTeamModal(page);
  const input = page
    .locator(
      '#onyx-chat-input-textbox, [role="textbox"][contenteditable="true"], textarea[placeholder]'
    )
    .first();
  await input.waitFor({ state: "visible", timeout: 30_000 });
  await input.click();
  await page.keyboard.type(CHAT_PROMPT, { delay: 10 });
  await page.keyboard.press("Enter");

  const aiMessage = page.locator('[data-testid="onyx-ai-message"]');
  const notice = page.getByText(/Set up an LLM provider/i);
  const started = Date.now();
  let answer = "";
  let noticeText = "";
  while (Date.now() - started < CHAT_TIMEOUT_MS) {
    if ((await aiMessage.count()) > 0) {
      answer = (await aiMessage.last().innerText().catch(() => "")).trim();
      if (answer) break;
    }
    if (await isVisible(notice, 500)) {
      noticeText = (await notice.first().innerText().catch(() => "")).trim();
      break;
    }
    await page.waitForTimeout(1_500);
  }
  // Let streaming settle before the screenshot.
  await page.waitForTimeout(2_500);
  if (answer) {
    answer = (await aiMessage.last().innerText().catch(() => answer)).trim();
  }
  return { answer, noticeText };
}

async function pageMentions(page, needle) {
  const text = await bodyText(page);
  return text.toLowerCase().includes(needle.toLowerCase());
}

// --- Flows ---------------------------------------------------------------

async function publicPages(browser) {
  const context = await browser.newContext({ viewport: DESKTOP });
  const page = await context.newPage();
  await step("login page", page, async () => {
    await goto(page, "/auth/login?autoRedirectToSignup=false");
    await emailInput(page).waitFor({ state: "visible", timeout: NAV_TIMEOUT_MS });
    await shot(page, "01-login.png");
    await checkBranding(page, "login page");
  });
  await step("signup page", page, async () => {
    await goto(page, "/auth/signup");
    await shot(page, "02-signup.png");
    await checkBranding(page, "signup page");
    if (/\/auth\/signup/.test(page.url())) {
      pass("signup page is reachable");
    } else {
      info("signup page", `redirected to ${page.url()}`);
    }
  });
  await context.close();

  const phoneContext = await browser.newContext({
    viewport: PHONE,
    isMobile: true,
    hasTouch: true,
    deviceScaleFactor: 2,
  });
  const phonePage = await phoneContext.newPage();
  await step("login page phone", phonePage, async () => {
    await goto(phonePage, "/auth/login?autoRedirectToSignup=false");
    await emailInput(phonePage).waitFor({
      state: "visible",
      timeout: NAV_TIMEOUT_MS,
    });
    await shot(phonePage, "01b-login-phone.png");
    const overflow = await phonePage.evaluate(
      () => document.documentElement.scrollWidth > window.innerWidth + 1
    );
    if (overflow) {
      fail("login page phone has no horizontal scroll");
    } else {
      pass("login page phone has no horizontal scroll");
    }
  });
  await phoneContext.close();
}

/** Home, account menu and admin users for a signed-in owner or admin. */
async function homeAndAdmin(page, email, prefix, names) {
  await step(`${prefix} home`, page, async () => {
    await dismissNewTeamModal(page, `${names.home.replace(".png", "")}-new-team-modal.png`);
    await shot(page, names.home);
    const greeting = await isVisible(page.getByText(BRAND_TAGLINE), 5_000);
    info(`${prefix} home shows tagline greeting`, String(greeting));
    pass(`${prefix} signed in`, `url=${page.url()}`);
  });
  await step(`${prefix} account menu`, page, async () => {
    await openAccountMenu(page, email);
    await shot(page, names.menu);
    pass(`${prefix} account menu shows ${email}`);
    await page.keyboard.press("Escape");
  });
  await step(`${prefix} admin users`, page, async () => {
    await adminUsersPage(page);
    await shot(page, names.users);
    if (await pageMentions(page, email)) {
      pass(`${prefix} admin users lists ${email}`);
    } else {
      fail(`${prefix} admin users lists ${email}`, "email not on the page");
    }
  });
}

async function singleMode(browser) {
  if (!LOGIN_EMAIL) {
    fail("single mode", "LOGIN_EMAIL is not set");
    return;
  }
  const context = await browser.newContext({ viewport: DESKTOP });
  const page = await context.newPage();
  const ok = await step("login", page, async () => {
    await login(page, LOGIN_EMAIL);
  });
  if (ok) {
    await homeAndAdmin(page, LOGIN_EMAIL, "single", {
      home: "03-company-a-home.png",
      menu: "04-company-a-account-menu.png",
      users: "05-company-a-admin-users.png",
    });
  }
  await context.close();
}

async function saasMode(browser) {
  // Company A owner.
  {
    const context = await browser.newContext({ viewport: DESKTOP });
    const page = await context.newPage();
    const ok = await step("company A sign-up", page, async () => {
      await signup(page, ACCOUNTS.ownerA);
    });
    if (ok) {
      await homeAndAdmin(page, ACCOUNTS.ownerA, "company A", {
        home: "03-company-a-home.png",
        menu: "04-company-a-account-menu.png",
        users: "05-company-a-admin-users.png",
      });
      await step("company A invite member", page, async () => {
        if (!/\/admin\/users/.test(page.url())) await adminUsersPage(page);
        const button = page.getByRole("button", { name: "Invite Users" });
        if (!(await isVisible(button, 5_000))) {
          throw new Error("no 'Invite Users' button on /admin/users");
        }
        await inviteUser(page, ACCOUNTS.memberA);
        await shot(page, "06-company-a-invite.png");
        if (await pageMentions(page, ACCOUNTS.memberA)) {
          pass("company A invite lists member A", ACCOUNTS.memberA);
        } else {
          fail("company A invite lists member A", "invited email not on the page");
        }
      });
      await step("company A llm config", page, async () => {
        await goto(page, "/admin/configuration/llm");
        await page.waitForTimeout(2_000);
        await shot(page, "07-company-a-llm.png");
        const none = await isVisible(page.getByText(/Set up an LLM provider/i), 2_000);
        const hasDefault = await isVisible(page.getByText("Default", { exact: true }), 2_000);
        info("company A llm configured", none ? "no provider" : hasDefault ? "default provider set" : "unknown");
      });
      await step("company A chat", page, async () => {
        const { answer, noticeText } = await sendChatMessage(page);
        await shot(page, "08-company-a-chat.png");
        if (answer) {
          pass("chat answered", JSON.stringify(answer.slice(0, 120)));
        } else {
          fail("chat answered", noticeText ? `notice=${JSON.stringify(noticeText)}` : "no assistant message within 90 s");
        }
      });
    }
    await context.close();
  }

  // Company B owner, isolated from company A.
  {
    const context = await browser.newContext({ viewport: DESKTOP });
    const page = await context.newPage();
    const ok = await step("company B sign-up", page, async () => {
      await signup(page, ACCOUNTS.ownerB);
    });
    if (ok) {
      await step("company B home", page, async () => {
        await dismissNewTeamModal(page, "09-company-b-new-team-modal.png");
        await shot(page, "09-company-b-home.png");
        pass("company B signed in", `url=${page.url()}`);
      });
      await step("company B admin users", page, async () => {
        await adminUsersPage(page);
        await page.getByText(ACCOUNTS.ownerB).first().waitFor({ timeout: 20_000 });
        await shot(page, "10-company-b-admin-users.png");
        if (await pageMentions(page, `owner-a-${TAG}`)) {
          fail("company B does not list company A users", "owner A email is on the page");
        } else {
          pass("company B does not list company A users");
        }
        if (await pageMentions(page, `member-a-${TAG}`)) {
          fail("company B does not list company A invites", "member A email is on the page");
        } else {
          pass("company B does not list company A invites");
        }
      });
    }
    await context.close();
  }

  // Member A accepts the invitation.
  {
    const context = await browser.newContext({ viewport: DESKTOP });
    const page = await context.newPage();
    const ok = await step("member A sign-up", page, async () => {
      await signup(page, ACCOUNTS.memberA);
    });
    if (ok) {
      await step("member A invitation", page, async () => {
        const accept = page.getByRole("button", { name: /Accept Invitation|^Join$/ });
        if (await isVisible(accept, 8_000)) {
          await shot(page, "11-member-a-invite-modal.png");
          await accept.click();
          await settle(page, 15_000);
          pass("member A accepted the invitation modal");
        } else {
          await dismissNewTeamModal(page, "11-member-a-new-team-modal.png");
          info("member A invitation", "no invitation modal; the account joined the inviting team on sign-up");
        }
      });
      await step("member A home", page, async () => {
        await shot(page, "12-member-a-home.png");
        pass("member A signed in", `url=${page.url()}`);
      });
      await step("member A admin blocked", page, async () => {
        await page.goto(url("/admin/users"), { waitUntil: "domcontentloaded", timeout: NAV_TIMEOUT_MS });
        await settle(page, 10_000);
        await page.waitForTimeout(1_500);
        await shot(page, "13-member-a-admin-blocked.png");
        const onAdmin = /\/admin\/users/.test(page.url());
        const inviteButton = await isVisible(page.getByRole("button", { name: "Invite Users" }), 2_000);
        if (!onAdmin || !inviteButton) {
          pass("member A is blocked from admin users", `url=${page.url()}`);
        } else {
          fail("member A is blocked from admin users", "admin users page rendered for a member");
        }
      });
    }
    await context.close();
  }

  // Owner A sees member A.
  {
    const context = await browser.newContext({ viewport: DESKTOP });
    const page = await context.newPage();
    const ok = await step("company A login", page, async () => {
      await login(page, ACCOUNTS.ownerA);
    });
    if (ok) {
      await step("company A users after", page, async () => {
        await adminUsersPage(page);
        await page.getByText(ACCOUNTS.ownerA).first().waitFor({ timeout: 20_000 });
        await shot(page, "14-company-a-users-after.png");
        if (await pageMentions(page, `member-a-${TAG}`)) {
          pass("company A lists member A", ACCOUNTS.memberA);
        } else {
          fail("company A lists member A", "member A email not on the page");
        }
      });
    }
    await context.close();
  }
}

// --- Main ----------------------------------------------------------------

function printSummary() {
  const width = Math.max(4, ...results.map((r) => r.step.length));
  console.log("");
  console.log("Summary");
  console.log(`${"STATUS".padEnd(6)} ${"STEP".padEnd(width)} DETAIL`);
  for (const r of results) {
    console.log(`${r.status.padEnd(6)} ${r.step.padEnd(width)} ${r.detail}`);
  }
  console.log("");
  console.log("Screenshots:");
  for (const name of screenshots) console.log(`  ${path.join(OUT_DIR, name)}`);
  console.log("");
  console.log("Test accounts:");
  if (MODE === "saas") {
    for (const [role, email] of Object.entries(ACCOUNTS)) {
      console.log(`  ${role}: ${email}`);
    }
  } else {
    console.log(`  login: ${LOGIN_EMAIL || "(LOGIN_EMAIL not set)"}`);
  }
}

async function main() {
  if (!BASE_URL) {
    console.error("BASE_URL is required");
    process.exit(2);
  }
  if (MODE !== "single" && MODE !== "saas") {
    console.error(`MODE must be single or saas, got ${JSON.stringify(MODE)}`);
    process.exit(2);
  }
  if (!PASSWORD) {
    console.error("PASSWORD is required");
    process.exit(2);
  }
  fs.mkdirSync(OUT_DIR, { recursive: true });
  console.log(`BASE_URL=${BASE_URL} MODE=${MODE} TAG=${TAG} OUT_DIR=${OUT_DIR}`);

  const browser = await chromium.launch();
  try {
    await publicPages(browser);
    if (MODE === "saas") {
      await saasMode(browser);
    } else {
      await singleMode(browser);
    }
  } finally {
    await browser.close();
  }

  printSummary();
  const failed = results.filter((r) => r.status === "FAIL").length;
  console.log(`\n${failed === 0 ? "ALL PASS" : `${failed} FAIL`}`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(`FAIL run: ${redact(error instanceof Error ? error.stack ?? error.message : error)}`);
  printSummary();
  process.exit(1);
});

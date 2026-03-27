const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');

  const contexts = browser.contexts();
  const context = contexts[0];
  const pages = context.pages();

  const page = pages.find(p => p.url().includes('localhost:3000')) || pages[0];

  await page.bringToFront();
  await page.waitForTimeout(2000);
  await page.screenshot({ path: 'screenshot.png', fullPage: true });

  await browser.close();
})();
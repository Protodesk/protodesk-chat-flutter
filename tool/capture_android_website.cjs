// Run against the deployed widget in a disposable Pixel Chrome session.
// Use the same synthetic conversations as the native integration test.
const { chromium } = require('playwright');
const { execFileSync } = require('node:child_process');
const { mkdirSync, writeFileSync } = require('node:fs');
const path = require('node:path');
const { threads } = require('../test/support/android_website_content.json');
const [output, device] = process.argv.slice(2);
if (!output || !device) throw Error('Usage: capture_android_website.cjs <output> <device>');
const adb = (...args) => execFileSync('adb', ['-s', device, ...args], { maxBuffer: 16e6 });
const pageOf = data => ({ data, nextCursor: null, hasMore: false });
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function main() {
  mkdirSync(output, { recursive: true });
  const browser = await chromium.connectOverCDP('http://127.0.0.1:19273');
  const page = await browser.contexts()[0].newPage();
  let thread, storageOrigin;
  try {
    page.on('response', async res => {
      if (new URL(res.url()).pathname.replace(/\/$/, '') === '/embed') {
        const csp = (await res.allHeaders())['content-security-policy'] || '';
        storageOrigin = csp.match(/https:\/\/[a-z0-9-]+\.r2\.cloudflarestorage\.com/i)?.[0];
      }
    });
    await page.routeWebSocket('**/v1/chat/realtime**', socket => socket.onMessage(raw => {
      if (JSON.parse(raw).type === 'realtime.resume') socket.send(JSON.stringify({
        type: 'realtime.ready', protocolVersion: 1, heartbeatIntervalSeconds: 30,
        maxFrameBytes: 262144, cursor: 'crc1.fixture.' + 'a'.repeat(20) + '.' + 'b'.repeat(20),
      }));
    }));
    await page.route('**/v1/chat/conversations**', route => {
      const req = route.request(), last = new URL(req.url()).pathname.split('/').pop();
      const conv = thread.conversation;
      if (req.method() === 'GET') {
        const data = { conversations: pageOf([conv]), messages: pageOf(thread.messages),
          contact: { email: '', dismissed: true, canRequest: false }, [conv.id]: conv };
        if (data[last]) return route.fulfill({ json: data[last] });
      }
      if (last === 'read') return route.fulfill({ json: { conversationId: conv.id,
        throughMessageId: thread.messages[0].id, unreadCount: 0, readAt: conv.updatedAt } });
      return route.abort();
    });
    const attachmentId = 'att_' + 'e'.repeat(26);
    await page.route(url => url.hostname.endsWith('.r2.cloudflarestorage.com'), route =>
      new URL(route.request().url()).pathname === '/android-visual-fixture/note.txt'
        ? route.fulfill({ status: 200, headers: { 'access-control-allow-origin': '*',
          'access-control-allow-headers': 'content-type', 'access-control-allow-methods': 'PUT, OPTIONS' }, body: '' })
        : route.abort());
    await page.route('**/v1/chat/attachments/**', route => {
      const last = new URL(route.request().url()).pathname.split('/').pop();
      if (last === 'uploads' && storageOrigin) return route.fulfill({ json: {
        attachmentId, uploadId: 'upl_' + 'd'.repeat(26), method: 'PUT',
        headers: { 'Content-Type': 'text/plain' }, expiresAt: new Date(Date.now() + 300000).toISOString(),
        url: storageOrigin + '/android-visual-fixture/note.txt?local=1',
      } });
      if (last === 'complete') return route.fulfill({ json: { id: attachmentId, filename: 'note.txt',
        contentType: 'text/plain', sizeBytes: 3, status: 'ready', createdAt: thread.conversation.createdAt } });
      return route.abort();
    });
    async function open(record) {
      thread = record;
      await page.goto('https://protodesk.io/', { waitUntil: 'domcontentloaded' });
      await page.waitForFunction(() => typeof window.Protodesk?.open === 'function');
      await page.evaluate(() => { void window.Protodesk.open(); });
      // The widget is inside the launcher's closed shadow root.
      for (let i = 0; i < 100; i++) {
        const widget = page.frames().find(f => /\/embed(?:[/?#]|$)/.test(f.url()));
        if (widget && await widget.getByText(record.messages[0].body, {exact:true}).isVisible()) {
          await widget.locator('.realtime-status').filter({hasText:'Connected'}).first().waitFor();
          return widget;
        }
        await sleep(200);
      }
      throw Error('The fixture conversation did not appear.');
    }
    const snap = name => page.screenshot({path: path.join(output, 'web-' + name + '.png'), scale:'css'});
    let frame = await open(threads[0]);
    await snap('populated');
    await frame.locator('.composer-form textarea').click();
    adb('shell', 'input', 'text', 'Thanks');
    await sleep(700);
    if (!adb('shell','dumpsys','input_method').toString().includes('mInputShown=true')) {
      throw Error('Dismiss Chrome onboarding and enable Gboard before capturing.');
    }
    writeFileSync(path.join(output, 'web-keyboard.png'), adb('exec-out','screencap','-p'));
    adb('shell','input','keyevent','4');
    frame = await open(threads[1]);
    await snap('attachment');
    await frame.evaluate(() => { document.documentElement.dataset.colorScheme = 'dark'; });
    await snap('dark');
    await frame.evaluate(() => { document.documentElement.dataset.colorScheme = 'light'; });
    await frame.locator('input[type=file]').setInputFiles({name:'note.txt', mimeType:'text/plain', buffer:Buffer.from('ABC')});
    await frame.locator('.composer-attachment[data-status=ready]').waitFor();
    await snap('staged');
  } finally {
    await page.close();
    await browser.close();
  }
}
main().catch(err => { console.error(err.message); process.exitCode = 1; });

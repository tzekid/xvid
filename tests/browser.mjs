// Real browser against the disposable E2E process. Reuse an installed Playwright
// library via XVID_BROWSER_MODULE; no application dependency or test framework.
import assert from 'node:assert/strict'
import { readFile, mkdir, readdir } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
const { chromium } = await import(pathToFileURL(process.env.XVID_BROWSER_MODULE).href)
const [origin, dataRoot] = process.argv.slice(2)
const initialJobs = new Set(await readdir(`${dataRoot}/jobs`))
const browser = await chromium.launch({ executablePath: process.env.XVID_BROWSER_BIN || '/usr/bin/chromium', headless: true, args: ['--no-sandbox'] })
const shots = process.env.XVID_BROWSER_SCREENSHOTS
if (shots) await mkdir(shots, { recursive: true })
// Fixtures use a second loopback port instead of the production CDN allowlist.
// CORS and Fetch credential/referrer rules remain active.
const context = await browser.newContext({ bypassCSP: true, viewport: { width: 390, height: 844 } })
context.setDefaultTimeout(15000)
await context.addInitScript(() => {
  window.clipboardValue = ''
  window.clipboardReads = 0
  Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
    readText: async () => {
      window.clipboardReads++
      if (window.clipboardDelay) await new Promise((resolve) => setTimeout(resolve, window.clipboardDelay))
      if (window.clipboardBlocked) throw new DOMException('Denied', 'NotAllowedError')
      return window.clipboardValue
    }
  } })
})
const page = await context.newPage()
const mediaRequests = []
page.on('request', request => { if (/\/(video|media)\//.test(new URL(request.url()).pathname)) mediaRequests.push(request) })
const errors = []
page.on('pageerror', (error) => errors.push(error.message))
let creates = 0
page.on('request', (request) => { if (request.method() === 'POST' && request.url() === `${origin}/jobs`) creates++ })
const link = (id) => `https://x.com/fixture/status/${id}`
const input = page.locator('#url')
const resolution = page.locator('[data-resolution]')
const download = page.locator('[data-download]')
const state = async (value) => page.waitForSelector(`#app[data-page-state="${value}"]:not([aria-busy])`)
const manifest = async () => JSON.parse(await readFile(`${dataRoot}/jobs/${await page.locator('#app').getAttribute('data-job-id')}/job.json`, 'utf8'))
const submit = async (id, choice = false) => {
  await input.fill(link(id))
  await resolution.setChecked(choice)
  await download.click()
  await state(choice && id === 2103 ? 'choose' : 'ready')
}
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png`, fullPage: true, animations: 'disabled' }) }
const instagramJourney = async () => {
  const url = 'https://www.instagram.com/p/Carousel/'
  await page.goto(origin)
  await input.fill(url)
  await resolution.check()
  await download.click()
  await state('choose')
  assert.equal(await page.locator('.instagram-item').count(), 12)
  assert.equal((await manifest()).source_artifacts.length, 0)
  assert.equal(await input.inputValue(), url)
  await shot('instagram-mobile-picker')
  await page.setViewportSize({ width: 1440, height: 1000 })
  await shot('instagram-desktop-picker')
  await page.locator('[name="item_id"][value="1007"]').click()
  await state('ready')
  const selected = await manifest()
  assert.equal(selected.selection.item_id, '1007')
  assert.equal(selected.source_artifacts.length, 1)
  assert.equal(selected.delivery.mode, 'original')
  assert.equal(await download.textContent(), 'Download again')
  await page.setViewportSize({ width: 390, height: 844 })
  await shot('instagram-mobile-video')
  await download.click()
  await state('choose')
  await page.locator('[name="item_id"][value="1004"]').click()
  await state('ready')
  assert.equal((await manifest()).source_artifacts[0].media_kind, 'image')
  assert.equal(await input.inputValue(), url)
  await input.fill('https://www.instagram.com/p/SinglePhoto/')
  await download.click()
  await state('ready')
  assert.equal(await page.locator('.instagram-picker').count(), 0)
  assert.equal((await manifest()).source_artifacts.length, 1)
  assert.deepEqual(errors, [])
  console.log('Instagram browser E2E passed: carousel selection, original video/photo, repeat link and single-item bypass')
}
try {
  if (process.argv[4] === 'instagram') {
    await instagramJourney()
  } else {
  await page.goto(origin)
  await page.locator('[data-paste]').waitFor({ state: 'visible' })
  assert.equal(await download.isVisible(), false)
  await resolution.check()
  assert.equal(creates, 0)
  assert.equal(await page.evaluate(() => clipboardReads), 0)
  await shot('mobile-home')
  await input.fill(link(2103))
  await resolution.uncheck()
  const beforeFastRepeat = creates
  const originalDownload = page.waitForEvent('download')
  await download.click()
  await page.waitForSelector('#app[data-job-id]:not([aria-busy])')
  await download.click()
  await state('ready')
  const originalFile = await originalDownload
  assert.match((await readFile(await originalFile.path())).toString(), /height=1080/)
  assert.equal(await originalFile.failure(), null)
  assert.equal((await manifest()).direct_delivery, true)
  assert.equal((await manifest()).source_artifacts.length, 0)
  assert.equal(creates, beforeFastRepeat + 1)
  assert.equal(await input.inputValue(), link(2103))
  assert.equal(await download.textContent(), 'Download again')
  assert.equal((await manifest()).delivery.mode, 'original')
  assert.equal(await page.evaluate(() => clipboardReads), 0)
  await shot('mobile-result')
  const firstPath = new URL(page.url()).pathname

  // Repeat the retained link with a different preference; each row submits once.
  await resolution.check()
  await download.click()
  await state('choose')
  assert.equal(await input.inputValue(), link(2103))
  assert.equal(await page.locator('input[type="radio"]').count(), 0)
  assert.equal(await page.locator('[name="delivery"]').inputValue(), 'original')
  await shot('mobile-resolution')
  const beforeChoice = creates
  const selectedDownload = page.waitForEvent('download')
  await page.locator('[name="variant"][value="video-720"]').click()
  await state('ready')
  assert.equal(creates, beforeChoice)
  const chosen = await manifest()
  assert.equal(chosen.selection.variant_id, 'video-720')
  assert.equal(chosen.delivery.mode, 'original')
  const selectedFile = await selectedDownload
  assert.match((await readFile(await selectedFile.path())).toString(), /height=720/)
  assert.equal(await selectedFile.failure(), null)

  // Actual cross-origin fetches must omit referrer and credentials.
  assert.ok(mediaRequests.length >= 2)
  for (const request of mediaRequests) {
    const headers = await request.allHeaders()
    assert.equal(headers.referer, undefined)
    assert.equal(headers.cookie, undefined)
  }

  // An expired link refreshes metadata once and preserves the selected quality.
  let cdnAttempts = 0
  let refreshes = 0
  const countRefresh = request => { if (new URL(request.url()).pathname.endsWith('/refresh')) refreshes++ }
  page.on('request', countRefresh)
  await page.route('**/video/**', async route => {
    cdnAttempts++
    if (cdnAttempts === 1) await route.fulfill({ status: 403, headers: { 'access-control-allow-origin': '*' }, body: 'expired' })
    else await route.continue()
  })
  const renewed = page.waitForEvent('download')
  await submit(2103)
  assert.match((await readFile(await (await renewed).path())).toString(), /height=1080/)
  assert.equal(cdnAttempts, 2)
  assert.equal(refreshes, 1)
  await page.unroute('**/video/**')
  page.off('request', countRefresh)

  // The transfer is cancellable on the device without changing the ready metadata.
  await submit(2130)
  await page.locator('[data-direct-cancel]:visible').click()
  await page.getByText('Cancelled', { exact: true }).waitFor()
  assert.equal((await manifest()).state, 'ready')
  assert.equal((await manifest()).source_artifacts.length, 0)

  // Chunked media works without a declared length; malformed media never downloads.
  const chunked = page.waitForEvent('download')
  await submit(2131)
  assert.equal((await readFile(await (await chunked).path())).length, 8 * 1024 * 1024 + 1)
  await submit(2127)
  await page.getByText('The response was not the requested media file.', { exact: true }).waitFor()

  // A large declared response stops before buffering it.
  await page.route('**/video/**', route => route.fulfill({ status: 200, headers: { 'access-control-allow-origin': '*', 'content-type': 'video/mp4', 'content-length': String(65 * 1024 * 1024) }, body: '' }))
  await submit(2103)
  await page.getByText('This file is too large to prepare here. Open original to save it.', { exact: true }).waitFor()
  await page.unroute('**/video/**')

  // The desktop file path writes chunks and closes only after a complete download.
  await page.goto(new URL(page.url()).pathname.startsWith('/j/') ? `${origin}${new URL(page.url()).pathname}` : origin)
  await state('ready')
  await page.evaluate(() => {
    window.streamed = { bytes: 0, closed: false, aborted: false }
    window.showSaveFilePicker = async () => ({ createWritable: async () => ({
      write: async chunk => { streamed.bytes += chunk.byteLength },
      close: async () => { streamed.closed = true },
      abort: async () => { streamed.aborted = true }
    }) })
  })
  await page.locator('[data-direct-download]').click()
  await page.waitForFunction(() => streamed.closed)
  assert.ok((await page.evaluate(() => streamed.bytes)) > 12)
  assert.equal(await page.evaluate(() => streamed.aborted), false)
  await page.evaluate(() => { delete window.showSaveFilePicker })

  await resolution.check()

  // Drafts survive stream updates, reload and history. Enter uses the visible URL.
  await input.fill(link(2102))
  await page.reload()
  assert.equal(await input.inputValue(), link(2102))
  assert.equal(await resolution.isChecked(), true)
  assert.equal(await download.textContent(), 'Download')
  await input.press('Enter')
  await state('ready')
  assert.equal((await manifest()).probe.x_plan.items.length, 4)
  const photoPath = new URL(page.url()).pathname
  await page.goBack()
  await state('ready')
  await page.waitForFunction((path) => location.pathname !== path && document.querySelector('#url').value.endsWith('/2102'), photoPath)
  await page.goForward()
  await page.waitForFunction((path) => location.pathname === path && document.querySelector('#app').dataset.pageState === 'ready', photoPath)

  // Paste always replaces a populated field, using the selected preference.
  await page.evaluate((value) => { clipboardValue = value }, link(2103))
  const beforePaste = creates
  await page.locator('[data-paste]').click()
  await state('choose')
  assert.equal(creates, beforePaste + 1)
  assert.equal(await input.inputValue(), link(2103))
  assert.equal(await page.evaluate(() => clipboardReads), 1)

  // Simultaneous attempts during a slow clipboard read must not submit the old field.
  await page.evaluate((value) => { clipboardValue = value; clipboardDelay = 250 }, link(2104))
  const beforeDouble = creates
  await page.evaluate(() => {
    const paste = document.querySelector('[data-paste]')
    paste.click(); paste.click()
    document.querySelector('[data-link-form]').requestSubmit()
  })
  await state('ready')
  assert.equal(creates, beforeDouble + 1)
  assert.equal((await manifest()).probe.x_plan.items.length, 2)
  assert.equal(await input.inputValue(), link(2104))
  await page.evaluate(() => { clipboardDelay = 0; clipboardBlocked = true })
  await page.locator('[data-paste]').click()
  await page.locator('[data-link-error]:visible').waitFor()
  assert.equal(creates, beforeDouble + 1)
  assert.equal(await input.inputValue(), link(2104))
  await page.evaluate(() => { clipboardBlocked = false; clipboardValue = 'not a link' })
  await page.locator('[data-paste]').click()
  await page.waitForFunction(() => document.querySelector('[data-link-error]').textContent.includes('does not contain'))
  assert.equal(creates, beforeDouble + 1)
  await page.evaluate(() => { Object.defineProperty(navigator, 'clipboard', { value: undefined, configurable: true }) })
  await page.locator('[data-paste]').click()
  await page.waitForFunction(() => document.querySelector('[data-link-error]').textContent.includes('unavailable'))
  await submit(2105, true)
  assert.equal((await manifest()).probe.x_plan.items.length, 3)

  // A new job supersedes an old transfer while preserving an edited draft.
  await input.fill(link(2130))
  await resolution.uncheck()
  await download.click()
  await state('ready')
  await input.fill(link(2103))
  await page.waitForTimeout(300)
  assert.equal(await input.inputValue(), link(2103))
  await download.click()
  await state('ready')
  const newestId = await page.locator('#app').getAttribute('data-job-id')
  await page.waitForTimeout(1200)
  assert.equal(await page.locator('#app').getAttribute('data-job-id'), newestId)
  assert.equal(await input.inputValue(), link(2103))

  // Probe errors keep the submitted link and allow an edited retry.
  await input.fill(link(2113))
  await download.click()
  await state('problem')
  await page.reload()
  assert.equal(await input.inputValue(), link(2113))
  await submit(2103, true)

  // A lost response never automatically replays a mutation.
  await page.waitForTimeout(550) // An intentional retry, outside the double-tap window.
  let lost = 0
  await page.route('**/jobs', async (route) => { lost++; await route.abort('failed') })
  await download.click()
  await page.getByText('Could not confirm the request.', { exact: false }).waitFor()
  await page.waitForTimeout(200)
  assert.equal(lost, 1)
  assert.equal(await input.inputValue(), link(2103))
  await page.unroute('**/jobs')
  await download.click()
  await state('choose')

  // Layout and keyboard access at small phone, tablet, desktop and dark mode.
  for (const [width, height] of [[320, 568], [390, 844], [768, 1024], [1440, 1000]]) {
    await page.setViewportSize({ width, height })
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
    const pasteBox = await page.locator('[data-paste]').boundingBox()
    const downloadBox = await download.boundingBox()
    assert.equal(pasteBox.width, downloadBox.width)
    assert.equal(pasteBox.height, downloadBox.height)
    assert.ok(downloadBox.y - pasteBox.y - pasteBox.height >= 8)
    assert.ok(downloadBox.y - pasteBox.y - pasteBox.height <= 12)
    assert.ok((await page.locator('.brand').boundingBox()).height >= 56)
    await shot(`resolution-${width}`)
  }
  await page.emulateMedia({ colorScheme: 'dark' })
  await page.setViewportSize({ width: 390, height: 844 })
  await shot('mobile-dark')
  await resolution.focus()
  await page.keyboard.press('Space')
  assert.equal(await resolution.isChecked(), false)
  assert.equal(await page.evaluate(() => getComputedStyle(document.querySelector('[data-resolution]')).outlineStyle), 'solid')

  const native = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 390, height: 844 } })
  const nativePage = await native.newPage()
  await nativePage.goto(origin)
  assert.equal(await nativePage.locator('[data-paste]').isVisible(), false)
  await nativePage.locator('#url').fill(link(2103))
  await nativePage.locator('[data-resolution]').check()
  await nativePage.locator('[data-download]').click()
  await nativePage.waitForSelector('[name="variant"][value="video-720"]', { timeout: 15000 })
  assert.equal(await nativePage.locator('#url').inputValue(), link(2103))
  await nativePage.locator('[name="variant"][value="video-720"]').click()
  await nativePage.waitForSelector('[data-page-state="ready"]', { timeout: 15000 })
  assert.equal(await nativePage.locator('#url').inputValue(), link(2103))
  assert.equal(await nativePage.locator('[data-download]').textContent(), 'Download again')
  await native.close()
  console.log('Browser desktop journeys passed')
  await page.goto(origin)
  for (const id of (await readdir(`${dataRoot}/jobs`)).filter(id => !initialJobs.has(id))) await context.request.post(`${origin}/j/${id}/delete`, { form: {} })
  // The iPhone UI prepares a shareable File and requires an explicit sheet tap.
  const phone = await browser.newContext({ bypassCSP: true, userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1', viewport: { width: 390, height: 844 } })
  await phone.addInitScript(() => {
    navigator.canShare = ({ files }) => files.length > 0
    navigator.share = async ({ files }) => { window.sharedFiles = files.map(file => ({ size: file.size, type: file.type, name: file.name })) }
  })
  const phonePage = await phone.newPage()
  phonePage.on('pageerror', error => errors.push(error.message))
  phonePage.on('response', response => { if (new URL(response.url()).pathname.endsWith('/events') && response.status() !== 200) console.log('Phone events HTTP:', response.status()) })
  await phonePage.goto(origin)
  await phonePage.locator('#url').fill(link(2103))
  await phonePage.locator('[data-download]').click()
  try { await phonePage.waitForSelector('[data-direct-preview][src]', { timeout: 10000 }) } catch (error) {
    console.log('Phone fixture state:', await phonePage.locator('#app').innerText())
    const phoneId = await phonePage.locator('#app').getAttribute('data-job-id')
    if (phoneId) console.log('Phone server state:', JSON.parse(await readFile(`${dataRoot}/jobs/${phoneId}/job.json`, 'utf8')).state)
    if (shots) await phonePage.screenshot({ path: `${shots}/phone-failure.png`, fullPage: true })
    throw error
  }
  await phonePage.locator('[data-direct-share]').click()
  await phonePage.waitForFunction(() => sharedFiles?.length === 1)
  assert.equal(await phonePage.evaluate(() => sharedFiles[0].type), 'video/mp4')
  await phonePage.locator('#url').fill(link(2102))
  await phonePage.locator('[data-download]').click()
  const allPhotos = phonePage.getByRole('button', { name: 'Save all photos…', exact: true })
  await allPhotos.click()
  await phonePage.getByRole('button', { name: 'Preparing photos…', exact: true }).waitFor({ state: 'hidden' })
  await allPhotos.click()
  await phonePage.waitForFunction(() => sharedFiles?.length === 4)
  assert.deepEqual(await phonePage.evaluate(() => sharedFiles.map(file => file.type)), ['image/jpeg', 'image/png', 'image/webp', 'image/jpeg'])
  await phone.close()
  assert.deepEqual(errors, [])
  assert.notEqual(firstPath, photoPath)
  console.log('Browser E2E passed: original resolutions, drafts, repeat/paste, failures, races, history, native forms and responsive layout')
  }
} catch (error) {
  await shot('failure')
  throw error
} finally {
  const createdJobs = (await readdir(`${dataRoot}/jobs`)).filter((id) => !initialJobs.has(id))
  for (const id of createdJobs) await context.request.post(`${origin}/j/${id}/delete`, { form: {} })
  await browser.close()
  for (let attempt = 0; attempt < 100; attempt++) {
    if (!(await readdir(`${dataRoot}/jobs`)).some((id) => createdJobs.includes(id))) break
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
}

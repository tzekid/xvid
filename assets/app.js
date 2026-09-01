(() => {
  const maxShareBytes = 64 * 1024 * 1024
  const preparedFiles = new Map()
  const pendingFiles = new Map()
  const preparedPhotoFiles = new Map()
  const pendingPhotoFiles = new Map()
  const pendingControllers = new Set()
  const xHosts = new Set([
    'x.com',
    'www.x.com',
    'mobile.x.com',
    'twitter.com',
    'www.twitter.com',
    'mobile.twitter.com',
    'm.twitter.com'
  ])
  let pageCleanup = () => {}
  let fragmentCleanup = () => {}
  let pageHidden = false
  let navigating = false

  const isIOS = /iPhone|iPad|iPod/i.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.getRegistrations()
      .then((registrations) => Promise.all(registrations.map((registration) => {
        const scripts = [registration.active, registration.waiting, registration.installing]
          .filter(Boolean)
          .map((worker) => new URL(worker.scriptURL).pathname)
        return scripts.some((path) => path === '/sw.js') ? registration.unregister() : false
      })))
      .catch(() => undefined)
  }

  const firstUrl = (value) => {
    const match = value.match(/https?:\/\/[^\s<>"']+/i)
    if (!match) return null
    const candidate = match[0].replace(/[),.;!?]+$/, '')
    try {
      const url = new URL(candidate)
      return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : null
    } catch {
      return null
    }
  }

  const xStatusUrl = (value) => {
    const candidate = firstUrl(value)
    if (!candidate) return null
    try {
      const url = new URL(candidate)
      return xHosts.has(url.hostname.toLowerCase()) &&
        /\/status\/\d{1,24}(?:\/(?:video|photo)\/\d+)?\/?$/.test(url.pathname)
        ? url.href
        : null
    } catch {
      return null
    }
  }

  const abortPending = () => {
    pendingControllers.forEach((controller) => controller.abort())
    pendingControllers.clear()
    pendingFiles.clear()
    pendingPhotoFiles.clear()
  }

  const clearPrepared = () => {
    abortPending()
    preparedFiles.clear()
    preparedPhotoFiles.clear()
  }

  const formDataWithSubmitter = (form, submitter) => {
    try {
      return new FormData(form, submitter || undefined)
    } catch {
      const data = new FormData(form)
      if (submitter?.name && !data.has(submitter.name)) data.append(submitter.name, submitter.value)
      return data
    }
  }

  const parseDocument = (html) => new DOMParser().parseFromString(html, 'text/html')

  const captureFocus = (root) => {
    const active = document.activeElement
    if (!active || !root.contains(active)) return null
    return active.getAttribute('data-focus-key') || active.id || null
  }

  const restoreFocus = (root, key) => {
    if (!key) return
    const byId = document.getElementById(key)
    if (byId && root.contains(byId)) {
      byId.focus({ preventScroll: true })
      return
    }
    const escape = globalThis.CSS?.escape || ((value) => value.replace(/["\\]/g, '\\$&'))
    root.querySelector(`[data-focus-key="${escape(key)}"]`)?.focus({ preventScroll: true })
  }

  const replaceApp = (nextDocument, responseUrl, historyMode = 'push') => {
    const current = document.querySelector('#app')
    const next = nextDocument.querySelector('#app')
    if (!current || !next) throw new Error('missing app shell')
    const focusKey = captureFocus(current)
    const replacement = document.importNode(next, true)
    current.replaceWith(replacement)
    document.title = nextDocument.title || 'xvid'
    if (historyMode === 'push') history.pushState(null, '', responseUrl)
    if (historyMode === 'replace') history.replaceState(null, '', responseUrl)
    boot(replacement)
    restoreFocus(replacement, focusKey)
    return replacement
  }

  const fetchPage = async (url, options = {}) => {
    const headers = { Accept: 'text/html', 'X-Xvid-Navigation': '1', ...(options.headers || {}) }
    const response = await fetch(url, {
      ...options,
      headers,
      credentials: 'same-origin',
      redirect: 'follow'
    })
    const type = response.headers.get('content-type') || ''
    if (!type.includes('text/html')) throw new Error('unexpected response')
    return { response, document: parseDocument(await response.text()) }
  }

  const setOptimistic = (form, submitter) => {
    const app = form.closest('#app')
    app?.setAttribute('aria-busy', 'true')
    form.querySelector('[data-optimistic]')?.remove()
    const status = document.createElement('p')
    status.dataset.optimistic = '1'
    status.className = 'privacy-note'
    status.setAttribute('role', 'status')
    status.textContent = form.matches('[data-link-form]')
      ? submitter?.name === 'advanced' ? 'Checking link…' : 'Starting download…'
      : 'Updating…'
    form.append(status)
    if (submitter) {
      submitter.dataset.previousLabel = submitter.textContent
      submitter.textContent = submitter.name === 'advanced' ? 'Checking…' : 'Working…'
      submitter.disabled = true
    }
  }

  const clearOptimistic = (form, submitter) => {
    form.closest('#app')?.removeAttribute('aria-busy')
    form.querySelector('[data-optimistic]')?.remove()
    if (submitter) {
      submitter.disabled = false
      if (submitter.dataset.previousLabel) submitter.textContent = submitter.dataset.previousLabel
      delete submitter.dataset.previousLabel
    }
  }

  const navigateForm = async (form, submitter) => {
    if (navigating) return
    navigating = true
    const body = new URLSearchParams()
    formDataWithSubmitter(form, submitter).forEach((value, key) => body.append(key, String(value)))
    setOptimistic(form, submitter)
    try {
      const { response, document: next } = await fetchPage(form.action, {
        method: (form.method || 'GET').toUpperCase(),
        body,
        headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' }
      })
      const currentUrl = new URL(location.href)
      const targetUrl = new URL(response.url)
      replaceApp(next, response.url, currentUrl.pathname === targetUrl.pathname ? 'replace' : 'push')
    } catch {
      clearOptimistic(form, submitter)
      form.dataset.nativeSubmit = '1'
      if (submitter) form.requestSubmit(submitter)
      else form.submit()
    } finally {
      navigating = false
    }
  }

  const navigateLink = async (link) => {
    if (navigating) return
    navigating = true
    try {
      const { response, document: next } = await fetchPage(link.href)
      replaceApp(next, response.url, 'push')
    } catch {
      location.assign(link.href)
    } finally {
      navigating = false
    }
  }

  const updateComposer = (root) => {
    const form = root.querySelector('[data-link-form]')
    const input = form?.querySelector('#url')
    const basic = form?.querySelector('[data-basic-submit]')
    const label = form?.querySelector('[data-basic-label]')
    const clear = form?.querySelector('[data-clear-input]')
    const error = form?.querySelector('[data-link-error]')
    if (!form || !input || !basic || !label) return

    const refresh = () => {
      label.textContent = input.value.trim() ? 'Save media' : navigator.clipboard?.readText ? 'Paste & save' : 'Save media'
      if (clear) clear.hidden = !input.value
      input.setCustomValidity('')
      if (error) error.hidden = true
    }
    input.addEventListener('input', refresh)
    input.addEventListener('paste', (event) => {
      const candidate = xStatusUrl(event.clipboardData?.getData('text') || '')
      if (!candidate) return
      event.preventDefault()
      input.value = candidate
      refresh()
    })
    clear?.addEventListener('click', () => {
      input.value = ''
      refresh()
      input.focus()
    })
    basic.addEventListener('click', async (event) => {
      if (input.value.trim() || !navigator.clipboard?.readText) return
      event.preventDefault()
      basic.disabled = true
      try {
        const candidate = xStatusUrl(await navigator.clipboard.readText())
        if (!candidate) throw new Error()
        input.value = candidate
        refresh()
        basic.disabled = false
        form.requestSubmit(basic)
      } catch {
        if (error) {
          error.textContent = 'Clipboard access was blocked or did not contain a public X status link.'
          error.hidden = false
        }
        input.focus()
      } finally {
        basic.disabled = false
      }
    })
    refresh()
  }

  const updateChoiceSummary = (form) => {
    const variant = form.querySelector('input[name="variant"]:checked')
    const delivery = form.querySelector('input[name="delivery"]:checked')
    const targets = [...form.querySelectorAll('[data-target-height]')]
    const targetWrap = form.querySelector('[data-target-heights]')
    const variantHeight = Number(variant?.dataset.variantHeight || 0)
    targets.forEach((target) => { target.disabled = variantHeight > 0 && Number(target.dataset.targetHeight) >= variantHeight })
    if (delivery?.value === 'downscale') {
      targetWrap?.removeAttribute('hidden')
      let selected = targets.find((target) => target.checked && !target.disabled)
      if (!selected) {
        selected = targets.find((target) => !target.disabled)
        if (selected) selected.checked = true
      }
    } else {
      targetWrap?.setAttribute('hidden', '')
    }
    const summary = form.querySelector('[data-selection-summary]')
    if (!summary) return
    const quality = variant?.closest('.radio-row')?.querySelector('strong')?.textContent?.trim()
    const size = variant?.closest('.radio-row')?.querySelector('.row-value')?.textContent?.trim()
    const prep = delivery?.closest('.radio-row')?.querySelector('strong')?.textContent?.trim()
    const target = delivery?.value === 'downscale' ? targets.find((item) => item.checked)?.value : null
    summary.textContent = [quality, target ? `${target}p` : prep, size && size !== '—' ? size : null].filter(Boolean).join(' · ')
  }

  const wireChoice = (root) => {
    const form = root.querySelector('[data-choice-form]')
    if (!form) return
    const update = () => updateChoiceSummary(form)
    form.addEventListener('change', update)
    update()
  }

  const shareKey = (button) => button.dataset.shareUrl
  const shareLabel = (button) => button.dataset.shareKind === 'video'
    ? 'Save video…'
    : button.dataset.shareKind === 'image'
      ? 'Save image…'
      : 'Share file…'

  const fetchFile = async (button, onProgress) => {
    const controller = new AbortController()
    pendingControllers.add(controller)
    try {
      const response = await fetch(button.dataset.shareUrl, { credentials: 'same-origin', signal: controller.signal })
      if (!response.ok) throw new Error()
      const expected = Number(button.dataset.shareSize)
      const declared = Number(response.headers.get('content-length'))
      if (!Number.isFinite(expected) || expected <= 0 || expected > maxShareBytes || declared !== expected) throw new Error()
      const chunks = []
      let loaded = 0
      if (response.body?.getReader) {
        const reader = response.body.getReader()
        while (true) {
          const { done, value } = await reader.read()
          if (done) break
          loaded += value.byteLength
          if (loaded > expected) throw new Error()
          chunks.push(value)
          onProgress?.(loaded, expected)
        }
      } else {
        const blob = await response.blob()
        loaded = blob.size
        chunks.push(blob)
        onProgress?.(loaded, expected)
      }
      if (loaded !== expected) throw new Error()
      const blob = new Blob(chunks, { type: button.dataset.shareType })
      return new File([blob], button.dataset.shareName, { type: button.dataset.shareType })
    } finally {
      pendingControllers.delete(controller)
    }
  }

  const deviceProgress = (button, loaded, total) => {
    const panel = button.closest('.artifact-row')?.querySelector('[data-device-preparation]')
    const progress = panel?.querySelector('[data-device-progress]')
    const percent = panel?.querySelector('[data-device-percent]')
    if (!panel || !progress) return
    panel.hidden = false
    progress.max = total
    progress.value = loaded
    if (percent) percent.textContent = `${Math.round(loaded / total * 100)}%`
  }

  const resetDeviceProgress = (button) => {
    const panel = button.closest('.artifact-row')?.querySelector('[data-device-preparation]')
    const progress = panel?.querySelector('[data-device-progress]')
    const percent = panel?.querySelector('[data-device-percent]')
    if (panel) panel.hidden = true
    if (progress) {
      progress.removeAttribute('value')
      progress.removeAttribute('max')
    }
    if (percent) percent.textContent = ''
  }

  const prepareShare = (button) => {
    const key = shareKey(button)
    if (preparedFiles.has(key)) return Promise.resolve(preparedFiles.get(key))
    if (pendingFiles.has(key)) return pendingFiles.get(key)
    const run = fetchFile(button, (loaded, total) => deviceProgress(button, loaded, total))
      .then((file) => {
        if (pageHidden || !navigator.canShare({ files: [file] })) throw new Error()
        preparedFiles.clear()
        preparedFiles.set(key, file)
        resetDeviceProgress(button)
        return file
      })
      .catch((error) => {
        resetDeviceProgress(button)
        throw error
      })
      .finally(() => pendingFiles.delete(key))
    pendingFiles.set(key, run)
    return run
  }

  const photoKey = (buttons) => buttons.map(shareKey).join('\n')
  const preparePhotoShare = (buttons) => {
    if (buttons.length < 2 || buttons.length > 4 || buttons.some((button) => button.dataset.shareKind !== 'image')) return Promise.reject(new Error())
    const key = photoKey(buttons)
    if (preparedPhotoFiles.has(key)) return Promise.resolve(preparedPhotoFiles.get(key))
    if (pendingPhotoFiles.has(key)) return pendingPhotoFiles.get(key)
    const sizes = buttons.map((button) => Number(button.dataset.shareSize))
    const total = sizes.reduce((sum, size) => sum + size, 0)
    if (sizes.some((size) => !Number.isFinite(size) || size <= 0) || total > maxShareBytes) return Promise.reject(new Error())
    const run = (async () => {
      const files = []
      for (const button of buttons) files.push(await fetchFile(button))
      if (pageHidden || !navigator.canShare({ files })) throw new Error()
      preparedPhotoFiles.clear()
      preparedPhotoFiles.set(key, files)
      return files
    })().finally(() => pendingPhotoFiles.delete(key))
    pendingPhotoFiles.set(key, run)
    return run
  }

  const recordShare = (buttons) => {
    const artifacts = buttons.map((button) => button.dataset.shareId).join(',')
    fetch(`${location.pathname}/shared`, {
      method: 'POST',
      body: new URLSearchParams({ artifacts }),
      credentials: 'same-origin',
      keepalive: true,
      headers: { 'X-Xvid-Navigation': '1' }
    }).catch(() => undefined)
  }

  const revealShares = (root) => {
    if (!navigator.share || !navigator.canShare || typeof File !== 'function') return
    const fragment = root.matches?.('[data-state-fragment]') ? root : root.querySelector('[data-state-fragment]')
    const terminalReady = fragment?.dataset.state === 'ready'
    const buttons = [...root.querySelectorAll('[data-share-file]')]
    buttons.forEach((button) => {
      const size = Number(button.dataset.shareSize)
      if (!Number.isFinite(size) || size <= 0 || size > maxShareBytes) return
      const sample = new File([], button.dataset.shareName, { type: button.dataset.shareType })
      if (!navigator.canShare({ files: [sample] })) return
      button.hidden = false
      button.dataset.readyLabel = isIOS ? shareLabel(button) : 'Share…'
      button.textContent = button.dataset.readyLabel
      if (terminalReady && isIOS && button.hasAttribute('data-share-primary')) {
        button.disabled = true
        button.textContent = 'Preparing save…'
        prepareShare(button).then(() => {
          button.disabled = false
          button.textContent = button.dataset.readyLabel
        }).catch(() => {
          button.disabled = false
          button.hidden = true
        })
      }
    })

    const group = root.querySelector('[data-share-photos]')
    const photos = buttons.filter((button) => button.dataset.shareKind === 'image')
    if (!group || !terminalReady || !isIOS || photos.length < 2 || photos.length > 4 || photos.length !== buttons.length) return
    const samples = photos.map((button) => new File([], button.dataset.shareName, { type: button.dataset.shareType }))
    if (!navigator.canShare({ files: samples })) return
    group.hidden = false
    group.disabled = true
    group.textContent = 'Preparing photos…'
    preparePhotoShare(photos).then(() => {
      group.disabled = false
      group.textContent = 'Save all photos…'
    }).catch(() => { group.hidden = true })
  }

  const triggerAutomaticDownload = (root) => {
    const app = root.closest('#app') || document.querySelector('#app')
    if (isIOS || pageHidden || !app?.hasAttribute('data-auto-start')) return
    const link = root.querySelector('[data-auto-download]')
    const key = `xvid-auto:${app.dataset.jobId || location.pathname}`
    if (!link) return
    try {
      if (sessionStorage.getItem(key) === '1') return
      sessionStorage.setItem(key, '1')
    } catch {
      if (link.dataset.started === '1') return
      link.dataset.started = '1'
    }
    const anchor = document.createElement('a')
    anchor.href = link.href
    anchor.download = ''
    anchor.hidden = true
    document.body.append(anchor)
    anchor.click()
    anchor.remove()
    const heading = root.querySelector('.ready-heading h2')
    if (heading) heading.textContent = 'Download started'
  }

  const updateExpiry = (root) => {
    const element = root.querySelector('[data-expiry]')
    const expires = Number(element?.dataset.expiresAt)
    if (!element || !Number.isFinite(expires)) return () => {}
    const render = () => {
      const remaining = Math.max(0, expires - Math.floor(Date.now() / 1000))
      element.textContent = remaining > 60
        ? `Temporary files expire in ${Math.ceil(remaining / 60)} min`
        : remaining > 0 ? `Temporary files expire in ${remaining}s` : 'Temporary files are expiring'
    }
    render()
    const timer = setInterval(render, 1000)
    return () => clearInterval(timer)
  }

  const enhanceState = (root) => {
    wireChoice(root)
    revealShares(root)
    triggerAutomaticDownload(root)
    const expiryCleanup = updateExpiry(root)
    return () => {
      expiryCleanup()
      abortPending()
    }
  }

  const replaceJobState = (app, html) => {
    const template = document.createElement('template')
    template.innerHTML = html.trim()
    const next = template.content.querySelector('[data-state-fragment]')
    const holder = app.querySelector('#job-state')
    if (!next || !holder) return false
    const revision = Number(next.dataset.revision || 0)
    const current = Number(app.dataset.revision || 0)
    if (revision <= current) return false
    const focusKey = captureFocus(holder)
    fragmentCleanup()
    holder.replaceChildren(next)
    app.dataset.revision = String(revision)
    const state = next.dataset.state
    app.dataset.pageState = state === 'ready' ? 'ready' : state === 'awaiting_choice' ? 'choose' : state === 'failed' || state === 'cancelled' ? 'problem' : state === 'probing' ? 'checking' : 'working'
    fragmentCleanup = enhanceState(holder)
    restoreFocus(holder, focusKey)
    return true
  }

  const connectJob = (app) => {
    const endpoint = app.dataset.events
    if (!endpoint || typeof EventSource !== 'function') return () => {}
    const connection = app.querySelector('[data-connection-state]')
    let source = null
    let pollTimer = null
    let retryTimer = null
    let errors = 0
    let closed = false

    const setConnection = (text) => {
      if (!connection) return
      connection.textContent = text
      connection.hidden = !text
    }
    const stopPoll = () => {
      if (pollTimer) clearInterval(pollTimer)
      if (retryTimer) clearTimeout(retryTimer)
      pollTimer = null
      retryTimer = null
    }
    const poll = async () => {
      try {
        const { document: next } = await fetchPage(location.href)
        const fragment = next.querySelector('[data-state-fragment]')
        if (fragment) replaceJobState(app, fragment.outerHTML)
        if (!next.querySelector('#app[data-events]')) {
          stopPoll()
          setConnection('')
          triggerAutomaticDownload(app)
        }
      } catch {
        setConnection('Updates interrupted')
      }
    }
    const startPoll = () => {
      if (pollTimer || closed) return
      setConnection('Checking every 5 seconds')
      void poll()
      pollTimer = setInterval(poll, 5000)
      retryTimer = setTimeout(() => {
        retryTimer = null
        if (!closed) {
          errors = 0
          open()
        }
      }, 20000)
    }
    const open = () => {
      if (closed) return
      source?.close()
      source = new EventSource(endpoint)
      source.addEventListener('open', () => {
        errors = 0
        setConnection('')
        stopPoll()
        document.querySelector('meta[http-equiv="refresh"]')?.remove()
      })
      source.addEventListener('job', (event) => replaceJobState(app, event.data))
      source.addEventListener('done', () => {
        source?.close()
        stopPoll()
        setConnection('')
        triggerAutomaticDownload(app)
      })
      source.addEventListener('deleted', () => {
        source?.close()
        stopPoll()
        void loadCurrent('/', 'replace')
      })
      source.addEventListener('error', () => {
        errors += 1
        setConnection('Reconnecting…')
        if (errors >= 3) {
          source?.close()
          startPoll()
        }
      })
    }

    open()
    return () => {
      closed = true
      source?.close()
      stopPoll()
    }
  }

  const loadCurrent = async (url, historyMode = 'push') => {
    const { response, document: next } = await fetchPage(url)
    replaceApp(next, response.url, historyMode)
  }

  const boot = (root = document.querySelector('#app')) => {
    if (!root) return
    pageCleanup()
    fragmentCleanup = () => {}
    updateComposer(root)
    const jobState = root.querySelector('#job-state')
    if (jobState) fragmentCleanup = enhanceState(jobState)
    const streamCleanup = connectJob(root)
    pageCleanup = () => {
      fragmentCleanup()
      streamCleanup()
      clearPrepared()
    }
    if (root.hasAttribute('data-auto-start')) {
      history.replaceState(null, '', location.pathname)
      if (!root.dataset.events) triggerAutomaticDownload(root)
    }
  }

  document.addEventListener('submit', (event) => {
    const form = event.target.closest('form[data-nav-form]')
    if (!form) return
    if (form.dataset.nativeSubmit === '1') {
      delete form.dataset.nativeSubmit
      return
    }
    const input = form.querySelector('#url')
    if (input) {
      const candidate = xStatusUrl(input.value)
      if (!candidate) {
        event.preventDefault()
        const error = form.querySelector('[data-link-error]')
        if (error) {
          error.textContent = 'Use a public X or Twitter status link.'
          error.hidden = false
        }
        input.setCustomValidity('Use a public X or Twitter status link.')
        input.reportValidity()
        input.focus()
        return
      }
      input.value = candidate
    }
    event.preventDefault()
    void navigateForm(form, event.submitter)
  })

  document.addEventListener('click', async (event) => {
    const link = event.target.closest('a[data-nav-link]')
    if (link && event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
      const url = new URL(link.href)
      if (url.origin === location.origin) {
        event.preventDefault()
        void navigateLink(link)
        return
      }
    }

    const group = event.target.closest('[data-share-photos]')
    if (group && !group.disabled) {
      const buttons = [...group.parentElement.querySelectorAll('[data-share-file][data-share-kind="image"]')]
      const key = photoKey(buttons)
      group.disabled = true
      try {
        const files = await preparePhotoShare(buttons)
        if (navigator.userActivation && !navigator.userActivation.isActive) {
          group.textContent = 'Tap to open save options'
          return
        }
        await navigator.share({ files, title: 'X photos' })
        recordShare(buttons)
        group.textContent = 'Opened'
      } catch (error) {
        group.textContent = error?.name === 'AbortError' ? 'Save all photos…' : preparedPhotoFiles.has(key) ? 'Tap to open save options' : 'Save all photos…'
      } finally {
        group.disabled = false
        if (group.textContent === 'Opened') setTimeout(() => { group.textContent = 'Save all photos…' }, 1200)
      }
      return
    }

    const button = event.target.closest('[data-share-file]')
    if (!button || button.disabled) return
    const key = shareKey(button)
    const label = button.dataset.readyLabel || shareLabel(button)
    button.disabled = true
    try {
      const file = await prepareShare(button)
      if (navigator.userActivation && !navigator.userActivation.isActive) {
        button.textContent = 'Tap to open save options'
        return
      }
      await navigator.share({ files: [file], title: button.dataset.shareName })
      recordShare([button])
      button.textContent = 'Opened'
    } catch (error) {
      button.textContent = error?.name === 'AbortError' ? label : preparedFiles.has(key) ? 'Tap to open save options' : label
    } finally {
      button.disabled = false
      if (button.textContent === 'Opened') setTimeout(() => { button.textContent = label }, 1200)
    }
  })

  addEventListener('popstate', () => {
    void loadCurrent(location.href, 'none').catch(() => location.reload())
  })
  addEventListener('pageshow', (event) => {
    pageHidden = false
    if (event.persisted) boot(document.querySelector('#app'))
  })
  addEventListener('pagehide', () => {
    pageHidden = true
    pageCleanup()
    clearPrepared()
  })

  boot()
})()

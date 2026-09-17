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
  let navigationVersion = 0
  let readingClipboard = false
  let lastSubmission = null

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

  const supportedPostUrl = (value) => {
    const candidate = firstUrl(value)
    if (!candidate) return null
    try {
      const url = new URL(candidate)
      const isX = xHosts.has(url.hostname.toLowerCase()) && /\/status\/\d{1,24}(?:\/(?:video|photo)\/\d+)?\/?$/.test(url.pathname)
      const isInstagram = ['instagram.com', 'www.instagram.com', 'm.instagram.com'].includes(url.hostname.toLowerCase()) && /^\/(?:p|reel|reels|tv|share)\/[A-Za-z0-9_-]{1,64}\/?$/.test(url.pathname)
      return (isX || isInstagram) && !url.username && !url.password
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

  const saveDraft = (value, path = location.pathname) => {
    try { sessionStorage.setItem(`xvid-draft:${path}`, value) } catch {}
  }

  const navigateForm = async (form, submitter) => {
    if (navigating || readingClipboard) return
    const body = new URLSearchParams()
    formDataWithSubmitter(form, submitter).forEach((value, key) => body.append(key, String(value)))
    const key = `${form.action}?${body}`
    const started = performance.now()
    // The next page may arrive between the two taps of a double tap.
    if (lastSubmission?.key === key && started - lastSubmission.at < 500) return
    lastSubmission = { key, at: started }
    navigating = true
    const version = ++navigationVersion
    // Stop old job events before starting another action, including in-flight polls.
    pageCleanup()
    const app = form.closest('#app')
    app.setAttribute('aria-busy', 'true')
    const controls = [...form.querySelectorAll('button')].filter((button) => !button.disabled)
    controls.forEach((button) => { button.disabled = true })
    form.querySelector('[data-navigation-status]')?.remove()
    const status = document.createElement('p')
    status.dataset.navigationStatus = '1'
    status.className = 'privacy-note'
    status.setAttribute('role', 'status')
    status.textContent = form.matches('[data-link-form]') ? 'Checking link…' : 'Updating…'
    form.append(status)
    try {
      const { response, document: next } = await fetchPage(form.action, {
        method: (form.method || 'GET').toUpperCase(),
        body,
        headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' }
      })
      if (version !== navigationVersion) return
      const targetUrl = new URL(response.url)
      const draft = document.querySelector('#url')?.value || ''
      saveDraft(draft, targetUrl.pathname)
      const nextInput = next.querySelector('#url')
      if (nextInput) nextInput.value = draft
      if (form.matches('[data-link-form]')) document.activeElement?.blur()
      replaceApp(next, response.url, location.pathname === targetUrl.pathname ? 'replace' : 'push')
      if (form.matches('[data-link-form]')) window.scrollTo(0, 0)
    } catch {
      if (version !== navigationVersion) return
      lastSubmission = null
      // A lost response may already have created a job. Never replay a POST automatically.
      status.className = 'field-error'
      status.textContent = 'Could not confirm the request. Check your connection before trying again.'
      const streamCleanup = connectJob(app)
      pageCleanup = () => {
        fragmentCleanup()
        streamCleanup()
        clearPrepared()
      }
    } finally {
      if (version === navigationVersion) {
        navigating = false
        app.removeAttribute('aria-busy')
        controls.forEach((button) => { button.disabled = false })
      }
    }
  }

  const navigateLink = async (link) => {
    if (navigating || readingClipboard) return
    try {
      await loadCurrent(link.href)
    } catch {
      location.assign(link.href)
    }
  }

  const refreshDownload = (root) => {
    const input = root.querySelector('#url')
    const button = root.querySelector('[data-download]')
    if (!input || !button) return
    button.hidden = !supportedPostUrl(input.value)
    button.textContent = root.dataset.pageState === 'ready' && input.value === input.defaultValue
      ? 'Download again' : 'Download'
  }

  const updateComposer = (root) => {
    const form = root.querySelector('[data-link-form]')
    const input = form?.querySelector('#url')
    const paste = form?.querySelector('[data-paste]')
    const download = form?.querySelector('[data-download]')
    const clear = form?.querySelector('[data-clear-input]')
    const error = form?.querySelector('[data-link-error]')
    if (!form || !input || !paste) return

    const resolution = form.querySelector('[data-resolution]')
    try {
      const saved = sessionStorage.getItem('xvid-resolution')
      if (saved !== null) resolution.checked = saved === '1'
      const draft = sessionStorage.getItem(`xvid-draft:${location.pathname}`)
      if (draft !== null) input.value = draft
    } catch {}
    resolution.addEventListener('change', () => {
      try { sessionStorage.setItem('xvid-resolution', resolution.checked ? '1' : '0') } catch {}
    })

    const refresh = () => {
      refreshDownload(root)
      if (clear) clear.hidden = !input.value
      input.setCustomValidity('')
      if (error) error.hidden = true
      saveDraft(input.value)
    }
    input.addEventListener('input', refresh)
    input.addEventListener('paste', (event) => {
      const candidate = supportedPostUrl(event.clipboardData?.getData('text') || '')
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
    paste.hidden = false
    paste.addEventListener('click', async () => {
      if (navigating || readingClipboard) return
      readingClipboard = true
      paste.disabled = true
      download.disabled = true
      const version = navigationVersion
      try {
        if (!navigator.clipboard?.readText) throw new Error('Clipboard access is unavailable. Paste a link into the field.')
        let text
        try { text = await navigator.clipboard.readText() } catch {
          throw new Error('Clipboard access was blocked. Allow access or paste a link into the field.')
        }
        if (!root.isConnected || version !== navigationVersion) return
        const candidate = supportedPostUrl(text)
        if (!candidate) throw new Error('The clipboard does not contain a public X or Instagram post link.')
        input.value = candidate
        refresh()
        readingClipboard = false
        download.disabled = false
        form.requestSubmit(download)
      } catch (failure) {
        if (!root.isConnected || version !== navigationVersion) return
        error.textContent = failure.message
        error.hidden = false
        input.focus()
      } finally {
        readingClipboard = false
        if (!navigating) {
          paste.disabled = false
          download.disabled = false
        }
      }
    })
    refresh()
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
      const subject = 'Temporary files'
      element.textContent = remaining > 60
        ? `${subject} expire in ${Math.ceil(remaining / 60)} min`
        : remaining > 0 ? `${subject} expire in ${remaining}s` : `${subject} are expiring`
    }
    render()
    const timer = setInterval(render, 1000)
    return () => clearInterval(timer)
  }

  // Original X files go straight to the reviewed CDN. Keep bytes out of the server.
  const enhanceDirect = (root) => {
    const section = root.querySelector('[data-direct-delivery]')
    if (!section) return null
    const rows = [...section.querySelectorAll('[data-direct-file]')]
    const running = new Map()
    const files = new Map()
    const objectUrls = new Map()
    let closed = false
    const expiryCleanup = updateExpiry(root)
    const allowed = (raw, kind) => {
      const url = new URL(raw)
      const fixture = location.hostname === '127.0.0.1' && url.hostname === '127.0.0.1' && url.protocol === 'http:'
      if (!fixture && (url.protocol !== 'https:' || url.port && url.port !== '443' || url.hostname !== (kind === 'video' ? 'video.twimg.com' : 'pbs.twimg.com'))) throw new Error('The media address was rejected.')
      if (url.username || url.password || url.hash) throw new Error('The media address was rejected.')
      return url.href
    }
    const report = (row, text) => { const e = row.querySelector('[data-direct-error]'); e.textContent = text; e.hidden = !text }
    const progress = (row, loaded, total) => {
      const panel = row.querySelector('[data-direct-progress]'); panel.hidden = false
      const bar = panel.querySelector('progress')
      if (total > 0) { bar.max = total; bar.value = loaded } else { bar.removeAttribute('value'); bar.removeAttribute('max') }
      panel.querySelector('[data-direct-percent]').textContent = total > 0 ? `${Math.floor(loaded / total * 100)}%` : `${(loaded / 1048576).toFixed(1)} MB`
    }
    const refresh = async (row, signal) => {
      const response = await fetch(`${location.pathname}/refresh`, { method: 'POST', body: new URLSearchParams({ item_id: row.dataset.itemId }), credentials: 'same-origin', signal })
      if (!response.ok) throw new Error('The original could not be refreshed. Download the post again.')
      row.dataset.url = allowed((await response.json()).url, row.dataset.kind)
      row.querySelector('[data-direct-download]').href = row.dataset.url
    }
    const receive = async (row, controller, writable, budget = maxShareBytes) => {
      let response
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          response = await fetch(allowed(row.dataset.url, row.dataset.kind), { credentials: 'omit', referrerPolicy: 'no-referrer', signal: controller.signal })
          if (attempt === 0 && [403, 404, 410].includes(response.status)) { await response.body?.cancel(); await refresh(row, controller.signal); continue }
          break
        } catch (error) {
          if (attempt || controller.signal.aborted || !(error instanceof TypeError)) throw error
          await refresh(row, controller.signal)
        }
      }
      if (!response?.ok || response.status !== 200 || !response.body) throw new Error('The original could not be downloaded. Try again.')
      allowed(response.url, row.dataset.kind)
      const total = Number(response.headers.get('content-length')) || 0
      const limit = writable ? 4 * 1024 ** 3 : budget
      if (total > limit) { await response.body.cancel(); throw Object.assign(new Error(writable ? 'This original is too large.' : 'Use Download to save this large original.'), { code: 'too-large' }) }
      const reader = response.body.getReader()
      const chunks = []
      let loaded = 0
      let signature = new Uint8Array()
      let checked = false
      let mime = ''
      const check = () => {
        const text = new TextDecoder('ascii').decode(signature)
        if (row.dataset.kind === 'video' && text.slice(4, 8) === 'ftyp') mime = 'video/mp4'
        if (row.dataset.kind === 'image') {
          if (signature[0] === 255 && signature[1] === 216 && signature[2] === 255) mime = 'image/jpeg'
          else if (signature[0] === 137 && text.slice(1, 4) === 'PNG') mime = 'image/png'
          else if (text.startsWith('RIFF') && text.slice(8, 12) === 'WEBP') mime = 'image/webp'
        }
        if (!mime) throw new Error('The response was not the requested media file.')
        checked = true
      }
      let lastUpdate = 0
      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break
          controller.signal.throwIfAborted()
          loaded += value.byteLength
          if (loaded > limit) throw Object.assign(new Error('Use Download to save this large original.'), { code: 'too-large' })
          if (!checked) {
            const head = new Uint8Array(Math.min(32, signature.length + value.length))
            head.set(signature); head.set(value.subarray(0, head.length - signature.length), signature.length); signature = head
            if (signature.length >= 12) check()
          }
          if (writable) await writable.write(value)
          else chunks.push(value)
          if (performance.now() - lastUpdate > 100) { progress(row, loaded, total); lastUpdate = performance.now() }
        }
        if (!checked) check()
        if (!loaded || total && loaded !== total) throw new Error('The download was incomplete. Try again.')
        controller.signal.throwIfAborted()
        if (writable) { await writable.close(); return null }
        const extension = mime === 'image/png' ? 'png' : mime === 'image/webp' ? 'webp' : mime === 'video/mp4' ? 'mp4' : 'jpg'
        return new File(chunks, row.dataset.filename.replace(/\.[^.]+$/, `.${extension}`), { type: mime })
      } catch (error) { await reader.cancel().catch(() => {}); throw error }
    }
    const fileUrl = (file) => {
      if (!objectUrls.has(file)) objectUrls.set(file, URL.createObjectURL(file))
      return objectUrls.get(file)
    }
    const downloadBlob = (file) => {
      const url = fileUrl(file)
      const link = document.createElement('a'); link.href = url; link.download = file.name; link.hidden = true
      document.body.append(link); link.click(); link.remove()
    }
    const describe = (row, file) => {
      row.querySelector('.artifact-copy strong').textContent = file.name
      const size = file.size >= 1048576 ? `${(file.size / 1048576).toFixed(1)} MB` : file.size >= 1024 ? `${(file.size / 1024).toFixed(1)} KB` : `${file.size} B`
      row.querySelector('[data-direct-details]').textContent = `${row.dataset.kind === 'video' ? 'video' : 'photo'} · ${size}`
      const share = row.querySelector('[data-direct-share]')
      share.hidden = !(navigator.share && navigator.canShare && navigator.canShare({ files: [file] }))
      share.textContent = isIOS ? (row.dataset.kind === 'video' ? 'Save video…' : 'Save photo…') : 'Share…'
    }
    const run = async (row, action) => {
      if (closed || running.has(row)) return
      report(row, '')
      const button = row.querySelector('[data-direct-download]')
      const share = row.querySelector('[data-direct-share]')
      const cancel = row.querySelector('[data-direct-cancel]')
      const controller = new AbortController(); running.set(row, controller); pendingControllers.add(controller)
      button.disabled = true; share.disabled = true; cancel.hidden = false
      let writable
      try {
        // Obtain the file handle during the user's click; the network must not consume activation first.
        if (action === 'download' && !isIOS && typeof window.showSaveFilePicker === 'function' && row.dataset.kind === 'video' && row.dataset.nativeDownload === '1' && !files.has(row)) {
          const handle = await window.showSaveFilePicker({ suggestedName: row.dataset.filename })
          controller.signal.throwIfAborted()
          writable = await handle.createWritable()
        }
        const file = files.get(row) || await receive(row, controller, writable)
        controller.signal.throwIfAborted()
        if (closed || !row.isConnected) return
        if (file) {
          if (!files.has(row)) {
            let retained = [...files.values()].reduce((sum, value) => sum + value.size, file.size)
            for (const [oldRow, oldFile] of files) {
              if (retained <= maxShareBytes) break
              URL.revokeObjectURL(objectUrls.get(oldFile)); objectUrls.delete(oldFile); files.delete(oldRow); retained -= oldFile.size
            }
            files.set(row, file)
          }
          describe(row, file)
          if (rows.length === 1) {
            const preview = section.querySelector('[data-direct-preview]')
            if (preview && !preview.getAttribute('src')) { preview.src = fileUrl(file); preview.hidden = false }
          }
          const canShare = !share.hidden
          if (action === 'share' && canShare) {
            if (navigator.userActivation && !navigator.userActivation.isActive) { share.textContent = 'Tap to open save options'; return }
            await navigator.share({ files: [file], title: file.name })
          } else if (action === 'download' || action === 'auto' && !isIOS) { downloadBlob(file); section.querySelector('h2').textContent = 'Download started' }
          button.textContent = 'Download'
        } else { section.querySelector('h2').textContent = 'Download started'; writable = null }
      } catch (error) {
        if (writable) await writable.abort().catch(() => {})
        if (error.code === 'too-large' && !writable) {
          row.dataset.nativeDownload = '1'; button.target = '_blank'
          const preview = section.querySelector('[data-direct-preview]')
          if (preview && rows.length === 1) { preview.crossOrigin = 'anonymous'; preview.src = allowed(row.dataset.url, row.dataset.kind); preview.hidden = false }
        }
        if (!closed && row.isConnected) report(row, error.name === 'AbortError' ? 'Cancelled' : error.message || 'The download was interrupted. Try again.')
      } finally {
        controller.abort(); running.delete(row); pendingControllers.delete(controller)
        button.disabled = false; share.disabled = false; cancel.hidden = true; row.querySelector('[data-direct-progress]').hidden = true
      }
    }
    rows.forEach((row) => {
      const button = row.querySelector('[data-direct-download]'); button.hidden = false
      button.onclick = event => {
        if (row.dataset.nativeDownload === '1' && (isIOS || typeof window.showSaveFilePicker !== 'function')) return
        event.preventDefault(); void run(row, 'download')
      }
      const share = row.querySelector('[data-direct-share]')
      if (isIOS && navigator.share && navigator.canShare) { share.hidden = false; share.textContent = row.dataset.kind === 'video' ? 'Save video…' : 'Save photo…' }
      share.onclick = () => void run(row, 'share')
      row.querySelector('[data-direct-cancel]').onclick = () => running.get(row)?.abort()
    })
    // Store originals without compression, matching the previous Download all ZIP.
    const makeZip = async (entries) => {
      const table = Uint32Array.from({ length: 256 }, (_, n) => {
        for (let bit = 0; bit < 8; bit++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1
        return n >>> 0
      })
      const parts = [], directory = []
      let offset = 0, directorySize = 0
      for (const file of entries) {
        const bytes = new Uint8Array(await file.arrayBuffer())
        const name = new TextEncoder().encode(file.name)
        let crc = 0xffffffff
        for (const byte of bytes) crc = table[(crc ^ byte) & 255] ^ (crc >>> 8)
        crc = (crc ^ 0xffffffff) >>> 0
        const local = new Uint8Array(30 + name.length), central = new Uint8Array(46 + name.length)
        const l = new DataView(local.buffer), c = new DataView(central.buffer)
        l.setUint32(0, 0x04034b50, true); l.setUint16(4, 20, true); l.setUint16(6, 0x800, true); l.setUint16(12, 33, true)
        l.setUint32(14, crc, true); l.setUint32(18, bytes.length, true); l.setUint32(22, bytes.length, true); l.setUint16(26, name.length, true); local.set(name, 30)
        c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true); c.setUint16(8, 0x800, true); c.setUint16(14, 33, true)
        c.setUint32(16, crc, true); c.setUint32(20, bytes.length, true); c.setUint32(24, bytes.length, true); c.setUint16(28, name.length, true); c.setUint32(42, offset, true); central.set(name, 46)
        parts.push(local, bytes); directory.push(central); offset += local.length + bytes.length; directorySize += central.length
      }
      const end = new Uint8Array(22), e = new DataView(end.buffer)
      e.setUint32(0, 0x06054b50, true); e.setUint16(8, entries.length, true); e.setUint16(10, entries.length, true); e.setUint32(12, directorySize, true); e.setUint32(16, offset, true)
      return new File([...parts, ...directory, end], section.dataset.bundleName, { type: 'application/zip' })
    }
    const prepareGroup = async () => {
      if (running.size) return null
      const controller = new AbortController(); pendingControllers.add(controller)
      rows.forEach(row => running.set(row, controller))
      const prepared = []
      let remaining = maxShareBytes
      try {
        for (const row of rows) {
          row.querySelector('[data-direct-cancel]').hidden = false
          const file = files.get(row) || await receive(row, controller, null, remaining)
          remaining -= file.size
          if (remaining < 0) throw new Error('These files are too large to save together. Download them individually.')
          prepared.push(file); describe(row, file)
        }
        if (closed) return null
        rows.forEach((row, index) => files.set(row, prepared[index]))
        return prepared
      } catch (error) {
        if (!closed) report(rows[0], error.name === 'AbortError' ? 'Cancelled' : error.message)
        return null
      } finally {
        controller.abort(); pendingControllers.delete(controller)
        rows.forEach(row => { running.delete(row); row.querySelector('[data-direct-cancel]').hidden = true; row.querySelector('[data-direct-progress]').hidden = true })
      }
    }
    const bundle = section.querySelector('[data-direct-bundle]')
    let archive = null
    const downloadGroup = async () => {
      if (closed || !bundle || bundle.disabled) return
      bundle.disabled = true
      try {
        if (!archive) { const prepared = await prepareGroup(); if (prepared && !closed) archive = await makeZip(prepared) }
        if (archive && !closed) { downloadBlob(archive); section.querySelector('h2').textContent = 'Download started' }
      } catch { if (!closed) report(rows[0], 'Could not prepare the ZIP. Try again.') }
      finally { bundle.disabled = false }
    }
    if (bundle) { bundle.hidden = false; bundle.onclick = () => void downloadGroup() }
    if (isIOS && rows.length > 1 && rows.every(row => row.dataset.kind === 'image') && navigator.share && navigator.canShare) {
      const group = document.createElement('button')
      group.type = 'button'; group.className = 'primary-action photo-share-action'; group.textContent = 'Preparing photos…'; group.disabled = true
      section.querySelector('.ready-heading').after(group)
      const preparePhotos = async () => {
        group.disabled = true
        const prepared = await prepareGroup()
        group.disabled = false
        group.hidden = !prepared || !navigator.canShare({ files: prepared })
        group.textContent = 'Save all photos…'
      }
      group.onclick = async () => {
        try { await navigator.share({ files: rows.map(row => files.get(row)) }) }
        catch (error) { if (error.name !== 'AbortError') report(rows[0], 'Could not open save options. Try again.') }
      }
      void preparePhotos()
    }
    const app = section.closest('#app')
    let automatic = false
    if (app?.hasAttribute('data-auto-start') && !pageHidden) {
      const key = `xvid-auto:${app.dataset.jobId || location.pathname}`
      let started = false
      try { started = sessionStorage.getItem(key) === '1'; sessionStorage.setItem(key, '1') } catch {}
      automatic = !started
    }
    if (rows.length === 1 && !pageHidden) void run(rows[0], automatic ? 'auto' : 'prepare')
    else if (automatic && !isIOS) void downloadGroup()
    return () => { closed = true; expiryCleanup(); running.forEach(c => c.abort()); files.clear(); objectUrls.forEach(url => URL.revokeObjectURL(url)) }
  }

  const enhanceState = (root) => {
    const directCleanup = enhanceDirect(root)
    if (directCleanup) return directCleanup
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
    if (!next || !holder || !app.isConnected) return false
    const revision = Number(next.dataset.revision || 0)
    const current = Number(app.dataset.revision || 0)
    if (revision <= current) return false
    const focusKey = captureFocus(holder)
    fragmentCleanup()
    holder.replaceChildren(next)
    app.dataset.revision = String(revision)
    const state = next.dataset.state
    app.dataset.pageState = state === 'ready' ? 'ready' : state === 'awaiting_choice' ? 'choose' : state === 'failed' || state === 'cancelled' ? 'problem' : state === 'probing' ? 'checking' : 'working'
    refreshDownload(app)
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
        if (closed) return
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
        if (closed) return
        errors = 0
        setConnection('')
        stopPoll()
        document.querySelector('meta[http-equiv="refresh"]')?.remove()
      })
      source.addEventListener('job', (event) => { if (!closed) replaceJobState(app, event.data) })
      source.addEventListener('done', () => {
        if (closed) return
        source?.close()
        stopPoll()
        setConnection('')
        triggerAutomaticDownload(app)
      })
      source.addEventListener('deleted', () => {
        if (closed) return
        source?.close()
        stopPoll()
        void loadCurrent('/', 'replace')
      })
      source.addEventListener('error', () => {
        if (closed) return
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
    const version = ++navigationVersion
    navigating = true
    pageCleanup()
    try {
      const { response, document: next } = await fetchPage(url)
      if (version === navigationVersion) replaceApp(next, response.url, historyMode)
    } catch (error) {
      if (version === navigationVersion) throw error
    } finally {
      if (version === navigationVersion) navigating = false
    }
  }

  const boot = (root = document.querySelector('#app')) => {
    if (!root) return
    document.querySelector('meta[http-equiv="refresh"]')?.remove()
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
    event.preventDefault()
    if (navigating || readingClipboard) return
    const input = form.querySelector('#url')
    if (input) {
      const candidate = supportedPostUrl(input.value)
      if (!candidate) {
        event.preventDefault()
        const error = form.querySelector('[data-link-error]')
        if (error) {
          error.textContent = 'Use a public X status link or Instagram post/Reel.'
          error.hidden = false
        }
        input.setCustomValidity('Use a public X status link or Instagram post/Reel.')
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
    navigationVersion += 1
    navigating = false
    pageCleanup()
    clearPrepared()
  })

  boot()
})()

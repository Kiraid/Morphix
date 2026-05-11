
 const CONFIG = {
    API_BASE:        window.MORPHIX_API_BASE = "{{API_BASE_URL}}",
    IOT_ENDPOINT:    window.MORPHIX_IOT_ENDPOINT = "{{IOT_ENDPOINT_URL}}",
    IOT_AUTH_URL:    window.MORPHIX_IOT_AUTH_URL = "{{IOT_AUTH_URL}}",
    MAX_FILES:       10,
    MAX_SIZE_MB:     25,
  };
  /* ALLOWED FORMATS */
  const ALLOWED_INPUT  = ["jpg","jpeg","png","webp","gif","bmp","tiff","tif","avif","heic","heif"];
  const OUTPUT_FORMATS = ["JPEG","PNG","WEBP","AVIF","BMP","TIFF","GIF"];
  const MIME_MAP = {
    "image/jpeg":true,"image/png":true,"image/webp":true,"image/gif":true,
    "image/bmp":true,"image/tiff":true,"image/avif":true,"image/heic":true,"image/heif":true
  };

  /* STATE */
  let files     = [];
  let targetFmt = null;
  let requestId = null;
  let mqttClient = null;

  /* DOM REFS */
  const $ = id => document.getElementById(id);
  const dropZone      = $("dropZone");
  const fileInput     = $("fileInput");
  const fileList      = $("fileList");
  const convertBtn    = $("convertBtn");
  const progressPanel = $("progressPanel");
  const resultPanel   = $("resultPanel");
  const errorPanel    = $("errorPanel");
  const formatGrid    = $("formatGrid");
  const acceptedPills = $("acceptedPills");
  const progressBar   = $("progressBar");
  const progressMsg   = $("progressMsg");

  /* INIT */
  function init() {
    buildFormatGrid();
    buildAcceptedPills();
    bindEvents();
  }

  function buildFormatGrid() {
    OUTPUT_FORMATS.forEach(fmt => {
      const btn = document.createElement("button");
      btn.className = "fmt-btn";
      btn.textContent = fmt;
      btn.dataset.fmt = fmt;
      btn.addEventListener("click", () => selectFormat(fmt, btn));
      formatGrid.appendChild(btn);
    });
  }

  function buildAcceptedPills() {
    ALLOWED_INPUT.forEach(ext => {
      const pill = document.createElement("span");
      pill.className = "fn-pill";
      pill.textContent = ext.toUpperCase();
      acceptedPills.appendChild(pill);
    });
  }

  function bindEvents() {
    $("browseBtn").addEventListener("click", () => fileInput.click());
    fileInput.addEventListener("change", e => addFiles([...e.target.files]));

    dropZone.addEventListener("click", e => {
      if (e.target === dropZone || e.target.classList.contains("drop-primary")) fileInput.click();
    });
    dropZone.addEventListener("dragover",  e => { e.preventDefault(); dropZone.classList.add("drag-over"); });
    dropZone.addEventListener("dragleave", () => dropZone.classList.remove("drag-over"));
    dropZone.addEventListener("drop", e => {
      e.preventDefault();
      dropZone.classList.remove("drag-over");
      addFiles([...e.dataTransfer.files]);
    });

    document.addEventListener("paste", e => {
      const items = [...(e.clipboardData?.items || [])];
      const imageFiles = items
        .filter(i => i.kind === "file" && MIME_MAP[i.type])
        .map(i => i.getAsFile());
      if (imageFiles.length) addFiles(imageFiles);
    });

    convertBtn.addEventListener("click", startConversion);
    $("resetBtn").addEventListener("click", reset);
    $("errorResetBtn").addEventListener("click", reset);
  }

  /* FORMAT SELECT */
  function selectFormat(fmt, btn) {
    document.querySelectorAll(".fmt-btn").forEach(b => b.classList.remove("selected"));
    btn.classList.add("selected");
    targetFmt = fmt;
    updateConvertButton();
  }

  /* FILE HANDLING */
  function addFiles(newFiles) {
    const errors = [];

    for (const f of newFiles) {
      if (files.length >= CONFIG.MAX_FILES) {
        errors.push(`Max ${CONFIG.MAX_FILES} files allowed.`);
        break;
      }
      const ext = f.name.split(".").pop().toLowerCase();
      if (!ALLOWED_INPUT.includes(ext)) {
        errors.push(`"${f.name}" is not a supported image format.`);
        continue;
      }
      if (f.size > CONFIG.MAX_SIZE_MB * 1024 * 1024) {
        errors.push(`"${f.name}" exceeds ${CONFIG.MAX_SIZE_MB} MB limit.`);
        continue;
      }
      if (files.find(x => x.name === f.name && x.size === f.size)) continue; // dedupe
      files.push(f);
    }

    if (errors.length) showToast(errors[0], "warn");
    renderFileList();
    updateConvertButton();
  }

  function renderFileList() {
    if (!files.length) { fileList.hidden = true; return; }
    fileList.hidden = false;
    fileList.innerHTML = "";
    files.forEach((f, i) => {
      const row = document.createElement("div");
      row.className = "file-item";
      row.id = `file-row-${i}`;
      row.innerHTML = `
        <span class="file-icon">${extIcon(f.name)}</span>
        <span class="file-name" title="${f.name}">${f.name}</span>
        <span class="file-size">${fmtBytes(f.size)}</span>
        <span class="file-status" id="fstatus-${i}"></span>
        <button class="file-remove" data-idx="${i}" title="Remove">✕</button>`;
      fileList.appendChild(row);
    });
    fileList.querySelectorAll(".file-remove").forEach(btn => {
      btn.addEventListener("click", () => {
        files.splice(+btn.dataset.idx, 1);
        renderFileList();
        updateConvertButton();
      });
    });
  }

  function extIcon(name) {
    const ext = name.split(".").pop().toLowerCase();
    const icons = {
      jpg:"🖼️", jpeg:"🖼️", png:"🖼️", webp:"🌐", gif:"🎞️",
      bmp:"🖼️", tiff:"📸", tif:"📸", avif:"🖼️", heic:"📷", heif:"📷"
    };
    return icons[ext] || "🗂️";
  }

  function fmtBytes(b) {
    if (b < 1024)      return b + " B";
    if (b < 1024**2)   return (b / 1024).toFixed(1) + " KB";
    return (b / 1024**2).toFixed(1) + " MB";
  }

  function updateConvertButton() {
    const summary = $("convertSummary");
    if (files.length && targetFmt) {
      convertBtn.disabled = false;
      summary.innerHTML = `Converting <strong>${files.length} file${files.length > 1 ? "s" : ""}</strong> → <strong>${targetFmt}</strong>`;
    } else if (!files.length) {
      convertBtn.disabled = true;
      summary.innerHTML = targetFmt
        ? `Add images to convert to <strong>${targetFmt}</strong>`
        : "Select a format and add images";
    } else {
      convertBtn.disabled = true;
      summary.innerHTML = `<strong>${files.length} file${files.length > 1 ? "s" : ""}</strong> ready — pick a format above`;
    }
  }

  /* CONVERSION FLOW */
  async function startConversion() {
    showProgress();
    setProgress(5, "Requesting upload URLs…");
    setProgStep("prog-upload", "active");

    try {
      // 1. Get presigned URLs + request ID
      const presignRes = await apiFetch("/presign", "POST", {
        files: files.map(f => ({ name: f.name, size: f.size, type: f.type })),
        target_format: targetFmt,
      });

      requestId = presignRes.request_id;
      const urls = presignRes.upload_urls; // [{filename, url}]

      // 2. Subscribe to IoT MQTT FIRST and wait for SUBACK before uploading.
      //    This guarantees we won't miss the DONE message even if the processor
      //    finishes before the WebSocket handshake completes (which happens when
      //    the processor Lambda is very fast, e.g. ~380ms).
      setProgress(10, "Connecting to notification service…");
      await subscribeIoT(requestId);

      // 3. Only start uploading once we are confirmed-subscribed
      setProgress(20, `Uploading ${files.length} file(s) directly to S3…`);
      const uploadTasks = files.map((f, i) => uploadFile(f, urls[i], i));
      await Promise.all(uploadTasks);

      setProgStep("prog-upload", "done");
      setProgStep("prog-process", "active");
      setProgress(60, "Lambda is converting your images…");

      // Fallback: if no MQTT message after 120s, show error
      setTimeout(() => {
        if (resultPanel.hidden && errorPanel.hidden) {
          showError("Conversion timed out. Please try again.");
        }
      }, 120_000);

    } catch (err) {
      showError(err.message || "Something went wrong. Please try again.");
    }
  }

  async function uploadFile(file, urlObj, idx) {
    const statusEl = $(`fstatus-${idx}`);
    if (statusEl) { statusEl.textContent = "↑"; statusEl.className = "file-status uploading"; }

    const res = await fetch(urlObj.url, {
      method: "PUT",
      body: file,
      headers: { "Content-Type": file.type || "application/octet-stream" },
    });

    if (!res.ok) throw new Error(`Upload failed for ${file.name}: ${res.status}`);
    if (statusEl) { statusEl.textContent = "✓"; statusEl.className = "file-status done"; }
  }

  /* IoT CORE MQTT */
  async function subscribeIoT(jobId) {
    let wssUrl;
    let clientId;

    if (CONFIG.IOT_AUTH_URL) {
      const r = await apiFetch(`/iot-auth?job_id=${jobId}`, "GET");
      wssUrl = r.wss_url;
      clientId = r.client_id; 
    } else {
      throw new Error("Notification service is not configured.");
    }

    return new Promise((resolve, reject) => {
      const ws = new WebSocket(wssUrl, ["mqtt"]);
      ws.binaryType = "arraybuffer";
      mqttClient = ws;
      let connacked = false;
      let subscribed = false;

      ws.addEventListener("open", () => {
        ws.send(buildMqttConnect(clientId));
      });

      ws.addEventListener("message", async e => {
        let data = e.data;
        // Browsers deliver binary WS frames as Blob for larger payloads
        // (the DONE message includes a long presigned URL), so always normalise.
        if (data instanceof Blob) data = await data.arrayBuffer();
        const buf = new Uint8Array(data instanceof ArrayBuffer ? data : data);

        // CONNACK packet type = 0x20 — broker accepted our connection.
        // Only SUBSCRIBE after this to avoid broker/client race conditions.
        if (!connacked && buf[0] === 0x20) {
          connacked = true;
          ws.send(buildMqttSubscribe(`morphix/jobs/${jobId}`));
          return;
        }

        // SUBACK packet type = 0x90 — broker confirmed our subscription.
        // Resolve the promise now so uploads can begin safely.
        if (!subscribed && buf[0] === 0x90) {
          subscribed = true;
          resolve();
          return;
        }

        // All subsequent messages are PUBLISH frames carrying job status.
        const msg = parseMqttPublish(data);
        if (msg) onMqttMessage(msg);
      });

      ws.addEventListener("error", () => {
        reject(new Error("Notification connection failed."));
      });

      ws.addEventListener("close", () => { mqttClient = null; });

      setTimeout(() => reject(new Error("IoT connection timeout")), 10_000);
    });
  }

  function onMqttMessage(payload) {
    try {
      const data = JSON.parse(payload);
      if (data.status === "PROCESSING") {
        setProgStep("prog-process", "active");
        setProgress(70, "Converting images with FFmpeg…");
      } else if (data.status === "ZIPPING") {
        setProgStep("prog-process", "done");
        setProgStep("prog-zip", "active");
        setProgress(85, "Preparing your download…");
      } else if (data.status === "DONE") {
        setProgStep("prog-zip", "done");
        setProgStep("prog-done", "done");
        setProgress(100, "Done!");
        setTimeout(() => showResult(data.download_url, data.file_count), 400);
      } else if (data.status === "ERROR") {
        showError(data.message || "Conversion failed on the server.");
      }
    } catch (_) {}
  }

  /* MINIMAL MQTT PACKET BUILDERS (over WebSocket) */
  function buildMqttConnect(clientId) {
    const cid = new TextEncoder().encode(clientId);
    const buf = new Uint8Array(14 + cid.length);
    let i = 0;
    buf[i++] = 0x10;             
    buf[i++] = 12 + cid.length;  
    buf[i++] = 0; buf[i++] = 4;  
    buf[i++] = 0x4d; buf[i++] = 0x51; buf[i++] = 0x54; buf[i++] = 0x54; 
    buf[i++] = 4;                
    buf[i++] = 2;               
    buf[i++] = 0; buf[i++] = 60; 
    buf[i++] = 0; buf[i++] = cid.length;
    cid.forEach(b => buf[i++] = b);
    return buf.buffer;
  }
  function buildMqttSubscribe(topic) {
    const t = new TextEncoder().encode(topic);
    // remaining = packet_id(2) + topic_len(2) + topic + qos(1)
    const remaining = 5 + t.length;
    const buf = new Uint8Array(2 + remaining);
    let i = 0;
    buf[i++] = 0x82;       // SUBSCRIBE packet type
    buf[i++] = remaining;
    buf[i++] = 0; buf[i++] = 1; // packet identifier
    buf[i++] = 0; buf[i++] = t.length;
    t.forEach(b => buf[i++] = b);
    buf[i++] = 0;          // QoS 0
    return buf.buffer;
  }

  function parseMqttPublish(data) {
    try {
      if (typeof data === "string") return data;
      const buf = new Uint8Array(data instanceof ArrayBuffer ? data : data);
      if ((buf[0] & 0xf0) !== 0x30) return null; // not a PUBLISH packet
      let i = 1;
      let mult = 1, len = 0, b;
      do { b = buf[i++]; len += (b & 0x7f) * mult; mult *= 128; } while (b & 0x80);
      const topicLen = (buf[i] << 8) | buf[i + 1];
      i += 2 + topicLen;
      return new TextDecoder().decode(buf.slice(i, i + len - topicLen - 2));
    } catch (_) { return null; }
  }

  /* UI STATE HELPERS */
  function showProgress() {
    $("stepFormat").style.opacity = ".4";
    $("stepUpload").style.opacity = ".4";
    $("stepAction").style.display = "none";
    progressPanel.hidden = false;
  }

  function setProgress(pct, msg) {
    progressBar.style.width = pct + "%";
    progressMsg.textContent = msg;
  }

  function setProgStep(id, state) {
    const el = $(id);
    el.classList.remove("active", "done");
    if (state) el.classList.add(state);
  }

  function pickDownloadFilename(url, fileCount) {
    try {
      const path = new URL(url).pathname;
      const seg = path.split("/").filter(Boolean).pop();
      if (seg) return decodeURIComponent(seg);
    } catch (_) {}
    if (fileCount > 1) return "morphix-converted.zip";
    const ext = targetFmt ? String(targetFmt).toLowerCase() : "bin";
    return `morphix-converted.${ext === "jpeg" ? "jpg" : ext}`;
  }

  async function downloadFromPresignedURL(url, fileCount) {
    const res = await fetch(url, { mode: "cors" });
    if (!res.ok) throw new Error(`Download failed (${res.status})`);
    const blob = await res.blob();
    const filename = pickDownloadFilename(url, fileCount);
    const objUrl = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = objUrl;
    a.download = filename;
    a.rel = "noopener";
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(objUrl);
  }

  function showResult(downloadUrl, fileCount) {
    progressPanel.hidden = true;
    resultPanel.hidden = false;
    $("resultSub").textContent = `${fileCount} file${fileCount > 1 ? "s" : ""} converted to ${targetFmt}`;
    const btn = $("downloadBtn");
    btn.textContent = fileCount > 1 ? "⬇ Download (.zip)" : "⬇ Download";
    btn.onclick = async () => {
      try {
        await downloadFromPresignedURL(downloadUrl, fileCount);
      } catch (e) {
        showToast(e.message || "Download failed", "warn");
      }
    };
  }

  function showError(msg) {
    progressPanel.hidden = true;
    errorPanel.hidden = false;
    $("errorMsg").textContent = msg;
  }

  function reset() {
    files     = [];
    targetFmt = null;
    requestId = null;

    if (mqttClient) { mqttClient.close(); mqttClient = null; }

    document.querySelectorAll(".fmt-btn").forEach(b => b.classList.remove("selected"));
    renderFileList();
    updateConvertButton();

    progressPanel.hidden = true;
    resultPanel.hidden   = true;
    errorPanel.hidden    = true;

    $("stepFormat").style.opacity = "1";
    $("stepUpload").style.opacity = "1";
    $("stepAction").style.display = "";

    ["prog-upload","prog-process","prog-zip","prog-done"].forEach(id => setProgStep(id, null));
    setProgress(0, "");

    fileInput.value = "";

    const dl = $("downloadBtn");
    if (dl) dl.onclick = null;
  }

  /* API HELPER */
  async function apiFetch(path, method, body) {
    const opts = {
      method,
      headers: { "Content-Type": "application/json" },
    };
    if (body) opts.body = JSON.stringify(body);
    const res = await fetch(CONFIG.API_BASE + path, opts);
    if (!res.ok) {
      let msg = `API error ${res.status}`;
      try { const j = await res.json(); msg = j.error || j.message || msg; } catch (_) {}
      throw new Error(msg);
    }
    return res.json();
  }

  /* TOAST */
  function showToast(msg, type = "info") {
    const t = document.createElement("div");
    t.style.cssText = `
      position:fixed;bottom:24px;right:24px;z-index:9999;
      background:${type === "warn" ? "#92400e" : "#1e1e2e"};
      border:1px solid ${type === "warn" ? "#f59e0b" : "#2a2a3e"};
      color:${type === "warn" ? "#fcd34d" : "#e8e8f0"};
      padding:12px 20px;border-radius:10px;font-size:.85rem;
      box-shadow:0 4px 24px rgba(0,0,0,.4);
      animation:slideIn .2s ease;max-width:320px;`;
    t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(() => t.remove(), 4000);
  }

  /* GO */
  init();
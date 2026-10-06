/* =====================================================================
   sf-common-2026-10-05.1.js — the parts the office-side pages share.

   Loaded by office.html, delivery.html, inventory.html, pace.html and
   upload.html, before each page's own script. One copy: change it here,
   not in the pages.

   ITS NAME CARRIES ITS VERSION. A change means a NEW file with a new name
   (sf-common-2026-11-02.1.js, say), and the pages that use it are updated
   to name the new file. Never edit this file in place once it's live: the
   tablets' offline helper keeps a saved copy of a file like this one, so a
   changed file under the same name would never reach them, and a page could
   run with a copy it was never tested with.

   The tablet app (index.html) and the TV (tv.html) keep their own copies
   for now: they're what the floor depends on every minute.
   ===================================================================== */

/* THE TWO SETTINGS — publishable key only. NEVER the secret key: this file is public. */
const SUPABASE_URL = "https://fueyfxjxlicqekaqtydi.supabase.co";
const SUPABASE_KEY = "sb_publishable_A5rEVQSSejSsQW7nhAX6iw_gNA5EZ9A";
const SF_COMMON_VERSION = "2026-10-05.1";

/* the key check: refuses to run with the secret key, which bypasses every security rule */
function keyProblem(url, key) {
  if (!url || !key || url.includes("PASTE-") || key.includes("PASTE-"))
    return { secret: false, text: "The project address and key haven't been filled in yet. Copy the two SUPABASE lines into sf-common (the shared file)." };
  const secret = { secret: true, text: "This is the SECRET key, not the publishable one. It bypasses every security rule, and this file is public. Take it out of the file now and use the publishable key. If this file was already put on GitHub with it, create a new secret key in Supabase so the old one stops working." };
  if (key.startsWith("sb_secret_")) return secret;
  const parts = key.split(".");
  if (parts.length === 3) {
    try { if (JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/"))).role === "service_role") return secret; }
    catch (e) { /* not a readable token */ }
  }
  if (!/^https:\/\//.test(url)) return { secret: false, text: "The project address should start with https://." };
  return null;
}

/* no connection, as opposed to a refusal */
function isNetworkError(err) {
  const m = String((err && (err.message || err.details)) || err || "");
  return /failed to fetch|networkerror|load failed|network request failed|fetch failed|timeout|aborted/i.test(m);
}

/* an id made on this computer, so a resend can never be kept twice */
function newId() {
  if (typeof crypto !== "undefined" && crypto.randomUUID) return crypto.randomUUID();
  return "10000000-1000-4000-8000-100000000000".replace(/[018]/g, c => (c ^ (Math.random() * 16) >> (c / 4)).toString(16));
}

/* ---------- which page this computer runs (select * from devices();) ----------
   The same device id as the tablet app, so a computer that opens both shows as one device. */
function sfDeviceId() {
  try {
    let id = JSON.parse(localStorage.getItem("sf_device") || "null");
    if (!id) { id = newId(); localStorage.setItem("sf_device", JSON.stringify(id)); }
    return id;
  } catch (e) { return null; }
}
function sfReportDevice(db, page, version) {   // never waits, never shows anything, never fails the page
  try {
    const dev = sfDeviceId();
    if (!dev || (typeof navigator !== "undefined" && navigator.onLine === false)) return;
    db.auth.getSession().then(({ data }) => {
      if (data && data.session) db.rpc("report_device", { p_device: dev, p_page: page, p_version: version,
        p_agent: String(navigator.userAgent || "").slice(0, 300) }).then(() => {}, () => {});
    }, () => {});
  } catch (e) {}
}

/* ---------- inside the office app ----------
   The office shows Deliveries, Inventory, Pace and Upload inside itself, each its own page in a frame. Shown that
   way, a page hides its own title row (the office's header is above it) and leaves sign-in, the menu and the
   Feedback button to the office. Opened on its own, nothing changes. */
const SF_EMBEDDED = (() => {
  try { return window.parent !== window && /[?&]embed=1\b/.test(location.search) && window.parent.location.origin === location.origin; }
  catch (e) { return false; }
})();
function sfEmbed(hide) {
  if (!SF_EMBEDDED) return;
  document.documentElement.classList.add("sf-embedded");
  const st = document.createElement("style");
  st.textContent = `${hide}{display:none !important}`;
  document.head.appendChild(st);
}

/* what's on screen, in words: the page's name, then whatever tab or section is marked current */
function sfDescribeScreen(doc, skipTitle) {
  const bits = [];
  const h = !skipTitle && doc.querySelector("header h1"); if (h) bits.push(h.textContent.trim());
  doc.querySelectorAll('main [aria-current="true"], #app [aria-current="true"], #tabs [aria-current="true"], [aria-selected="true"]')
    .forEach(el => { const t = el.textContent.replace(/\s+/g, " ").trim(); if (t && t.length < 60 && !bits.includes(t)) bits.push(t); });
  return bits.join(" › ");
}

/* ---------- the Feedback button (5 Oct) — the same piece on office, delivery, inventory, pace and upload ----------
   A note for the office, sent with who's signed in, this page, what's on screen and the page's version, through
   send_feedback() (feedback.sql). Nobody replies: it's a record for planning changes. The tablet page has its own,
   which waits on the device when there's no signal. */
function sfFeedbackSetup(o) {
  const ICON = '<svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><path d="M3 4h14v9H8l-4 3v-3H3z"/></svg>';
  if (!document.getElementById("sf-fb-css")) {
    const st = document.createElement("style"); st.id = "sf-fb-css";
    st.textContent = `.sf-fb-btn{display:inline-flex; align-items:center; gap:6px; min-height:36px; padding:5px 12px; border-radius:99px; border:1.5px solid #5A6178;
        background:transparent; color:#FFF4D5; font:inherit; font-size:14px; font-weight:600; white-space:nowrap; cursor:pointer}
      @media (max-width:560px){ .sf-fb-btn span{display:none} .sf-fb-btn{padding:5px 9px} }
      .sf-fb-ovl{position:fixed; inset:0; z-index:1000; background:rgba(24,29,46,.55); display:flex; align-items:center; justify-content:center; padding:16px}
      .sf-fb-box{background:#fff; color:#181D2E; border-radius:14px; width:100%; max-width:520px; padding:20px; box-shadow:0 10px 40px rgba(24,29,46,.3)}
      .sf-fb-box h3{margin:0 0 6px; font-size:22px}
      .sf-fb-sub{margin:0 0 12px; color:#5A6178; font-size:15px; line-height:1.4}
      .sf-fb-sub b{color:#181D2E}
      .sf-fb-box textarea{display:block; width:100%; box-sizing:border-box; min-height:140px; padding:10px 12px; border:1.5px solid #C2BAA0; border-radius:10px;
        font:inherit; font-size:17px; color:#181D2E; resize:vertical}
      .sf-fb-msg{min-height:1.2em; margin:8px 0 0; font-size:15px; color:#181D2E}
      .sf-fb-msg.warn{color:#181D2E; background:#FFF4D5; border-left:4px solid #ED5E0F; padding:6px 10px; border-radius:6px}
      .sf-fb-btns{display:flex; justify-content:flex-end; gap:10px; margin-top:12px}
      .sf-fb-btns button{font:inherit; font-size:16px; font-weight:600; padding:9px 18px; border-radius:10px; cursor:pointer; border:1.5px solid #C2BAA0; background:#fff; color:#181D2E}
      .sf-fb-btns .sf-fb-go{background:#181D2E; color:#FFF4D5; border-color:#181D2E}
      .sf-fb-btns .sf-fb-go:disabled{opacity:.45; cursor:default}
      .sf-fb-done{font-size:18px; font-weight:600; padding:14px 0 4px}`;
    document.head.appendChild(st);
  }
  if (o.mount) {
    const m = document.querySelector(o.mount);
    if (m && !m.querySelector("[data-sffb]")) {
      const b = document.createElement("button"); b.type = "button"; b.className = "sf-fb-btn"; b.dataset.sffb = "1";
      b.setAttribute("aria-label", "Feedback"); b.innerHTML = ICON + "<span>Feedback</span>"; m.appendChild(b);
    }
  }
  const offline = (e) => /Failed to fetch|NetworkError|Load failed|network|fetch failed/i.test(String((e && (e.message || e)) || ""));
  const notSetUp = (e) => /send_feedback|schema cache|does not exist|PGRST202|42883/i.test(String((e && (e.message || e.code)) || "") + " " + String((e && e.code) || ""));
  function where() {
    let w = "";
    try { w = o.screen ? String(o.screen() || "") : ""; } catch (e) {}
    if (!w) w = sfDescribeScreen(document);
    return w.slice(0, 300) || document.title;
  }
  function open() {
    if (document.getElementById("sf-fb")) return;
    const id = (typeof crypto !== "undefined" && crypto.randomUUID) ? crypto.randomUUID()
      : "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === "x" ? r : (r & 3 | 8)).toString(16); });
    const here = where();
    const ov = document.createElement("div"); ov.id = "sf-fb"; ov.className = "sf-fb-ovl";
    ov.innerHTML = `<div class="sf-fb-box" role="dialog" aria-modal="true" aria-labelledby="sf-fb-h"><h3 id="sf-fb-h">Feedback</h3>
      <p class="sf-fb-sub">What's wrong, what's missing, or what would help? It goes to the office with your name and this screen: <b></b></p>
      <textarea maxlength="2000" placeholder="Type it here" aria-label="Your feedback"></textarea>
      <p class="sf-fb-msg" role="status"></p>
      <div class="sf-fb-btns"><button type="button" data-sffbx="1">Cancel</button><button type="button" class="sf-fb-go" data-sffbsend="1" disabled>Send</button></div></div>`;
    ov.querySelector(".sf-fb-sub b").textContent = here;
    document.body.appendChild(ov);
    const ta = ov.querySelector("textarea"), go = ov.querySelector("[data-sffbsend]"), msg = ov.querySelector(".sf-fb-msg");
    const say = (t, warn) => { msg.textContent = t; msg.className = "sf-fb-msg" + (warn ? " warn" : ""); };
    ta.oninput = () => { go.disabled = !ta.value.trim(); };
    ov.querySelector("[data-sffbx]").onclick = () => ov.remove();
    ta.focus();
    go.onclick = async () => {
      go.disabled = true; say("Sending…");
      let r;
      try {
        const s = await o.db.auth.getSession();
        if (!s || !s.data || !s.data.session) { say("Sign in first, so the office knows who it's from. Your note is still here.", true); go.disabled = false; return; }
        r = await o.db.rpc("send_feedback", { p_client_id: id, p_page: typeof o.page === "function" ? o.page() : o.page, p_screen: here,
          p_version: (typeof o.version === "function" ? o.version() : o.version) || ("page dated " + new Date(document.lastModified).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })), p_body: ta.value.trim() });
      } catch (e) { r = { error: e }; }
      if (r && r.error) {
        say(offline(r.error) ? "No connection. Your note is still here: tap Send again when you're back online."
          : notSetUp(r.error) ? "Feedback isn't set up in the database yet (feedback.sql). Your note is still here."
          : (r.error.message || "That didn't send.") + " Your note is still here.", true);
        go.disabled = !ta.value.trim(); return;
      }
      const box = ov.querySelector(".sf-fb-box");
      box.innerHTML = `<div class="sf-fb-done" role="status">Thanks — sent to the office.</div><div class="sf-fb-btns"><button type="button" data-sffbx="1">Close</button></div>`;
      box.querySelector("[data-sffbx]").onclick = () => ov.remove();
      setTimeout(() => ov.remove(), 2500);
    };
  }
  document.addEventListener("click", (e) => { const b = e.target && e.target.closest && e.target.closest("[data-sffb]"); if (b) { e.preventDefault(); open(); } });
}

if (typeof module !== "undefined") module.exports = { keyProblem, isNetworkError, newId, sfDescribeScreen, SF_COMMON_VERSION };

// sim-deep-link.js — deep-link URL bar for the focus page.
//
// Hangs `window.DeepLinkBar` on the global so sim-native.js can surface a
// floating glass card holding a command bar: type a URL, hit Enter, it
// opens on the device.
//
// The bar is a dumb sender. Completions come from
// `GET /simulators/<udid>/schemes?q=…` already ranked — the ordering rule
// (an app's own scheme ahead of its reverse-DNS and `exp+…` aliases)
// lives in Swift and is tested there, so this file never re-implements
// it. Opening is `POST /simulators/<udid>/openurl?url=…`, whose response
// carries `routing` plus, for https, the warning copy to render. That
// copy is server-side for the same reason: one explanation, not a
// drifting client duplicate.
//
// Two behaviours worth keeping if this is ever rewritten:
//
//   * Typing never blocks. Scheme discovery is a subprocess plus a plist
//     read per app on the Swift side, so the fetch is debounced and its
//     results are dropped if a newer keystroke has already superseded
//     them. The input stays live regardless of what discovery is doing.
//   * The combobox follows the ARIA pattern — `aria-autocomplete="both"`
//     is the codified contract for "inline ghost text *and* a popup
//     list", which is exactly what this is.

(function () {
  'use strict';

  const HISTORY_KEY = 'baguette.deeplink.history';
  const HISTORY_MAX = 25;
  const DEBOUNCE_MS = 60;

  const TEMPLATE = `
    <div class="dl-bar">
      <div class="dl-field">
        <div class="dl-ghost" aria-hidden="true"><span class="dl-ghost-typed"></span><span
             class="dl-ghost-rest"></span></div>
        <input class="dl-input" type="text" spellcheck="false" autocomplete="off"
               role="combobox" aria-expanded="false" aria-autocomplete="both"
               aria-controls="dlList" placeholder="myapp://path — or pick below">
      </div>
      <button class="dl-go" type="button" title="Open (Enter)">Open</button>
    </div>
    <ul class="dl-list" id="dlList" role="listbox" hidden></ul>
    <p class="dl-note" role="status" aria-live="polite"></p>
  `;

  class DeepLinkBar {
    constructor() {
      this.host = null;
      this.udid = null;
      this.suggestions = [];
      this.active = -1;
      this.history = [];
      this.historyAt = -1;
      this._timer = null;
      // Monotonic request id — a slow response for "ava" must not
      // overwrite a fast one for "avas-m".
      this._seq = 0;
    }

    attach(host, udid) {
      this.host = host;
      this.udid = udid;
      this.history = this._loadHistory();
      host.innerHTML = TEMPLATE;

      this.input = host.querySelector('.dl-input');
      this.ghostTyped = host.querySelector('.dl-ghost-typed');
      this.ghostRest = host.querySelector('.dl-ghost-rest');
      this.list = host.querySelector('.dl-list');
      this.note = host.querySelector('.dl-note');

      this._wire();
      this._request('');
      this.input.focus();
    }

    detach() {
      if (this._timer) clearTimeout(this._timer);
      this._timer = null;
      if (this.host) this.host.innerHTML = '';
      this.host = null;
    }

    focus() {
      if (this.input) this.input.focus();
    }

    // ---- wiring

    _wire() {
      this.input.addEventListener('input', () => {
        this.historyAt = -1;
        this._schedule();
      });
      this.input.addEventListener('keydown', (e) => this._onKey(e));
      this.host.querySelector('.dl-go').addEventListener('click', () => this._open());
      this.list.addEventListener('mousedown', (e) => {
        // mousedown, not click — click would fire after the input blurs.
        const li = e.target.closest('li[data-scheme]');
        if (!li) return;
        e.preventDefault();
        this._accept(li.getAttribute('data-completion'));
      });
    }

    _onKey(e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        if (this.active >= 0 && this.suggestions[this.active]) {
          this._accept(this.suggestions[this.active].completion);
        } else {
          this._open();
        }
        return;
      }
      if (e.key === 'Escape') {
        this._renderList([]);
        return;
      }
      // Tab / → accept the inline completion, matching a shell.
      if ((e.key === 'Tab' || e.key === 'ArrowRight') && this._ghostRemainder()) {
        e.preventDefault();
        this._accept(this.suggestions[Math.max(this.active, 0)].completion);
        return;
      }
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        // With an empty box and nothing suggested, ↑ walks history —
        // the shell reflex.
        if (!this.suggestions.length) return this._recall(e.key === 'ArrowUp' ? 1 : -1);
        const step = e.key === 'ArrowDown' ? 1 : -1;
        this.active = Math.max(-1, Math.min(this.suggestions.length - 1, this.active + step));
        this._paint();
      }
    }

    // ---- completion

    _schedule() {
      if (this._timer) clearTimeout(this._timer);
      this._timer = setTimeout(() => this._request(this.input.value.trim()), DEBOUNCE_MS);
    }

    // Only the scheme fragment drives completion — once the user has
    // typed "myapp://prof" there is nothing left to complete, and
    // re-querying on every path character would be noise.
    _schemeFragment(value) {
      const cut = value.indexOf(':');
      return cut === -1 ? value : null;
    }

    _request(value) {
      const fragment = this._schemeFragment(value);
      if (fragment === null) {
        this._renderList([]);
        return;
      }
      const seq = ++this._seq;
      const url = `/simulators/${encodeURIComponent(this.udid)}/schemes`
        + `?q=${encodeURIComponent(fragment)}`;
      fetch(url, { headers: { accept: 'application/json' } })
        .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
        .then((body) => {
          if (seq !== this._seq) return;           // superseded; drop it
          this._renderList((body && body.schemes) || []);
        })
        .catch(() => {
          if (seq === this._seq) this._renderList([]);
        });
    }

    _renderList(suggestions) {
      this.suggestions = suggestions;
      this.active = suggestions.length ? 0 : -1;
      this._paint();
    }

    _paint() {
      const rows = this.suggestions;
      this.list.hidden = rows.length === 0;
      this.input.setAttribute('aria-expanded', rows.length ? 'true' : 'false');
      this.list.innerHTML = rows.map((s, i) => `
        <li role="option" data-scheme="${esc(s.scheme)}"
            data-completion="${esc(s.completion)}"
            aria-selected="${i === this.active ? 'true' : 'false'}"
            class="${i === this.active ? 'active' : ''}">
          <span class="dl-scheme">${esc(s.completion)}</span>
          <span class="dl-app">${esc(s.app)}</span>
        </li>`).join('');
      this._paintGhost();
    }

    // Inline completion: the typed text is rendered transparent beneath
    // the real input, and only the remainder shows through.
    _paintGhost() {
      const typed = this.input.value;
      const rest = this._ghostRemainder();
      this.ghostTyped.textContent = typed;
      this.ghostRest.textContent = rest;
    }

    _ghostRemainder() {
      const typed = this.input.value;
      const pick = this.suggestions[Math.max(this.active, 0)];
      if (!typed || !pick) return '';
      const lower = typed.toLowerCase();
      return pick.completion.toLowerCase().startsWith(lower)
        ? pick.completion.slice(typed.length)
        : '';
    }

    _accept(completion) {
      if (!completion) return;
      this.input.value = completion;
      this.input.focus();
      this._renderList([]);
      this._paintGhost();
    }

    // ---- history

    _loadHistory() {
      try {
        const raw = JSON.parse(localStorage.getItem(HISTORY_KEY) || '[]');
        return Array.isArray(raw) ? raw.filter((v) => typeof v === 'string') : [];
      } catch (_) {
        return [];
      }
    }

    _remember(url) {
      this.history = [url].concat(this.history.filter((v) => v !== url)).slice(0, HISTORY_MAX);
      try {
        localStorage.setItem(HISTORY_KEY, JSON.stringify(this.history));
      } catch (_) { /* private mode — history is a nicety, not a feature */ }
    }

    _recall(step) {
      if (!this.history.length) return;
      this.historyAt = Math.max(-1, Math.min(this.history.length - 1, this.historyAt + step));
      this.input.value = this.historyAt < 0 ? '' : this.history[this.historyAt];
      this._paintGhost();
    }

    // ---- opening

    _open() {
      const url = this.input.value.trim();
      if (!url) return;
      this._say('Opening…', '');
      const endpoint = `/simulators/${encodeURIComponent(this.udid)}/openurl`
        + `?url=${encodeURIComponent(url)}`;
      fetch(endpoint, { method: 'POST' })
        .then((r) => r.json().then((body) => ({ ok: r.ok, body })))
        .then(({ ok, body }) => {
          if (!ok) return this._say((body && body.error) || 'Open failed', 'bad');
          this._remember(url);
          this._renderList([]);
          // A browser-routed link "succeeded" and still didn't reach the
          // app — say so rather than reporting a bare OK.
          if (body && body.routing === 'browser') {
            this._say(body.warning || 'Opened in Safari, not your app.', 'warn');
          } else {
            this._say(`Opened ${url}`, 'good');
          }
        })
        .catch(() => this._say('Open failed — is the device still booted?', 'bad'));
    }

    _say(text, tone) {
      this.note.textContent = text;
      this.note.className = `dl-note${tone ? ' ' + tone : ''}`;
    }
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    })[c]);
  }

  window.DeepLinkBar = DeepLinkBar;
})();

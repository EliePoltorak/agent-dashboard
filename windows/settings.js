/* Agent Dashboard: Settings drawer. Loaded by the page with one script tag; talks to /api/settings/* (dashboard_settings.py).
   Styles use the page's own tokens (--panel, --btn, --ink, ...). Never stores or shows a token; a pasted token lives in memory until it is sent. */
(function () {
  'use strict';
  if (location.protocol !== 'http:' && location.protocol !== 'https:') return;       // the saved .html copy opened from disk has no server behind it
  const HDR = { 'X-Quota-App': '1', 'Content-Type': 'application/json' };
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const emailsOn = () => { try { return localStorage.getItem('q2emails') === '1'; } catch (e) { return false; } };   // the page's own "Show emails" switch
  const S = { data: null, auto: null, upd: null, wait: false, fk: '', tab: 'claude', job: null, note: null, form: { label: '', token: '', replace: false }, open: false };

  const css = document.createElement('style');
  css.textContent = `
#qs-drawer{margin:0 0 0 auto;height:100dvh;max-height:100dvh;width:min(620px,100vw);max-width:100vw;border:0;border-left:1px solid var(--grid);border-radius:16px 0 0 16px;padding:0;background:var(--panel);color:var(--ink);font:inherit}
#qs-drawer::backdrop{background:rgba(0,0,0,.5)}
#qs-drawer .qh{display:flex;align-items:center;gap:8px;padding:14px 18px;border-bottom:1px solid var(--grid);position:sticky;top:0;background:var(--panel);z-index:1}
#qs-drawer .qh h2{margin:0;font-size:19px;flex:1}
#qs-drawer .qb{padding:6px 18px 28px}
#qs-drawer .qt{display:flex;flex-wrap:wrap;gap:4px;margin:12px 0}
#qs-drawer .qt button{background:none;display:inline-flex;gap:8px;align-items:center;padding:7px 12px}
#qs-drawer .qt button[aria-pressed="true"]{background:var(--btn);color:var(--ink)}
#qs-drawer .qs{border-radius:12px;background:var(--bg);padding:10px 14px;margin:0 0 12px;color:var(--ink2)}
#qs-drawer .qs.err{border-left:4px solid var(--bad)}#qs-drawer .qs.run{border-left:4px solid var(--c-codex)}#qs-drawer .qs.ok{border-left:4px solid var(--ok)}
#qs-drawer .qs pre{margin:8px 0 0;font:12px ui-monospace,Consolas,monospace;white-space:pre-wrap;color:var(--ink2);max-height:180px;overflow:auto}
#qs-drawer h3{font-size:15px;margin:18px 0 8px}
#qs-drawer .seat{background:var(--bg);border-radius:12px;padding:10px 14px;margin:0 0 8px;display:grid;grid-template-columns:1fr auto;gap:6px 12px;align-items:center}
#qs-drawer .seat .nm{display:flex;flex-wrap:wrap;gap:4px 8px;align-items:baseline}
#qs-drawer .seat .nm b{font-size:16px}
#qs-drawer .seat .meta{grid-column:1/-1;display:flex;flex-wrap:wrap;gap:4px 14px;color:var(--muted);font-size:13px;align-items:center}
#qs-drawer .seat .acts{display:flex;flex-wrap:wrap;gap:6px;grid-column:1/-1}
#qs-drawer .seat .acts button,#qs-drawer .row button,#qs-drawer .qb .sm{padding:5px 10px;font-size:13px;color:var(--ink)}
#qs-drawer .bad{color:var(--bad)}#qs-drawer .okc{color:var(--ok)}
#qs-drawer input[type=text],#qs-drawer input[type=password],#qs-drawer input[type=number]{font:inherit;background:var(--panel);color:var(--ink);border:1px solid var(--grid);border-radius:8px;padding:6px 10px;min-width:0}
#qs-drawer input:focus-visible{outline:2px solid var(--ink2);outline-offset:1px}
#qs-drawer input[type=number]{width:5.5em}
#qs-drawer .row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:8px 0}
#qs-drawer .row label{display:inline-flex;gap:6px;align-items:center;color:var(--ink2)}
#qs-drawer .hint{color:var(--muted);font-size:13px;margin:4px 0}
#qs-drawer button.primary{background:var(--btnon);color:var(--btnonink)}
#qs-drawer .task{display:flex;gap:12px;align-items:center;justify-content:space-between;background:var(--bg);border-radius:12px;padding:10px 14px;margin:0 0 8px}
#qs-drawer .task small{display:block;color:var(--muted)}
#qs-drawer .log{font:12px ui-monospace,Consolas,monospace;color:var(--muted);white-space:pre-wrap;margin:4px 0 0}
#qs-drawer button:disabled{opacity:.5}
#qs-cfm{background:var(--panel);color:var(--ink);border:1px solid var(--grid);border-radius:16px;padding:20px;width:min(460px,calc(100vw - 32px));font:inherit}
#qs-cfm::backdrop{background:rgba(0,0,0,.6)}
#qs-cfm h2{font-size:19px;margin:0 0 10px}#qs-cfm p{margin:0 0 8px;color:var(--ink2)}
#qs-cfm .dact{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}
#qs-cfm button.primary{background:var(--btnon);color:var(--btnonink)}
#qs-cfm input{font:inherit;background:var(--bg);color:var(--ink);border:1px solid var(--grid);border-radius:8px;padding:6px 10px}
@media (max-width:600px){#qs-drawer{border-radius:0;width:100vw}}
`;
  document.head.appendChild(css);

  const drawer = document.createElement('dialog');
  drawer.id = 'qs-drawer';
  drawer.setAttribute('aria-labelledby', 'qs-title');
  const cfm = document.createElement('dialog');
  cfm.id = 'qs-cfm';
  cfm.setAttribute('aria-labelledby', 'qs-cfm-t');
  document.body.append(drawer, cfm);

  function toast(text, outcome) {
    if (typeof window.toast === 'function') return window.toast(text, outcome);
    const t = document.getElementById('toast');
    if (t) { t.textContent = text; t.dataset.outcome = outcome; t.hidden = false; setTimeout(() => { t.hidden = true; }, 9000); }
  }

  async function api(path, body) {
    try {
      const r = await fetch(path, body === undefined ? undefined : { method: 'POST', headers: HDR, body: JSON.stringify(body) });
      let j = {};
      try { j = await r.json(); } catch (e) { /* not JSON */ }
      return Object.assign({ status: r.status }, j, r.ok ? {} : { outcome: 'error', text: j.text || 'The server answered ' + r.status + '.' });
    } catch (e) {
      return { status: 0, outcome: 'error', text: 'The dashboard did not answer. Is it still running?' };
    }
  }

  function confirmDlg(title, lines, go, label) {
    cfm.innerHTML = `<h2 id="qs-cfm-t">${esc(title)}</h2>${lines.map(l => `<p>${esc(l)}</p>`).join('')}` +
      `<div class="dact"><button data-c="no" autofocus>Cancel</button><button class="primary" data-c="yes">${esc(label || 'Continue')}</button></div>`;
    cfm.onclick = e => { const c = e.target.closest('[data-c]'); if (!c) return; cfm.close(); if (c.dataset.c === 'yes') go(); };
    cfm.showModal();
  }

  function emailDlg(label, go) {
    cfm.innerHTML = `<h2 id="qs-cfm-t">Address shown for seat ${esc(label)}</h2><p>Only used as a label on this page. Leave it empty to clear it.</p>` +
      `<p><input type="text" id="qs-em" style="width:100%" aria-label="Email address" autocomplete="off" spellcheck="false"></p>` +
      `<div class="dact"><button data-c="no">Cancel</button><button class="primary" data-c="yes">Save</button></div>`;
    cfm.onclick = e => { const c = e.target.closest('[data-c]'); if (!c) return; const v = document.getElementById('qs-em').value.trim(); cfm.close(); if (c.dataset.c === 'yes') go(v); };
    cfm.showModal();
    document.getElementById('qs-em').focus();
  }

  // Update now: the same call the page's banner button makes. When the dashboard's own code changed it restarts: wait for the new build, then reload.
  async function updateNow() {
    if (busy()) return;
    S.wait = 'update'; S.note = null; render();
    const b0 = ((await api('/api/data')) || {}).build;
    const r = await api('/api/update', {});
    S.wait = false;
    if (r.outcome !== 'ok') S.note = { text: r.text || 'The update did not run.', ok: false };
    else if (!r.restart) { S.note = { text: r.text, ok: true }; toast(r.text, 'ok'); }
    else {
      S.wait = 'update'; S.note = null; render();
      for (let i = 0; i < 40; i++) {
        await new Promise(ok => setTimeout(ok, 1500));
        const d = await api('/api/data');
        if (d.build && b0 && d.build !== b0) { location.reload(); return; }
      }
      S.wait = false; S.note = { text: 'The update installed, but the dashboard has not come back. Reload this page, or restart it from Task Scheduler.', ok: false };
    }
    S.upd = null; await load();
  }

  // ---- running an action: quick ones answer at once, long ones are a job the page polls
  async function act(body, after) {
    if (S.job || S.wait) return;
    S.note = null; S.wait = body.action === 'update.check' ? 'check' : true; render();           // every button is held while a request is out: no second click, and the page says so
    const r = await api('/api/settings/action', body);
    S.wait = false;
    if (r.job) { S.job = { id: r.job, title: r.text.replace(/ started\.$/, ''), state: 'running', tail: [] }; render(); poll(after); return; }
    toast(r.text || 'Done', r.outcome === 'ok' ? 'ok' : 'error');
    S.note = { text: r.text || 'Done', ok: r.outcome === 'ok' };
    if (after) after(r);
    await load();
  }
  async function poll(after) {
    for (let n = 0; n < 900 && S.job; n++) {
      await new Promise(ok => setTimeout(ok, 1000));
      const j = await api('/api/settings/job?id=' + encodeURIComponent(S.job.id));
      if (j.status === 404 || j.status === 0) { S.job = null; S.note = { text: j.text, ok: false }; break; }
      if (j.state && j.state !== 'running') {
        toast(j.text, j.state === 'ok' ? 'ok' : 'error');
        S.job = null; S.note = { text: j.text, ok: j.state === 'ok', tail: j.state === 'ok' ? [] : j.tail };
        if (after) after(j);
        if (typeof window.loadData === 'function') { try { window.loadData(); } catch (e) { /* the page reloads itself every minute */ } }
        break;
      }
      S.job.state = 'running';
    }
    S.job = null;
    await load();
  }

  async function load() {
    const [s, a, u] = await Promise.all([api('/api/settings/seats'), S.tab === 'auto' ? api('/api/settings/automation') : Promise.resolve(S.auto),
      S.tab === 'upd' ? api('/api/settings/update') : Promise.resolve(S.upd)]);
    if (s.providers) S.data = s; else S.note = { text: s.text, ok: false };
    if (a && !a.outcome) S.auto = a;
    if (u && !u.outcome) S.upd = u;
    render();
  }

  // ---- views
  const pct = h => h == null ? '<span class="muted">no reading</span>' : `<span class="${h < .1 ? 'bad' : ''}">${Math.round(h * 100)}% left</span>`;
  const when = ts => { const m = /^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)/.exec(ts); return m ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5])).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : ts; };
  const busy = () => !!(S.job || S.wait);
  const dis = () => busy() ? ' disabled' : '';

  function seatCard(p, s) {
    const act = s.active || {};
    const badges = (act.cli ? '<span class="bdg">CLI</span>' : '') + (act.app ? '<span class="bdg app">App</span>' : '') + (act.login ? '<span class="bdg">In use</span>' : '') +
      (s.roles && !s.roles.cli ? '<span class="muted">app only</span>' : '') + (s.roles && !s.roles.app ? '<span class="muted">CLI only</span>' : '');
    const inUse = Object.values(act).some(Boolean);
    const sw = [];
    const L = esc(s.label);
    if (p.can.includes('cli.switch') && s.roles && s.roles.cli && !act.cli) sw.push(`<button data-a="sw-cli" data-l="${L}"${dis()}>Use for CLI</button>`);
    if (p.can.includes('app.switch') && s.roles && s.roles.app && !act.app) sw.push(`<button data-a="sw-app" data-l="${L}"${dis()}>Use for App</button>`);
    if (p.kind === 'codex' && p.can.includes('switch') && !act.app) sw.push(`<button data-a="sw-codex" data-l="${L}"${dis()}>Use for CLI + App</button>`);
    if (p.kind === 'cred' && !act.login) sw.push(`<button data-a="sw-cred" data-l="${L}"${dis()}>Switch to this</button>`);
    const h = s.health || {};
    return `<div class="seat"><div class="nm"><b>${L}</b>${badges}</div>` +
      `<div>${s.plan ? `<span class="muted">${esc(s.plan)}</span>` : ''}</div>` +
      `<div class="meta">${emailsOn() && s.email ? `<span>${esc(s.email)}</span>` : ''}<span>${pct(s.headroom)}</span>` +
      `<label>Counts as <input type="number" min="0" max="100" step="0.5" value="${esc(s.weight)}" data-w="${L}" aria-label="Weight of seat ${L}"${dis()}> seat(s)</label>` +
      (h.ok === false || h.note ? `<span class="${h.ok === false ? 'bad' : ''}">${esc(h.note || 'problem reading this seat')}</span>` : '') + `</div>` +
      `<div class="acts">${sw.join('')}` +
      (p.can.includes('email') ? `<button data-a="email" data-l="${L}"${dis()}>Set address</button>` : '') +
      `<button data-a="remove" data-l="${L}"${dis()}${inUse ? ' disabled title="In use: switch to another seat first"' : ''}>Remove</button></div></div>`;
  }

  function addForm(p) {
    const f = S.form, nameIn = `<input type="text" id="qs-label" maxlength="32" value="${esc(f.label)}" placeholder="Seat name, e.g. G" aria-label="Seat name" autocomplete="off" spellcheck="false">`;
    if (p.kind === 'claude') {
      return `<h3>Add a seat</h3><div class="hint">CLI seat: sign in to the account in the window that opens, copy the token it prints, paste it here.</div>` +
        `<div class="row">${nameIn}<button data-a="cli-add"${dis()}>1. Open the sign-in window</button></div>` +
        `<div class="row"><input type="password" id="qs-token" value="${esc(f.token)}" placeholder="Paste the token here" aria-label="Claude token" autocomplete="off" spellcheck="false" style="flex:1;min-width:12em">` +
        `<label><input type="checkbox" id="qs-replace"${f.replace ? ' checked' : ''}> replace an existing seat</label><button class="primary" data-a="cli-import"${dis()}>2. Save token</button></div>` +
        `<div class="hint">App seat: sign in to the account in the Claude app, quit the app completely, then save it under the seat name above.</div>` +
        `<div class="row"><button data-a="app-capture"${dis()}>Save the app's current login</button></div>`;
    }
    if (p.kind === 'codex') {
      return `<h3>Add a seat</h3><div class="hint">Use an account that is not already a seat. A new seat name only: an existing one would be overwritten.</div>` +
        `<div class="row">${nameIn}<button data-a="codex-add"${dis()}>1. Open the sign-in window</button><button class="primary" data-a="codex-check"${dis()}>2. Check the login</button></div>`;
    }
    const cur = p.current || {};
    const signin = p.signin && !cur.present
      ? `<div class="qs err" role="status"><b>${esc(p.name)} is installed but not signed in.</b> Press the button: ${esc(p.name)} opens in a new window and asks you to log in. When you are done, press Check again.` +
        `<div class="row"><button class="primary" data-a="cred-signin"${dis()}>Open ${esc(p.name)} to sign in</button><button data-a="recheck"${dis()}>Check again</button></div></div>` : '';
    return signin + `<h3>Add a seat</h3><div class="hint">${esc(p.how)}</div>` +
      `<div class="hint">Current login: ${cur.present ? (cur.saved ? 'already saved as a seat' : (emailsOn() && cur.email ? esc(cur.email) : 'not saved yet')) : 'none found'}.</div>` +
      `<div class="row">${nameIn}<label><input type="checkbox" id="qs-replace"${f.replace ? ' checked' : ''}> replace an existing seat</label>` +
      `<button class="primary" data-a="cred-capture"${dis()}${cur.present ? '' : ' disabled title="Sign in first: there is no login to save yet"'}>Save the current login</button></div>`;
  }

  function providerView(p) {
    if (p.kind === 'unsupported') return `<div class="qs">${esc(p.how)}</div>`;
    const bestBtn = p.can.includes('best') && p.seats.length > 1 ? `<button data-a="best"${dis()}>Switch to the seat with most headroom</button>` : '';
    const removed = p.removed.length ? `<h3>Removed seats</h3><div class="hint">Moved aside, not deleted. Restore puts one back as it was.</div>` +
      p.removed.map(r => `<div class="task"><div>${esc(r.label)}<small>removed ${esc(when(r.ts))}</small></div><button data-a="restore" data-id="${esc(r.id)}"${dis()}>Restore</button></div>`).join('') : '';
    return `<div class="hint">${esc(p.how)}</div><div class="row">${bestBtn}</div>` +
      (p.seats.length ? p.seats.map(s => seatCard(p, s)).join('') : '<div class="qs">No seats saved yet.</div>') + addForm(p) + removed;
  }

  function autoView() {
    const a = S.auto;
    if (!a) return '<div class="qs">Loading…</div>';
    const st = { ready: 'On', running: 'On, running now', disabled: 'Off', missing: 'Not set up on this PC' };
    const tasks = a.tasks.map(t => `<div class="task"><div>${esc(t.name)}<small>${esc(st[t.state] || t.state)}</small></div>` +
      (t.state === 'missing' ? '' : `<label><input type="checkbox" data-t="${esc(t.id)}"${t.state === 'disabled' ? '' : ' checked'}${dis()}> on</label>`) + `</div>`).join('');
    const log = (l, name) => l.length ? `<div class="hint">${esc(name)}</div><div class="log">${l.map(esc).join('\n')}</div>` : '';
    return `<h3>Scheduled jobs</h3>${tasks}` +
      `<div class="task"><div>Wake up running Claude sessions after a limit rotation<small>${a.autoResume ? 'On' : 'Off'}</small></div><label><input type="checkbox" data-resume="1"${a.autoResume ? ' checked' : ''}${dis()}> on</label></div>` +
      `<h3>Rotate proxy</h3><div class="task"><div>${a.proxy.up ? (a.proxy.ok ? 'Running and healthy' : 'Running, but not healthy (a seat is refused)') : 'Not running'}</div><button data-a="proxy-restart"${dis()}>Restart</button></div>` +
      `<h3>Actions</h3><div class="row"><button data-a="sync-history"${dis()}>Sync the Claude app's history now</button><button data-a="keepalive-status"${dis()}>Check the app-seat keepalive</button></div>` +
      log(a.keepaliveLog, 'Claude app-seat keepalive, last lines') + log(a.codexKeepaliveLog, 'Codex keepalive, last lines');
  }

  function updView() {
    const u = S.upd && S.upd.update;
    if (!S.upd) return '<div class="qs" role="status">Loading…</div>';
    if (!u) return '<div class="qs">The update state is not available on this copy of the dashboard.</div>';
    const n = (u.differing || []).length, d = dis();
    const when = ts => ts ? new Date(ts * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : 'never';
    const status = u.checkout ? 'This copy is a git checkout: update it with git pull there.'
      : u.state === 'running' ? 'An update is installing now.'
      : u.state === 'failed' ? 'The last update did not install: ' + u.text
      : n ? n + ' file' + (n === 1 ? '' : 's') + ' differ from GitHub: ' + u.differing.join(', ') + '.'
      : u.checked ? 'Up to date with GitHub.' : 'Not checked yet.';
    return `<h3>Updates</h3>` +
      `<div class="task"><div>Install updates automatically<small>${u.auto ? 'On: it installs by itself when nothing else is running' : 'Off: the dashboard only offers Update now'}</small></div>` +
      `<label><input type="checkbox" data-up-auto="1"${u.auto ? ' checked' : ''}${d}> on</label></div>` +
      `<div class="task"><div>Installed commit<small>${u.installed ? `<code>${esc(u.installed)}</code>${u.checkout ? ' (git checkout)' : n ? '' : ' (matches GitHub)'}` : 'not known yet'}</small></div>` +
      `<div class="muted" style="text-align:right">Last check<small>${esc(when(u.checked))}</small></div></div>` +
      `<div class="qs ${u.state === 'failed' ? 'err' : n ? 'run' : 'ok'}">${esc(status)}</div>` +
      `<div class="row"><button data-a="upd-check"${d}>${S.wait === 'check' ? 'Checking…' : 'Check now'}</button>` +
      `<button class="primary" data-a="upd-now"${d}${u.checkout ? ' disabled title="A git checkout is updated with git pull"' : ''}>${S.wait === 'update' ? 'Updating…' : 'Update now'}</button></div>` +
      `<div class="hint">An update keeps a backup of every file it replaces and never touches your own settings (rotator.local.json). If the dashboard itself changed, it restarts and this page reloads.</div>`;
  }

  function render() {
    if (!S.open) return;
    const ps = S.data ? S.data.providers : [];
    const tabs = ps.map(p => `<button data-tab="${esc(p.id)}" aria-pressed="${S.tab === p.id}">${esc(p.name)}</button>`).join('') +
      `<button data-tab="auto" aria-pressed="${S.tab === 'auto'}">Automation</button><button data-tab="upd" aria-pressed="${S.tab === 'upd'}">Updates</button>`;
    let st = '';
    if (S.job) st = `<div class="qs run" role="status">Running: ${esc(S.job.title)}… This can take a minute. Don't start anything else yet.</div>`;
    else if (S.wait) st = `<div class="qs run" role="status">Working…</div>`;
    else if (S.note) st = `<div class="qs ${S.note.ok ? 'ok' : 'err'}" role="${S.note.ok ? 'status' : 'alert'}">${S.note.ok ? '' : '<b>'}${esc(S.note.text)}${S.note.ok ? '' : '</b>'}${(S.note.tail || []).length ? `<pre>${esc(S.note.tail.join('\n'))}</pre>` : ''}</div>`;
    const p = ps.find(x => x.id === S.tab);
    const keep = document.activeElement && document.activeElement.id;
    drawer.innerHTML = `<div class="qh"><h2 id="qs-title">Settings</h2><button data-a="close" aria-label="Close settings">Close</button></div>` +
      `<div class="qb"><div class="qt" role="group" aria-label="Section">${tabs}</div><div aria-live="polite">${st}</div>` +
      (S.tab === 'auto' ? autoView() : S.tab === 'upd' ? updView() : p ? providerView(p) : '<div class="qs">Loading…</div>') + `</div>`;
    if (keep) { const el = document.getElementById(keep); if (el) el.focus(); }
  }

  // ---- events
  drawer.addEventListener('input', e => {
    if (e.target.id === 'qs-label') S.form.label = e.target.value.trim();
    if (e.target.id === 'qs-token') S.form.token = e.target.value;
  });
  drawer.addEventListener('change', async e => {
    const t = e.target;
    if (t.id === 'qs-replace') { S.form.replace = t.checked; return; }
    if (t.dataset.w) {
      const v = t.value === '' ? null : Number(t.value);
      return act({ action: 'set.weight', provider: S.tab, label: t.dataset.w, weight: v });
    }
    if (t.dataset.t) return act({ action: 'task.set', task: t.dataset.t, enabled: t.checked }, () => { S.auto = null; });
    if (t.dataset.resume) return act({ action: 'auto.resume', enabled: t.checked }, () => { S.auto = null; });
    if (t.dataset.upAuto) return act({ action: 'update.auto', enabled: t.checked });
  });
  drawer.addEventListener('click', async e => {
    const tb = e.target.closest('[data-tab]');
    if (tb) { S.tab = tb.dataset.tab; S.note = null; if (S.tab === 'auto') S.auto = null; if (S.tab === 'upd') S.upd = null; render(); return load(); }
    const b = e.target.closest('[data-a]');
    if (!b || b.disabled) return;
    const a = b.dataset.a, l = b.dataset.l, p = S.tab, f = S.form;
    const need = () => { if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/.test(f.label)) { S.note = { text: 'Type a seat name first: 1 to 32 letters, digits, - or _, starting with a letter or digit.', ok: false }; render(); return false; } return true; };
    if (a === 'close') return drawer.close();
    if (a === 'sw-cli') return act({ action: 'claude.cli.switch', label: l });
    if (a === 'sw-app') return confirmDlg('Switch the Claude app to seat ' + l + '?', ['This closes the Claude app and opens it again on seat ' + l + '.', 'Sessions running in the app end.'], () => act({ action: 'claude.app.switch', label: l }), 'Switch');
    if (a === 'sw-codex') return confirmDlg('Switch Codex to seat ' + l + '?', ['This closes the Codex app and opens it again on seat ' + l + '.', 'Anything the Codex app is doing stops.'], () => act({ action: 'codex.switch', label: l }), 'Switch');
    if (a === 'sw-cred') return confirmDlg('Switch to seat ' + l + '?', ['The program must be closed first; it will say so if it is not.', 'The login you have now is backed up first, and you can switch back any time.'], () => act({ action: 'cred.switch', provider: p, label: l }), 'Switch');
    if (a === 'best') {
      if (p === 'claude') return act({ action: 'best', provider: 'claude' });
      return confirmDlg('Switch to the seat with the most room left?', ['Chosen from the dashboard\'s own numbers; a seat that is used up is never picked.', p === 'codex' ? 'This closes and reopens the Codex app.' : 'The program must be closed first.'], () => act({ action: 'best', provider: p }), 'Switch');
    }
    if (a === 'remove') return confirmDlg('Remove seat ' + l + '?', ['Its login is moved to "Removed seats" on this PC. Nothing is deleted.', 'You can restore it from that list at any time.'], () => act({ action: 'remove', provider: p, label: l }), 'Remove');
    if (a === 'restore') return act({ action: 'restore', provider: p, id: b.dataset.id });
    if (a === 'email') return emailDlg(l, v => act({ action: 'set.email', provider: p, label: l, email: v }));
    if (a === 'cli-add') { if (!need()) return; return act({ action: 'claude.cli.add', label: f.label }); }
    if (a === 'cli-import') {
      if (!need()) return;
      const tok = f.token.trim(); f.token = '';
      return act({ action: 'claude.cli.import', label: f.label, token: tok, replace: f.replace }, () => { f.token = ''; });
    }
    if (a === 'app-capture') { if (!need()) return; return act({ action: 'claude.app.capture', label: f.label }); }
    if (a === 'codex-add') { if (!need()) return; return act({ action: 'codex.add', label: f.label }); }
    if (a === 'codex-check') { if (!need()) return; return act({ action: 'codex.check', label: f.label }); }
    if (a === 'cred-signin') return act({ action: 'cred.signin', provider: p });
    if (a === 'recheck') { S.note = null; return load(); }
    if (a === 'cred-capture') { if (!need()) return; return act({ action: 'cred.capture', provider: p, label: f.label, replace: f.replace }); }
    if (a === 'upd-check') return act({ action: 'update.check' }, () => { S.upd = null; });
    if (a === 'upd-now') return updateNow();
    if (a === 'proxy-restart') return act({ action: 'proxy.restart' }, () => { S.auto = null; });
    if (a === 'sync-history') return act({ action: 'sync.history' });
    if (a === 'keepalive-status') return act({ action: 'keepalive.status' });
  });
  drawer.addEventListener('close', () => { S.open = false; S.form.token = ''; });

  function openDrawer() {
    S.open = true; S.note = null;
    if (!drawer.open) drawer.showModal();
    render();
    load();
  }

  // ---- the gear: the page rebuilds #app on every render, so put the button back whenever it is gone
  let queued = false;
  function ensureGear() {
    queued = false;
    const top = document.querySelector('.top');
    if (!top || top.querySelector('#qs-gear')) return;
    const b = document.createElement('button');
    b.id = 'qs-gear';
    b.setAttribute('aria-label', 'Settings');
    b.title = 'Settings: seats and automation';
    b.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>';
    b.addEventListener('click', openDrawer);
    top.insertBefore(b, top.lastElementChild);
  }
  const queue = () => { if (!queued) { queued = true; requestAnimationFrame(ensureGear); } };
  new MutationObserver(queue).observe(document.body, { childList: true, subtree: true });
  ensureGear();
})();

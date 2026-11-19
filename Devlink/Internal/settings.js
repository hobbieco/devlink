// 프로젝트 설정 화면 (devlink://project/<id>/settings).
// 편집은 화면 안의 사본(draft)에만 하고, [저장] 을 눌러야 Swift 로 보낸다. 마지막 검증은 Swift.
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const projectID = location.pathname.split('/')[1];

  let otherNames = new Set();   // 다른 프로젝트 이름 (겹치면 저장 못 함)
  let latest = null;     // Swift 가 보낸 마지막 상태
  let palettes = [];     // 색 견본 [{key, hex}] (순서 = 새 환경 기본 색 순서)
  let draft = null;      // 편집 중인 사본
  let envID = new URLSearchParams(location.search).get('env');   // 선택한 환경 (프로젝트 화면에서 넘어온 값, 없으면 첫 환경)
  let dirty = false;
  let authAvailable = true;   // 인증을 쓸 수 없으면 잠금을 새로 걸 수 없다
  let leaveAfterSave = false;
  let copySource = null; // 복사 원본 { d: 서비스, kind: 'uri'|'acc', item: URI 또는 계정 하나 }
  // 접힌 URI·계정 표 (보기 편의, 저장 안 함 — 화면을 열 때마다 모두 펼침)
  let armed = null;   // 삭제 확인 중인 버튼 (하나만): { btn, label, at, timer }
  // 접힌 서비스: URI·계정 영역을 숨긴다 (화면에서만 유지). 저장해서 사본이 새로 만들어져도 이어지도록 id 로 기억한다 (저장 전 새 서비스는 객체).
  const foldedKeys = new Set();
  const folded = { has: (d) => foldedKeys.has(d.id || d), add: (d) => foldedKeys.add(d.id || d), delete: (d) => foldedKeys.delete(d.id || d) };
  function post(type, data = {}) {
    try { window.webkit.messageHandlers.lh.postMessage(Object.assign({ type }, data)); } catch (e) {}
  }

  // 잠근 계정의 저장된 값 요청: Swift 가 인증한 뒤 돌려준다 (done(값) · 취소·실패는 done(null))
  const pendingReveal = new Map();
  let revealSeq = 0;
  function reveal(d, a, done) {
    const token = String(++revealSeq);
    pendingReveal.set(token, done);
    post('revealPassword', { domainID: d.id, account: a.id, token });
  }
  /** 저장된 계정인가 (저장된 도메인에 같은 아이디가 있음) */
  function isSaved(d, a) {
    return !!latest && latest.envs.some((e) => e.domains.some((x) => x.id === d.id && x.accounts.some((y) => y.id === a.id)));
  }
  const DOTS = '•'.repeat(100);   // 잠근 계정의 빈 칸 표시: 칸 끝까지 채워 자릿수를 숨긴다
  const LOCK_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="11" width="14" height="9" rx="2" fill="currentColor"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>';
  const UNLOCK_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 7.5-2"/></svg>';

  // ── 사본 만들기 ──
  function makeDraft(p) {
    return {
      name: p.name, baseDomain: p.baseDomain || '', description: p.description || '',
      visitCheck: p.visitCheck !== false,
      color: p.color || '',
      envs: p.envs.map((e) => ({
        id: e.id, name: e.rawName, color: e.color, palette: e.palette,
        domains: e.domains.map((d) => ({
          id: d.id, alias: d.alias, ssl: d.ssl, useBase: d.useBase, sub: d.sub, showInSidebar: d.showInSidebar,
          swaggerAuth: !!d.swaggerAuth, tokenPrefix: d.tokenPrefix ?? 'Bearer', tokenKey: d.tokenKey || '', tokenPath: d.tokenPath || '',
          // 계정: 아이디 + 비밀번호 (비밀번호도 [저장] 할 때 함께 저장)
          // 잠근 계정은 값을 받지 않는다 (pw: null = 건드리지 않음, hasPw = 저장돼 있음)
          accounts: d.accounts.map((a) => ({ name: a.name, id: a.id, pw: a.locked ? null : (d.passwords || {})[a.id] || '',
                                             locked: !!a.locked, hasPw: !!a.hasPw, enabled: a.enabled !== false, http: !!a.http })),
          uris: d.uris.map((u) => ({ ...cloneUri(u), id: u.id })),   // 기존 URI 는 id 유지
        })),
      })),
    };
  }

  /** URI 복제 (새 id) */
  function cloneUri(u) {
    return { id: null, alias: u.alias, path: u.path, showInSidebar: u.showInSidebar !== false,
             params: u.params.map((x) => ({ ...x })) };
  }

  /** 도메인 복제: 구성 + URI. 기본은 앞부분(서브 도메인)을 비우고 계정을 뺀다.
   *  full 이면 서브 도메인과 계정(비밀번호·사용 체크 포함)까지 그대로 가져온다 (환경 추가, 다른 환경 탭으로 끌어놓기). */
  function cloneDomain(d, full = false) {
    return { id: null, alias: d.alias, ssl: d.ssl, useBase: d.useBase, sub: full ? d.sub : '', showInSidebar: d.showInSidebar,
             swaggerAuth: !!d.swaggerAuth, tokenPrefix: d.tokenPrefix ?? 'Bearer', tokenKey: d.tokenKey || '', tokenPath: d.tokenPath || '',
             // 값을 가져올 수 없는 잠근 계정(pw: null)은 따라가지 않는다
             accounts: full ? d.accounts.filter((a) => a.pw !== null).map((a) => ({ name: a.name, id: a.id, pw: a.pw, locked: !!a.locked, enabled: a.enabled !== false, http: !!a.http })) : [],
             uris: d.uris.map(cloneUri) };
  }

  function currentEnv() { return draft.envs.find((e) => e.id === envID) || draft.envs[0]; }

  /** 화면에 보일 주소 (Swift 규칙과 같게: 대표 도메인 사용 → 앞부분 + 대표 도메인 그대로 이어 붙임) */
  function originOf(d) {
    const sub = d.sub.trim();
    const base = draft.baseDomain.trim();
    const host = d.useBase ? (base ? sub + base : '') : sub;
    return host ? `${d.ssl ? 'https' : 'http'}://${host}` : '';
  }

  function setDirty(v = true) {
    if (dirty !== v) post('dirty', { dirty: v });   // 탭·창 닫기 확인용으로 앱에 알린다
    dirty = v;
    $('save').disabled = !v;
    $('dirtyMark').hidden = !v;
    $('error').hidden = true;
  }

  // ── 그리기 ──
  function render() {
    $('back').textContent = latest.name;
    document.title = tr('{name} Settings', { name: latest.name });
    $('fName').value = draft.name;
    $('fBase').value = draft.baseDomain;
    $('fDesc').value = draft.description;
    $('fVisit').checked = draft.visitCheck;
    $('fColor').value = draft.color || '#8e8e93';
    $('fColorBox').classList.toggle('none', !draft.color);   // 색 없음 = 흰 바탕 + 빨간 사선
    $('dangerZone').hidden = !!latest.isDefault;   // Default 는 지울 수 없다
    $('projectExport').disabled = !!latest.isDefault;   // Default 는 내보내지 않는다 (숨기지 않고 비활성)
    renderEnv();   // closed 면 끝에서 잠근다
  }

  /** 선택한 환경 탭이 가로 스크롤 밖이면 보이게 (페이지는 스크롤하지 않는다) */
  function scrollActiveTabIntoView() {
    const box = $('envTabs');
    const tab = box.querySelector('.env-tab.active');
    if (!tab) return;
    if (tab.offsetLeft < box.scrollLeft) box.scrollLeft = tab.offsetLeft;
    else if (tab.offsetLeft + tab.offsetWidth > box.scrollLeft + box.clientWidth) box.scrollLeft = tab.offsetLeft + tab.offsetWidth - box.clientWidth;
  }

  // 위쪽 고정 줄 높이를 환경 탭 줄의 고정 위치(top)로 쓴다
  const stickyTop = document.querySelector('.set-sticky');
  const syncStickyHeight = () => document.documentElement.style.setProperty('--set-sticky-h', stickyTop.offsetHeight + 'px');
  new ResizeObserver(syncStickyHeight).observe(stickyTop);
  syncStickyHeight();

  function renderEnv() {
    const env = currentEnv();
    envID = env.id;
    $('envTabs').replaceChildren(...draft.envs.map(envTab), addEnvTab());
    scrollActiveTabIntoView();
    $('fEnvName').value = env.name;
    $('envColor').querySelector('i').style.background = env.color;
    $('swatches').hidden = true;
    disarmDelete();   // 환경을 바꾸거나 다시 그리면 확인 상태 해제
    $('envDelete').disabled = draft.envs.length <= 1;
    $('envDelete').title = draft.envs.length <= 1 ? tr('A project needs at least one env') : '';
    $('domains').replaceChildren(...env.domains.map((d) => domainCard(env, d)));
    const anyOpen = env.domains.some((d) => !folded.has(d));
    $('foldAll').textContent = anyOpen ? tr('Collapse All') : tr('Expand All');
    $('foldAll').disabled = env.domains.length === 0;
    if (env.domains.length === 0) $('domains').append(note(tr('No domains')));
    lockIfClosed();
  }

  /** closed 프로젝트: 삭제와 환경 이동(탭)만. 나머지 입력·버튼은 모두 끈다. */
  function lockIfClosed() {
    const closed = !!latest?.closed;
    $('closedNote').hidden = !closed;
    // 삭제는 closed 만: 아니면 버튼을 끄고 안내 문구를 보인다
    $('projectDelete').disabled = !closed;
    $('deleteNote').hidden = !closed;
    $('deleteHint').hidden = closed;
    if (!closed) {
      // 화면이 열린 채 closed 가 풀린 경우: 고정 입력 칸을 다시 켠다 (나머지는 다시 그려져서 켜져 있음)
      for (const id of ['fName', 'fBase', 'fDesc', 'fVisit', 'fColor', 'fEnvName', 'envColor', 'domainAdd']) $(id).disabled = false;
      return;
    }
    const allowed = (el) => el.id === 'back' || el.id === 'backList' || el.id === 'projectDelete' || el.id === 'projectExport'
      || (el.classList.contains('env-tab') && !el.classList.contains('add'));
    for (const el of document.querySelectorAll('.settings input, .settings textarea, .settings button, .settings select')) {
      if (!allowed(el)) el.disabled = true;
    }
  }

  function envTab(env) {
    const b = document.createElement('button');
    b.className = 'env-tab' + (env.id === envID ? ' active' : '');
    const dot = dragHandle(b, { kind: 'env', env }, document.createElement('i'));   // 색 동그라미가 드래그 핸들
    dot.style.background = env.color || 'var(--no-env)';
    const s = document.createElement('span');
    s.textContent = env.name || tr('(no name)');
    b.append(dot, s);
    b.title = env.name;
    b.addEventListener('click', () => { envID = env.id; renderEnv(); });
    // 서비스를 다른 환경 탭에 끌어놓으면 그 환경 맨 끝에 복사하고 그 환경으로 넘어간다 (지금 환경 탭은 대상 아님)
    bindDrop(b, (s) => s.kind === 'domain' && s.env !== env && 'copy', (s) => {
      const copy = cloneDomain(s.d, true);
      env.domains.push(copy);
      envID = env.id;
      queueMicrotask(() => flashDomain(copy));
    }, true);
    // 환경 탭끼리: 순서 바꾸기 (왼쪽 절반 = 앞, 오른쪽 절반 = 뒤)
    b._env = env;
    bindDrop(b, (s) => s.kind === 'env' && s.env !== env && 'move', (s, after) => moveEnv(s.env, env, after), false, true);
    return b;
  }

  function moveEnv(src, target, after) {
    draft.envs.splice(draft.envs.indexOf(src), 1);
    draft.envs.splice(draft.envs.indexOf(target) + (after ? 1 : 0), 0, src);
  }

  // 탭 사이 빈 틈에 놓아도 가장 가까운 탭 기준으로 받는다 (탭 위는 각 탭이 직접 처리)
  function gapTarget(e) {
    if (drag?.kind !== 'env' || e.target.closest('.env-tab')) return null;
    let best = null, bestD = Infinity;
    for (const t of $('envTabs').querySelectorAll('.env-tab:not(.add)')) {
      if (t._env === drag.env) continue;
      const r = t.getBoundingClientRect();
      const dx = Math.max(r.left - e.clientX, 0, e.clientX - r.right), dy = Math.max(r.top - e.clientY, 0, e.clientY - r.bottom);
      const d = dy * 1000 + dx;   // 같은 줄을 우선
      if (d < bestD) { bestD = d; best = t; }
    }
    if (!best) return null;
    const r = best.getBoundingClientRect();
    return { tab: best, after: e.clientX > r.left + r.width / 2 };
  }
  $('envTabs').addEventListener('dragover', (e) => {
    const g = gapTarget(e);
    if (!g) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    clearMarks();
    g.tab.classList.add(g.after ? 'drop-after' : 'drop-before');
  });
  $('envTabs').addEventListener('drop', (e) => {
    const g = gapTarget(e);
    if (!g) return;
    e.preventDefault();
    const src = drag.env;
    drag = null;
    delete document.body.dataset.drag;
    clearMarks();
    moveEnv(src, g.tab._env, g.after);
    setDirty();
    renderEnv();
  });

  function addEnvTab() {
    const b = document.createElement('button');
    b.className = 'env-tab add';
    b.textContent = tr('+ Env');
    b.addEventListener('click', openEnvModal);
    return b;
  }

  // ── 환경 추가 (복제할 환경·도메인 선택) ──
  function openEnvModal() {
    $('newEnvName').value = '';
    $('newEnvError').hidden = true;
    const sel = $('newEnvSource');
    sel.replaceChildren(new Option(tr('Empty env'), ''), ...draft.envs.map((e) => new Option(e.name || tr('(no name)'), e.id)));
    sel.value = currentEnv().id;   // 지금 보던 환경을 기본으로
    renderEnvDomains();
    $('envModal').hidden = false;
    $('newEnvName').focus();
  }

  function renderEnvDomains() {
    const src = draft.envs.find((e) => e.id === $('newEnvSource').value);
    const box = $('newEnvDomains');
    box.replaceChildren(...(src ? src.domains.map((d, i) => {
      const l = document.createElement('label');
      l.className = 'opt';
      const c = document.createElement('input');
      c.type = 'checkbox'; c.checked = true; c.dataset.index = i;
      l.append(c, ` ${d.alias || originOf(d) || tr('Domain not set')} · ${tr('{n} URIs', { n: d.uris.length })}`);
      return l;
    }) : []));
    box.hidden = !src || src.domains.length === 0;
  }

  $('newEnvSource').addEventListener('change', renderEnvDomains);
  $('newEnvCancel').addEventListener('click', () => { $('envModal').hidden = true; });
  $('newEnvAdd').addEventListener('click', () => {
    const name = $('newEnvName').value.trim();
    const err = !name ? tr('Enter an env name')
      : draft.envs.some((e) => e.name.trim().toLowerCase() === name.toLowerCase()) ? tr('An env with this name already exists') : null;
    if (err) { $('newEnvError').textContent = err; $('newEnvError').hidden = false; return; }
    const src = draft.envs.find((e) => e.id === $('newEnvSource').value);
    const picked = [...$('newEnvDomains').querySelectorAll('input:checked')].map((c) => src.domains[+c.dataset.index]);
    const def = palettes[draft.envs.length % palettes.length] || {};   // 기본 색: 순서대로
    const env = {
      id: 'new-' + Math.random(), name, color: def.hex, palette: def.key,
      domains: picked.map((d) => cloneDomain(d, true)),   // 환경 추가는 서브 도메인·계정까지 복사
    };
    draft.envs.push(env);
    envID = env.id;
    $('envModal').hidden = true;
    setDirty();
    renderEnv();
  });
  $('newEnvName').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('newEnvAdd').click(); });

  // ── 도메인 묶음 (왼쪽, 편집) — 부품: 머리 · URI 머리 · URI 행 · 계정 머리 · 계정 행 ──

  /** 비교가 아닐 때: 부품을 한 카드에 쌓는다 */
  function domainCard(env, d) {
    const card = div('domain-card');
    card.dataset.domain = '';
    card._domain = d;
    card.append(domainHead(env, d));
    bindDomainDrop(card, env, d);
    if (folded.has(d)) {
      // 접힌 서비스도 URI 를 끌어다 놓을 수 있다 (맨 앞에 이동/복사)
      bindDrop(card, (s) => s.kind === 'uri' && live(d) && (s.d === d ? 'move' : 'copy'), (s) => dropUri(s, d, 0, false, true), true);
      return card;
    }
    const ut = div('dc-table');
    ut.append(...d.uris.map((u) => uriRow(d, u)));
    const at = div('dc-table');
    at.append(...d.accounts.map((_, k) => accRow(d, k)));
    if (d.swaggerAuth) card.append(authRow(d));   // 접으면 함께 접힌다
    card.append(uriHead(env, d), ut, accHead(d), at);
    return card;
  }

  /** 도메인 머리: 윗줄 = 핸들 · 이름 · 앞부분(또는 host) · 주소 · 삭제 / 아랫줄 = 체크 옵션 */
  function domainHead(env, d) {
    const box = div('dc-headbox');
    const row = div('dc-row dc-top');
    const alias = input(d.alias, (v) => { d.alias = v; });
    alias.classList.add('w-alias');
    const preview = span('dc-origin', originOf(d));
    const sync = () => { preview.textContent = originOf(d); preview.title = originOf(d); };
    const sub = input(d.sub, (v) => { d.sub = v; sync(); });
    sub.classList.add('w-sub');
    sync();
    row.append(dragHandle(() => box.closest('.domain-card') || box, { kind: 'domain', env, d }), alias, sub, preview, summaryBox(d),
      smallBtn(tr('Delete'), (e) => confirmDelete(e.currentTarget, () => { env.domains.splice(env.domains.indexOf(d), 1); setDirty(); renderEnv(); }), 'danger keep'));
    const checks = div('dc-row dc-checks has-handle');
    checks.append(
      check('SSL', d.ssl, (v) => { d.ssl = v; sync(); }),
      check(tr('Use base domain'), d.useBase, (v) => { d.useBase = v; sync(); }),
      check(tr('Active'), d.showInSidebar, (v) => { d.showInSidebar = v; renderEnv(); }, 'keep'),   // 해제하면 사이드바·프로젝트 화면에서 빠지고 편집 금지
      check('Swagger Authorize', d.swaggerAuth, (v) => { d.swaggerAuth = v; renderEnv(); }),   // 켜면 아래에 토큰 줄이 열린다 (값은 꺼도 남는다)
      spacer(), foldBtn(d));
    box.append(row, checks);
    return freeze(box, d);
  }

  /** Swagger Authorize 줄 (체크했을 때만, 접으면 함께 접힌다): 이 서비스 페이지(스웨거 등)의 요청에
   *  `Authorization: <Prefix> <토큰>` 을 덧붙인다. 토큰은 쿠키(Key)에서 읽고, Path 가 있으면 값(JWT·JSON)의 안쪽 값을 쓴다.
   *  "Bearer Token" · "Token Cookie" 는 지금은 고정 글자 (방식·출처가 늘면 선택 박스로). */
  function authRow(d) {
    const row = div('dc-row dc-auth has-handle');
    const prefix = input(d.tokenPrefix, (v) => { d.tokenPrefix = v.trim(); });
    prefix.classList.add('w-tokenprefix');
    prefix.title = tr('Sent as "Authorization: <Prefix> <token>". Empty = the token only.');
    const key = input(d.tokenKey, (v) => { d.tokenKey = v.trim(); key.classList.toggle('need', !d.tokenKey); });
    key.classList.add('w-tokenkey');
    key.classList.toggle('need', !d.tokenKey);   // 비어 있으면 헤더를 붙이지 않는다
    key.placeholder = tr('Key');
    key.title = tr('Cookie name that holds the token');
    const path = input(d.tokenPath, (v) => { d.tokenPath = v.trim(); });
    path.classList.add('w-tokenpath');
    path.placeholder = tr('Path (optional)');
    path.title = tr('When the cookie value is a JWT or JSON, use this inner field as the token (e.g. user.accessToken)');
    row.append(span('dc-label', 'Bearer Token'), span('dc-label', 'Prefix'), prefix, span('dc-label', 'Token'), span('', 'Cookie'), key, path);
    return freeze(row, d);
  }

  /** 접힘과 상관없이 항상 보이는 요약: 전체 (활성/비활성) — URI | Account. 활성 = 체크한 것 */
  function summaryBox(d) {
    const box = div('dc-summary');
    const uris = d.uris, accs = d.accounts;
    const part = (n, a, one, many) => {
      const s = span('dc-label', tr(n === 1 ? one : many, { n, a, i: n - a }));
      s.title = tr('Total {n} · Active {a} · Inactive {i}', { n, a, i: n - a });
      return s;
    };
    box.append(
      part(uris.length, uris.filter((u) => u.showInSidebar !== false).length, '{n} ({a}/{i}) URI', '{n} ({a}/{i}) URIs'),
      div('dc-sep'),
      part(accs.length, accs.filter((a) => a.enabled !== false).length, '{n} ({a}/{i}) Account', '{n} ({a}/{i}) Accounts'));
    return box;
  }

  /** 사용(Active) 해제한 서비스는 편집 금지: 입력란·버튼을 잠근다. 'keep' 표시한 것(Active 체크·접기·삭제)만 남긴다. */
  const live = (d) => !!d.showInSidebar;
  function freeze(el, d) {
    if (live(d)) return el;
    for (const c of el.querySelectorAll('input, button, textarea, select')) {
      if (!c.closest('.keep')) c.disabled = true;
    }
    return el;
  }

  function uriHead(env, d) {
    const h = div('dc-head');
    h.append(span('dc-label', 'URI'), spacer(),
      smallBtn(tr('+ URI'), () => {
        d.uris.push({ id: null, alias: '', path: '/', showInSidebar: true, params: [] });
        setDirty(); renderEnv();
      }));
    bindDrop(h, (s) => s.kind === 'uri' && live(d) && (s.d === d ? 'move' : 'copy'), (s) => dropUri(s, d, 0, false, true), true);
    return freeze(h, d);
  }

  /** URI 행: 맨 앞 드래그 핸들 · 사이드바 표시 체크 (도메인이 사이드바에 없으면 꺼짐) · 이름 · path · parameter · ×
   *  핸들로 같은 도메인 안에서는 순서 이동, 다른 도메인 URI 줄 위에 놓으면 그 위치에 복사. */
  function uriRow(d, u) {
    const row = div('uri-row');
    const side = document.createElement('input');
    side.type = 'checkbox';
    side.className = 'side-check';
    side.checked = u.showInSidebar !== false;
    side.disabled = !d.showInSidebar;
    side.title = tr('Active');
    side.addEventListener('change', () => { u.showInSidebar = side.checked; setDirty(); renderEnv(); });   // 요약 숫자도 바로 바뀌게
    const alias = input(u.alias, (v) => { u.alias = v; });
    alias.classList.add('w-alias');
    const path = input(u.path, (v) => { u.path = v; });
    path.classList.add('w-path');
    const params = div('params');
    u.params.forEach((p, k) => {
      const pr = div('param');
      const key = input(p.key, (v) => { p.key = v; });
      const val = input(p.value, (v) => { p.value = v; });
      const desc = input(p.desc, (v) => { p.desc = v; });
      key.classList.add('w-key'); val.classList.add('w-val'); desc.classList.add('w-desc');
      desc.title = tr('Value description');
      // 체크 = 주소에 적용, 해제 = 미적용 (목록에는 남고 입력란은 흐리게, 편집은 가능)
      const use = document.createElement('input');
      use.type = 'checkbox';
      use.className = 'side-check';
      use.checked = p.enabled !== false;
      use.title = tr('Active');
      pr.classList.toggle('off', !use.checked);
      use.addEventListener('change', () => { p.enabled = use.checked; pr.classList.toggle('off', !use.checked); setDirty(); });
      pr.append(dragHandle(pr, { kind: 'param', d, u, p }), use, key, val, desc, xBtn(() => { u.params.splice(u.params.indexOf(p), 1); setDirty(); renderEnv(); }));
      // 같은 URI 안이면 순서 이동, 다른 URI(서비스 상관없이) 로 끌면 복사
      bindDrop(pr, (s) => s.kind === 'param' && live(d) && (s.u === u ? 'move' : 'copy'), (s, after) => dropParam(s, u, u.params.indexOf(p), after));
      params.append(pr);
    });
    const tail = div('row-tail');
    const addParam = smallBtn('+', () => { u.params.push({ key: '', value: '', desc: '', enabled: true }); setDirty(); renderEnv(); }, 'add');
    addParam.title = tr('Add parameter');
    const copyUri = smallBtn('→', (e) => openCopy(d, 'uri', u, e.currentTarget.closest('.uri-row')), 'add');
    copyUri.title = tr('Copy to other service');
    tail.append(addParam, copyUri, xBtn(() => { d.uris.splice(d.uris.indexOf(u), 1); setDirty(); renderEnv(); }));
    // 첫 줄: 핸들 · 체크 · 이름 · path · + × / 둘째 줄: parameter
    const top = div('uri-top');
    top.append(dragHandle(row, { kind: 'uri', d, u }), side, alias, path, tail);
    bindDrop(row, (s) => s.kind === 'uri' && live(d) && (s.d === d ? 'move' : 'copy'), (s, after) => dropUri(s, d, d.uris.indexOf(u), after));
    // URI 줄에 파라미터를 놓으면 그 URI 의 맨 앞에 (파라미터가 없는 URI 도 받는다)
    bindDrop(top, (s) => s.kind === 'param' && live(d) && (s.u === u ? 'move' : 'copy'), (s) => dropParam(s, u, 0, false, true), true);
    row.append(top, params);
    return freeze(row, d);
  }

  function accHead(d) {
    const h = div('dc-head');
    h.append(span('dc-label', tr('Accounts')), spacer(),
      smallBtn(tr('+ Account'), () => { d.accounts.push({ name: '', id: '', pw: '', enabled: true }); setDirty(); renderEnv(); }));
    return freeze(h, d);
  }

  /** 계정 행 (세로, URI 와 연결하지 않음): 아이디 · 비밀번호 (가려서 표시, 눈 버튼으로 보기) */
  function accRow(d, k) {
    const a = d.accounts[k];
    const row = div('acc-row');
    const name = input(a.name, (v) => { a.name = v; });
    name.classList.add('w-accname');
    name.placeholder = tr('Name');
    const locked = !!a.locked;
    const id = input(a.id, (v) => { a.id = v; });
    id.classList.add('w-acc');
    id.placeholder = tr('ID');
    id.disabled = locked;   // 잠근 계정은 아이디를 바꿀 수 없다 (풀고 바꾼다)
    // 잠금 여부와 관계없이 저장된 값은 화면에 두지 않는다: 점으로 칸을 꽉 채워 보이고(자릿수를 숨김),
    // 새로 입력하면 입력한 자릿수만 점으로 보이며(수정했다는 표시) 저장하면 입력한 값이 비밀번호가 된다. 모두 지우면 원래대로.
    const edited = () => 'pwOrig' in a && a.pw !== a.pwOrig;
    const pw = input(edited() ? a.pw : '', (v) => {
      if (!('pwOrig' in a)) a.pwOrig = a.pw;   // 처음 입력할 때의 값을 기억 (잠근 계정은 null)
      a.pw = v === '' ? a.pwOrig : v;
      placeholder();
    });
    pw.classList.add('w-pw', 'masked');
    const placeholder = () => { pw.placeholder = a.hasPw || a.pw ? DOTS : tr('Password'); };
    placeholder();
    pw.autocomplete = 'off';
    const lock = document.createElement('button');
    lock.className = 'x-btn lock' + (locked ? ' on' : '');
    lock.innerHTML = locked ? LOCK_SVG : UNLOCK_SVG;
    lock.title = locked ? tr('Locked: authenticate to unlock') : tr('Lock: authenticate to show or fill the password');
    lock.disabled = !locked && !authAvailable;
    // 잠금은 저장 버튼과 관계없이 바로 적용한다. 아직 저장하지 않은 계정·도메인은 [저장] 때 함께 적용된다.
    const setLock = (on) => {
      a.locked = on;
      if (isSaved(d, a)) post('setLock', { domainID: d.id, account: a.id, locked: on });
      else setDirty();
      renderEnv();
    };
    lock.addEventListener('click', () => {
      if (!locked) { setLock(true); return; }   // 잠그기는 바로, 풀기는 인증 뒤에
      reveal(d, a, (v) => {
        if (v === null) return;
        if (a.pw === null) a.pw = v;
        setLock(false);
      });
    });
    const eye = document.createElement('button');
    eye.className = 'x-btn eye';
    const eyeSvg = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>';
    eye.innerHTML = eyeSvg + '<span class="eye-on">' + eyeSvg + '</span>';
    eye.title = tr('Show password');
    // 평문은 10초만 보이고 다시 가린다 (버튼 배경이 시계처럼 회색으로 돌아간다)
    const setShown = (shown) => {
      pw.classList.toggle('masked', !shown);
      if (!shown) pw.value = edited() ? a.pw : '';   // 다시 가릴 때 저장된 값은 화면에서 비운다 (입력한 값은 그대로)
      placeholder();
      eye.classList.remove('on');
      if (shown) { void eye.offsetWidth; eye.classList.add('on'); }   // 애니메이션 처음부터
      eye.title = shown ? tr('Hide password') : tr('Show password');
    };
    eye.addEventListener('click', () => {
      if (!pw.classList.contains('masked')) { setShown(false); return; }
      if (!locked) { pw.value = a.pw ?? ''; setShown(true); return; }
      reveal(d, a, (v) => {   // 잠근 계정: 인증 뒤에 보인다
        if (v === null) return;
        pw.value = a.pw !== null ? a.pw : v;
        setShown(true);
      });
    });
    eye.addEventListener('animationend', () => setShown(false));
    const tail = div('row-tail');
    const copyAcc = smallBtn('→', (e) => openCopy(d, 'acc', a, e.currentTarget.closest('.acc-row')), 'add');
    copyAcc.title = tr('Copy to other service');
    copyAcc.disabled = !a.id.trim() || locked;   // 아이디가 비거나 잠근 계정은 복사할 수 없다
    id.addEventListener('input', () => { copyAcc.disabled = !a.id.trim() || locked; });
    tail.append(copyAcc, xBtn(() => { d.accounts.splice(k, 1); setDirty(); renderEnv(); }));
    // 체크 = 자동 채우기에 사용, 해제 = 제외 (목록에는 남고 입력란은 흐리게)
    const use = document.createElement('input');
    use.type = 'checkbox';
    use.className = 'side-check';
    use.checked = a.enabled !== false;
    use.title = tr('Active');
    row.classList.toggle('off', !use.checked);
    use.addEventListener('change', () => { a.enabled = use.checked; row.classList.toggle('off', !use.checked); setDirty(); renderEnv(); });
    // HTTP 인증용 = 인증 창(Basic 등)의 계정 목록에만 나온다 (로그인 칸 목록에서는 빠진다)
    const http = document.createElement('button');
    http.className = 'ghost small http-btn' + (a.http ? ' on' : '');
    http.textContent = 'HTTP';
    http.title = tr('For HTTP authentication (shown in the sign-in prompt instead of login fields)');
    http.addEventListener('click', () => { a.http = !a.http; http.classList.toggle('on', a.http); setDirty(); });
    row.append(dragHandle(row, { kind: 'acc', d, a }), use, name, id, pw, lock, eye, http, tail);
    bindDrop(row, (s) => s.kind === 'acc' && s.d === d && live(d) && 'move', (s, after) => {
      const i = d.accounts.indexOf(s.a);
      d.accounts.splice(i, 1);
      let to = d.accounts.indexOf(a) + (after ? 1 : 0);
      d.accounts.splice(to, 0, s.a);
    });
    return freeze(row, d);
  }

  /** 삭제 확인 (환경·서비스): 첫 클릭은 문구만 'Sure?' 로 바꾸고, 다음 클릭에서 삭제.
   *  바로 이어진 클릭(더블클릭)은 무시, 3초 뒤·다시 그릴 때·다른 삭제 버튼을 누를 때 원래대로. */
  function disarmDelete() {
    if (!armed) return;
    clearTimeout(armed.timer);
    armed.btn.textContent = armed.label;
    armed.btn.classList.remove('armed');
    armed = null;
  }
  function confirmDelete(btn, onConfirm, label = tr('Sure?')) {
    if (armed?.btn !== btn) {
      disarmDelete();
      armed = { btn, label: btn.textContent, at: Date.now(), timer: setTimeout(disarmDelete, 3000) };
      btn.textContent = label;
      btn.classList.add('armed');   // 3초간 깜빡임 (타이머 끝나면 함께 해제)
      return;
    }
    if (Date.now() - armed.at < 500) return;   // 더블클릭은 삭제가 아니라 문구 변경만
    disarmDelete();
    onConfirm();
  }

  // ── 드래그 핸들: 서비스(같은 환경 안 순서) · URI 줄(같은 서비스 = 순서, 다른 서비스 = 복사) · 계정 줄(같은 서비스 안 순서) ──
  let drag = null;   // { kind: 'domain'|'uri'|'param'|'acc', ... }

  function bindDomainDrop(el, env, d) {
    bindDrop(el, (s) => s.kind === 'domain' && s.env === env, (s, after) => {
      env.domains.splice(env.domains.indexOf(s.d), 1);
      env.domains.splice(env.domains.indexOf(d) + (after ? 1 : 0), 0, s.d);
      queueMicrotask(() => flashDomain(s.d));   // 다시 그린 뒤 보이게 스크롤
    });
  }

  function dragHandle(row, state, h = span('drag-handle', '⠿')) {
    h.classList.add('drag-handle');
    h.draggable = true;
    h.title = tr('Drag to reorder');
    h.addEventListener('dragstart', (e) => {
      if (latest?.closed || (state.kind !== 'domain' && state.d && !live(state.d))) { e.preventDefault(); return; }
      drag = state;
      document.body.dataset.drag = state.kind;
      e.dataTransfer.effectAllowed = 'copyMove';
      e.dataTransfer.setData('text/plain', '');
      const el = typeof row === 'function' ? row() : row;
      e.dataTransfer.setDragImage(el, 12, 12);
      el.classList.add('dragging');
      h._el = el;
    });
    h.addEventListener('dragend', () => { drag = null; delete document.body.dataset.drag; h._el?.classList.remove('dragging'); clearMarks(); });
    return h;
  }

  function clearMarks() {
    for (const el of document.querySelectorAll('.drop-before, .drop-after')) el.classList.remove('drop-before', 'drop-after');
  }

  /** accept(state) → false | 'move' | 'copy'. after: 대상 줄의 아래쪽 절반에 놓았는가 (headMode 면 항상 맨 앞 삽입) */
  function bindDrop(el, accept, onDrop, headMode = false, horizontal = false) {
    const isAfter = (e) => { const r = el.getBoundingClientRect(); return horizontal ? e.clientX > r.left + r.width / 2 : e.clientY > r.top + r.height / 2; };
    el.addEventListener('dragover', (e) => {
      const mode = drag && accept(drag);
      if (!mode) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = mode;
      clearMarks();
      el.classList.add(headMode ? 'drop-after' : isAfter(e) ? 'drop-after' : 'drop-before');
    });
    el.addEventListener('dragleave', (e) => { if (!el.contains(e.relatedTarget)) el.classList.remove('drop-before', 'drop-after'); });
    el.addEventListener('drop', (e) => {
      if (!drag || !accept(drag)) return;
      e.preventDefault();
      const s = drag, after = isAfter(e);
      drag = null;
      delete document.body.dataset.drag;
      clearMarks();
      onDrop(s, after);
      setDirty();
      renderEnv();
    });
  }

  /** 파라미터 놓기: 같은 URI 면 이동, 다른 URI 면 그 위치에 복사. idx = 대상 파라미터 번호, 머리(head)면 맨 앞 */
  function dropParam(s, u, idx, after, head = false) {
    const list = u.params;
    const at = head ? 0 : idx + (after ? 1 : 0);
    if (s.u === u) {
      const i = list.indexOf(s.p);
      list.splice(i, 1);
      list.splice(at > i ? at - 1 : at, 0, s.p);
    } else {
      list.splice(at, 0, { ...s.p });
    }
  }

  /** URI 놓기: 같은 도메인이면 이동, 다른 도메인이면 그 위치에 복사. idx = 대상 줄 번호, 머리(head)면 맨 앞 */
  function dropUri(s, d, idx, after, head = false) {
    const list = d.uris;
    const at = head ? 0 : idx + (after ? 1 : 0);
    if (s.d === d) {
      const i = list.indexOf(s.u);
      list.splice(i, 1);
      list.splice(at > i ? at - 1 : at, 0, s.u);
    } else {
      list.splice(at, 0, cloneUri(s.u));
    }
  }

  /** 옮긴 도메인 묶음이 보이게 스크롤하고 잠깐 강조 */
  function flashDomain(d) {
    const el = [...$('domains').querySelectorAll('[data-domain]')].find((x) => x._domain === d);
    el?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    el?.classList.add('moved');
    setTimeout(() => el?.classList.remove('moved'), 800);
  }

  /** 서비스 접기 버튼 (텍스트, Delete 와 같은 크기) */
  function foldBtn(d) {
    return smallBtn(folded.has(d) ? tr('Expand') : tr('Collapse'), () => {
      if (folded.has(d)) folded.delete(d); else folded.add(d);
      renderEnv();
    }, 'keep');
  }

  // ── 작은 부품 ──
  function div(cls) { const e = document.createElement('div'); e.className = cls; return e; }
  function span(cls, text) { const e = document.createElement('span'); e.className = cls; e.textContent = text; return e; }
  function spacer() { return span('spacer', ''); }
  function note(text) { const p = document.createElement('p'); p.className = 'uri-empty'; p.textContent = text; return p; }
  function input(value, onInput) {
    const i = document.createElement('input');
    i.type = 'text'; i.value = value ?? ''; i.spellcheck = false;
    i.addEventListener('input', () => { onInput(i.value); setDirty(); });
    return i;
  }
  function check(label, value, onChange, extra = '') {
    const l = document.createElement('label');
    l.className = 'check' + (extra ? ' ' + extra : '');
    const c = document.createElement('input');
    c.type = 'checkbox'; c.checked = value;
    c.addEventListener('change', () => { onChange(c.checked); setDirty(); });
    l.append(c, ' ' + label);
    return l;
  }
  function smallBtn(label, onClick, extra) {
    const b = document.createElement('button');
    b.className = 'ghost small' + (extra ? ' ' + extra : '');
    b.textContent = label;
    b.addEventListener('click', onClick);
    return b;
  }
  function xBtn(onClick, title = tr('Delete')) {
    const b = document.createElement('button');
    b.className = 'x-btn danger';
    b.textContent = '×';
    b.title = title;
    b.addEventListener('click', () => confirmDelete(b, onClick, '?'));   // 첫 클릭 = ?, 같은 자리에서 다시 클릭하면 삭제
    return b;
  }

  // ── 기본 항목 입력 ──
  const bind = (id, key, prop = 'value') => $(id).addEventListener(prop === 'value' ? 'input' : 'change', () => {
    draft[key] = $(id)[prop];
    setDirty();
    if (key === 'baseDomain') renderEnv();   // 주소 미리보기 갱신
  });
  bind('fName', 'name'); bind('fBase', 'baseDomain'); bind('fDesc', 'description');
  // 설명은 2줄까지 (줄바꿈 1번)
  $('fDesc').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && $('fDesc').value.includes('\n')) e.preventDefault();
  });
  $('fDesc').addEventListener('input', () => {
    const v = $('fDesc').value, i = v.indexOf('\n');
    if (i >= 0 && v.indexOf('\n', i + 1) >= 0) {
      $('fDesc').value = v.slice(0, i + 1) + v.slice(i + 1).replace(/\n/g, ' ');   // 붙여넣기 등
      draft.description = $('fDesc').value;
    }
  });
  bind('fVisit', 'visitCheck', 'checked');
  // 색상 패널의 사선 칸(투명)을 고르면 alpha 0 으로 온다 → 색 없음. 값 형식(#hex / color(srgb…) / rgba)에 상관없이 canvas 로 읽는다.
  const probe = document.createElement('canvas').getContext('2d', { willReadFrequently: true });
  function readColor(v) {
    probe.clearRect(0, 0, 1, 1);
    probe.fillStyle = '#000';
    probe.fillStyle = v;
    probe.fillRect(0, 0, 1, 1);
    const [r, g, b, a] = probe.getImageData(0, 0, 1, 1).data;
    return a === 0 ? '' : '#' + [r, g, b].map(x => x.toString(16).padStart(2, '0')).join('');
  }
  $('fColor').addEventListener('input', () => {
    draft.color = readColor($('fColor').value);
    $('fColorBox').classList.toggle('none', !draft.color);
    setDirty();
  });
  $('fEnvName').addEventListener('input', () => {
    currentEnv().name = $('fEnvName').value;
    setDirty();
    $('envTabs').replaceChildren(...draft.envs.map(envTab), addEnvTab());
  });
  // ── 환경 색 ──
  $('envColor').addEventListener('click', (e) => {
    e.stopPropagation();
    const env = currentEnv();
    const used = new Set(draft.envs.filter((x) => x !== env).map((x) => x.palette));
    $('swatches').replaceChildren(...palettes.map((p) => {
      const b = document.createElement('button');
      b.className = 'swatch' + (p.key === env.palette ? ' current' : '') + (used.has(p.key) ? ' used' : '');
      b.style.background = p.hex;
      b.title = used.has(p.key) ? tr('Used by another env') : '';
      b.addEventListener('click', () => {
        env.palette = p.key;
        env.color = p.hex;
        setDirty();
        renderEnv();
      });
      return b;
    }));
    $('swatches').hidden = !$('swatches').hidden;
  });
  addEventListener('click', (e) => { if (!e.target.closest('.color-pick')) $('swatches').hidden = true; });

  $('projectExport').addEventListener('click', () => post('exportProject', { projectID }));
  $('projectDelete').addEventListener('click', () => post('deleteProject', { projectID }));

  $('foldAll').addEventListener('click', () => {
    const env = currentEnv();
    const fold = env.domains.some((d) => !folded.has(d));
    for (const d of env.domains) { if (fold) folded.add(d); else folded.delete(d); }
    renderEnv();
  });

  $('envDelete').addEventListener('click', () => {
    if (draft.envs.length <= 1) return;
    confirmDelete($('envDelete'), () => {
      const i = draft.envs.indexOf(currentEnv());
      draft.envs.splice(i, 1);
      envID = draft.envs[Math.min(i, draft.envs.length - 1)].id;   // 같은 자리 유지 (마지막이면 새 마지막)
      setDirty();
      renderEnv();
    });
  });
  // ── 도메인 추가: 빈 도메인 또는 다른 도메인 복제 (이름·SSL·대표 도메인 사용·사이드바·URI, 앞부분 비움, 계정 제외) ──
  $('domainAdd').addEventListener('click', () => {
    const box = $('domainSources');
    const radio = (label, value, checked) => {
      const l = document.createElement('label');
      l.className = 'opt';
      const r = document.createElement('input');
      r.type = 'radio'; r.name = 'domainSource'; r.checked = checked;
      r._source = value;
      l.append(r, label);
      return l;
    };
    box.replaceChildren(radio(' ' + tr('Empty domain (one /)'), null, true));
    for (const e of draft.envs) {
      if (e.domains.length === 0) continue;
      box.append(span('copy-env', e.name));
      for (const d of e.domains) {
        const l = radio(` ${d.alias || tr('Domain')} `, d, false);
        l.append(span('dim', `${originOf(d) || tr('Domain not set')} · ${tr('{n} URIs', { n: d.uris.length })}`));
        box.append(l);
      }
    }
    $('domainModal').hidden = false;
  });
  $('domainCancel').addEventListener('click', () => { $('domainModal').hidden = true; });
  $('domainAddRun').addEventListener('click', () => {
    const src = $('domainSources').querySelector('input:checked')?._source;
    currentEnv().domains.push(src ? cloneDomain(src) : {
      id: null, alias: '', ssl: true, useBase: true, sub: '', showInSidebar: true, swaggerAuth: false, tokenPrefix: 'Bearer', tokenKey: '', tokenPath: '', accounts: [],
      uris: [{ id: null, alias: '', path: '/', showInSidebar: true, params: [] }],   // 새 도메인은 / 하나로 시작
    });
    $('domainModal').hidden = true;
    setDirty();
    renderEnv();
    const cards = $('domains').children;
    cards[cards.length - 1]?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  });

  // ── 검사 · 저장 ──
  function validate() {
    if (!draft.name.trim()) return tr('Enter a project name');
    if (otherNames.has(draft.name.trim().toLowerCase())) return tr('Project name already exists');
    const names = draft.envs.map((e) => e.name.trim());
    if (names.some((n) => !n)) return tr('Enter an env name');
    if (new Set(names.map((n) => n.toLowerCase())).size !== names.length) return tr('Env names must be unique');
    return null;
  }

  function save() {
    const err = validate();
    if (err) { showError(err); return false; }
    const out = JSON.parse(JSON.stringify(draft));
    for (const e of out.envs) {
      if (String(e.id).startsWith('new-')) e.id = null;   // 새 항목은 Swift 가 id 를 만든다
      for (const d of e.domains) d.uris = d.uris.filter(Boolean);   // 비교 중 생긴 빈 자리 제거
    }
    post('saveProject', { projectID, project: out });
    return true;
  }

  function showError(msg) {
    $('error').textContent = msg;
    $('error').hidden = false;
  }

  $('save').addEventListener('click', () => { leaveAfterSave = false; save(); });
  addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); if (dirty) save(); }
  });

  // ── 나가기 (경로: Projects › 프로젝트 이름) ──
  let leaveToList = false;   // true: 프로젝트 목록으로, false: 프로젝트 화면으로
  function leave() { if (leaveToList) post('back'); else post('openProject', { projectID, envID }); }
  function tryLeave(toList) { leaveToList = toList; if (dirty) $('leaveModal').hidden = false; else leave(); }
  $('back').addEventListener('click', () => tryLeave(false));
  $('backList').addEventListener('click', () => tryLeave(true));
  $('leaveCancel').addEventListener('click', () => { $('leaveModal').hidden = true; });
  $('leaveDiscard').addEventListener('click', () => { setDirty(false); leave(); });
  $('leaveSave').addEventListener('click', () => {
    $('leaveModal').hidden = true;
    leaveAfterSave = true;
    if (!save()) leaveAfterSave = false;
  });

  // ── 복사: URI·계정 하나를 다른 서비스로 (URI 는 같은 path, 계정은 같은 아이디면 건너뜀. 사본에만 반영 → 저장해야 확정) ──
  function openCopy(d, kind, item, row) {
    clearCopySrc();
    copySource = { d, kind, item, row };
    row?.classList.add('copy-src');   // 무엇을 눌렀는지 팝업 뒤에서 강조
    const env = draft.envs.find((e) => e.domains.includes(d));
    const acc = kind === 'acc';
    const label = acc ? (item.name && item.name !== item.id ? `${item.name} (${item.id})` : item.id) : (item.alias || item.path);
    $('copyTitle').textContent = acc ? tr('Copy Account') : tr('Copy URI');
    $('copyFrom').textContent = tr('Source: {path}', { path: [env?.name ?? '', d.alias || originOf(d) || tr('Domain'), label].join(' > ') });
    $('copyOverwriteLabel').textContent = acc ? tr('Overwrite name and password of the same ID') : tr('Overwrite parameters of the same path');
    const box = $('copyTargets');
    box.replaceChildren();
    for (const e of draft.envs) {
      const targets = e.domains.filter((t) => t !== d && live(t));   // 사용 안 하는(편집 금지) 서비스는 붙여넣기 대상에서 제외
      if (targets.length === 0) continue;
      box.append(span('copy-env', e.name));
      for (const t of targets) {
        const l = document.createElement('label');
        l.className = 'opt';
        const c = document.createElement('input');
        c.type = 'checkbox';
        c._target = t;
        c.addEventListener('change', syncCopyRun);
        l.append(c, ` ${t.alias || tr('Domain')} `, span('dim', originOf(t) || tr('Domain not set')));
        box.append(l);
      }
    }
    if (!box.children.length) box.append(note(tr('No other domain to paste into')));
    $('copyOverwrite').checked = false;   // 기본은 건너뜀
    syncCopyRun();
    $('copyModal').hidden = false;
  }

  /** 대상을 하나도 고르지 않으면 복사 버튼을 끈다 (기본은 모두 해제) */
  function syncCopyRun() {
    $('copyRun').disabled = !$('copyTargets').querySelector('input:checked');
  }

  function clearCopySrc() { copySource?.row?.classList.remove('copy-src'); }
  $('copyCancel').addEventListener('click', () => { clearCopySrc(); $('copyModal').hidden = true; });
  $('copyRun').addEventListener('click', () => {
    const targets = [...$('copyTargets').querySelectorAll('input:checked')].map((c) => c._target);
    if (!targets.length || !copySource) return;
    // 같은 path(URI) / 같은 아이디(계정): 덮어쓰기 꺼짐 → 건너뜀, 켜짐 → URI 는 parameter 를 모두 지우고 원본 것을 넣고, 계정은 이름·비밀번호를 원본 것으로 (나머지는 그대로)
    const overwrite = $('copyOverwrite').checked;
    const { kind, item } = copySource;
    let added = 0, replaced = 0, skipped = 0;
    for (const target of targets) {
      if (kind === 'acc') {
        const same = target.accounts.find((t) => t.id === item.id);
        if (!same) { target.accounts.push({ name: item.name, id: item.id, pw: item.pw, enabled: item.enabled !== false, http: !!item.http }); added++; }
        else if (overwrite) { same.name = item.name; same.pw = item.pw; same.http = !!item.http; replaced++; }
        else skipped++;
        continue;
      }
      const same = target.uris.find((t) => t && t.path === item.path);
      const params = item.params.map((x) => ({ ...x }));
      if (!same) { target.uris.push({ ...cloneUri(item), params }); added++; }
      else if (overwrite) { same.params = params; replaced++; }
      else skipped++;
    }
    clearCopySrc();
    $('copyModal').hidden = true;
    if (added || replaced) setDirty();
    renderEnv();
    const parts = [tr('{n} added', { n: added })];
    if (replaced) parts.push(tr('{n} overwritten', { n: replaced }));
    if (skipped) parts.push(tr(copySource.kind === 'acc' ? '{n} skipped (same ID)' : '{n} skipped (same path)', { n: skipped }));
    toast(tr('{n} targets: {parts}', { n: targets.length, parts: parts.join(', ') }));
  });

  let toastTimer;
  function toast(msg) {
    const el = $('toast');
    el.textContent = msg;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, 2000);
  }

  // ── Swift → 화면 ──
  window.devlink = {
    render(state) {
      const p = state.projects.find((x) => x.id === projectID);
      if (!p) { post('back'); return; }   // 삭제된 프로젝트 → 목록
      latest = p;
      otherNames = new Set(state.projects.filter((x) => x.id !== projectID).map((x) => x.name.trim().toLowerCase()));
      palettes = state.palettes || palettes;
      authAvailable = state.authAvailable !== false;
      if (dirty) { renderEnv(); return; }   // 편집 중에는 덮어쓰지 않는다
      draft = makeDraft(p);
      render();
    },
    revealed(token, value) {
      const done = pendingReveal.get(token);
      pendingReveal.delete(token);
      if (done) done(value);
    },
    saved() {
      setDirty(false);
      const index = Math.max(0, draft.envs.indexOf(currentEnv()));   // 새 환경은 id 가 바뀌므로 위치로 유지
      draft = makeDraft(latest);
      envID = draft.envs[Math.min(index, draft.envs.length - 1)]?.id;
      if (leaveAfterSave) { leave(); return; }
      render();
      toast(tr('Saved'));
    },
    saveFailed() {
      leaveAfterSave = false;
      showError(tr("Couldn't save. Check the project and env names"));
    },
  };

  post('ready');
})();

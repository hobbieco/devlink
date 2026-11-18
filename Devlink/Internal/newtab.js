// 새 탭: 프로젝트 목록. 값은 Swift 가 render(state) 로 넣어주고, 동작은 post() 로 요청한다.
// 영역: 고정(🏠 Default 첫 칸) / 일반(+ 첫 칸) / closed(− 첫 칸). 상태는 영역을 넘는 드래그로만 바뀐다.
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const pinnedGrid = $('pinnedGrid'), grid = $('grid'), closedGrid = $('closedGrid'), search = $('search');
  const GRIDS = () => [pinnedGrid, grid, closedGrid];
  const toastEl = $('toast'), clearBtn = $('searchClear');
  const saveSearch = () => post('search', { text: search.value });   // 탭이 기억: 프로젝트·설정 화면에 다녀와도 복원

  let state = { projects: [] };
  let drag = null;
  let first = true;
  let suppressClick = false;

  function post(type, data = {}) {
    try { window.webkit.messageHandlers.lh.postMessage(Object.assign({ type }, data)); } catch (e) {}
  }

  const GEAR_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>';

  // ── 목록 ──
  const query = () => search.value.trim().toLowerCase();
  // 이름·base 도메인·설명, 대소문자 무시. Default 는 항상 보인다.
  const matches = (p) => p.isDefault || !query() ||
    [p.name, p.baseDomain, p.description].some((v) => (v || '').toLowerCase().includes(query()));

  /** 순서는 드래그로 정한 순서 그대로 (정렬 없음) */
  function areas() {
    const def = state.projects.filter((p) => p.isDefault && matches(p));
    const pinned = state.projects.filter((p) => p.pinned && !p.isDefault && !p.closed && matches(p));
    const others = state.projects.filter((p) => !p.pinned && !p.isDefault && !p.closed && matches(p));
    const closed = state.projects.filter((p) => p.closed && !p.isDefault && matches(p));
    return { pinned: def.concat(pinned), others, closed };
  }

  /** 드래그는 검색 중이 아닐 때만 */
  function canDrag() { return !query(); }

  function render() {
    post('status', { text: '' });   // 다시 그리면 mouseleave 가 안 오므로 설명을 지운다
    const a = areas();
    pinnedGrid.replaceChildren(...a.pinned.map(card));
    const others = a.others.map(card);
    if (!query()) others.unshift(addCard());
    grid.replaceChildren(...others);
    const closed = a.closed.map(card);
    if (!query()) closed.unshift(minusCard());
    closedGrid.replaceChildren(...closed);
    clearBtn.hidden = !search.value;
  }

  function card(p) {
    const el = document.createElement('article');
    el.className = p.closed ? 'card closed' : 'card';
    el.dataset.id = p.id;
    if (p.isDefault) el.dataset.fixed = 'default';
    else if (canDrag()) el.classList.add('can-drag');

    const head = document.createElement('div');
    head.className = 'head';
    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = p.name;
    name.title = p.name;
    head.append(name);
    // 고정 표시 (설정 버튼 위, 표시 전용): Default 는 집, 고정 프로젝트는 핀
    if (p.isDefault) head.append(mark('🏠', tr('Default project')));
    else if (p.pinned) head.append(mark('📌', tr('Pinned')));
    else if (p.closed) head.append(mark('🔒', tr('Closed')));


    // 대표 도메인 (프로젝트 기본 도메인, 표시만). 없으면 빈 줄.
    const domain = document.createElement('div');
    domain.className = 'domain';
    domain.textContent = p.baseDomain || '';
    if (p.baseDomain) domain.title = p.baseDomain;

    const descRow = document.createElement('div');
    descRow.className = 'desc-row';
    const desc = document.createElement('div');
    desc.className = 'desc';
    desc.textContent = p.description || '';
    if (p.description) desc.title = p.description;
    const gear = document.createElement('button');
    gear.className = 'gear';
    gear.title = tr('Settings');
    gear.innerHTML = GEAR_SVG;
    gear.addEventListener('click', (e) => { e.stopPropagation(); post('openSettings', { projectID: p.id }); });
    descRow.append(desc, gear);

    // 환경 한 줄: 4칸 (나머지 환경은 프로젝트 화면의 환경 탭에서)
    const chips = document.createElement('div');
    chips.className = 'chips';
    // 환경 순서대로 앞 4개. 모자라면 빈 칸 (클릭 안 됨)
    for (let i = 0; i < 4; i++) {
      const env = p.envs[i];
      chips.append(!env ? blankChip() : env.ready ? chip(p, env) : disabledChip(env.name));
    }

    // 프로젝트 색 띠 (탭 아래 띠와 같게: 위 구분선 1 + 색 3). 색이 없어도 같은 높이
    const band = document.createElement('div');
    band.className = 'color-band';
    if (/^#[0-9a-f]{6}$/i.test(p.color || '')) band.style.setProperty('--pc', p.color);

    el.append(head, domain, descRow, chips, band);
    el.addEventListener('click', () => {
      if (suppressClick) { suppressClick = false; return; }
      post('openProject', { projectID: p.id });
    });
    bindDrag(el);
    return el;
  }

  function addCard() {
    const el = document.createElement('button');
    el.className = 'card add-card';
    el.dataset.fixed = 'add';
    el.title = tr('Add project');
    el.innerHTML = '<span>+</span>';
    el.addEventListener('click', openAdd);
    return el;
  }

  /** closed 영역 첫 칸. 끌 수 없고 그 앞에 놓을 수 없다. 여기나 closed 영역에 놓으면 closed.
   *  설명은 마우스를 올린 동안 상태 표시줄에 표시. */
  function minusCard() {
    const el = document.createElement('div');
    el.className = 'card add-card minus-card';
    el.dataset.fixed = 'minus';
    el.innerHTML = '<span>−</span>';
    el.addEventListener('mouseenter', () => post('status', { text: tr('Drop a project card here to close it') }));
    el.addEventListener('mouseleave', () => post('status', { text: '' }));
    return el;
  }

  function chip(p, env) {
    const b = document.createElement('button');
    b.className = 'chip';
    b.textContent = env.name;
    b.style.background = env.color;
    b.title = tr('{env}: project page · ⌘-click: home in a new tab · ⌥-click: compare home on the right', { env: env.name });
    b.addEventListener('click', (e) => {
      e.stopPropagation();
      if (e.altKey) post('openEnv', { projectID: p.id, envID: env.id, mode: 'compare' });
      else if (e.metaKey) post('openEnv', { projectID: p.id, envID: env.id, mode: 'newTab' });
      else post('openProject', { projectID: p.id, envID: env.id });
    });
    return b;
  }

  function mark(icon, title) {
    const m = document.createElement('span');
    m.className = 'pin-mark';
    m.textContent = icon;
    m.title = title;
    return m;
  }

  /** 드래그로 영역이 바뀌면 카드의 상태 표시(📌 / 🔒 / 흐림)도 바로 바꾼다 */
  function setAreaMark(el, area) {
    if (!el) return;
    const head = el.querySelector('.head');
    head.querySelector('.pin-mark')?.remove();
    if (area === pinnedGrid) head.append(mark('📌', tr('Pinned')));
    if (area === closedGrid) head.append(mark('🔒', tr('Closed')));
    el.classList.toggle('closed', area === closedGrid);
  }

  function blankChip() {
    const d = document.createElement('div');
    d.className = 'chip disabled blank';
    d.addEventListener('click', (e) => e.stopPropagation());
    return d;
  }

  function disabledChip(name) {
    const d = document.createElement('div');
    d.className = 'chip disabled';
    d.textContent = name;
    d.title = tr('{name} not set up', { name });
    d.addEventListener('click', (e) => e.stopPropagation());
    return d;
  }

  // ── 드래그 (마우스 이벤트, 놓는 즉시 저장) ──
  // 고정 영역 ↔ 일반 영역을 넘으면 고정 설정·해제. Default 와 + 카드는 끌 수 없고, 그 앞에도 놓을 수 없다.
  function bindDrag(el) {
    el.addEventListener('mousedown', (down) => {
      if (down.button !== 0 || down.target.closest('button') || el.dataset.fixed) return;
      const rect = el.getBoundingClientRect();
      drag = { el, ghost: null, x0: down.clientX, y0: down.clientY,
               dx: down.clientX - rect.left, dy: down.clientY - rect.top,
               moved: false, allowed: canDrag(), from: el.parentElement };
      addEventListener('mousemove', onMove);
      addEventListener('mouseup', onUp, { once: true });
      down.preventDefault();
    });
  }

  function onMove(e) {
    if (!drag) return;
    if (!drag.moved) {
      if (Math.hypot(e.clientX - drag.x0, e.clientY - drag.y0) < 6) return;
      drag.moved = true;
      if (!drag.allowed) return;
      const rect = drag.el.getBoundingClientRect();
      const ghost = drag.el.cloneNode(true);
      ghost.classList.add('drag-ghost');
      ghost.style.width = rect.width + 'px';
      ghost.style.height = rect.height + 'px';
      document.body.append(ghost);
      drag.ghost = ghost;
      drag.el.classList.add('dragging');
      document.body.classList.add('drag-active');
    }
    if (!drag.allowed || !drag.ghost) return;
    drag.ghost.style.left = (e.clientX - drag.dx) + 'px';
    drag.ghost.style.top = (e.clientY - drag.dy) + 'px';

    const under = document.elementFromPoint(e.clientX, e.clientY);
    const targetGrid = under?.closest('.grid') || (under?.closest('#pinnedArea') ? pinnedGrid : null);
    for (const g of GRIDS()) g.classList.toggle('drop-target', g === targetGrid);
    if (!targetGrid) return;

    const target = under.closest('.card:not(.drag-ghost)');
    if (target && target !== drag.el && target.parentElement === targetGrid) {
      const r = target.getBoundingClientRect();
      let after = (e.clientX - r.left) > r.width / 2;
      if (target.dataset.fixed) after = true;     // Default·+·− 카드 앞에는 못 놓는다
      targetGrid.insertBefore(drag.el, after ? target.nextSibling : target);
    } else if (!target && drag.el.parentElement !== targetGrid) {
      targetGrid.append(drag.el);                 // 영역의 빈 곳 → 그 영역 맨 끝
    }
    setAreaMark(drag.el, drag.el.parentElement);
    setAreaMark(drag.ghost, drag.el.parentElement);
  }

  function onUp() {
    removeEventListener('mousemove', onMove);
    if (!drag) return;
    const d = drag;
    drag = null;
    if (!d.moved) return;
    suppressClick = true;
    setTimeout(() => { suppressClick = false; }, 0);
    if (!d.allowed) return;
    d.ghost?.remove();
    d.el.classList.remove('dragging');
    document.body.classList.remove('drag-active');
    for (const g of GRIDS()) g.classList.remove('drop-target');

    const ids = (g) => [...g.children].filter((c) => !c.dataset.fixed).map((c) => c.dataset.id);
    post('reorder', { pinned: ids(pinnedGrid), others: ids(grid), closed: ids(closedGrid) });   // 즉시 저장
    const to = d.el.parentElement;
    if (to !== d.from) {
      if (to === pinnedGrid) toast(tr('Pinned'));
      else if (to === closedGrid) toast(tr('Closed'));
      else toast(d.from === pinnedGrid ? tr('Unpinned') : tr('Reopened'));
    }
  }

  let toastTimer;
  function toast(text) {
    toastEl.textContent = text;
    toastEl.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toastEl.hidden = true; }, 1800);
  }

  // ── 프로젝트 추가 팝업 ──
  const modal = $('addModal'), form = $('addForm'), nameInput = $('addName'), sourceSel = $('addSource');
  const dupOptions = $('dupOptions');

  function openAdd() {
    nameInput.value = '';
    form.mode.value = 'empty';
    // 프로젝트 화면과 같은 순서 (Default → 고정 → 일반 → closed), 검색과 무관하게 전체
    const ps = state.projects;
    const list = ps.filter((p) => p.isDefault)
      .concat(ps.filter((p) => p.pinned && !p.isDefault && !p.closed),
              ps.filter((p) => !p.pinned && !p.isDefault && !p.closed),
              ps.filter((p) => p.closed && !p.isDefault));
    sourceSel.replaceChildren(...list.map((p) => {
      const o = document.createElement('option');
      o.value = p.id;
      o.textContent = p.closed ? `${p.name}  (closed)` : p.name;
      return o;
    }));
    $('optDomains').checked = true; $('optURIs').checked = true; $('optAccounts').checked = false;
    syncMode();
    modal.hidden = false;
    nameInput.focus();
  }

  function closeAdd() { modal.hidden = true; search.focus(); }

  function syncMode() {
    const dup = form.mode.value === 'duplicate';
    sourceSel.disabled = !dup;
    dupOptions.disabled = !dup;
    const p = state.projects.find((x) => x.id === sourceSel.value);
    const s = p?.summary || {};
    $('sumDomain').textContent = s.domain || tr('None');
    $('sumURIs').textContent = tr('{n} URIs', { n: s.uris ?? 0 });
    $('sumAccounts').textContent = tr('{n} accounts', { n: s.accounts ?? 0 });
  }

  form.addEventListener('change', syncMode);
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const dup = form.mode.value === 'duplicate';
    post('createProject', {
      name: nameInput.value,
      mode: dup ? 'duplicate' : 'empty',
      sourceID: dup ? sourceSel.value : null,
      copyDomains: $('optDomains').checked,
      copyURIs: $('optURIs').checked,
      copyAccounts: $('optAccounts').checked,
    });
    modal.hidden = true;
  });
  $('addCancel').addEventListener('click', closeAdd);
  modal.addEventListener('mousedown', (e) => { if (e.target === modal) closeAdd(); });
  addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.hidden) closeAdd(); });

  // ── 검색 ──
  search.addEventListener('input', () => { saveSearch(); render(); });
  clearBtn.addEventListener('click', () => { search.value = ''; saveSearch(); render(); search.focus(); });
  search.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      const a = areas();
      const all = a.pinned.concat(a.others, a.closed);
      if (all.length === 1) post('openProject', { projectID: all[0].id });
    }
  });

  window.devlink = {
    render(next) {
      if (drag && drag.moved) return;
      state = next;
      if (first) { first = false; search.value = next.search || ''; }
      render();
    },
  };

  post('ready');
  search.focus();
})();

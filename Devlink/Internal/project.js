// 프로젝트 화면: ① 이름·대표 도메인 ② 설명 ③ 보기·설정 ④ 환경 탭 ⑤ 도메인(서비스)별 URI 표.
// 값은 Swift 가 render(state) 로 넣어주고, 동작은 post() 로 요청한다.
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const projectID = location.pathname.replace(/^\//, '');
  let envID = new URLSearchParams(location.search).get('env');
  let project = null;
  let layout = 'tabs';   // tabs | list (Swift 가 저장)

  function post(type, data = {}) {
    try { window.webkit.messageHandlers.lh.postMessage(Object.assign({ type }, data)); } catch (e) {}
  }

  /** 설정에서 등록한 parameter 를 path 에 반영: { path, q, vars }
   *  path variable: key 가 path 의 {key} 와 같으면 쿼리 대신 그 자리에 넣는다 (값이 비면 {key} 그대로).
   *  나머지는 인코딩한 쿼리 문자열 q (path 에 이미 ? 가 있으면 & 로 잇는다). vars 는 화면 표시용 "key=value". */
  function resolve(uri) {
    let path = uri.path;
    const query = [];
    const vars = [];
    for (const p of (uri.params || []).filter((x) => x.key && x.enabled !== false)) {
      const token = `{${p.key}}`;
      if (uri.path.includes(token)) {
        vars.push(`${p.key}=${p.value ?? ''}`);
        if (p.value) path = path.split(token).join(encodeURIComponent(p.value));
      } else {
        query.push(`${encodeURIComponent(p.key)}=${encodeURIComponent(p.value ?? '')}`);
      }
    }
    const q = query.length ? (uri.path.includes('?') ? '&' : '?') + query.join('&') : '';
    return { path, q, vars };
  }

  /** 파일로 지정한 URI (file:// 전체 주소) 는 도메인을 붙이지 않는다 */
  function isFile(uri) { return uri.path.startsWith('file://'); }

  function currentEnv() {
    return project.envs.find((e) => e.id === envID) || project.envs[0];
  }

  function render() {
    if (!project) return;
    const env = currentEnv();
    envID = env?.id;
    document.title = project.name;
    $('pjName').textContent = project.name;
    $('pjClosed').hidden = !project.closed;   // closed: 열기·복사 버튼은 꺼진다 (설정·환경·보기만)
    $('pjDesc').textContent = project.description || '';
    $('pjDesc').hidden = !project.description;

    const tabs = layout === 'tabs';
    $('viewTabs').classList.toggle('active', tabs);
    $('viewList').classList.toggle('active', !tabs);

    $('pjDomain').textContent = project.baseDomain || '';
    $('pjDomain').hidden = !project.baseDomain;

    $('envTabs').hidden = !tabs;
    $('envTabs').replaceChildren(...(tabs ? project.envs.map(envTab) : []));
    if (!env) { $('envBody').replaceChildren(emptyText(tr('No environments'))); return; }
    if (tabs) $('envBody').replaceChildren(...envBlocks(env));
    else $('envBody').replaceChildren(...project.envs.map((e) => {
      // 목록형: 환경 제목 + 그 환경의 도메인별 표
      const sec = document.createElement('section');
      sec.className = 'env-section';
      sec.append(envTitle(e), ...envBlocks(e));
      return sec;
    }));
    alignColumns();
  }

  /** 환경 하나: 도메인마다 제목(alias · 주소) + URI 표 */
  function envBlocks(env) {
    const domains = env.domains.filter((d) => d.showInSidebar !== false);   // 사용(Active) 해제한 서비스는 설정에만 보인다
    if (domains.length === 0) return [noteBox(tr('{env} has no domains', { env: env.name }))];
    return domains.map((d) => {
      const block = document.createElement('div');
      block.className = 'domain-block';
      const h = document.createElement('h3');
      if (d.alias) {
        const a = document.createElement('span');
        a.textContent = d.alias;
        h.append(a);
      }
      const o = document.createElement('span');
      o.className = 'dim';
      o.textContent = d.origin ? (d.alias ? ` · ${d.origin}` : d.origin) : (d.alias ? ' · ' : '') + tr('Domain not set');
      h.append(o);
      block.append(h);
      const uris = (d.origin ? d.uris : d.uris.filter(isFile)).filter((u) => u.showInSidebar !== false);   // 도메인이 없어도 파일 URI 는 열 수 있다
      if (!d.origin && uris.length === 0) block.append(noteBox(tr('Domain not set')));
      else if (uris.length === 0) block.append(noteBox(tr('No URIs')));
      else {
        const box = document.createElement('div');
        box.className = 'uri-box';
        const table = document.createElement('table');
        table.className = 'uri-table';
        table.append(...uris.map((u) => uriRow(env, d, u)));
        box.append(table);
        block.append(box);
      }
      return block;
    });
  }

  function noteBox(msg) {
    const box = document.createElement('div');
    box.className = 'uri-box';
    box.append(emptyText(msg));
    return box;
  }

  /** 표끼리 칸을 맞춘다. 각 칸의 가장 넓은 폭으로 맞추고, 오른쪽 끝 칸이 남는 폭을 쓴다. */
  function alignColumns() {
    const tables = [...document.querySelectorAll('.uri-table')];
    const widths = [];
    for (const t of tables) {
      [...t.rows[0].cells].forEach((c, i) => { widths[i] = Math.max(widths[i] || 0, c.getBoundingClientRect().width); });
    }
    // 고정 레이아웃: 첫 행 폭을 그대로 쓰고, 폭이 없는 오른쪽 끝 칸이 나머지를 쓴다
    for (const t of tables) {
      [...t.rows[0].cells].forEach((c, i, all) => { c.style.width = i < all.length - 1 ? widths[i] + 'px' : 'auto'; });
      t.style.tableLayout = 'fixed';
    }
  }

  function envTitle(env) {
    const h = document.createElement('h2');
    h.innerHTML = '<i></i>';
    h.querySelector('i').style.background = env.color;
    h.append(env.name);
    return h;
  }

  function emptyText(msg) {
    const p = document.createElement('p');
    p.className = 'uri-empty';
    p.textContent = msg;
    return p;
  }

  function envTab(env) {
    const b = document.createElement('button');
    b.className = 'env-tab' + (env.id === envID ? ' active' : '') + (env.ready ? '' : ' disabled');
    b.innerHTML = '<i></i>';
    b.querySelector('i').style.background = env.color;
    const name = document.createElement('span');
    name.textContent = env.name;
    b.append(name);
    b.title = env.ready ? env.name : tr('{name} not set up', { name: env.name });
    b.addEventListener('click', () => { envID = env.id; render(); });
    return b;
  }

  function uriRow(env, domain, uri) {
    const row = document.createElement('tr');   // tr 은 번역 함수라 이름을 피한다
    const r = resolve(uri);
    const full = r.path + r.q;
    const cells = [
      button(tr('Copy'), () => copy(isFile(uri) ? full : domain.origin + full), tr('Copy URL')),
      button(tr('Open'), (e) => open(env, domain, full, e), tr('Open · ⌘-click: new tab · ⌥-click: compare on the right')),
      button(tr('Browser ▾'), () => post('openExternal', { projectID, envID: env.id, domainID: domain.id, path: full }),
        tr('Open in another browser')),
      text(uri.alias),
      text(uri.path),
      paramText(uri, [...r.vars, r.q].filter(Boolean).join(' ')),   // path variable 값 + 쿼리
    ];
    for (const c of cells) { const td = document.createElement('td'); td.append(c); row.append(td); }
    return row;
  }

  function button(label, onClick, title) {
    const b = document.createElement('button');
    b.className = 'row-btn';
    b.textContent = label;
    b.disabled = !!project?.closed;
    if (title) b.title = title;
    b.addEventListener('click', onClick);
    return b;
  }

  /** parameter 칸: 설명은 마우스를 올리면 툴팁으로 (key=value — 설명) */
  function paramText(uri, q) {
    const s = text(q);
    if (q) s.title = (uri.params || []).filter((p) => p.key && p.enabled !== false)
      .map((p) => `${p.key}=${p.value ?? ''}${p.desc ? ` — ${p.desc}` : ''}`).join('\n');
    return s;
  }

  function text(value) {
    const s = document.createElement('span');
    s.textContent = value || '—';
    if (!value) s.className = 'dim';
    else s.title = value;
    return s;
  }

  function open(env, domain, path, e) {
    const mode = e.altKey ? 'compare' : e.metaKey ? 'newTab' : 'here';
    post('openEnv', { projectID, envID: env.id, domainID: domain.id, path, mode });
  }

  function copy(textValue) {
    post('copy', { text: textValue });
    toast(tr('Copied: {text}', { text: textValue }));
  }

  let toastTimer;
  function toast(msg) {
    const el = $('toast');
    el.textContent = msg;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, 2000);
  }

  $('back').addEventListener('click', () => post('back'));
  for (const [id, value] of [['viewTabs', 'tabs'], ['viewList', 'list']]) {
    $(id).addEventListener('click', () => { layout = value; post('setLayout', { layout }); render(); });
  }
  $('pjSettings').addEventListener('click', () => post('openSettings', { projectID, envID: layout === 'tabs' ? envID : null }));

  window.devlink = {
    render(state) {
      project = state.projects.find((p) => p.id === projectID) || null;
      layout = state.envLayout === 'list' ? 'list' : 'tabs';
      if (!project) { post('back'); return; }   // 삭제된 프로젝트
      render();
    },
  };

  post('ready');
})();

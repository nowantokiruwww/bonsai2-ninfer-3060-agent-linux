/* ===========================================================================
   ninfer-3060-bonsai 控制台前端
   ---------------------------------------------------------------------------
   约束（照做，别改）：
     * 原生 JS，无 ES module import（普通 <script src> 直接加载）
     * 无框架、无 CDN、不引用任何外部 URL（离线可用）
     * 所有 fetch 都 try/catch，失败必须在界面上给出可读的中文错误
     * 不自动触发任何写操作：保存 / 启动 / 停止 / 重启都必须用户点击
   轮询节奏：
     * /api/status    每 2 秒；有异步动作在跑时每 1 秒
     * /api/requests  每 5 秒
   后端：webui/server.py（同源，无需 CORS）
   =========================================================================== */
(function () {
  'use strict';

  /* ------------------------------------------------------------------ *
   * 小工具
   * ------------------------------------------------------------------ */

  /** 按 id 取元素 */
  function $(id) { return document.getElementById(id); }

  /** 人类可读字节数 */
  function fmtBytes(n) {
    if (n === null || n === undefined || isNaN(Number(n))) return '–';
    n = Number(n);
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KiB';
    if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MiB';
    return (n / 1024 / 1024 / 1024).toFixed(2) + ' GiB';
  }

  /** 秒 → “1h 2m 3s” */
  function fmtUptime(s) {
    if (s === null || s === undefined || s === '' || isNaN(Number(s))) return '–';
    var t = Math.max(0, Math.floor(Number(s)));
    var h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), sec = t % 60;
    if (h > 0) return h + 'h ' + m + 'm';
    if (m > 0) return m + 'm ' + sec + 's';
    return sec + 's';
  }

  /** 数字显示（null/undefined → '–'） */
  function num(v, digits) {
    if (v === null || v === undefined || v === '' || isNaN(Number(v))) return '–';
    var n = Number(v);
    return digits === undefined ? String(n) : n.toFixed(digits);
  }

  /** 整数化（用于比较），无法解析 → null */
  function toNum(v) {
    if (v === null || v === undefined || v === '') return null;
    var n = Number(v);
    return isNaN(n) ? null : n;
  }

  /** 中位数（忽略 null/NaN）；无有效值 → null */
  function median(list) {
    var a = list.filter(function (v) { return typeof v === 'number' && !isNaN(v); })
                .slice().sort(function (x, y) { return x - y; });
    if (!a.length) return null;
    var mid = Math.floor(a.length / 2);
    return a.length % 2 ? a[mid] : (a[mid - 1] + a[mid]) / 2;
  }

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  /** 设置元素文本（null → '–'） */
  function setText(el, text) { if (el) el.textContent = (text === null || text === undefined || text === '') ? '–' : String(text); }

  /* ------------------------------------------------------------------ *
   * fetch 封装：统一错误 → 可读中文 Error
   * ------------------------------------------------------------------ */
  async function httpJson(path, options) {
    var resp;
    try {
      resp = await fetch(path, options);
    } catch (e) {
      throw new Error('无法连接后端 ' + path + '（' + (e && e.message ? e.message : e) + '）');
    }
    var text = '';
    try {
      text = await resp.text();
    } catch (e) {
      throw new Error('读取响应失败 ' + path + '：' + (e && e.message ? e.message : e));
    }
    var data = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch (e) {
        throw new Error('后端返回的不是 JSON（HTTP ' + resp.status + '）：' + text.slice(0, 140));
      }
    }
    if (!resp.ok) {
      var msg = (data && (data.error || data.message)) || ('HTTP ' + resp.status);
      var err = new Error(msg);
      err.status = resp.status;
      err.data = data;
      throw err;
    }
    return data === null ? {} : data;
  }

  function postJson(path, body) {
    return httpJson(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
  }

  /* ------------------------------------------------------------------ *
   * Toast 提示
   * ------------------------------------------------------------------ */
  var toastBox = $('toasts');
  function toast(msg, kind) {
    if (!toastBox) return;
    var d = document.createElement('div');
    d.className = 'toast' + (kind ? ' toast-' + kind : '');
    d.textContent = String(msg);
    toastBox.appendChild(d);
    setTimeout(function () {
      if (d.parentNode) d.parentNode.removeChild(d);
    }, kind === 'error' ? 9000 : 5000);
  }

  /* ------------------------------------------------------------------ *
   * 元素引用 + 全局状态
   * ------------------------------------------------------------------ */
  var els = {
    // 状态栏
    stDot: $('st-dot'), stState: $('st-state'), stPid: $('st-pid'), stUptime: $('st-uptime'),
    stModel: $('st-model'), stKv: $('st-kv'), stThinking: $('st-thinking'), stSpec: $('st-spec'),
    stSampling: $('st-sampling'), stGpu: $('st-gpu'), stEndpoint: $('st-endpoint'), stError: $('st-error'),
    btnRefresh: $('btn-refresh'),
    // 控制区
    inPreset: $('in-preset'), presetDesc: $('preset-desc'), presetWarn: $('preset-warn'),
    inKvCapacity: $('in-kv-capacity'), inKvDtype: $('in-kv-dtype'), inSpec: $('in-spec'),
    inPort: $('in-port'), inExtra: $('in-extra'),
    btnStart: $('btn-start'), btnStop: $('btn-stop'), btnRestart: $('btn-restart'), btnSave: $('btn-save'),
    actionNote: $('action-note'), actionPanel: $('action-panel'), actionOutput: $('action-output'),
    actionSummary: $('action-summary'), gpuList: $('gpu-list'), configPath: $('config-path'),
    // 日志
    logView: $('log-view'), logFollow: $('log-follow'), logAutoscroll: $('log-autoscroll'),
    btnLogPause: $('btn-log-pause'), btnLogClear: $('btn-log-clear'), btnLogDownload: $('btn-log-download'),
    logSize: $('log-size'), logPath: $('log-path'), streamState: $('log-stream-state'),
    // 请求
    reqSummary: $('req-summary'), reqBody: $('req-body'), reqHead: $('req-head'),
    reqEmpty: $('req-empty'), reqTable: $('req-table'), reqBytes: $('req-bytes'),
    btnReqRefresh: $('btn-req-refresh')
  };

  var state = {
    status: null,          // 最近一次 /api/status
    actionRunning: false,  // 是否有异步动作在跑（决定 status 轮询 1s 还是 2s）
    actionJobId: null,     // 当前跟踪的 job id
    printedAction: 0,      // 已打印的 output 行数
    requests: [],          // 最近请求
    reqSortKey: null,      // 排序列
    reqSortDir: 0,         // 1=升序 -1=降序 0=服务端原序（新→旧）
    es: null,              // EventSource
    emptyLogFallback: false
  };

  var ACTION_NOTE_IDLE = els.actionNote ? els.actionNote.textContent : '';

  /* ==================================================================== *
   * A. 顶部状态栏
   * ==================================================================== */

  function setStatusError(msg) {
    if (!els.stError) return;
    if (msg) {
      els.stError.textContent = msg;
      els.stError.hidden = false;
    } else {
      els.stError.textContent = '';
      els.stError.hidden = true;
    }
  }

  function setDot(cls, title) {
    if (!els.stDot) return;
    els.stDot.className = 'dot dot-' + cls;
    if (title) els.stDot.title = title;
  }

  /** 渲染 /api/status 的结果 */
  function renderStatus(s) {
    if (!s || typeof s !== 'object') {
      setStatusError('/api/status 返回了意外的内容');
      setDot('red', '状态异常');
      els.stState.textContent = '状态异常';
      return;
    }
    // 后端在 launcher 完全失败时会回 {"running":false,"error":"..."}
    if (s.error) setStatusError('状态读取失败：' + s.error);
    else setStatusError('');

    var running = !!s.running;
    var code = String(s.endpoint_http === undefined || s.endpoint_http === null ? '000' : s.endpoint_http);

    if (!running) {
      setDot('gray', '未运行');
      els.stState.textContent = '未运行';
    } else if (code === '200') {
      setDot('green', '运行中，端点就绪（HTTP 200）');
      els.stState.textContent = '运行中 · 就绪';
    } else if (code === '503') {
      setDot('yellow', '运行中但未就绪：权重仍在加载（HTTP 503）');
      els.stState.textContent = '运行中 · 未就绪（503 权重加载中）';
    } else {
      setDot('yellow', '运行中但端点不可达：http=' + code);
      els.stState.textContent = '运行中 · 端点异常（' + code + '）';
    }

    setText(els.stPid, running ? s.pid : null);
    setText(els.stUptime, running ? fmtUptime(s.uptime_s) : null);
    setText(els.stModel, s.model);

    var kv = (s.kv_dtype || s.kv_capacity) ? (s.kv_dtype || '?') + ' @ ' + (s.kv_capacity || '?') : null;
    setText(els.stKv, kv);

    if (String(s.thinking) === 'off') {
      setText(els.stThinking, 'off');
    } else if (s.thinking) {
      var th = s.thinking === 'unknown' ? '?' : s.thinking;
      setText(els.stThinking, th + (s.budget ? ' budget=' + s.budget : '') + (s.effort ? ' effort=' + s.effort : ''));
    } else {
      setText(els.stThinking, null);
    }

    setText(els.stSpec, s.spec);
    setText(els.stSampling, s.sampling);

    if (s.gpu_name) {
      setText(els.stGpu, s.gpu_name + (s.gpu_free_mib ? ' · 空闲 ' + s.gpu_free_mib + ' MiB' : ''));
      els.stGpu.title = s.gpu_uuid ? ('UUID ' + s.gpu_uuid) : '';
    } else {
      setText(els.stGpu, s.gpu_uuid || null);
      els.stGpu.title = '';
    }

    if (s.host && s.port) {
      var url = 'http://' + s.host + ':' + s.port + '/v1';
      els.stEndpoint.textContent = url + (running ? ' [' + code + ']' : '');
      els.stEndpoint.title = '引擎 OpenAI 兼容端点（' + (running ? 'http=' + code : '未运行') + '）';
      els.stEndpoint.style.color = (!running || code === '200') ? '' : (code === '503' ? '#d29922' : '#f85149');
    } else {
      setText(els.stEndpoint, null);
    }

    // 日志大小跟着状态一起刷新
    if (els.logSize && s.log_bytes !== undefined) els.logSize.textContent = fmtBytes(s.log_bytes);
    if (s.root && els.configPath && !els.configPath.textContent) {
      els.configPath.textContent = '仓库根：' + s.root;
    }
  }

  async function refreshStatus() {
    try {
      var s = await httpJson('/api/status');
      state.status = s;
      renderStatus(s);
      return s;
    } catch (e) {
      setStatusError('/api/status 读取失败：' + e.message);
      setDot('red', '无法读取状态');
      els.stState.textContent = '无法读取状态';
      return null;
    }
  }

  /** 自调度轮询：有动作在跑时 1s，否则 2s；页面隐藏时放缓 */
  function scheduleStatus() {
    var delay = state.actionRunning ? 1000 : 2000;
    setTimeout(async function () {
      if (!document.hidden) await refreshStatus();
      scheduleStatus();
    }, delay);
  }

  /* ==================================================================== *
   * B. 控制区
   * ==================================================================== */

  // 离线兜底预设（/api/presets 拉不到时仍能操作；desc 与 app/presets.env 同步）
  var FALLBACK_PRESETS = [
    { name: 'balanced', thinking: 'on',  effort: 'medium', budget: '1024', sample: 'v100', desc: '生产默认：思考开 + 预算 1024 + V100 采样' },
    { name: 'fast',     thinking: 'off', effort: '',       budget: '',     sample: 'v100', desc: '关思考：代码/工具最快，中文散文反而更慢' },
    { name: 'think',    thinking: 'on',  effort: 'medium', budget: '4096', sample: 'v100', desc: '思考预算 4096：更慢、产出未必更好' },
    { name: 'deep',     thinking: 'on',  effort: 'high',   budget: '8192', sample: 'v100', desc: '预算 8192 + effort high：最慢' },
    { name: 'greedy',   thinking: 'on',  effort: 'medium', budget: '1024', sample: 'greedy', desc: '危险：--greedy 强制 argmax，会诱发逐字节复读锁死（L26）' }
  ];
  var presets = [];

  function renderPresetOptions(list) {
    var keep = els.inPreset.value;
    els.inPreset.textContent = '';
    list.forEach(function (p) {
      var o = document.createElement('option');
      o.value = p.name;
      o.textContent = p.name + (p.budget ? '（budget ' + p.budget + '）' : (p.thinking === 'off' ? '（无思考）' : ''));
      els.inPreset.appendChild(o);
    });
    var exists = list.some(function (p) { return p.name === keep; });
    els.inPreset.value = exists ? keep : (list[0] ? list[0].name : '');
    renderPresetDesc();
  }

  function currentPreset() {
    var name = els.inPreset.value;
    for (var i = 0; i < presets.length; i++) if (presets[i].name === name) return presets[i];
    return null;
  }

  /** 选中预设 → 显示 desc；greedy → 红色警告 */
  function renderPresetDesc() {
    var p = currentPreset();
    if (!p) {
      els.presetDesc.textContent = '（没有可用预设）';
      els.presetWarn.hidden = true;
      return;
    }
    var bits = [];
    bits.push('思考 ' + (p.thinking === 'off' ? 'off' : (p.thinking || '?')));
    if (p.effort) bits.push('effort=' + p.effort);
    if (p.budget) bits.push('budget=' + p.budget);
    if (p.sample) bits.push('采样 ' + p.sample);
    els.presetDesc.textContent = bits.join(' · ') + '　—　' + (p.desc || '（无说明）');
    els.presetWarn.hidden = (p.name !== 'greedy');
  }

  async function loadPresets() {
    try {
      var d = await httpJson('/api/presets');
      presets = (d && Array.isArray(d.presets) && d.presets.length) ? d.presets : FALLBACK_PRESETS;
      if (!d || !Array.isArray(d.presets) || !d.presets.length) {
        toast('/api/presets 没有返回预设，已使用内置兜底列表', 'error');
      }
    } catch (e) {
      presets = FALLBACK_PRESETS;
      toast('预设读取失败：' + e.message + '（已用内置兜底列表）', 'error');
    }
    renderPresetOptions(presets);
  }

  // config/runtime.env 缺失时的引擎默认值（与 app/env.sh 一致）
  var CFG_DEFAULTS = {
    PORT: '8098',
    KV_DTYPE: 'rk2v4-e8',
    KV_CAPACITY: '49152',
    SPEC_FLAGS: '--spec dflash2 --draft-tokens 7',
    EXTRA_FLAGS: ''
  };

  /** 读 /api/config 预填输入框（只读，不写） */
  async function loadConfig() {
    try {
      var d = await httpJson('/api/config');
      var v = (d && d.values) || {};
      var defaulted = [];

      function fill(input, key) {
        if (!input) return;
        if (v[key] !== undefined && v[key] !== '') {
          input.value = v[key];
          input.title = key + ' 来自 ' + ((d && d.path) || 'config/runtime.env');
        } else {
          input.value = CFG_DEFAULTS[key] || '';
          input.title = key + ' 在 config 里没有设置，这里是引擎默认值';
          defaulted.push(key);
        }
      }

      fill(els.inPort, 'PORT');
      fill(els.inKvCapacity, 'KV_CAPACITY');
      fill(els.inKvDtype, 'KV_DTYPE');
      fill(els.inSpec, 'SPEC_FLAGS');
      fill(els.inExtra, 'EXTRA_FLAGS');

      var note = '配置文件：' + ((d && d.path) || 'config/runtime.env');
      if (defaulted.length) note += '（其中 ' + defaulted.join('、') + ' 未设置，显示的是引擎默认值）';
      els.configPath.textContent = note;
    } catch (e) {
      els.configPath.textContent = '配置读取失败：' + e.message;
      toast('配置读取失败：' + e.message, 'error');
    }
  }

  /** GPU 列表：只读展示，两张卡都能看出来，但不提供任何操作入口 */
  async function loadGpus() {
    var box = els.gpuList;
    if (!box) return;
    box.textContent = '';
    try {
      var d = await httpJson('/api/gpus');
      var list = (d && Array.isArray(d.gpus)) ? d.gpus : [];
      if (!list.length) {
        var none = document.createElement('span');
        none.className = 'dim';
        none.textContent = '没有读到 GPU（nvidia-smi 无输出？）';
        box.appendChild(none);
        return;
      }
      list.forEach(function (g) {
        var row = document.createElement('div');
        row.className = 'gpu';

        var name = document.createElement('span');
        name.className = 'gpu-name';
        name.textContent = g.name || ('GPU ' + g.index);
        row.appendChild(name);

        var isOurs = String(g.compute_cap) === '8.6'; // 本项目只编译了 sm_86
        var badge = document.createElement('span');
        badge.className = 'badge ' + (isOurs ? 'badge-use' : 'badge-other');
        badge.textContent = isOurs ? '本项目使用（sm_' + String(g.compute_cap).replace('.', '') + '）' : '其他用途 · 只读（sm_' + String(g.compute_cap || '?').replace('.', '') + '）';
        row.appendChild(badge);

        var used = toNum(g.mem_used_mib) || 0;
        var total = toNum(g.mem_total_mib) || 0;
        var free = toNum(g.mem_free_mib);
        var mem = document.createElement('span');
        mem.className = 'mono dim';
        mem.textContent = '显存 ' + used + '/' + total + ' MiB（空闲 ' + (free === null ? '?' : free) + '）' + (g.util_pct ? ' · 利用率 ' + g.util_pct + '%' : '');
        row.appendChild(mem);

        var bar = document.createElement('span');
        bar.className = 'mem-bar';
        var inner = document.createElement('i');
        inner.style.width = (total > 0 ? Math.min(100, Math.round(used * 100 / total)) : 0) + '%';
        bar.appendChild(inner);
        row.appendChild(bar);

        var uuid = document.createElement('span');
        uuid.className = 'mono dim';
        uuid.textContent = g.uuid || '';
        uuid.title = g.uuid || '';
        row.appendChild(uuid);

        box.appendChild(row);
      });
    } catch (e) {
      var err = document.createElement('span');
      err.className = 'dim';
      err.textContent = 'GPU 读取失败：' + e.message;
      box.appendChild(err);
    }
  }

  /* ---------------- 异步动作（启动 / 停止 / 重启） ---------------- */

  function setActionBusy(busy, action) {
    [els.btnStart, els.btnStop, els.btnRestart, els.btnSave].forEach(function (b) {
      if (b) b.disabled = !!busy;
    });
    if (els.actionNote) {
      els.actionNote.textContent = busy
        ? ('正在执行 ' + action + ' …（异步，进度见下方「操作输出」）')
        : ACTION_NOTE_IDLE;
    }
  }

  function appendActionOutput(lines) {
    if (!els.actionOutput) return;
    var atBottom = els.actionOutput.scrollHeight - els.actionOutput.scrollTop - els.actionOutput.clientHeight < 40;
    var frag = document.createDocumentFragment();
    lines.forEach(function (l) {
      var d = document.createElement('div');
      d.textContent = String(l);
      frag.appendChild(d);
    });
    els.actionOutput.appendChild(frag);
    if (atBottom) els.actionOutput.scrollTop = els.actionOutput.scrollHeight;
  }

  function setActionSummary(txt) {
    if (els.actionSummary) els.actionSummary.textContent = txt ? '（' + txt + '）' : '（无）';
  }

  /** 组装 POST /api/action 的参数（只取非空值，避免后端报未知参数） */
  function buildActionBody(action) {
    var body = { action: action };
    if (action === 'stop') return body;   // stop 不需要参数
    var pairs = [
      ['preset', els.inPreset.value],
      ['ctx', els.inKvCapacity.value],
      ['kv_dtype', els.inKvDtype.value],
      ['spec', els.inSpec.value],
      ['port', els.inPort.value],
      ['extra', els.inExtra.value]
    ];
    pairs.forEach(function (kv) {
      var v = (kv[1] === null || kv[1] === undefined) ? '' : String(kv[1]).trim();
      if (v !== '') body[kv[0]] = v;
    });
    return body;
  }

  /** 打印 /api/action 的 output 新增部分 */
  function printActionOutput(job) {
    if (!els.actionOutput) return;
    if (job.id !== state.actionJobId) {
      state.actionJobId = job.id;
      state.printedAction = 0;
      els.actionOutput.textContent = '';
    }
    var out = Array.isArray(job.output) ? job.output : [];
    if (out.length > state.printedAction) {
      appendActionOutput(out.slice(state.printedAction));
      state.printedAction = out.length;
    }
  }

  /** 轮询 /api/action 直到 running=false */
  async function pollAction(jobId, action) {
    state.actionRunning = true;
    var t0 = Date.now();
    var failures = 0;
    try {
      for (;;) {
        await sleep(800);
        var j;
        try {
          j = await httpJson('/api/action');
          failures = 0;
        } catch (e) {
          failures++;
          setActionSummary('轮询失败 ' + failures + ' 次：' + e.message);
          if (failures >= 5) {
            appendActionOutput(['[fail] /api/action 连续 5 次读取失败，停止跟踪：' + e.message]);
            toast('跟踪操作进度失败：' + e.message, 'error');
            return;
          }
          continue;
        }
        printActionOutput(j);
        setActionSummary(action + ' · ' + (j.running ? '运行中 ' + num(j.elapsed, 1) + 's' : '已结束'));

        if (!j.running) {
          var okExit = Number(j.rc) === 0;
          if (okExit) {
            appendActionOutput(['[ok] ' + action + ' 成功结束（rc=0，用时 ' + num(j.elapsed, 1) + 's）']);
            toast(action + ' 成功（' + num(j.elapsed, 1) + 's）', 'ok');
          } else {
            appendActionOutput(['[fail] ' + action + ' 失败（rc=' + num(j.rc) + '，用时 ' + num(j.elapsed, 1) + 's）—— 细节看下面的日志区']);
            toast(action + ' 失败（rc=' + num(j.rc) + '），详见日志', 'error');
          }
          return;
        }
        if (Date.now() - t0 > 15 * 60 * 1000) {
          appendActionOutput(['[fail] 跟踪超时（15 分钟），已停止轮询']);
          toast('跟踪操作超时（15 分钟），已停止轮询', 'error');
          return;
        }
      }
    } finally {
      state.actionRunning = false;
      setActionBusy(false, action);
      await refreshStatus();
      await refreshRequests();
    }
  }

  async function runAction(action) {
    if (state.actionRunning) {
      toast('已有操作在进行中，等它结束再操作', 'error');
      return;
    }
    // 有意义的提示（不做任何拦截写操作的行为，只是确认）
    if (action === 'start' && state.status && state.status.running) {
      if (!window.confirm('引擎看起来已经在运行。再点一次「启动」会被 launcher 拒绝（“已经在跑”）。\n\n要用新参数生效，请用「重启」。仍要继续启动吗？')) return;
    }

    var body = buildActionBody(action);
    state.actionRunning = true;
    state.actionJobId = null;
    state.printedAction = 0;
    setActionBusy(true, action);
    if (els.actionOutput) els.actionOutput.textContent = '';
    if (els.actionPanel) els.actionPanel.open = true;   // 自动展开「操作输出」
    setActionSummary(action + ' · 已提交');
    appendActionOutput([
      '$ POST /api/action ' + JSON.stringify(body),
      '(启动/重启是异步的：就绪要等权重加载，约 30–40 秒)'
    ]);

    var res;
    try {
      res = await postJson('/api/action', body);
    } catch (e) {
      state.actionRunning = false;
      setActionBusy(false, action);
      appendActionOutput(['[fail] 请求被拒绝：' + e.message]);
      setActionSummary(action + ' · 被拒绝');
      toast(action + ' 请求失败：' + e.message, 'error');
      return;
    }

    appendActionOutput(['[info] 已受理 job=' + res.job + '（' + (res.action || action) + '）']);
    await pollAction(res.job, res.action || action);
  }

  /** 保存到 config/runtime.env（只写文件，不重启） */
  async function saveConfig() {
    if (state.actionRunning) { toast('有操作正在进行，稍后再保存', 'error'); return; }
    var payload = {
      PORT: String(els.inPort.value || '').trim(),
      KV_CAPACITY: String(els.inKvCapacity.value || '').trim(),
      KV_DTYPE: String(els.inKvDtype.value || '').trim(),
      SPEC_FLAGS: String(els.inSpec.value || '').trim(),
      EXTRA_FLAGS: String(els.inExtra.value || '').trim()
    };
    try {
      var r = await postJson('/api/config', payload);
      var changed = Array.isArray(r.changed) ? r.changed : [];
      if (els.actionPanel) els.actionPanel.open = true;
      appendActionOutput(['$ POST /api/config ' + JSON.stringify(payload),
                          '[ok] 已写入 ' + ((r.path || 'config/runtime.env')) + '，改动：' + (changed.length ? changed.join('、') : '（无变化）'),
                          '[info] 只写了文件，没有重启引擎；要让参数生效请点「重启」']);
      setActionSummary('save · 完成');
      toast('已保存到 config：' + (changed.length ? changed.join('、') : '无变化'), 'ok');
      await loadConfig();  // 回读一次，确认落盘
    } catch (e) {
      appendActionOutput(['[fail] 保存失败：' + e.message]);
      setActionSummary('save · 失败');
      toast('保存到 config 失败：' + e.message, 'error');
    }
  }

  /* ==================================================================== *
   * C. 日志区
   * ==================================================================== */

  // 关键字高亮规则：数组顺序 = 优先级（红 > 绿 > 黄 > 青）
  var LOG_RULES = [
    { cls: 'log-err',  re: /(fail|error|Error|ERROR)/g },
    { cls: 'log-ok',   re: /(engine ready|listening)/gi },
    { cls: 'log-warn', re: /(WARN|warn)/g },
    { cls: 'log-cyan', re: /(decode|tok\/s)/gi }
  ];
  var LOG_MAX_LINES = 2000;

  /** 整行主色 = 第一条命中的规则 */
  function logLineClass(line) {
    for (var i = 0; i < LOG_RULES.length; i++) {
      LOG_RULES[i].re.lastIndex = 0;
      if (LOG_RULES[i].re.test(line)) return LOG_RULES[i].cls;
    }
    return '';
  }

  /** 把一行日志按关键字拆成若干带色 span（textContent 写入，不解析 HTML） */
  function highlightInto(parent, line) {
    var marks = new Array(line.length);
    for (var r = 0; r < LOG_RULES.length; r++) {
      var rule = LOG_RULES[r];
      rule.re.lastIndex = 0;
      var m;
      while ((m = rule.re.exec(line)) !== null) {
        if (!m[0].length) { rule.re.lastIndex++; continue; }
        for (var i = m.index; i < m.index + m[0].length; i++) {
          if (!marks[i]) marks[i] = rule.cls;
        }
      }
    }
    var seg = '';
    // 收尾哨兵：marks 里的值只会是 undefined（无高亮）或类名字符串，
    // 所以哨兵必须与两者都不相等；用 null/undefined 会让末尾那一段永远不 flush。
    var END = '\u0000end';
    var cur = END;
    for (var k = 0; k <= line.length; k++) {
      var cls = k < line.length ? marks[k] : END;
      if (cls !== cur) {
        if (seg) {
          if (cur) {
            var sp = document.createElement('span');
            sp.className = cur;
            sp.textContent = seg;
            parent.appendChild(sp);
          } else {
            parent.appendChild(document.createTextNode(seg));
          }
        }
        seg = '';
        cur = cls;
      }
      if (k < line.length) seg += line[k];
    }
  }

  function appendLogLine(line) {
    var view = els.logView;
    if (!view) return;
    var d = document.createElement('div');
    d.className = 'log-line' + (logLineClass(line) ? ' ' + logLineClass(line) : '');
    highlightInto(d, String(line));
    view.appendChild(d);

    // 上限裁剪，避免长时间运行把 DOM 撑爆
    while (view.childElementCount > LOG_MAX_LINES) view.removeChild(view.firstChild);

    if (els.logAutoscroll && els.logAutoscroll.checked) view.scrollTop = view.scrollHeight;
  }

  function clearLog(quiet) {
    if (!els.logView) return;
    els.logView.textContent = '';
    if (!quiet) toast('日志面板已清空（只清界面，不动服务端文件）');
  }

  function setStreamState(txt, cls) {
    if (!els.streamState) return;
    els.streamState.textContent = txt || '';
    els.streamState.className = 'stream-state' + (cls ? ' ' + cls : '');
  }

  /** 读最近 n 行填充面板（用于首次 / 流不可用时的兜底） */
  async function loadLogsTail(n) {
    try {
      var d = await httpJson('/api/logs?n=' + (n || 300));
      if (els.logSize) els.logSize.textContent = fmtBytes(d.bytes);
      if (d.path && els.logPath) els.logPath.textContent = d.path;
      var lines = Array.isArray(d.lines) ? d.lines : [];
      els.logView.textContent = '';
      if (!lines.length) {
        appendLogLine('（日志为空：' + (d.path || 'logs/service.log') + '）');
        return;
      }
      lines.forEach(appendLogLine);
    } catch (e) {
      appendLogLine('[fail] 日志读取失败：' + e.message);
      toast('日志读取失败：' + e.message, 'error');
    }
  }

  /** 下载（走 GET /api/logs?n=5000 拼 Blob，不依赖任何外部资源） */
  async function downloadLogs() {
    try {
      var d = await httpJson('/api/logs?n=5000');
      var lines = Array.isArray(d.lines) ? d.lines : [];
      if (!lines.length) { toast('日志为空，没什么可下载的', 'error'); return; }
      var text = lines.join('\n') + '\n';
      var blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a');
      var ts = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
      a.href = url;
      a.download = 'service-log-' + ts + '.txt';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      setTimeout(function () { URL.revokeObjectURL(url); }, 10000);
      toast('已下载最近 ' + lines.length + ' 行（' + fmtBytes(text.length) + '）', 'ok');
    } catch (e) {
      toast('下载日志失败：' + e.message, 'error');
    }
  }

  function stopStream(quiet) {
    if (state.es) {
      try { state.es.close(); } catch (e) { /* 忽略 */ }
      state.es = null;
    }
    if (!quiet) setStreamState('实时流已暂停', 'off');
  }

  function startStream() {
    if (state.es) return;
    // SSE 连接时会先把最近 200 行推回来；为避免与面板里已有的旧内容重复，先清空
    if (els.logView && els.logView.childElementCount > 0) els.logView.textContent = '';
    state.emptyLogFallback = false;

    var es;
    try {
      es = new EventSource('/api/logs/stream');
    } catch (e) {
      setStreamState('无法建立日志流：' + e.message, 'err');
      toast('无法建立日志流：' + e.message, 'error');
      loadLogsTail(300);
      return;
    }
    state.es = es;
    setStreamState('正在连接实时流…', 'off');

    es.onopen = function () {
      if (state.es !== es) return;
      setStreamState('实时流已连接', 'on');
    };

    es.onmessage = function (ev) {
      if (state.es !== es) return;
      var d;
      try { d = JSON.parse(ev.data); } catch (e) { return; }   // 心跳等非 JSON 直接忽略
      if (d && d.reset) {
        clearLog(true);
        appendLogLine('—— 日志已轮转，面板已清空 ——');
        return;
      }
      if (d && typeof d.line === 'string') {
        state.emptyLogFallback = true;   // 收到过数据，不需要兜底
        appendLogLine(d.line);
      }
    };

    es.onerror = function () {
      if (state.es !== es) return;
      if (es.readyState === EventSource.CLOSED) {
        // 服务端主动断开：浏览器不会自己重连，我们自己来
        stopStream(true);
        setStreamState('实时流断开，3 秒后重连…', 'err');
        if (!state.emptyLogFallback) loadLogsTail(300);
        setTimeout(function () {
          if (els.logFollow && els.logFollow.checked) startStream();
        }, 3000);
      } else {
        setStreamState('实时流重连中…', 'err');
      }
    };
  }

  /** 「跟随实时流」开关 */
  function setFollow(on) {
    if (els.logFollow) els.logFollow.checked = !!on;
    if (els.btnLogPause) els.btnLogPause.textContent = on ? '暂停' : '继续';
    if (on) startStream();
    else stopStream(false);
  }

  /* ==================================================================== *
   * D. 请求指标区
   * ==================================================================== */

  var REQ_COLUMNS = [
    { key: 'time',              label: '时间',          sortable: true },
    { key: 'request_id',        label: 'req#',          sortable: true },
    { key: 'thinking',          label: '思考',          sortable: true },
    { key: 'context',           label: '上下文',        sortable: true },
    { key: 'completion_tokens', label: '输出 tok',      sortable: true },
    { key: 'thinking_tokens',   label: '思考 tok',      sortable: true },
    { key: 'decode_tps',        label: 'decode tok/s',  sortable: true },
    { key: 'accept_pct',        label: '投机接受率',    sortable: true },
    { key: 'ttft_s',            label: 'TTFT',          sortable: true },
    { key: 'total_s',           label: '总耗时',        sortable: true },
    { key: 'finish_reason',     label: 'finish_reason', sortable: true }
  ];

  function sortedRequests() {
    var rows = state.requests.slice();
    if (!state.reqSortKey || !state.reqSortDir) return rows;
    var key = state.reqSortKey, dir = state.reqSortDir;
    rows.sort(function (a, b) {
      var va = sortValue(a, key), vb = sortValue(b, key);
      if (va === null && vb === null) return 0;
      if (va === null) return 1;          // 缺值永远排后面
      if (vb === null) return -1;
      if (va < vb) return -1 * dir;
      if (va > vb) return 1 * dir;
      return 0;
    });
    return rows;
  }

  function sortValue(r, key) {
    if (key === 'context') {
      var m = toNum(r.messages), t = toNum(r.tools);
      if (m === null && t === null) return null;
      return (m || 0) + (t || 0);
    }
    if (key === 'thinking') {
      // on 排前面，并且 on 内部按 budget 比
      var on = r.thinking ? 1 : 0;
      var b = toNum(r.budget) || 0;
      return on * 1000000 + b;
    }
    if (key === 'time') return r.time || null;
    if (key === 'finish_reason') return r.finish_reason || null;
    return toNum(r[key]);
  }

  function tpsClass(v) {
    if (typeof v !== 'number') return '';
    if (v >= 100) return 'tps-hi';
    if (v >= 50) return 'tps-mid';
    return 'tps-lo';
  }

  function cell(text, cls, title) {
    var td = document.createElement('td');
    td.textContent = text;
    if (cls) td.className = cls;
    if (title) td.title = title;
    return td;
  }

  function renderRequests() {
    var head = els.reqHead;
    var body = els.reqBody;
    if (!body) return;

    // 表头排序指示
    if (head) {
      Array.prototype.forEach.call(head.querySelectorAll('th'), function (th) {
        th.classList.remove('sorted-asc', 'sorted-desc');
        if (state.reqSortKey && th.dataset.sort === state.reqSortKey && state.reqSortDir) {
          th.classList.add(state.reqSortDir > 0 ? 'sorted-asc' : 'sorted-desc');
        }
      });
    }

    var rows = sortedRequests();
    var empty = rows.length === 0;

    if (els.reqEmpty) {
      els.reqEmpty.hidden = !empty;
      // 复位文案：否则一次读取失败留下的错误文案会一直挂在空表上
      if (empty) els.reqEmpty.textContent = '还没有请求记录 —— 引擎还没有被调用过';
    }
    if (els.reqTable) els.reqTable.hidden = empty;
    body.textContent = '';

    // 小结始终用「最近 N 条」的服务端顺序原始数据，和排序无关
    renderSummary();

    if (empty) return;

    rows.forEach(function (r) {
      var tr = document.createElement('tr');

      tr.appendChild(cell(r.time || '–'));
      tr.appendChild(cell(num(r.request_id)));

      // 思考：on/off + budget
      var thinkTxt = r.thinking ? ('on' + (r.budget ? ' / ' + r.budget : '')) : (r.thinking === false ? 'off' : '–');
      var thinkTd = cell(thinkTxt, r.thinking ? '' : 'dimc');
      tr.appendChild(thinkTd);

      // 上下文：messages + tools
      var mc = toNum(r.messages), tc = toNum(r.tools);
      tr.appendChild(cell((mc === null ? '?' : mc) + ' msg + ' + (tc === null ? '?' : tc) + ' tools'));

      tr.appendChild(cell(num(r.completion_tokens)));
      tr.appendChild(cell(num(r.thinking_tokens)));

      var tps = toNum(r.decode_tps);
      tr.appendChild(cell(num(tps, 1), tpsClass(tps)));

      var acc = toNum(r.accept_pct);
      tr.appendChild(cell(acc === null ? '–' : num(acc, 1) + '%',
        acc === null ? '' : (acc >= 50 ? 'tps-hi' : (acc >= 20 ? 'tps-mid' : 'tps-lo'))));

      tr.appendChild(cell(r.ttft_s === null || r.ttft_s === undefined ? '–' : num(r.ttft_s, 2) + 's'));
      tr.appendChild(cell(r.total_s === null || r.total_s === undefined ? '–' : num(r.total_s, 2) + 's'));

      var fr = r.finish_reason || '–';
      tr.appendChild(cell(fr, fr === 'length' ? 'fr-length' : (fr === 'stop_token' || fr === 'stop' ? 'fr-ok' : '')));

      body.appendChild(tr);
    });
  }

  function renderSummary() {
    if (!els.reqSummary) return;
    var rows = state.requests;
    if (!rows.length) {
      els.reqSummary.textContent = '还没有请求记录 —— 引擎还没有被调用过';
      return;
    }
    var tps = [];
    var acc = [];
    var fr = {};
    rows.forEach(function (r) {
      var t = toNum(r.decode_tps);
      if (t !== null) tps.push(t);
      var a = toNum(r.accept_pct);
      if (a !== null) acc.push(a);
      var k = r.finish_reason || '(空)';
      fr[k] = (fr[k] || 0) + 1;
    });
    var md = median(tps), ma = median(acc);
    var dist = Object.keys(fr).map(function (k) { return k + '×' + fr[k]; }).join('，');
    els.reqSummary.textContent = '最近 ' + rows.length + ' 条：中位 decode ' +
      (md === null ? '–' : md.toFixed(1) + ' tok/s') +
      ' · 中位接受率 ' + (ma === null ? '–' : ma.toFixed(1) + '%') +
      ' · finish_reason 分布：' + dist;
  }

  async function refreshRequests() {
    if (document.hidden) return;
    try {
      var d = await httpJson('/api/requests?n=50');
      state.requests = (d && Array.isArray(d.requests)) ? d.requests : [];
      if (els.reqBytes) els.reqBytes.textContent = '（request.jsonl ' + fmtBytes(d.bytes) + (d.path ? ' · ' + d.path : '') + '）';
      renderRequests();
    } catch (e) {
      if (els.reqSummary) els.reqSummary.textContent = '请求指标读取失败：' + e.message;
      if (els.reqEmpty) { els.reqEmpty.hidden = false; els.reqEmpty.textContent = '请求指标读取失败：' + e.message; }
      if (els.reqTable) els.reqTable.hidden = true;
    }
  }

  function bindSorting() {
    if (!els.reqHead) return;
    Array.prototype.forEach.call(els.reqHead.querySelectorAll('th[data-sort]'), function (th) {
      th.addEventListener('click', function () {
        var key = th.dataset.sort;
        if (state.reqSortKey !== key) {
          state.reqSortKey = key;
          state.reqSortDir = 1;
        } else if (state.reqSortDir === 1) {
          state.reqSortDir = -1;
        } else {
          state.reqSortKey = null;   // 第三次点击回到服务端原序（新→旧）
          state.reqSortDir = 0;
        }
        renderRequests();
      });
    });
  }

  /* ==================================================================== *
   * 事件绑定 + 启动
   * ==================================================================== */

  function bindEvents() {
    // 状态栏刷新
    if (els.btnRefresh) {
      els.btnRefresh.addEventListener('click', async function () {
        await refreshStatus();
        await refreshRequests();
        await loadGpus();
        toast('已刷新', 'ok');
      });
    }

    // 预设
    if (els.inPreset) els.inPreset.addEventListener('change', renderPresetDesc);

    // KV 容量快捷按钮
    Array.prototype.forEach.call(document.querySelectorAll('button[data-kv-quick]'), function (b) {
      b.addEventListener('click', function () {
        if (els.inKvCapacity) {
          els.inKvCapacity.value = b.dataset.kvQuick;
          els.inKvCapacity.title = '点了快捷按钮：' + b.textContent;
        }
      });
    });

    // 动作按钮：全部必须用户点击，代码里不自动触发
    if (els.btnStart) els.btnStart.addEventListener('click', function () { runAction('start'); });
    if (els.btnStop) els.btnStop.addEventListener('click', function () {
      if (state.status && !state.status.running) { toast('引擎没在跑，不需要停止', 'error'); return; }
      runAction('stop');
    });
    if (els.btnRestart) els.btnRestart.addEventListener('click', function () { runAction('restart'); });
    if (els.btnSave) els.btnSave.addEventListener('click', function () { saveConfig(); });

    // 日志工具栏
    if (els.logFollow) {
      els.logFollow.addEventListener('change', function () { setFollow(els.logFollow.checked); });
    }
    if (els.btnLogPause) {
      els.btnLogPause.addEventListener('click', function () {
        var next = !(els.logFollow && els.logFollow.checked);
        setFollow(next);
      });
    }
    if (els.btnLogClear) els.btnLogClear.addEventListener('click', function () { clearLog(false); });
    if (els.btnLogDownload) els.btnLogDownload.addEventListener('click', function () { downloadLogs(); });

    // 用户手动往上滚 → 自动取消「自动滚动」
    if (els.logView) {
      els.logView.addEventListener('scroll', function () {
        var v = els.logView;
        var atBottom = (v.scrollHeight - v.scrollTop - v.clientHeight) < 30;
        if (!atBottom && els.logAutoscroll && els.logAutoscroll.checked) {
          els.logAutoscroll.checked = false;
        }
      });
    }

    // 请求表格排序 + 手动刷新
    bindSorting();
    if (els.btnReqRefresh) els.btnReqRefresh.addEventListener('click', function () { refreshRequests(); });

    // 页面重新可见时立刻补一次（隐藏期间暂停了轮询）
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) {
        refreshStatus();
        refreshRequests();
      }
    });
  }

  async function init() {
    bindEvents();

    // 并行拉三份静态数据（互不依赖）
    await Promise.all([
      loadPresets().catch(function (e) { toast('预设加载异常：' + e.message, 'error'); }),
      loadConfig().catch(function (e) { toast('配置加载异常：' + e.message, 'error'); }),
      loadGpus().catch(function (e) { toast('GPU 加载异常：' + e.message, 'error'); })
    ]);

    await refreshStatus();
    await refreshRequests();

    // 日志：默认跟随实时流（SSE 会先补最近 200 行）
    setFollow(true);

    scheduleStatus();
    setInterval(refreshRequests, 5000);   // 请求指标每 5 秒
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

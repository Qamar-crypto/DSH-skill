window.__ModuleLoader__.load({ id: "dsh-plugin-mimo-delegate", factory: (require) => { var module = { exports: {} };
var React = require("react");
var jsxRuntime = require("react/jsx-runtime");
var NS = "mimo-delegate";
var BRIDGE_PATH = "D:\\Deepseek Harness\\_mimo_bridge\\MimoDesktop.ps1";
var SKILL_PATH = "C:\\Users\\MI\\.dsh\\skills\\mimo-delegate\\SKILL.md";
var DEFAULT_PROJECT_DIR = "D:\\Deepseek Harness";
var DEFAULT_TASK_TEXT = "只回一行：ok";

var DICT_ZH = {
  cardTitle: "MiMo 委托 · mimo-delegate",
  cardDesc: "把脏活累活交给本机免费的小米 MiMo Desktop，由 DSH 负责验收。",
  bridgeLabel: "桥：",
  skillLabel: "技能：",
  statusOn: "已启用",
  statusOff: "已停用",
  loading: "读取中…",
  btnEnable: "启用",
  btnDisable: "停用",
  btnOn: "开",
  btnOff: "关",
  footerOn: "MiMo 委托 · 开",
  footerOff: "MiMo 委托 · 关",
  footerLoading: "MiMo 委托 · …",
  note: "改动会立即移动技能目录并改写 ~/.dsh/AGENTS.md 的规则块",
  folderLabel: "项目文件夹：",
  taskLabel: "任务文本：",
  btnNewProject: "在 MiMo 新建项目",
  btnNewTask: "在 MiMo 新建会话并发起任务",
  opRunning: "进行中…",
  opIdle: "（尚未发起桥操作）",
  opDone: "完成：",
  opFail: "失败："
};

var DICT_EN = {
  cardTitle: "MiMo Delegate · mimo-delegate",
  cardDesc: "Hand heavy lifting to free local Xiaomi MiMo Desktop; DSH reviews the result.",
  bridgeLabel: "Bridge: ",
  skillLabel: "Skill: ",
  statusOn: "Enabled",
  statusOff: "Disabled",
  loading: "Loading…",
  btnEnable: "Enable",
  btnDisable: "Disable",
  btnOn: "On",
  btnOff: "Off",
  footerOn: "MiMo Delegate · On",
  footerOff: "MiMo Delegate · Off",
  footerLoading: "MiMo Delegate · …",
  note: "Changes immediately move the skill directory and rewrite the rule block in ~/.dsh/AGENTS.md",
  folderLabel: "Project folder: ",
  taskLabel: "Task text: ",
  btnNewProject: "Create MiMo project",
  btnNewTask: "Create MiMo session + task",
  opRunning: "Running…",
  opIdle: "(no bridge action yet)",
  opDone: "OK: ",
  opFail: "Failed: "
};

function pickDict() {
  var lang = "";
  try {
    if (typeof navigator !== "undefined" && navigator.language) lang = String(navigator.language);
  } catch (e) {
    try { console.warn("[mimo-delegate]", "navigator.language failed", e); } catch (e2) {}
  }
  return /^zh/i.test(lang) ? DICT_ZH : DICT_EN;
}

function useSettings(settings) {
  return React.useSyncExternalStore(
    function (cb) { return settings.subscribe(cb); },
    function () { return settings.getSnapshot(); }
  );
}

function formatSetError(err) {
  var msg = String((err && err.message) || err || "unknown error");
  if (msg.length > 160) msg = msg.substring(0, 160);
  return msg;
}

function performToggle(settings, current, onOk, onFail) {
  var settled = false;
  var ok = function () {
    if (settled) return;
    settled = true;
    if (typeof onOk === "function") onOk();
  };
  var fail = function (err) {
    if (settled) return;
    settled = true;
    var msg = formatSetError(err);
    try { console.warn("[mimo-delegate]", msg); } catch (e) {}
    if (typeof onFail === "function") onFail(msg);
  };
  try {
    var p = settings.set("enabled", !current);
    if (p && typeof p.then === "function") p.then(ok, fail);
    else ok();
  } catch (e) {
    fail(e);
  }
}

/** Start a bridge op: prefer direct host API, else write settings for the host. */
function startBridgeOp(settings, hostApi, kind, dir, message, onLocal) {
  var payload = { ok: false, error: "", data: null };
  var finish = function (result) {
    try {
      if (result && result.ok) {
        var detail = "ok";
        try {
          if (result.data && result.data.sessionId) detail = String(result.data.sessionId);
          else if (result.data && result.data.dir) detail = "ok dir=" + result.data.dir;
          else if (result.data) detail = JSON.stringify(result.data);
        } catch (e) {}
        onLocal({ ok: true, text: detail });
      } else {
        onLocal({ ok: false, text: String((result && result.error) || "bridge failed") });
      }
    } catch (e) {
      onLocal({ ok: false, text: formatSetError(e) });
    }
  };

  // 1) direct host method if the context exposed one
  try {
    if (hostApi && kind === "newproject" && typeof hostApi.newProject === "function") {
      var p1 = hostApi.newProject(dir);
      if (p1 && typeof p1.then === "function") {
        p1.then(finish, function (e) { finish({ ok: false, error: formatSetError(e) }); });
        return;
      }
    }
    if (hostApi && kind === "newtask" && typeof hostApi.newTask === "function") {
      var p2 = hostApi.newTask(dir, message);
      if (p2 && typeof p2.then === "function") {
        p2.then(finish, function (e) { finish({ ok: false, error: formatSetError(e) }); });
        return;
      }
    }
  } catch (e) {
    // fall through to settings-driven path
  }

  // 2) settings-driven path (host observe() picks this up)
  try { settings.set("op", kind); } catch (e) {}
  try { settings.set("opStatus", "running"); } catch (e) {}
  try { settings.set("opResult", ""); } catch (e) {}
  try { settings.set("opSessionId", ""); } catch (e) {}
  try { settings.set("projectDir", dir); } catch (e) {}
  try { if (kind === "newtask") settings.set("taskText", message); } catch (e) {}
}

var styles = {
  card: {
    padding: "12px 14px",
    borderRadius: "10px",
    border: "1px solid rgba(120,140,170,0.35)",
    background: "rgba(16,20,32,0.92)",
    color: "#e8f0ff",
    fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif",
    fontSize: "13px",
    lineHeight: "1.5",
    position: "relative"
  },
  cardTitle: {
    fontSize: "15px",
    fontWeight: 600,
    marginBottom: "6px",
    color: "#e8f0ff"
  },
  cardDesc: {
    marginBottom: "8px",
    color: "#b7c4d8"
  },
  meta: {
    fontFamily: "ui-monospace, Consolas, monospace",
    fontSize: "11px",
    color: "#8fa0b8",
    wordBreak: "break-all",
    marginBottom: "2px"
  },
  statusRow: {
    marginTop: "8px",
    marginBottom: "8px",
    display: "flex",
    alignItems: "center",
    gap: "8px",
    flexWrap: "wrap"
  },
  statusOn: { color: "#7dffb3", fontWeight: 600 },
  statusOff: { color: "#ffc857", fontWeight: 600 },
  statusLoading: { color: "#7a8bb0", fontWeight: 600 },
  error: {
    marginTop: "4px",
    marginBottom: "4px",
    color: "#ff5c5c",
    fontSize: "11px",
    wordBreak: "break-all"
  },
  opOk: {
    marginTop: "4px",
    color: "#7dffb3",
    fontSize: "11px",
    wordBreak: "break-all"
  },
  opIdle: {
    marginTop: "4px",
    color: "#7a8bb0",
    fontSize: "11px"
  },
  toggle: {
    appearance: "none",
    border: "1px solid rgba(92,225,230,0.45)",
    background: "rgba(92,225,230,0.12)",
    color: "#5ce1e6",
    borderRadius: "8px",
    padding: "4px 12px",
    fontSize: "12px",
    cursor: "pointer",
    lineHeight: "1.4"
  },
  toggleOn: {
    border: "1px solid rgba(255,158,90,0.5)",
    background: "rgba(255,158,90,0.12)",
    color: "#ff9e5a"
  },
  toggleDisabled: {
    opacity: 0.5,
    cursor: "not-allowed"
  },
  fieldRow: {
    display: "flex",
    alignItems: "center",
    gap: "6px",
    marginTop: "6px",
    flexWrap: "wrap"
  },
  fieldLabel: {
    color: "#8fa0b8",
    fontSize: "11px",
    minWidth: "72px"
  },
  fieldInput: {
    flex: "1 1 180px",
    minWidth: "160px",
    boxSizing: "border-box",
    padding: "4px 6px",
    borderRadius: "6px",
    border: "1px solid rgba(120,140,170,0.4)",
    background: "rgba(8,12,24,0.85)",
    color: "#e8f0ff",
    fontSize: "12px",
    outline: "none"
  },
  note: {
    marginTop: "10px",
    textAlign: "right",
    fontSize: "10px",
    color: "#6d7c93"
  },
  footerBtn: {
    display: "flex",
    alignItems: "center",
    gap: "6px",
    width: "100%",
    boxSizing: "border-box",
    padding: "6px 8px",
    border: "1px solid rgba(120,140,170,0.28)",
    background: "transparent",
    color: "#c9d4e8",
    borderRadius: "8px",
    fontSize: "12px",
    cursor: "pointer",
    lineHeight: "1.3",
    fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif",
    textAlign: "left"
  },
  footerBtnHover: {
    background: "rgba(92,225,230,0.12)",
    color: "#e8f0ff"
  },
  footerBtnDisabled: {
    opacity: 0.55,
    cursor: "not-allowed"
  },
  icon: {
    width: "10px",
    height: "10px",
    flex: "0 0 auto",
    display: "block"
  }
};

function SvgDot(props) {
  var on = !!props.on;
  var fill = on ? "#7dffb3" : "#ffc857";
  return React.createElement(
    "svg",
    { style: styles.icon, viewBox: "0 0 10 10", "aria-hidden": "true", focusable: "false" },
    React.createElement("rect", { x: 1, y: 1, width: 8, height: 8, rx: 2, fill: fill })
  );
}

function Card(props) {
  var settings = props.settings;
  var hostApi = props.hostApi || null;
  var t = pickDict();
  var snap = useSettings(settings);
  var errState = React.useState("");
  var err = errState[0];
  var setErr = errState[1];
  var folderState = React.useState("");
  var taskState = React.useState("");
  var opState = React.useState({ kind: "", text: "", ok: null });

  var status = snap && snap.status;
  var ready = status === "ready";
  var value = (snap && snap.value) || {};
  var enabled = !!value.enabled;
  var statusText = !ready ? t.loading : enabled ? t.statusOn : t.statusOff;
  var statusColor = !ready ? styles.statusLoading : enabled ? styles.statusOn : styles.statusOff;

  var folder = folderState[0] !== "" ? folderState[0] : (value.projectDir || DEFAULT_PROJECT_DIR);
  var taskText = taskState[0] !== "" ? taskState[0] : (value.taskText || DEFAULT_TASK_TEXT);
  var setFolder = folderState[1];
  var setTask = taskState[1];
  var op = opState[0];
  var setOp = opState[1];

  var busy = !!(op && op.kind && (op.text === t.opRunning));
  var hostRunning = value.opStatus === "running";

  var btnStyle = Object.assign({}, styles.toggle, enabled ? styles.toggleOn : null, !ready ? styles.toggleDisabled : null);
  var btnLabel = !ready ? t.loading : enabled ? t.btnDisable : t.btnEnable;
  var btnTitle = !ready ? t.loading : enabled ? t.btnDisable : t.btnEnable;

  var bridgeBtnStyle = Object.assign({}, styles.toggle, (busy || hostRunning) ? styles.toggleDisabled : null);

  var opLine = null;
  if (hostRunning) {
    opLine = React.createElement("div", { style: styles.opIdle }, t.opRunning);
  } else if (op && op.kind) {
    if (op.ok === true) {
      opLine = React.createElement("div", { style: styles.opOk }, t.opDone + op.text);
    } else if (op.ok === false) {
      opLine = React.createElement("div", { style: styles.error, role: "alert" }, t.opFail + op.text);
    } else {
      opLine = React.createElement("div", { style: styles.opIdle }, op.text || t.opRunning);
    }
  } else if (value.opStatus === "done" && value.opResult) {
    opLine = React.createElement("div", { style: styles.opOk }, t.opDone + value.opResult + (value.opSessionId ? " · session=" + value.opSessionId : ""));
  } else if (value.opStatus === "error" && value.opResult) {
    opLine = React.createElement("div", { style: styles.error, role: "alert" }, t.opFail + value.opResult);
  } else {
    opLine = React.createElement("div", { style: styles.opIdle }, t.opIdle);
  }

  function onBridge(kind) {
    if (!ready || busy || hostRunning) return;
    var dir = String(folder || "").trim();
    var msg = String(taskText || "").trim();
    if (!dir) {
      setOp({ kind: "", text: t.opFail + "project folder is empty", ok: false });
      return;
    }
    if (kind === "newtask" && !msg) {
      setOp({ kind: "", text: t.opFail + "task message is empty", ok: false });
      return;
    }
    setErr("");
    setOp({ kind: kind, text: t.opRunning, ok: null });
    startBridgeOp(settings, hostApi, kind, dir, msg, function (res) {
      setOp({ kind: kind, text: res.text, ok: !!res.ok });
      if (!res.ok) {
        try { console.warn("[mimo-delegate]", res.text); } catch (e) {}
      }
    });
  }

  return React.createElement(
    "div",
    { style: styles.card, "data-key": NS },
    React.createElement("div", { style: styles.cardTitle }, t.cardTitle),
    React.createElement("div", { style: styles.cardDesc }, t.cardDesc),
    React.createElement(
      "div",
      { style: styles.meta },
      t.bridgeLabel,
      BRIDGE_PATH
    ),
    React.createElement(
      "div",
      { style: styles.meta },
      t.skillLabel,
      SKILL_PATH
    ),
    React.createElement(
      "div",
      { style: styles.statusRow },
      React.createElement("span", { style: statusColor }, statusText),
      React.createElement(
        "button",
        {
          type: "button",
          style: btnStyle,
          disabled: !ready,
          title: btnTitle,
          onClick: function () {
            if (!ready) return;
            performToggle(
              settings,
              enabled,
              function () { setErr(""); },
              function (msg) { setErr(msg); }
            );
          }
        },
        btnLabel
      )
    ),
    err
      ? React.createElement("div", { style: styles.error, role: "alert" }, err)
      : null,
    React.createElement(
      "div",
      { style: styles.fieldRow },
      React.createElement("span", { style: styles.fieldLabel }, t.folderLabel),
      React.createElement("input", {
        type: "text",
        style: styles.fieldInput,
        value: folder,
        spellCheck: false,
        placeholder: DEFAULT_PROJECT_DIR,
        onChange: function (e) {
          var v = e && e.target ? e.target.value : "";
          setFolder(v);
        }
      })
    ),
    React.createElement(
      "div",
      { style: styles.fieldRow },
      React.createElement("span", { style: styles.fieldLabel }, t.taskLabel),
      React.createElement("input", {
        type: "text",
        style: styles.fieldInput,
        value: taskText,
        spellCheck: false,
        placeholder: DEFAULT_TASK_TEXT,
        onChange: function (e) {
          var v = e && e.target ? e.target.value : "";
          setTask(v);
        }
      })
    ),
    React.createElement(
      "div",
      { style: styles.statusRow },
      React.createElement(
        "button",
        {
          type: "button",
          style: bridgeBtnStyle,
          disabled: !ready || busy || hostRunning,
          title: t.btnNewProject,
          onClick: function () { onBridge("newproject"); }
        },
        busy && op && op.kind === "newproject" ? t.opRunning : t.btnNewProject
      ),
      React.createElement(
        "button",
        {
          type: "button",
          style: bridgeBtnStyle,
          disabled: !ready || busy || hostRunning,
          title: t.btnNewTask,
          onClick: function () { onBridge("newtask"); }
        },
        busy && op && op.kind === "newtask" ? t.opRunning : t.btnNewTask
      )
    ),
    opLine,
    React.createElement("div", { style: styles.note }, t.note)
  );
}

function FooterButton(props) {
  var settings = props.settings;
  var t = pickDict();
  var snap = useSettings(settings);
  var errState = React.useState("");
  var err = errState[0];
  var setErr = errState[1];
  var hoverState = React.useState(false);
  var hover = hoverState[0];
  var setHover = hoverState[1];
  var status = snap && snap.status;
  var ready = status === "ready";
  var value = (snap && snap.value) || {};
  var enabled = !!value.enabled;
  var baseLabel = !ready ? t.footerLoading : enabled ? t.footerOn : t.footerOff;
  var label = err ? baseLabel + "!" : baseLabel;
  var title = !ready
    ? t.loading
    : err
      ? baseLabel + " — " + err
      : baseLabel;

  var btnStyle = Object.assign({}, styles.footerBtn, hover && ready ? styles.footerBtnHover : null, !ready ? styles.footerBtnDisabled : null);

  return React.createElement(
    "button",
    {
      type: "button",
      style: btnStyle,
      title: title,
      "aria-pressed": ready ? (enabled ? "true" : "false") : "false",
      disabled: !ready,
      onMouseEnter: function () { setHover(true); },
      onMouseLeave: function () { setHover(false); },
      onClick: function () {
        if (!ready) return;
        performToggle(
          settings,
          enabled,
          function () { setErr(""); },
          function (msg) { setErr(msg); }
        );
      }
    },
    React.createElement(SvgDot, { on: enabled && ready }),
    React.createElement("span", null, label)
  );
}

// Keep a single literal for each slot name in the bundle (see accept counts).
var SLOT_PLUGIN_ITEM = "settings.plugin.item";
var SLOT_SIDEBAR_FOOTER = "sidebar.footer.action";

module.exports = {
  // The client module contract is the Cordis plugin shape (name / inject /
  // apply), exactly as a working third-party client half declares it. An
  // invented { id, activate } shape registers nothing.
  name: "dsh-plugin-mimo-delegate",
  inject: ["slots", "locale"],
  apply: function (ctx) {
    if (!ctx || typeof ctx.inject !== "function") return;
    ctx.inject(["settingsScope"], function (c) {
      if (!c || !c.settingsScope || !c.slots) return;
      var settings = c.settingsScope.bind({ namespace: NS });
      var hostApi = null;
      try {
        if (c.mimoDelegate) hostApi = c.mimoDelegate;
        else if (c[NS]) hostApi = c[NS];
        else if (ctx && ctx.mimoDelegate) hostApi = ctx.mimoDelegate;
      } catch (e) {
        hostApi = null;
      }
      var injectSettings = function () { return { settings: settings, hostApi: hostApi }; };

      c.slots.inject(SLOT_PLUGIN_ITEM, function () {
        return c.slots.register(
          {
            name: SLOT_PLUGIN_ITEM,
            key: NS,
            locale: NS,
            inject: injectSettings
          },
          Card
        );
      });

      c.slots.inject(SLOT_SIDEBAR_FOOTER, function () {
        return c.slots.register(
          {
            name: SLOT_SIDEBAR_FOOTER,
            id: NS,
            order: 5,
            locale: NS,
            inject: injectSettings
          },
          FooterButton
        );
      });
    });
  }
};

return module.exports; } });

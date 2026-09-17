window.__ModuleLoader__.load({ id: "dsh-plugin-mimo-delegate", factory: (require) => { var module = { exports: {} };
var React = require("react");
var jsxRuntime = require("react/jsx-runtime");
var NS = "mimo-delegate";
var BRIDGE_PATH = "D:\\Deepseek Harness\\_mimo_bridge\\MimoDesktop.ps1";
var SKILL_PATH = "C:\\Users\\MI\\.dsh\\skills\\mimo-delegate\\SKILL.md";

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
  note: "改动会立即移动技能目录并改写 ~/.dsh/AGENTS.md 的规则块"
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
  note: "Changes immediately move the skill directory and rewrite the rule block in ~/.dsh/AGENTS.md"
};

function pickDict() {
  var lang = "";
  try {
    if (typeof navigator !== "undefined" && navigator.language) lang = String(navigator.language);
  } catch (e) { /* ignore */ }
  return /^zh/i.test(lang) ? DICT_ZH : DICT_EN;
}

function useSettings(settings) {
  return React.useSyncExternalStore(
    function (cb) { return settings.subscribe(cb); },
    function () { return settings.getSnapshot(); }
  );
}

function safeToggle(settings, current) {
  try {
    settings.set("enabled", !current);
  } catch (e) { /* ignore */ }
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
    gap: "8px"
  },
  statusOn: { color: "#7dffb3", fontWeight: 600 },
  statusOff: { color: "#ffc857", fontWeight: 600 },
  statusLoading: { color: "#7a8bb0", fontWeight: 600 },
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
    border: "rgba(255,158,90,0.5)",
    background: "rgba(255,158,90,0.12)",
    color: "#ff9e5a"
  },
  toggleDisabled: {
    opacity: 0.5,
    cursor: "not-allowed"
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
  var t = pickDict();
  var snap = useSettings(settings);
  var status = snap && snap.status;
  var ready = status === "ready";
  var value = (snap && snap.value) || {};
  var enabled = !!value.enabled;
  var statusText = !ready ? t.loading : enabled ? t.statusOn : t.statusOff;
  var statusColor = !ready ? styles.statusLoading : enabled ? styles.statusOn : styles.statusOff;

  var btnStyle = Object.assign({}, styles.toggle, enabled ? styles.toggleOn : null, !ready ? styles.toggleDisabled : null);
  var btnLabel = !ready ? t.loading : enabled ? t.btnDisable : t.btnEnable;

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
          onClick: function () {
            if (!ready) return;
            safeToggle(settings, enabled);
          }
        },
        btnLabel
      )
    ),
    React.createElement("div", { style: styles.note }, t.note)
  );
}

function FooterButton(props) {
  var settings = props.settings;
  var t = pickDict();
  var snap = useSettings(settings);
  var status = snap && snap.status;
  var ready = status === "ready";
  var value = (snap && snap.value) || {};
  var enabled = !!value.enabled;
  var label = !ready ? t.footerLoading : enabled ? t.footerOn : t.footerOff;
  var hoverState = React.useState(false);
  var hover = hoverState[0];
  var setHover = hoverState[1];

  var btnStyle = Object.assign({}, styles.footerBtn, hover && ready ? styles.footerBtnHover : null, !ready ? styles.footerBtnDisabled : null);

  return React.createElement(
    "button",
    {
      type: "button",
      style: btnStyle,
      title: label,
      "aria-pressed": ready ? (enabled ? "true" : "false") : "false",
      disabled: !ready,
      onMouseEnter: function () { setHover(true); },
      onMouseLeave: function () { setHover(false); },
      onClick: function () {
        if (!ready) return;
        safeToggle(settings, enabled);
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
  id: NS,
  activate: function (ctx) {
    if (!ctx || typeof ctx.inject !== "function") return;
    ctx.inject(["settingsScope"], function (c) {
      if (!c || !c.settingsScope || !c.slots) return;
      var settings = c.settingsScope.bind({ namespace: NS });
      var injectSettings = function () { return { settings: settings }; };

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

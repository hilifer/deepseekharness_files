/**
 * dsh-plugin-market client half — Settings → 插件市场 page.
 *
 * Communicates with the admin backend through nginx's /plugin-market/ route
 * (forwarded to admin with the employee's Remote-User), NOT through the local
 * DSH instance — install/uninstall + whitelist all live in admin/core.py.
 */
window.__ModuleLoader__.load({
	id: "dsh-plugin-market",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");
		const createElement = react.createElement;

		const inject = ["slots"];

		const css = `
.pmk_section{display:flex;flex-direction:column;gap:14px;padding:0 24px 24px}
.pmk_row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.pmk_title{font-weight:600;font-size:14px}
.pmk_meta{font-size:12px;color:var(--dsw-alias-label-secondary,#888)}
.pmk_err{color:#c62828;font-size:12px}
.pmk_ok{color:#2e7d32;font-size:12px}
.pmk_btn{cursor:pointer;font-size:12px;padding:5px 12px;border-radius:8px;border:1px solid rgba(128,128,128,.5);background:transparent;color:inherit}
.pmk_btn:hover{background:rgba(128,128,128,.12)}
.pmk_btn:disabled{opacity:.5;cursor:default}
.pmk_btn.primary{border-color:transparent;background:#1976d2;color:#fff}
.pmk_btn.danger{border-color:#c62828;color:#c62828}
.pmk_list{display:flex;flex-direction:column;gap:10px}
.pmk_card{border:1px solid rgba(128,128,128,.3);border-radius:12px;padding:12px 16px;display:flex;align-items:center;gap:12px}
.pmk_name{font-weight:600;font-size:13px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.pmk_badge{font-size:11px;padding:1px 7px;border-radius:8px;border:1px solid rgba(128,128,128,.4);white-space:nowrap}
.pmk_badge.on{color:#2e7d32;border-color:#2e7d32}
.pmk_badge.off{color:var(--dsw-alias-label-secondary,#888)}
.pmk_spacer{flex:1}
.pmk_empty{padding:24px;text-align:center;color:var(--dsw-alias-label-secondary,#888);font-size:12px}`;
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=\"dsh-plugin-market/section\"]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "dsh-plugin-market";
			tag.dataset.pluginCss = "dsh-plugin-market/section";
			tag.textContent = css;
			document.head.appendChild(tag);
		}

		function esc(s) {
			return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
		}

		function api(path, options) {
			return fetch("/plugin-market/api" + path, {
				headers: { "Content-Type": "application/json" },
				...options,
			}).then(async (resp) => ({ ok: resp.ok, status: resp.status, body: await resp.json().catch(() => ({})) }));
		}

		function PluginCard({ p, onAction, busy }) {
			return createElement("div", { className: "pmk_card" },
				createElement("span", { className: "pmk_name" }, esc(p.name)),
				createElement("span", { className: "pmk_badge " + (p.installed ? "on" : "off") }, p.installed ? "已安装" : "未安装"),
				createElement("span", { className: "pmk_spacer" }),
				p.installed
					? createElement("button", { className: "pmk_btn danger", onClick: () => onAction(p, "uninstall"), disabled: busy === p.name }, busy === p.name ? "…" : "卸载")
					: createElement("button", { className: "pmk_btn primary", onClick: () => onAction(p, "install"), disabled: busy === p.name }, busy === p.name ? "…" : "安装"),
			);
		}

		function PluginMarketSection() {
			const [plugins, setPlugins] = react.useState(null);
			const [busy, setBusy] = react.useState("");
			const [msg, setMsg] = react.useState({ kind: "", text: "" });

			const refresh = react.useCallback(() => {
				setMsg({ kind: "", text: "" });
				api("/list").then((r) => {
					if (r.ok) setPlugins(r.body.plugins || []);
					else setMsg({ kind: "err", text: r.body.error || "加载失败" });
				}).catch((e) => setMsg({ kind: "err", text: String(e) }));
			}, []);

			react.useEffect(() => { refresh(); }, [refresh]);

			const onAction = async (p, action) => {
				setBusy(p.name);
				setMsg({ kind: "", text: "" });
				try {
					const r = await api("/" + action, { method: "POST", body: JSON.stringify({ plugin: p.name }) });
					if (r.ok) {
						setMsg({ kind: "ok", text: (action === "install" ? "已安装 " : "已卸载 ") + p.name + "，实例正在重启生效…" });
						refresh();
					} else {
						setMsg({ kind: "err", text: r.body.error || (action + "失败 (HTTP " + r.status + ")") });
					}
				} catch (e) {
					setMsg({ kind: "err", text: String(e) });
				}
				setBusy("");
			};

			return createElement("div", { className: "pmk_section" },
				createElement("div", { className: "pmk_row" },
					createElement("span", { className: "pmk_title" }, "插件市场"),
					createElement("span", { className: "pmk_meta" }, "共 " + (plugins ? plugins.length : 0) + " 个可选"),
					createElement("div", { style: { marginLeft: "auto" } },
						createElement("button", { className: "pmk_btn", onClick: refresh }, "刷新"),
					),
				),
				createElement("div", { className: "pmk_meta" }, "这里列出的插件由管理员白名单控制，安装是每员工独立的，互不影响。安装/卸载后实例会自动重启。"),
				msg.text ? createElement("div", { className: msg.kind === "err" ? "pmk_err" : "pmk_ok" }, msg.text) : null,
				plugins === null
					? createElement("div", { className: "pmk_empty" }, "加载中…")
					: plugins.length === 0
						? createElement("div", { className: "pmk_empty" }, "暂无可安装的插件（管理员尚未配置白名单）")
						: createElement("div", { className: "pmk_list" },
							plugins.map((p) => createElement(PluginCard, { key: p.name, p, onAction, busy })),
						),
			);
		}

		function apply(ctx) {
			ctx.slots.inject("settings.section", () => ctx.slots.register({
				name: "settings.section",
				id: "plugin-market",
				order: 43,
				label: "插件市场",
			}, PluginMarketSection));
		}

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});

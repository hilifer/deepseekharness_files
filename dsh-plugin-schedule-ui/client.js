/**
 * dsh-schedule-ui client half — Settings → 定时任务 page.
 *
 * Authored in the DSH client module format (window.__ModuleLoader__), the same
 * delivery shape as dsh-wechat's prebuilt client bundle. Communicates with the
 * host through the plugin's own HTTP API (/schedule-ui/api/*) registered on the
 * GUI webserver — no @deepseek-ai imports at runtime.
 */
window.__ModuleLoader__.load({
	id: "dsh-schedule-ui",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");
		const createElement = react.createElement;

		const inject = ["slots"];

		const css = `
.sch_section{display:flex;flex-direction:column;gap:14px;padding:0 24px 24px}
.sch_row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.sch_title{font-weight:600;font-size:14px}
.sch_meta{font-size:12px;color:var(--dsw-alias-label-secondary,#888)}
.sch_err{color:#c62828;font-size:12px}
.sch_ok{color:#2e7d32;font-size:12px}
.sch_btn{cursor:pointer;font-size:12px;padding:5px 12px;border-radius:8px;border:1px solid rgba(128,128,128,.5);background:transparent;color:inherit}
.sch_btn:hover{background:rgba(128,128,128,.12)}
.sch_btn:disabled{opacity:.5;cursor:default}
.sch_btn.primary{border-color:transparent;background:#1976d2;color:#fff}
.sch_btn.danger{border-color:#c62828;color:#c62828}
.sch_tbl{width:100%;border-collapse:collapse;font-size:13px}
.sch_tbl th{text-align:left;font-size:11px;color:var(--dsw-alias-label-secondary,#888);font-weight:600;padding:6px 10px;border-bottom:1px solid rgba(128,128,128,.25)}
.sch_tbl td{padding:8px 10px;border-bottom:1px solid rgba(128,128,128,.12);vertical-align:middle}
.sch_tbl tr:last-child td{border-bottom:none}
.sch_empty{padding:24px;text-align:center;color:var(--dsw-alias-label-secondary,#888);font-size:12px}
.sch_badge{font-size:11px;padding:1px 7px;border-radius:8px;border:1px solid rgba(128,128,128,.4);white-space:nowrap}
.sch_badge.after{color:#1976d2;border-color:#1976d2}
.sch_badge.at{color:#7c3aed;border-color:#7c3aed}
.sch_badge.every{color:#ed6c02;border-color:#ed6c02}
.sch_badge.overdue{color:#c62828;border-color:#c62828}
.sch_badge.scheduled{color:#2e7d32;border-color:#2e7d32}
.sch_remain.overdue{color:#c62828;font-weight:600}
.sch_form{display:flex;flex-direction:column;gap:10px}
.sch_form label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:var(--dsw-alias-label-secondary,#888)}
.sch_form input,.sch_form select{font:inherit;font-size:13px;padding:6px 8px;border-radius:8px;border:1px solid rgba(128,128,128,.4);background:transparent;color:inherit}
.sch_sel{font:inherit;font-size:13px;padding:6px 8px;border-radius:8px;border:1px solid rgba(128,128,128,.4);background:transparent;color:inherit;min-width:200px;flex:1}
.sch_dlg_h{font-weight:600;font-size:15px;padding:14px 20px;border-bottom:1px solid rgba(128,128,128,.2)}
.sch_dlg_b{padding:16px 20px;display:flex;flex-direction:column;gap:12px}
.sch_dlg_f{padding:12px 20px;border-top:1px solid rgba(128,128,128,.2);display:flex;gap:9px;justify-content:flex-end}
.sch_dlg{position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;z-index:1000}
.sch_dlg_box{background:var(--dsw-color-bg-base,#fff);color:inherit;border:1px solid rgba(128,128,128,.3);border-radius:12px;width:440px;max-width:94vw}`;
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=\"dsh-schedule-ui/section\"]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "dsh-schedule-ui";
			tag.dataset.pluginCss = "dsh-schedule-ui/section";
			tag.textContent = css;
			document.head.appendChild(tag);
		}

		function api(path, options) {
			return fetch("/schedule-ui/api" + path, {
				headers: { "Content-Type": "application/json" },
				...options,
			}).then(async (resp) => ({ ok: resp.ok, status: resp.status, body: await resp.json().catch(() => ({})) }));
		}

		const KIND_LABEL = { after: "延迟", at: "定时", every: "循环" };

		function esc(s) {
			return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
		}

		function basename(p) {
			const parts = String(p || "").split("/").filter(Boolean);
			return parts.length ? parts[parts.length - 1] : "";
		}

		function fmtTime(iso) {
			const d = new Date(iso);
			return isNaN(d) ? iso : d.toLocaleString();
		}

		function fmtDuration(ms) {
			const s = Math.floor(ms / 1000);
			if (s < 60) return s + " 秒";
			if (s < 3600) return Math.floor(s / 60) + " 分 " + (s % 60) + " 秒";
			if (s < 86400) return Math.floor(s / 3600) + " 小时 " + Math.floor((s % 3600) / 60) + " 分";
			return Math.floor(s / 86400) + " 天 " + Math.floor((s % 86400) / 3600) + " 小时";
		}

		function remainOf(iso) {
			const diff = new Date(iso) - Date.now();
			if (diff <= 0) return { cls: "overdue", text: "已过期 " + fmtDuration(-diff) + "前" };
			return { cls: "", text: fmtDuration(diff) };
		}

		function TaskRow({ t, onEdit, onDelete }) {
			const remain = remainOf(t.scheduledAt);
			return createElement("tr", null,
				createElement("td", null, esc(t.prompt)),
				createElement("td", null, createElement("span", { className: "sch_badge " + t.kind }, KIND_LABEL[t.kind] || t.kind)),
				createElement("td", null, fmtTime(t.scheduledAt)),
				createElement("td", { className: remain.cls ? "sch_remain overdue" : "sch_remain" }, remain.text),
				createElement("td", null, createElement("span", { className: "sch_badge " + (t.state === "overdue" ? "overdue" : "scheduled") }, t.state === "overdue" ? "已逾期" : "待触发")),
				createElement("td", null,
					createElement("div", { className: "sch_row", style: { gap: "6px" } },
						createElement("button", { className: "sch_btn", onClick: () => onEdit(t) }, "编辑"),
						createElement("button", { className: "sch_btn danger", onClick: () => onDelete(t) }, "删除"),
					),
				),
			);
		}

		function EditorDialog({ sessionId, task, onClose, onSaved }) {
			const [prompt, setPrompt] = react.useState(task ? task.prompt : "");
			const [kind, setKind] = react.useState(task ? task.kind : "after");
			const [after, setAfter] = react.useState(task && task.afterSeconds ? String(task.afterSeconds) : "");
			const [every, setEvery] = react.useState(task && task.everySeconds ? String(task.everySeconds) : "");
			const [at, setAt] = react.useState(() => {
				if (task && task.kind === "at") {
					const d = new Date(task.scheduledAt);
					return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
				}
				return "";
			});
			const [err, setErr] = react.useState("");
			const [busy, setBusy] = react.useState(false);

			const save = async () => {
				setErr("");
				if (!prompt.trim()) { setErr("请输入提醒内容"); return; }
				const payload = { sessionId, prompt: prompt.trim(), kind };
				if (kind === "after") payload.afterSeconds = parseInt(after, 10);
				if (kind === "every") payload.everySeconds = parseInt(every, 10);
				if (kind === "at") {
					if (!at) { setErr("请选择触发时间"); return; }
					payload.at = { date: at.slice(0, 10), time: at.slice(11) + ":00", time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone };
				}
				setBusy(true);
				try {
					const path = task ? "/edit" : "/create";
					const r = await api(path, { method: "POST", body: JSON.stringify(task ? { ...payload, id: task.id } : payload) });
					if (!r.ok) { setErr(r.body.error || ("失败 (HTTP " + r.status + ")")); setBusy(false); return; }
					onSaved();
				} catch (e) {
					setErr(String(e));
					setBusy(false);
				}
			};

			return createElement("div", { className: "sch_dlg" },
				createElement("div", { className: "sch_dlg_box" },
					createElement("div", { className: "sch_dlg_h" }, task ? "编辑定时任务" : "新建定时任务"),
					createElement("div", { className: "sch_dlg_b" },
						createElement("label", null, "提醒内容",
							createElement("input", { value: prompt, onChange: (e) => setPrompt(e.target.value), placeholder: "例如：提醒我开会" })),
						createElement("label", null, "类型",
							createElement("select", { value: kind, onChange: (e) => setKind(e.target.value) },
								createElement("option", { value: "after" }, "延迟（after）— 若干秒后触发一次"),
								createElement("option", { value: "at" }, "定时（at）— 指定时间触发一次"),
								createElement("option", { value: "every" }, "循环（every）— 每 N 秒重复"),
							)),
						kind === "after" ? createElement("label", null, "延迟秒数",
							createElement("input", { type: "number", min: "1", value: after, onChange: (e) => setAfter(e.target.value), placeholder: "300" })) : null,
						kind === "at" ? createElement("label", null, "触发时间",
							createElement("input", { type: "datetime-local", value: at, onChange: (e) => setAt(e.target.value) })) : null,
						kind === "every" ? createElement("label", null, "间隔秒数（≥300）",
							createElement("input", { type: "number", min: "300", value: every, onChange: (e) => setEvery(e.target.value), placeholder: "3600" })) : null,
						createElement("span", { className: "sch_meta" }, "循环任务最小间隔 300 秒。编辑会删除旧任务并按新参数重建。"),
						err ? createElement("span", { className: "sch_err" }, err) : null,
					),
					createElement("div", { className: "sch_dlg_f" },
						createElement("button", { className: "sch_btn", onClick: onClose, disabled: busy }, "取消"),
						createElement("button", { className: "sch_btn primary", onClick: save, disabled: busy }, busy ? "…" : "保存"),
					),
				),
			);
		}

		function ScheduleSection() {
			const [sessions, setSessions] = react.useState([]);
			const [sessionId, setSessionId] = react.useState("");
			const [tasks, setTasks] = react.useState([]);
			const [err, setErr] = react.useState("");
			const [editing, setEditing] = react.useState(null);

			const loadTasks = react.useCallback((sid) => {
				if (!sid) return;
				setErr("");
				api("/list", { method: "POST", body: JSON.stringify({ sessionId: sid }) }).then((r) => {
					if (r.ok) setTasks(r.body.tasks || []);
					else setErr(r.body.error || ("加载失败 (HTTP " + r.status + ")"));
				}).catch((e) => setErr(String(e)));
			}, []);

			const refresh = react.useCallback(() => {
				api("/sessions", { method: "POST", body: JSON.stringify({}) }).then((r) => {
					if (!r.ok) return;
					const list = r.body.sessions || [];
					setSessions(list);
					setSessionId((prev) => {
						const next = prev && list.some((s) => s.id === prev) ? prev : (list[0]?.id || "");
						if (next) loadTasks(next);
						return next;
					});
				}).catch(() => {});
			}, [loadTasks]);

			react.useEffect(() => { refresh(); }, [refresh]);

			react.useEffect(() => {
				const id = setInterval(() => { if (sessionId) loadTasks(sessionId); }, 5000);
				return () => clearInterval(id);
			}, [sessionId, loadTasks]);

			const onDelete = (t) => {
				if (!confirm("确定删除这个定时任务？")) return;
				api("/delete", { method: "POST", body: JSON.stringify({ sessionId, id: t.id }) }).then((r) => {
					if (r.ok) loadTasks(sessionId);
					else setErr(r.body.error || "删除失败");
				}).catch((e) => setErr(String(e)));
			};

			return createElement("div", { className: "sch_section" },
				createElement("div", { className: "sch_row" },
					createElement("span", { className: "sch_title" }, "定时任务"),
					createElement("span", { className: "sch_meta" }, "共 " + tasks.length + " 个"),
					createElement("div", { style: { marginLeft: "auto", display: "flex", gap: "8px", alignItems: "center" } },
						createElement("select", { className: "sch_sel", value: sessionId, onChange: (e) => { setSessionId(e.target.value); loadTasks(e.target.value); } },
							sessions.map((s) => createElement("option", { key: s.id, value: s.id }, (s.cwd ? basename(s.cwd) + " · " : "") + s.id.slice(0, 12))),
						),
						createElement("button", { className: "sch_btn", onClick: refresh }, "刷新"),
						createElement("button", { className: "sch_btn primary", onClick: () => setEditing({}) }, "新建任务"),
					),
				),
				err ? createElement("div", { className: "sch_err" }, err) : null,
				tasks.length === 0
					? createElement("div", { className: "sch_empty" }, "暂无定时任务，点「新建任务」开始")
					: createElement("table", { className: "sch_tbl" },
						createElement("thead", null,
							createElement("tr", null,
								createElement("th", null, "内容"),
								createElement("th", null, "类型"),
								createElement("th", null, "触发时间"),
								createElement("th", null, "剩余时间"),
								createElement("th", null, "状态"),
								createElement("th", null, "操作"),
							),
						),
						createElement("tbody", null,
							tasks.map((t) => createElement(TaskRow, { key: t.id, t, onEdit: (x) => setEditing(x), onDelete })),
						),
					),
				editing !== null ? createElement(EditorDialog, {
					sessionId,
					task: editing && editing.id ? editing : null,
					onClose: () => setEditing(null),
					onSaved: () => { setEditing(null); loadTasks(sessionId); },
				}) : null,
			);
		}

		function apply(ctx) {
			ctx.slots.inject("settings.section", () => ctx.slots.register({
				name: "settings.section",
				id: "schedule",
				order: 41,
				label: "定时任务",
			}, ScheduleSection));
		}

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});

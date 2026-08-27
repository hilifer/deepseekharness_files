/**
 * dsh-skill-ui client half — Settings → 技能 page.
 *
 * Authored in the DSH client module format (window.__ModuleLoader__). Communicates
 * with the host through /skill-ui/api/* — no @deepseek-ai imports at runtime.
 */
window.__ModuleLoader__.load({
	id: "dsh-skill-ui",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");
		const createElement = react.createElement;

		const inject = ["slots"];

		const css = `
.skl_section{display:flex;flex-direction:column;gap:14px;padding:0 24px 24px}
.skl_row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.skl_title{font-weight:600;font-size:14px}
.skl_meta{font-size:12px;color:var(--dsw-alias-label-secondary,#888)}
.skl_err{color:#c62828;font-size:12px}
.skl_btn{cursor:pointer;font-size:12px;padding:5px 12px;border-radius:8px;border:1px solid rgba(128,128,128,.5);background:transparent;color:inherit}
.skl_btn:hover{background:rgba(128,128,128,.12)}
.skl_btn.primary{border-color:transparent;background:#1976d2;color:#fff}
.skl_list{display:flex;flex-direction:column;gap:10px}
.skl_card{border:1px solid rgba(128,128,128,.3);border-radius:12px;padding:12px 16px;display:flex;flex-direction:column;gap:6px}
.skl_card_head{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.skl_name{font-weight:600;font-size:13px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.skl_desc{font-size:13px;color:inherit}
.skl_when{font-size:12px;color:var(--dsw-alias-label-secondary,#888)}
.skl_tags{display:flex;gap:6px;flex-wrap:wrap}
.skl_badge{font-size:11px;padding:1px 7px;border-radius:8px;border:1px solid rgba(128,128,128,.4);white-space:nowrap;color:var(--dsw-alias-label-secondary,#888)}
.skl_badge.src{border-color:#1976d2;color:#1976d2}
.skl_badge.model{color:#2e7d32;border-color:#2e7d32}
.skl_badge.useronly{color:#ed6c02;border-color:#ed6c02}
.skl_empty{padding:24px;text-align:center;color:var(--dsw-alias-label-secondary,#888);font-size:12px}`;
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=\"dsh-skill-ui/section\"]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "dsh-skill-ui";
			tag.dataset.pluginCss = "dsh-skill-ui/section";
			tag.textContent = css;
			document.head.appendChild(tag);
		}

		const SOURCE_LABEL = {
			"project-dsh": "项目 (.dsh/skills)",
			"project-agents": "项目 (.agents/skills)",
			"custom": "自定义",
			"user-dsh": "用户 ($DSH_HOME/skills)",
			"user-agents": "用户 (~/.agents/skills)",
		};

		function esc(s) {
			return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
		}

		function SkillCard({ s }) {
			return createElement("div", { className: "skl_card" },
				createElement("div", { className: "skl_card_head" },
					createElement("span", { className: "skl_name" }, "/" + esc(s.name)),
					createElement("span", { className: "skl_tags" },
						s.source ? createElement("span", { className: "skl_badge src" }, SOURCE_LABEL[s.source] || s.source) : null,
						s.modelInvocable ? createElement("span", { className: "skl_badge model" }, "模型可调用") : null,
						s.userInvocable && !s.modelInvocable ? createElement("span", { className: "skl_badge useronly" }, "仅用户可调用") : null,
					),
				),
				createElement("div", { className: "skl_desc" }, esc(s.description)),
				s.whenToUse ? createElement("div", { className: "skl_when" }, "使用场景：" + esc(s.whenToUse)) : null,
			);
		}

		function SkillSection() {
			const [skills, setSkills] = react.useState(null);
			const [err, setErr] = react.useState("");

			const refresh = react.useCallback(() => {
				setErr("");
				fetch("/skill-ui/api/list", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })
					.then(async (r) => ({ ok: r.ok, body: await r.json().catch(() => ({})) }))
					.then((r) => {
						if (r.ok) setSkills(r.body.skills || []);
						else setErr(r.body.error || "加载失败");
					})
					.catch((e) => setErr(String(e)));
			}, []);

			react.useEffect(() => { refresh(); }, [refresh]);

			return createElement("div", { className: "skl_section" },
				createElement("div", { className: "skl_row" },
					createElement("span", { className: "skl_title" }, "技能"),
					createElement("span", { className: "skl_meta" }, "共 " + (skills ? skills.length : 0) + " 个"),
					createElement("div", { style: { marginLeft: "auto" } },
						createElement("button", { className: "skl_btn", onClick: refresh }, "刷新"),
					),
				),
				createElement("div", { className: "skl_meta" }, "在对话输入框打 / 即可调用技能。文件放在 $DSH_HOME/skills 或工作区 .dsh/skills 下自动生效。"),
				err ? createElement("div", { className: "skl_err" }, err) : null,
				skills === null
					? createElement("div", { className: "skl_empty" }, "加载中…")
					: skills.length === 0
						? createElement("div", { className: "skl_empty" }, "暂无技能，在 skills 目录放 SKILL.md 文件即可安装")
						: createElement("div", { className: "skl_list" },
							skills.map((s) => createElement(SkillCard, { key: s.name, s })),
						),
			);
		}

		function apply(ctx) {
			ctx.slots.inject("settings.section", () => ctx.slots.register({
				name: "settings.section",
				id: "skill",
				order: 42,
				label: "技能",
			}, SkillSection));
		}

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});

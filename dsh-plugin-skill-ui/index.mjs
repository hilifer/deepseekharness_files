export const name = "skill-ui";
export const inject = ["skills", "agents"];

function sendJson(res, status, body) {
  const response = res;
  response.statusCode = status;
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Cache-Control", "no-store");
  response.end(JSON.stringify(body));
}

export function apply(ctx) {
  const context = ctx;

  async function listSkills() {
    const skills = context.get("skills");
    const agents = context.get("agents");
    if (!skills || !agents) return [];
    const agent = agents.roots()[0];
    if (!agent) return [];
    try {
      const result = await skills.list({
        cwd: agent.session.header?.cwd,
        scope: agent,
      });
      return result.map((s) => ({
        name: s.name,
        description: s.description ?? "",
        whenToUse: s.whenToUse ?? "",
        modelInvocable: !!s.invocation?.modelInvocable,
        userInvocable: !!s.invocation?.userInvocable,
        source: s.source ?? "",
        provider: s.provider ?? "",
      }));
    } catch (err) {
      return [];
    }
  }

  if (typeof context.inject === "function") {
    context.inject(["webServer"], (httpCtx) => {
      const webServer = httpCtx.get("webServer");
      if (!webServer) return;

      webServer.register({
        kind: "exact",
        path: "/skill-ui/api/list",
        handler: async (_req, res) => {
          try {
            sendJson(res, 200, { skills: await listSkills() });
          } catch (err) {
            sendJson(res, 500, { error: String(err) });
          }
        },
      });
    });
  }
}

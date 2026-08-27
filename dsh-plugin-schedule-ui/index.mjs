import {
  foldScheduleEvents,
  scheduleView,
  createAfterScheduleRecord,
  createAtScheduleRecord,
  createEveryScheduleRecord,
  allocateScheduleId,
} from "@deepseek-ai/dsh-schedule";

export const name = "schedule-ui";
export const inject = ["sessions", "agents"];

function sendJson(res, status, body) {
  const response = res;
  response.statusCode = status;
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Cache-Control", "no-store");
  response.end(JSON.stringify(body));
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const stream = req;
    stream.on("data", (chunk) => {
      if (typeof chunk === "string") chunks.push(Buffer.from(chunk));
      else if (chunk instanceof Uint8Array) chunks.push(Buffer.from(chunk));
    });
    stream.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf-8");
      if (!raw.trim()) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch (err) {
        reject(new Error(`invalid JSON body: ${String(err)}`));
      }
    });
    stream.on("error", reject);
  });
}

export function apply(ctx) {
  const context = ctx;

  const agentFor = (sessionId) => {
    const agents = context.get("agents");
    return agents ? agents.get(sessionId) : undefined;
  };

  const foldFor = (agent) => {
    const seed = agent.session.header?.seedLength ?? 0;
    return foldScheduleEvents(agent.session.events, seed);
  };

  const flush = async (agent) => {
    const sessions = context.get("sessions");
    if (sessions && typeof sessions.flush === "function") {
      await sessions.flush(agent.session);
    }
  };

  function listSessions() {
    const sessions = context.get("sessions");
    if (!sessions) return [];
    return sessions.list().map((s) => ({
      id: s.id,
      cwd: s.header?.cwd ?? "",
    }));
  }

  function listTasks(sessionId) {
    const agent = agentFor(sessionId);
    if (!agent) return { error: "找不到该会话的 agent（可能已归档或未激活）" };
    const folded = foldFor(agent);
    const now = Date.now();
    return {
      tasks: folded.active
        .map((r) => scheduleView(r, now))
        .sort((a, b) => Date.parse(a.scheduledAt) - Date.parse(b.scheduledAt)),
    };
  }

  async function deleteTask(sessionId, id) {
    const agent = agentFor(sessionId);
    if (!agent) return { error: "找不到该会话的 agent" };
    if (typeof id !== "string" || id.trim() === "" || id.trim() !== id) {
      return { error: "id 不能为空或含首尾空格" };
    }
    await flush(agent);
    const folded = foldFor(agent);
    if (!folded.active.some((r) => r.id === id)) {
      return { id, deleted: false, code: "schedule_not_found" };
    }
    agent.session.append("schedule/change", { version: 1, operation: "delete", id });
    await flush(agent);
    return { id, deleted: true };
  }

  function buildRecord(id, input, now) {
    if (input.kind === "at") return createAtScheduleRecord(id, input.prompt, input.at, now);
    if (input.kind === "every") return createEveryScheduleRecord(id, input.prompt, input.everySeconds, now);
    return createAfterScheduleRecord(id, input.prompt, input.afterSeconds, now);
  }

  async function createTask(sessionId, input) {
    const agent = agentFor(sessionId);
    if (!agent) return { error: "找不到该会话的 agent" };
    await flush(agent);
    const folded = foldFor(agent);
    const id = allocateScheduleId(folded);
    let record;
    try {
      record = buildRecord(id, input, Date.now());
    } catch (err) {
      return { error: err?.message || String(err) };
    }
    agent.session.append("schedule/change", { version: 1, operation: "create", schedule: record });
    await flush(agent);
    return { task: scheduleView(record, Date.now()) };
  }

  async function editTask(sessionId, id, input) {
    const del = await deleteTask(sessionId, id);
    if (del.error) return del;
    if (!del.deleted) return { error: "任务不存在，无法编辑" };
    return createTask(sessionId, input);
  }

  if (typeof context.inject === "function") {
    context.inject(["webServer"], (httpCtx) => {
      const webServer = httpCtx.get("webServer");
      if (!webServer) return;

      const register = (path, fn) => {
        webServer.register({
          kind: "exact",
          path,
          handler: async (req, res) => {
            try {
              const body = await readJsonBody(req);
              const result = await fn(body);
              if (result.error) sendJson(res, 400, result);
              else sendJson(res, 200, result);
            } catch (err) {
              sendJson(res, 500, { error: String(err) });
            }
          },
        });
      };

      register("/schedule-ui/api/sessions", () => ({ sessions: listSessions() }));
      register("/schedule-ui/api/list", (body) => listTasks(body.sessionId));
      register("/schedule-ui/api/delete", (body) => deleteTask(body.sessionId, body.id));
      register("/schedule-ui/api/create", (body) => createTask(body.sessionId, body));
      register("/schedule-ui/api/edit", (body) => editTask(body.sessionId, body.id, body));
    });
  }
}

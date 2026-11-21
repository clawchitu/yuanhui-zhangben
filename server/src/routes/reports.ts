// 报表与查询接口（§7、设计稿 09 / 10 / 07a / 07c）。权限由 guard 按 permissions.json 判：家用 / 审核能，收银员 403，被踢 401。
// 店 id 一律取自令牌；日期参数是上海时区的日历日，不合法（格式不对、2 月 30 日）→ 400 invalid。
import type { FastifyInstance } from "fastify";
import { authOf } from "../auth/plugin.ts";
import { isValidDay, isValidMonth, monthOf, today } from "../reports/common.ts";
import { reportToday } from "../reports/today.ts";
import { reportMonth } from "../reports/month.ts";
import { entriesOfDay, entryDays } from "../reports/entries.ts";
import { sendError } from "./errors.ts";

const dateQ = { type: "string", pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" } as const;

export async function reportRoutes(app: FastifyInstance): Promise<void> {
  const db = app.deps.db.kysely;

  app.get<{ Querystring: { date?: string } }>(
    "/v1/reports/today",
    { schema: { querystring: { type: "object", additionalProperties: false, properties: { date: dateQ } } } },
    async (req, reply) => {
      const date = req.query.date ?? today(req.receivedAt);
      if (!isValidDay(date)) return sendError(reply, 400, "invalid", { message: "日期不对" });
      return reportToday(db, authOf(req).store.id, date, req.receivedAt);
    },
  );

  app.get<{ Querystring: { month?: string } }>(
    "/v1/reports/month",
    { schema: { querystring: { type: "object", additionalProperties: false, properties: { month: { type: "string", pattern: "^[0-9]{4}-(0[1-9]|1[0-2])$" } } } } },
    async (req, reply) => {
      const month = req.query.month ?? monthOf(req.receivedAt);
      if (!isValidMonth(month)) return sendError(reply, 400, "invalid", { message: "月份不对" });
      return reportMonth(db, authOf(req).store.id, month, req.receivedAt);
    },
  );

  app.get<{ Querystring: { date: string } }>(
    "/v1/entries",
    { schema: { querystring: { type: "object", additionalProperties: false, required: ["date"], properties: { date: dateQ } } } },
    async (req, reply) => {
      if (!isValidDay(req.query.date)) return sendError(reply, 400, "invalid", { message: "日期不对" });
      return entriesOfDay(db, authOf(req).store.id, req.query.date);
    },
  );

  app.get<{ Querystring: { before?: string; limit?: number } }>(
    "/v1/entries/days",
    {
      schema: {
        querystring: {
          type: "object",
          additionalProperties: false,
          properties: { before: dateQ, limit: { type: "integer", minimum: 1, maximum: 31, default: 7 } },
        },
      },
    },
    async (req, reply) => {
      const before = req.query.before ?? today(req.receivedAt);
      if (!isValidDay(before)) return sendError(reply, 400, "invalid", { message: "日期不对" });
      return entryDays(db, authOf(req).store.id, before, req.query.limit ?? 7);
    },
  );
}

// 契约 components/schemas/Error：{ code, message?, locked_until?, retry_after_s? }
import type { FastifyReply } from "fastify";

export function sendError(
  reply: FastifyReply,
  status: number,
  code: string,
  extra: { message?: string; locked_until?: string; retry_after_s?: number } = {},
) {
  return reply.code(status).send({ code, ...extra });
}

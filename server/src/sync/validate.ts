// 同步请求的校验。
// - 请求外壳（epoch、游标、ops 数组、每个 op 的 id / type / occurred_at / payload 是否成形）：不成形就整个请求 400，
//   因为连 op 的 id 都认不出来，没法逐个给结果。用严格模式（不删多余字段、不转类型），和契约 additionalProperties:false 一致。
// - 每个 op 的 payload：按 contracts/ops.schema.json（§4.3、§5.0 上限）逐个校验，不过就是这个 op rejected: invalid。
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv, type ValidateFunction } from "ajv";
import { Ajv2020 } from "ajv/dist/2020.js";
import formatsModule from "ajv-formats";

export const OPS_SCHEMA_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "../../../contracts/ops.schema.json");

export const OP_TYPES = [
  "sale_batch",
  "void",
  "product_upsert",
  "product_edit",
  "barcode_link",
  "barcode_unlink",
  "stock_in",
  "opening",
  "product_review_complete",
  "count",
  "expiry_dispose",
  "lot_snooze",
] as const;
export type OpType = (typeof OP_TYPES)[number];

/** 一次最多 200 个 op（§4.2） */
export const MAX_OPS = 200;

type FormatsPlugin = (ajv: Ajv | Ajv2020) => unknown;
const addFormats = ((formatsModule as unknown as { default?: FormatsPlugin }).default ?? formatsModule) as unknown as FormatsPlugin;

const rev = { type: "integer", minimum: 0, maximum: Number.MAX_SAFE_INTEGER } as const;

/** POST /v1/sync 的请求体外壳（契约 SyncRequest；op 的 payload 在这里只要求是对象） */
export const syncBodySchema = {
  type: "object",
  additionalProperties: false,
  required: ["epoch", "cursors", "ops", "app_build"],
  properties: {
    epoch: { type: "string", format: "uuid" },
    cursors: {
      type: "object",
      additionalProperties: false,
      required: ["catalog", "ledger"],
      properties: { catalog: rev, ledger: rev },
    },
    ops: {
      type: "array",
      maxItems: MAX_OPS,
      items: {
        type: "object",
        required: ["id", "type", "occurred_at", "payload"],
        properties: {
          id: { type: "string", format: "uuid" },
          type: { enum: OP_TYPES },
          occurred_at: { type: "string", format: "date-time" },
          payload: { type: "object" },
        },
      },
    },
    app_build: { type: "integer", minimum: 0 },
    pull: { type: "boolean" },
  },
} as const;

const strict = new Ajv({ allErrors: false, strict: true, coerceTypes: false, removeAdditional: false, useDefaults: false });
addFormats(strict);

/** Fastify 路由的 validatorCompiler：严格校验，不用 Fastify 默认的「删多余字段、转类型」 */
export function strictValidatorCompiler({ schema }: { schema: object }): ValidateFunction {
  return strict.compile(schema);
}

const opsAjv = new Ajv2020({ strict: false, allErrors: false });
addFormats(opsAjv);
const validateOpSchema = opsAjv.compile(JSON.parse(readFileSync(OPS_SCHEMA_PATH, "utf8")));

/** 整个 op（id、type、occurred_at、payload）是否符合 ops.schema.json */
export function opSchemaValid(op: unknown): boolean {
  return validateOpSchema(op) as boolean;
}

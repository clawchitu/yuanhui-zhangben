// 读 contracts/openapi.yaml（解引用后），用 ajv 按契约校验响应。
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import formatsModule from "ajv-formats";
import { dereference } from "@readme/openapi-parser";

export const CONTRACTS_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../../../contracts");

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Any = any;
let cached: Promise<Any> | undefined;
export function loadOpenApi(): Promise<Any> {
  cached ??= dereference(resolve(CONTRACTS_DIR, "openapi.yaml")) as Promise<Any>;
  return cached;
}

type FormatsPlugin = (ajv: Ajv2020) => Ajv2020;
const addFormats = ((formatsModule as unknown as { default?: FormatsPlugin }).default ??
  formatsModule) as unknown as FormatsPlugin;
const ajv = new Ajv2020({ strict: false, allErrors: true });
addFormats(ajv);

export function validatorFor(schema: object) {
  return ajv.compile(schema);
}

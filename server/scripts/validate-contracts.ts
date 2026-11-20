// 校验 contracts/：openapi.yaml 语法、所有 JSON Schema 语法、向量文件和示例是否符合各自的 schema、
// 权限表是否覆盖了全部接口和 op 类型。只查格式，不重算向量里的数字（数字由评审对照 §5 人工核）。
// 用法（在 server/ 下）：npm run contracts:check
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import formatsModule from "ajv-formats";
import { validate as validateOpenApi } from "@readme/openapi-parser";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../contracts");
const vectorsDir = join(root, "vectors");
const schemasDir = join(vectorsDir, "schemas");

let failures = 0;
const fail = (msg: string) => {
  failures++;
  console.error(`  [失败] ${msg}`);
};
const ok = (msg: string) => console.log(`  [通过] ${msg}`);

const readJson = (path: string): unknown => JSON.parse(readFileSync(path, "utf8"));

type FormatsPlugin = (ajv: Ajv2020) => Ajv2020;
const addFormats = ((formatsModule as unknown as { default?: FormatsPlugin }).default ??
  formatsModule) as unknown as FormatsPlugin;

const ajv = new Ajv2020({ strict: true, strictRequired: false, allErrors: true, allowUnionTypes: true });
addFormats(ajv);

// 1. 所有 schema 能编译（语法 + 元 schema 校验）
console.log("JSON Schema 语法");
const schemaFiles = [
  join(root, "ops.schema.json"),
  join(root, "permissions.schema.json"),
  ...readdirSync(schemasDir)
    .filter((f) => f.endsWith(".schema.json"))
    .map((f) => join(schemasDir, f)),
];
const compiled = new Map<string, ReturnType<typeof ajv.compile>>();
for (const file of schemaFiles) {
  try {
    compiled.set(file, ajv.compile(readJson(file) as object));
    ok(file.slice(root.length + 1));
  } catch (e) {
    fail(`${file.slice(root.length + 1)}：${(e as Error).message}`);
  }
}

// 向量文件里只允许安全整数：没有小数、没有超过 2^53 的数（JSON.parse 会静默丢精度）
function checkIntegers(value: unknown, path: string, file: string) {
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) fail(`${file} ${path}：${value} 不是安全整数`);
  } else if (Array.isArray(value)) {
    value.forEach((v, i) => checkIntegers(v, `${path}[${i}]`, file));
  } else if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) checkIntegers(v, `${path}.${k}`, file);
  }
}

function collectIds(value: unknown, out: string[]) {
  if (Array.isArray(value)) value.forEach((v) => collectIds(v, out));
  else if (value && typeof value === "object") {
    const o = value as Record<string, unknown>;
    if (typeof o.id === "string") out.push(o.id);
    for (const v of Object.values(o)) if (typeof v === "object") collectIds(v, out);
  }
}

// 2. 向量文件符合各自的 schema
console.log("向量文件");
const vectorFiles = readdirSync(vectorsDir).filter((f) => f.endsWith(".json"));
const expected = ["allocation.json", "cost.json", "rounddiv.json", "expiry.json", "prefix.json"];
for (const f of expected) if (!vectorFiles.includes(f)) fail(`缺少 vectors/${f}`);
for (const f of vectorFiles) {
  const schemaFile = join(schemasDir, f.replace(/\.json$/, ".schema.json"));
  const validateFn = compiled.get(schemaFile);
  if (!validateFn) {
    fail(`vectors/${f} 没有对应的 schemas/${f.replace(/\.json$/, ".schema.json")}`);
    continue;
  }
  const data = readJson(join(vectorsDir, f));
  const before = failures;
  if (!validateFn(data)) fail(`vectors/${f}：${ajv.errorsText(validateFn.errors, { separator: "\n    " })}`);
  checkIntegers(data, "$", `vectors/${f}`);
  const ids: string[] = [];
  collectIds((data as Record<string, unknown>), ids);
  const dup = ids.filter((id, i) => ids.indexOf(id) !== i && !/^P[0-9]+$/.test(id));
  if (dup.length) fail(`vectors/${f}：重复的用例 id ${[...new Set(dup)].join(", ")}`);
  if (failures === before) ok(`vectors/${f}（${ids.filter((id) => !/^P[0-9]+$/.test(id)).length} 组）`);
}

// 3. op 示例：合法的都要过，不合法的都要被拒
console.log("op 示例");
const validateOp = compiled.get(join(root, "ops.schema.json"));
if (validateOp) {
  const good = readJson(join(root, "examples/ops-valid.json")) as unknown[];
  good.forEach((op, i) => {
    if (!validateOp(op)) fail(`ops-valid.json[${i}] 应该合法：${ajv.errorsText(validateOp.errors)}`);
  });
  const bad = readJson(join(root, "examples/ops-invalid.json")) as { why: string; op: unknown }[];
  bad.forEach(({ why, op }, i) => {
    if (validateOp(op)) fail(`ops-invalid.json[${i}]（${why}）应该被拒，却通过了`);
  });
  ok(`${good.length} 个合法、${bad.length} 个不合法示例`);
}

// 4. OpenAPI 语法（含对 ops.schema.json 的外部引用）
console.log("OpenAPI");
const openapiPath = join(root, "openapi.yaml");
const result = await validateOpenApi(openapiPath);
if (!result.valid) fail(`openapi.yaml：${JSON.stringify(result.errors, null, 2)}`);
else ok("openapi.yaml");

// 5. 权限表覆盖全部接口和 op 类型，且没有多余的行
console.log("权限表覆盖");
type Rule = { id: string; kind: string; method?: string; path?: string; op?: string };
const perms = readJson(join(root, "permissions.json")) as { rules: Rule[] };
const permIds = new Set(perms.rules.map((r) => r.id));
const { parse } = await import("@readme/openapi-parser");
const api = (await parse(openapiPath)) as unknown as {
  paths: Record<string, Record<string, { "x-permission"?: string }>>;
};
const apiIds = new Set<string>();
for (const [path, item] of Object.entries(api.paths)) {
  for (const [method, operation] of Object.entries(item)) {
    const id = `${method.toUpperCase()} ${path}`;
    apiIds.add(id);
    if (operation["x-permission"] !== id) fail(`${id} 的 x-permission 应为「${id}」`);
    if (!permIds.has(id)) fail(`permissions.json 缺少接口 ${id}`);
  }
}
const opSchema = readJson(join(root, "ops.schema.json")) as { $defs: { op_type: { enum: string[] } } };
const opTypes = new Set(opSchema.$defs.op_type.enum);
for (const t of opTypes) if (!permIds.has(`op:${t}`)) fail(`permissions.json 缺少 op ${t}`);
for (const r of perms.rules) {
  if (r.kind === "http" && !apiIds.has(r.id)) fail(`permissions.json 有 openapi 里没有的接口 ${r.id}`);
  if (r.kind === "http" && r.id !== `${r.method} ${r.path}`) fail(`permissions.json 行 ${r.id} 的 id 与 method/path 不一致`);
  if (r.kind === "op" && (!r.op || !opTypes.has(r.op) || r.id !== `op:${r.op}`)) fail(`permissions.json 行 ${r.id} 的 op 不在 ops.schema.json 里`);
}
if (permIds.size !== perms.rules.length) fail("permissions.json 有重复的 id");
ok(`${apiIds.size} 个接口、${opTypes.size} 种 op`);

if (failures) {
  console.error(`\n契约校验失败：${failures} 处`);
  process.exit(1);
}
console.log("\n契约校验全部通过");

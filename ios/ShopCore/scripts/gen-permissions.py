#!/usr/bin/env python3
"""从 contracts/permissions.json 生成 Sources/ShopCore/Roles/PermissionTable.generated.swift。

用法（在仓库根目录或任意位置）：python3 ios/ShopCore/scripts/gen-permissions.py
改了 permissions.json 之后重跑；ShopCoreTests 里的 PermissionTableTests 会在两者不一致时失败。
"""
import json, os, sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, "..", "..", ".."))
src = os.path.join(root, "contracts", "permissions.json")
dst = os.path.join(here, "..", "Sources", "ShopCore", "Roles", "PermissionTable.generated.swift")

ROLES = ["family", "cashier", "review", "revoked"]
DECISION = {"public": ".public", "allow": ".allow", "deny": ".deny", "held": ".held", "not_applicable": ".notApplicable"}

def s(x):
    return json.dumps(x, ensure_ascii=False)

data = json.load(open(src, encoding="utf-8"))
out = []
out.append("// 自动生成，勿手改。来源：contracts/permissions.json（version %d）。" % data["version"])
out.append("// 生成：python3 ios/ShopCore/scripts/gen-permissions.py")
out.append("")
out.append("extension PermissionTable {")
out.append("    public static let version = %d" % data["version"])
out.append("    public static let rules: [PermissionRule] = [")
for r in data["rules"]:
    cells = []
    for role in ROLES:
        c = r[role]
        conds = c.get("conditions", [])
        cells.append("            .%s: PermissionCell(%s, conditions: [%s])" % (
            role, DECISION[c["decision"]], ", ".join(s(x) for x in conds)))
    out.append("        PermissionRule(id: %s, kind: %s, cells: [" % (s(r["id"]), s(r["kind"])))
    out.append(",\n".join(cells))
    out.append("        ]),")
out.append("    ]")
out.append("}")
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
print("wrote", os.path.relpath(dst, root))

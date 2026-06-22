// Aerolab patch: re-enable plugin secret-ref resolution on master.
//
// Upstream master fail-closes plugin secret refs as part of the (incomplete)
// company-scoped-plugin migration (PAP-2394): both the runtime resolver and the
// config endpoint reject secret-ref UUIDs. This instance is single-company, so
// that cross-company-disclosure mitigation does not apply. We restore the direct
// UUID resolution (pre-#5429 behaviour) so paperclip-plugin-slack can resolve its
// bot token / signing secret. Remove once upstream completes PAP-2394.
//
// Two edits, both anchor-checked (build fails loudly if upstream changed):
//   1) services/plugin-secrets-handler.ts — restore resolve()
//   2) routes/plugins.ts — drop the config-endpoint 422 guard
const fs = require("fs");

// ---- 1) Runtime resolver -------------------------------------------------
const handlerFile = "server/src/services/plugin-secrets-handler.ts";
let h = fs.readFileSync(handlerFile, "utf8");

const importAnchor = 'import type { Db } from "@paperclipai/db";';
if (!h.includes(importAnchor)) { console.error("ERROR: handler import anchor missing"); process.exit(1); }
h = h.replace(
  importAnchor,
  [
    'import { eq, and } from "drizzle-orm";',
    importAnchor,
    'import { companySecrets, companySecretVersions } from "@paperclipai/db";',
    'import type { SecretProvider } from "@paperclipai/shared";',
    'import { getSecretProvider } from "../secrets/provider-registry.js";',
    'import type { StoredSecretVersionMaterial } from "../secrets/types.js";',
  ].join("\n"),
);

const destructAnchor = "  const { pluginId } = options;";
if (!h.includes(destructAnchor)) { console.error("ERROR: handler destructure anchor missing"); process.exit(1); }
h = h.replace(destructAnchor, "  const { db, pluginId } = options;");

const throwAnchor = "      throw new Error(PLUGIN_SECRET_REFS_DISABLED_MESSAGE);";
if (!h.includes(throwAnchor)) { console.error("ERROR: handler kill-switch throw anchor missing"); process.exit(1); }
const resolution = [
  "      // Aerolab single-tenant override: resolve the secret directly by UUID.",
  "      const secret = await db",
  "        .select()",
  "        .from(companySecrets)",
  "        .where(eq(companySecrets.id, trimmedRef))",
  "        .then((rows) => rows[0] ?? null);",
  "      if (!secret) {",
  "        throw invalidSecretRef(trimmedRef);",
  "      }",
  "      const versionRow = await db",
  "        .select()",
  "        .from(companySecretVersions)",
  "        .where(",
  "          and(",
  "            eq(companySecretVersions.secretId, secret.id),",
  "            eq(companySecretVersions.version, secret.latestVersion),",
  "          ),",
  "        )",
  "        .then((rows) => rows[0] ?? null);",
  "      if (!versionRow) {",
  "        throw invalidSecretRef(trimmedRef);",
  "      }",
  "      const provider = getSecretProvider(secret.provider as SecretProvider);",
  "      return provider.resolveVersion({",
  "        material: versionRow.material as StoredSecretVersionMaterial,",
  "        externalRef: secret.externalRef,",
  "      });",
].join("\n");
h = h.replace(throwAnchor, resolution);
fs.writeFileSync(handlerFile, h);
console.log("Aerolab: plugin-secrets-handler resolve() restored");

// ---- 2) Config-endpoint guard -------------------------------------------
const routeFile = "server/src/routes/plugins.ts";
let r = fs.readFileSync(routeFile, "utf8");
const guardAnchor = "if (secretRefsByPath.size > 0) {";
if (!r.includes(guardAnchor)) { console.error("ERROR: config-endpoint guard anchor missing"); process.exit(1); }
r = r.replace(
  guardAnchor,
  'if (secretRefsByPath.size > 0 && process.env.PAPERCLIP_ENFORCE_PLUGIN_SECRET_KILLSWITCH === "1") {',
);
fs.writeFileSync(routeFile, r);
console.log("Aerolab: config-endpoint secret-ref guard neutralised");

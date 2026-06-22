// Aerolab patch (route-scoped): Paperclip only captures the raw request body for
// JSON requests (global express.json verify callback). Slack slash commands and
// interactivity are application/x-www-form-urlencoded, so they reach the plugin
// webhook route with an empty rawBody and HMAC signature verification fails.
//
// A GLOBAL urlencoded parser broke HTTP serving entirely (504s), so instead we
// attach a urlencoded parser ONLY to the webhook route. It fires solely for
// urlencoded content types (JSON keeps using the global json verify), captures
// the raw bytes into req.rawBody, and cannot affect any other route.
const fs = require("fs");

const file = "server/src/routes/plugins.ts";
let s = fs.readFileSync(file, "utf8");

// 1) Add a default express import (needed for express.urlencoded).
const importAnchor = 'import { Router } from "express";';
if (!s.includes(importAnchor)) {
  console.error("ERROR: Router import anchor not found in plugins.ts");
  process.exit(1);
}
if (!s.includes('import express from "express";')) {
  s = s.replace(importAnchor, 'import express from "express";\n' + importAnchor);
}

// 2) Attach a route-scoped urlencoded raw-body capture middleware.
const routeAnchor = '  router.post("/plugins/:pluginId/webhooks/:endpointKey", async (req, res) => {';
if (!s.includes(routeAnchor)) {
  console.error("ERROR: webhook route anchor not found in plugins.ts");
  process.exit(1);
}
const routeReplacement = [
  '  router.post(',
  '    "/plugins/:pluginId/webhooks/:endpointKey",',
  '    // Aerolab: capture raw body for urlencoded webhooks (Slack slash commands /',
  '    // interactivity) so the plugin can verify the HMAC signature. Fires only for',
  '    // urlencoded content types; scoped to this route so it cannot affect others.',
  '    express.urlencoded({',
  '      extended: false,',
  '      limit: "10mb",',
  '      verify: (req, _res, buf) => {',
  '        (req as unknown as { rawBody?: Buffer }).rawBody = buf;',
  '      },',
  '    }),',
  '    async (req, res) => {',
].join("\n");
s = s.replace(routeAnchor, routeReplacement);

fs.writeFileSync(file, s);
console.log("Aerolab: route-scoped urlencoded raw-body capture inserted into plugins.ts");

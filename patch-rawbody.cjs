// Aerolab patch: Paperclip only captures the raw request body for JSON requests
// (express.json verify callback). Slack slash commands and interactivity are sent
// as application/x-www-form-urlencoded, so their raw body is never stashed and the
// plugin's HMAC signature verification always fails ("invalid Slack signature").
// Add a urlencoded parser that captures the raw body the same way. This gap exists
// on upstream master too; safe to carry until upstream adds urlencoded raw capture.
const fs = require("fs");

const file = "server/src/app.ts";
let src = fs.readFileSync(file, "utf8");

const anchor = `  app.use(express.json({
    // Company import/export payloads can inline full portable packages.
    limit: "10mb",
    verify: (req, _res, buf) => {
      (req as unknown as { rawBody: Buffer }).rawBody = buf;
    },
  }));`;

if (!src.includes(anchor)) {
  console.error("ERROR: express.json rawBody anchor not found in app.ts — upstream changed, review patch-rawbody.cjs");
  process.exit(1);
}

const injected = anchor + `
  // Aerolab: also capture the raw body for urlencoded requests (Slack slash
  // commands / interactivity) so plugin webhook HMAC signature verification works.
  app.use(express.urlencoded({
    extended: false,
    limit: "10mb",
    verify: (req, _res, buf) => {
      (req as unknown as { rawBody: Buffer }).rawBody = buf;
    },
  }));`;

src = src.replace(anchor, injected);
fs.writeFileSync(file, src);
console.log("Aerolab: urlencoded raw-body capture inserted into app.ts");

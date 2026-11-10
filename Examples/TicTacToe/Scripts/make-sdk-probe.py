#!/usr/bin/env python3
"""Builds Sources/sdk-probe.html: an MCP App written with the official SDK.

It downloads the self-contained build of @modelcontextprotocol/ext-apps (pinned below) from the
npm CDN and inlines it, so the probe needs no network at run time. The output is not committed:
the SDK is third-party code under its own license (MIT / Apache-2.0).

    python3 Examples/TicTacToe/Scripts/make-sdk-probe.py
"""
import pathlib
import re
import urllib.request

VERSION = "2.0.4"
URL = f"https://unpkg.com/@modelcontextprotocol/ext-apps@{VERSION}/dist/src/app-with-deps.js"
OUT = pathlib.Path(__file__).resolve().parent.parent / "Sources" / "sdk-probe.html"

PROBE = r"""
const { App } = window.__extApps;
const logEl = document.getElementById("log");
const log = (text) => { const li = document.createElement("li"); li.textContent = text; logEl.appendChild(li); };
const show = (value) => JSON.stringify(value);

const app = new App({ name: "sdk-probe", version: "1.0.0" }, { availableDisplayModes: ["inline", "fullscreen"] }, { autoResize: true });
app.ontoolinput = (params) => log("tool-input " + show(params.arguments));
app.ontoolresult = (result) => log("tool-result " + show(result.content));
app.onhostcontextchanged = (context) => log("host-context-changed " + show(context));
app.onteardown = async () => { log("teardown"); return {}; };

async function run(label, action) {
  try { log(label + " → " + show(await action())); }
  catch (error) { log(label + " ✗ " + (error && error.message ? error.message : show(error))); }
}

document.getElementById("call").addEventListener("click", () =>
  run("callServerTool", () => app.callServerTool({ name: "report_result", arguments: { winner: "sdk-probe" } })));
document.getElementById("message").addEventListener("click", () =>
  run("sendMessage", () => app.sendMessage({ role: "user", content: [{ type: "text", text: "Hello from an app built with the official SDK." }] })));
document.getElementById("link").addEventListener("click", () =>
  run("openLink", () => app.openLink({ url: "https://modelcontextprotocol.io/extensions/apps/overview" })));
document.getElementById("context").addEventListener("click", () =>
  run("updateModelContext", () => app.updateModelContext({ content: [{ type: "text", text: "Probe state: ok" }] })));
document.getElementById("mode").addEventListener("click", () =>
  run("requestDisplayMode", () => app.requestDisplayMode({ mode: "fullscreen" })));

try {
  await app.connect();
  const host = app.getHostVersion();
  const context = app.getHostContext();
  document.getElementById("status").textContent = "Connected to " + (host ? host.name : "?");
  log("connected: host " + show(host) + ", theme " + (context && context.theme) + ", platform " + (context && context.platform));
  await app.sendLog({ level: "info", data: "sdk-probe connected" });
} catch (error) {
  document.getElementById("status").textContent = "Handshake failed";
  log("connect ✗ " + (error && error.message ? error.message : show(error)));
}
"""

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Official SDK probe</title>
<style>
  body { margin: 0; font: 14px/1.4 -apple-system, system-ui, sans-serif; color: #14181a; background: #fff; }
  main { padding: 14px; display: grid; gap: 10px; }
  h1 { font-size: 16px; margin: 0; }
  #status { font-weight: 700; color: #0b6e5d; }
  .buttons { display: flex; flex-wrap: wrap; gap: 6px; }
  button { border: 1px solid #dde1e3; background: #f3f5f6; border-radius: 9px; padding: 8px 10px; font: 600 13px -apple-system, system-ui, sans-serif; min-height: 40px; }
  ol { margin: 0; padding-left: 18px; font: 11px/1.45 ui-monospace, Menlo, monospace; color: #454b42; word-break: break-all; }
</style>
</head>
<body>
<main>
  <h1>App built with @modelcontextprotocol/ext-apps __VERSION__</h1>
  <div id="status">Connecting…</div>
  <div class="buttons">
    <button id="call" type="button">callServerTool</button>
    <button id="message" type="button">sendMessage</button>
    <button id="link" type="button">openLink</button>
    <button id="context" type="button">updateModelContext</button>
    <button id="mode" type="button">requestDisplayMode</button>
  </div>
  <ol id="log"></ol>
</main>
<script type="module">
__BUNDLE__
__PROBE__
</script>
</body>
</html>
"""


def main() -> None:
    bundle = urllib.request.urlopen(URL, timeout=60).read().decode("utf-8")
    # Replace the module's export list with a global, so the probe below can use it.
    match = re.search(r"export\s*\{([^}]*)\};?\s*$", bundle)
    if not match:
        raise SystemExit("Unexpected bundle format: no trailing export list")
    pairs = []
    for item in match.group(1).split(","):
        parts = item.strip().split(" as ")
        local, exported = (parts[0], parts[1]) if len(parts) == 2 else (parts[0], parts[0])
        pairs.append(f"{exported.strip()}:{local.strip()}")
    bundle = bundle[: match.start()] + "window.__extApps={" + ",".join(pairs) + "};"
    bundle = bundle.replace("</script", "<\\/script")
    html = PAGE.replace("__VERSION__", VERSION).replace("__PROBE__", PROBE).replace("__BUNDLE__", bundle)
    OUT.write_text(html, encoding="utf-8")
    print(f"Wrote {OUT} ({len(html):,} bytes)")


if __name__ == "__main__":
    main()

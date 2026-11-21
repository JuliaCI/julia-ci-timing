#!/usr/bin/env node
// Static checks of the site's pages, run by CI (node tools/check-site.mjs).
// No browser and no data: it catches a script that does not parse, an
// inline handler calling a function no script defines, a page referring to
// a local file that is not there, and a ?tab= link to a tab that does not
// exist.

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join, dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { spawnSync } from "node:child_process";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const errors = [];
const fail = (msg) => errors.push(msg);
const read = (p) => readFileSync(join(ROOT, p), "utf8");

const pages = ["index.html", "404.html", "preview.html"];
for (const d of readdirSync(ROOT)) {
  if (existsSync(join(ROOT, d, "index.html")) && statSync(join(ROOT, d)).isDirectory()) pages.push(`${d}/index.html`);
}
const scripts = readdirSync(join(ROOT, "assets")).filter((f) => f.endsWith(".js")).map((f) => `assets/${f}`);

// Every script, and every inline script of a page, compiles
const inlineScriptTags = (html) =>
  [...html.matchAll(/<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/g)].map((m) => ({
    type: (m[1].match(/\btype="([^"]+)"/) || [])[1] ?? "",
    src: m[2],
  }));
const inlineScripts = (html) => inlineScriptTags(html).filter((t) => t.type !== "importmap").map((t) => t.src);
const checkScript = (src, where, type = "") => {
  if (type === "importmap") {
    try {
      JSON.parse(src);
    } catch (e) {
      fail(`${where}: import map is not JSON: ${e.message}`);
    }
  } else if (type === "module") {
    // A module cannot be compiled by vm without a flag, so node checks it
    const r = spawnSync(process.execPath, ["--input-type=module", "--check"], { input: src, encoding: "utf8" });
    if (r.status !== 0) fail(`${where}: ${r.stderr.split("\n").find((l) => l.includes("Error")) ?? r.stderr}`);
  } else {
    try {
      new vm.Script(src, { filename: where });
    } catch (e) {
      fail(`${where}: ${e.message}`);
    }
  }
};
for (const f of scripts) checkScript(read(f), f);
for (const p of pages) {
  // The link preview page is a Caddy template, not a page a browser runs
  if (p === "preview.html") continue;
  inlineScriptTags(read(p)).forEach((t, i) => checkScript(t.src, `${p}, inline script ${i + 1}`, t.type));
}

// Inline handlers (onclick="name(...)") call functions by name, which is
// also why the image's minifier keeps every name
const KEYWORDS = new Set(["if", "return", "void", "typeof", "new", "this", "event", "window", "document"]);
const defines = (src, name) =>
  new RegExp(`(function\\s+${name}\\b|\\b(const|let|var|class)\\s+${name}\\b|window\\.${name}\\s*=)`).test(src);
const siteScripts = scripts.map(read).join("\n");
for (const f of [...pages, ...scripts]) {
  const src = read(f);
  // A page's own inline scripts count too
  const scope = f === "index.html" || f.startsWith("assets/") ? siteScripts : siteScripts + inlineScripts(src).join("\n");
  const names = new Set([...src.matchAll(/\bon[a-z]+=\\?["']\s*([A-Za-z_$][\w$]*)\s*\(/g)].map((m) => m[1]));
  for (const n of names) {
    if (!KEYWORDS.has(n) && !n.startsWith("__") && !defines(scope, n)) fail(`${f}: an inline handler calls ${n}, which no script defines`);
  }
}

// Local files the pages refer to exist. The server answers api/, db/,
// data/ and badges/ itself, and preview.html refers to the page it describes.
const SERVED = /^(api|db|data|badges)(\/|$)/;
for (const p of pages) {
  if (p === "preview.html") continue;
  for (const m of read(p).matchAll(/\b(?:src|href)="([^"]+)"/g)) {
    let ref = m[1];
    if (/^(https?:|mailto:|data:|#|javascript:|\$\{)/.test(ref) || ref.includes("{{")) continue;
    ref = ref.replace(/[?#].*$/, "");
    if (ref === "" || ref === "/" || ref === "../") continue;
    const path = ref.startsWith("/") ? ref.slice(1) : relative(ROOT, resolve(ROOT, dirname(p), ref));
    if (SERVED.test(path)) continue;
    const target = join(ROOT, path);
    if (!existsSync(target) || (statSync(target).isDirectory() && !existsSync(join(target, "index.html")))) {
      fail(`${p}: refers to ${m[1]}, which is not in the repository`);
    }
  }
}

// ?tab= values name a tab: its key or its url in the TABS table
const app = read("assets/app.js");
const start = app.indexOf("const TABS = {");
const tabsSrc = app.slice(start, app.indexOf("\n};", start));
const tabs = new Set([
  ...[...tabsSrc.matchAll(/^ {2}"?([\w-]+)"?: \{/gm)].map((m) => m[1]),
  ...[...tabsSrc.matchAll(/^ {4}url: "([\w-]+)"/gm)].map((m) => m[1]),
]);
if (tabs.size < 5) fail("assets/app.js: could not read the TABS table");
for (const f of [...pages, ...scripts, "README.md", "llms.txt"]) {
  for (const m of read(f).matchAll(/[?&]tab=([\w-]+)|p\.set\("tab", "([\w-]+)"\)/g)) {
    const t = m[1] ?? m[2];
    if (!tabs.has(t)) fail(`${f}: links to tab ${t}, which TABS does not have`);
  }
}

if (errors.length) {
  for (const e of errors) console.error(`error: ${e}`);
  process.exit(1);
}
console.log(`ok: ${scripts.length} scripts, ${pages.length} pages, ${tabs.size} tab names`);

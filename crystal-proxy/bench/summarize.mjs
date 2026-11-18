// Reads bench/results/**.json and prints markdown tables: median [min-max] over the repetitions.
import fs from "node:fs";
import path from "node:path";

const dir = path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")), "results");

const median = (a) => {
  const s = [...a].sort((x, y) => x - y);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
const fmt = (a, digits = 0, unit = "") =>
  `${median(a).toFixed(digits)}${unit} [${Math.min(...a).toFixed(digits)}-${Math.max(...a).toFixed(digits)}]`;
const metric = (text, name) => Number((text.match(new RegExp(`^${name} (\\d+)`, "m")) ?? [])[1] ?? 0);

function load(scenario) {
  const groups = new Map(); // "name|conns" -> runs[]
  const folder = path.join(dir, scenario);
  for (const file of fs.readdirSync(folder).filter((f) => f.endsWith(".json"))) {
    const m = file.match(/^(.*)_c(\d+)_r(\d+)\.json$/);
    if (!m) continue;
    const [, name, conns] = m;
    const json = JSON.parse(fs.readFileSync(path.join(folder, file), "utf8"));
    const base = path.join(folder, file.replace(/\.json$/, ""));
    const requests = Math.round(json.summary.requestsPerSec * json.summary.total);
    const run = {
      rps: json.summary.requestsPerSec,
      p50: json.latencyPercentiles.p50 * 1000,
      p99: json.latencyPercentiles.p99 * 1000,
      p999: json.latencyPercentiles["p99.9"] * 1000,
      max: json.summary.slowest * 1000,
      ok: json.summary.successRate * 100,
      requests,
      connsPer1k: fs.existsSync(base + ".accepts") ? (Number(fs.readFileSync(base + ".accepts", "utf8")) / requests) * 1000 : NaN,
    };
    const key = `${name}|${conns}`;
    groups.set(key, [...(groups.get(key) ?? []), run]);
  }
  return groups;
}

const out = [];
const tp = load("tp");
out.push("### Throughput (median [min-max] over repetitions)\n");
out.push("| Setup | Conns | Req/s | p50 ms | p99 ms | backend conns opened per 1000 req | OK % |");
out.push("|---|---:|---:|---:|---:|---:|---:|");
for (const [key, runs] of [...tp].sort((a, b) => Number(a[0].split("|")[1]) - Number(b[0].split("|")[1]))) {
  const [name, conns] = key.split("|");
  out.push(`| ${name} | ${conns} | ${fmt(runs.map((r) => r.rps))} | ${fmt(runs.map((r) => r.p50), 1)} | ${fmt(runs.map((r) => r.p99), 1)} | ${fmt(runs.map((r) => r.connsPer1k), 1)} | ${median(runs.map((r) => r.ok)).toFixed(2)} |`);
}

const slow = load("slow");
out.push("\n### One backend slow (+500 ms), 50 connections (median [min-max])\n");
out.push("| Setup | Req/s | p99 ms | p99.9 ms | slowest ms | OK % |");
out.push("|---|---:|---:|---:|---:|---:|");
for (const [key, runs] of slow) {
  const [name] = key.split("|");
  out.push(`| ${name} | ${fmt(runs.map((r) => r.rps))} | ${fmt(runs.map((r) => r.p99), 1)} | ${fmt(runs.map((r) => r.p999), 1)} | ${fmt(runs.map((r) => r.max), 0)} | ${median(runs.map((r) => r.ok)).toFixed(2)} |`);
}
console.log(out.join("\n"));

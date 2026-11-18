// Server-side "control plane" for the demo. It owns three things:
//   1. the proxy process (crystal-proxy)
//   2. the demo backends (.NET processes, one per port)
//   3. a traffic generator
// The dashboard talks to this through /api/state and /api/action. The only
// integration with the proxy itself is: write proxy.yml, POST /admin/reload,
// and read GET /api/state from the proxy admin port. No custom protocol.

import { spawn, ChildProcess } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(process.cwd(), "..");
const IS_WIN = process.platform === "win32";
const PROXY_EXE = path.join(ROOT, "crystal-proxy", "bin", IS_WIN ? "crystal-proxy.exe" : "crystal-proxy");
const BACKEND_DLL = path.join(ROOT, "demo-backend", "out", "DemoBackend.dll");
const RUNTIME_DIR = path.join(ROOT, "crystal-proxy", "runtime");
const CONFIG_PATH = path.join(RUNTIME_DIR, "proxy.yml");

export const PROXY_PORT = 8080;
export const ADMIN_PORT = 9090;
export const PROXY_URL = `http://127.0.0.1:${PROXY_PORT}`;
export const ADMIN_URL = `http://127.0.0.1:${ADMIN_PORT}`;

export type PoolSettings = {
  health_interval_ms: number;
  unhealthy_after: number;
  healthy_after: number;
  read_timeout_ms: number;
};

export type AutoBanSettings = { enabled: boolean; threshold: number; ban_seconds: number };

export type Model = {
  pools: Record<string, { backends: number[]; settings: PoolSettings }>;
  autoban: AutoBanSettings;
};

export type Traffic = {
  running: boolean;
  concurrency: number;
  mix: "fast" | "work" | "mixed" | "payload";
  sent: number;
  ok: number;
  errors: number;
};

type Manager = {
  proxy: ChildProcess | null;
  backends: Map<number, ChildProcess>;
  model: Model;
  traffic: Traffic;
  trafficToken: number;
  log: string[];
};

const defaults: PoolSettings = { health_interval_ms: 1000, unhealthy_after: 2, healthy_after: 2, read_timeout_ms: 5000 };

const g = globalThis as unknown as { __manager?: Manager };

export function manager(): Manager {
  if (!g.__manager) {
    g.__manager = {
      proxy: null,
      backends: new Map(),
      model: {
        pools: {
          api: { backends: [9001, 9002, 9003], settings: { ...defaults } },
          web: { backends: [9101], settings: { ...defaults } },
        },
        autoban: { enabled: false, threshold: 10, ban_seconds: 30 },
      },
      traffic: { running: false, concurrency: 8, mix: "mixed", sent: 0, ok: 0, errors: 0 },
      trafficToken: 0,
      log: [],
    };
    const cleanup = () => {
      const m = g.__manager!;
      m.proxy?.kill();
      m.backends.forEach((p) => p.kill());
    };
    process.on("exit", cleanup);
    process.on("SIGINT", () => { cleanup(); process.exit(0); });
    process.on("SIGTERM", () => { cleanup(); process.exit(0); });
  }
  return g.__manager;
}

function note(msg: string) {
  const m = manager();
  m.log.unshift(`${new Date().toLocaleTimeString()}  ${msg}`);
  m.log.length = Math.min(m.log.length, 30);
}

// ---- config generation -----------------------------------------------------

export function renderConfig(model: Model): string {
  const lines = [`listen: "0.0.0.0:${PROXY_PORT}"`, `metrics_listen: "127.0.0.1:${ADMIN_PORT}"`, "access_log: false", ""];
  if (model.autoban.enabled) {
    // trust_forwarded_for: only so the dashboard can pretend to be other clients (X-Forwarded-For).
    // Never enable it on a proxy that clients reach directly.
    lines.push("autoban:", `  threshold: ${model.autoban.threshold}`, "  window_seconds: 30", `  ban_seconds: ${model.autoban.ban_seconds}`, "  trust_forwarded_for: true", "");
  }
  lines.push("pools:");
  for (const [name, pool] of Object.entries(model.pools)) {
    const urls = pool.backends.map((p) => `"http://127.0.0.1:${p}"`).join(", ");
    lines.push(
      `  ${name}:`,
      `    backends: [${urls}]`,
      `    health_path: "/health"`,
      `    health_interval_ms: ${pool.settings.health_interval_ms}`,
      `    unhealthy_after: ${pool.settings.unhealthy_after}`,
      `    healthy_after: ${pool.settings.healthy_after}`,
      `    connect_timeout_ms: 500`,
      `    read_timeout_ms: ${pool.settings.read_timeout_ms}`,
    );
  }
  lines.push("", "routes:", `  - {host: "*", path_prefix: "/", pool: api}`, `  - {host: "*", path_prefix: "/static", pool: web}`, "");
  return lines.join("\n");
}

export async function applyConfig(): Promise<string | null> {
  const m = manager();
  fs.mkdirSync(RUNTIME_DIR, { recursive: true });
  fs.writeFileSync(CONFIG_PATH, renderConfig(m.model));
  if (!m.proxy) return null;
  try {
    const res = await fetch(`${ADMIN_URL}/admin/reload`, { method: "POST" });
    if (!res.ok) return await res.text();
  } catch (e) {
    return String(e);
  }
  return null;
}

// ---- processes -------------------------------------------------------------

export function proxyBuilt() {
  return fs.existsSync(PROXY_EXE);
}
export function backendBuilt() {
  return fs.existsSync(BACKEND_DLL);
}

export function startBackend(port: number) {
  const m = manager();
  if (m.backends.has(port)) return;
  const child = spawn("dotnet", [BACKEND_DLL, "--port", String(port), "--name", `app-${port}`], { stdio: "ignore", windowsHide: true });
  child.on("exit", () => {
    if (m.backends.get(port) === child) m.backends.delete(port);
  });
  m.backends.set(port, child);
  note(`started backend :${port}`);
}

// Polls the backend's /health for up to ~8 s.
export async function waitUntilHealthy(port: number) {
  for (let i = 0; i < 40; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(300) });
      if (res.ok) return;
    } catch {
      /* not listening yet */
    }
    await new Promise((r) => setTimeout(r, 200));
  }
}

export function killBackend(port: number) {
  const m = manager();
  m.backends.get(port)?.kill();
  m.backends.delete(port);
  note(`killed backend :${port} (still in config: watch the health check eject it)`);
}

export async function startProxy(): Promise<string | null> {
  const m = manager();
  if (m.proxy) return null;
  if (!proxyBuilt()) return `proxy binary not found at ${PROXY_EXE}. Build it first (see README).`;
  await applyConfig();
  const child = spawn(PROXY_EXE, ["--config", CONFIG_PATH], { stdio: "ignore", windowsHide: true, cwd: path.dirname(PROXY_EXE) });
  child.on("exit", () => {
    if (m.proxy === child) m.proxy = null;
  });
  m.proxy = child;
  note("started crystal-proxy");
  return null;
}

export function stopProxy() {
  const m = manager();
  m.proxy?.kill();
  m.proxy = null;
  note("stopped crystal-proxy");
}

export function startDemo() {
  const m = manager();
  for (const pool of Object.values(m.model.pools)) pool.backends.forEach(startBackend);
}

export function nextPort(pool: string) {
  const all = Object.values(manager().model.pools).flatMap((p) => p.backends);
  const base = pool === "web" ? 9101 : 9001;
  let port = base;
  while (all.includes(port)) port++;
  return port;
}

// ---- traffic generator -----------------------------------------------------

function pickPath(mix: Traffic["mix"]): string {
  const r = Math.random();
  switch (mix) {
    case "fast":
      return "/";
    case "work":
      return `/work?ms=${20 + Math.floor(Math.random() * 120)}`;
    case "payload":
      return `/payload?kb=${256 + Math.floor(Math.random() * 1024)}`;
    default:
      if (r < 0.45) return "/";
      if (r < 0.75) return `/work?ms=${10 + Math.floor(Math.random() * 90)}`;
      if (r < 0.9) return "/static/app.css";
      return `/payload?kb=${64 + Math.floor(Math.random() * 512)}`;
  }
}

export function startTraffic(concurrency: number, mix: Traffic["mix"]) {
  const m = manager();
  m.trafficToken++;
  const token = m.trafficToken;
  Object.assign(m.traffic, { running: true, concurrency, mix, sent: 0, ok: 0, errors: 0 });
  for (let i = 0; i < concurrency; i++) {
    void (async () => {
      while (m.trafficToken === token) {
        try {
          const res = await fetch(PROXY_URL + pickPath(m.traffic.mix));
          await res.arrayBuffer();
          m.traffic.sent++;
          res.status < 500 ? m.traffic.ok++ : m.traffic.errors++;
        } catch {
          m.traffic.sent++;
          m.traffic.errors++;
          await new Promise((r) => setTimeout(r, 200));
        }
      }
    })();
  }
  note(`traffic ON: ${concurrency} concurrent clients, mix=${mix}`);
}

export function stopTraffic() {
  const m = manager();
  m.trafficToken++;
  m.traffic.running = false;
  note("traffic OFF");
}

// ---- state snapshot --------------------------------------------------------

async function getJson(url: string, ms = 800): Promise<any | null> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(ms), cache: "no-store" });
    return res.ok ? await res.json() : null;
  } catch {
    return null;
  }
}

export async function snapshot() {
  const m = manager();
  const proxyState = m.proxy ? await getJson(`${ADMIN_URL}/api/state`) : null;
  const ports = new Set<number>([...m.backends.keys(), ...Object.values(m.model.pools).flatMap((p) => p.backends)]);
  const controls: Record<number, any> = {};
  await Promise.all(
    [...ports].map(async (port) => {
      controls[port] = m.backends.has(port) ? await getJson(`http://127.0.0.1:${port}/control`) : null;
    }),
  );
  return {
    now: Date.now(),
    built: { proxy: proxyBuilt(), backend: backendBuilt() },
    proxyRunning: !!m.proxy,
    proxy: proxyState,
    model: m.model,
    running: [...m.backends.keys()],
    controls,
    traffic: m.traffic,
    log: m.log,
  };
}

// ---- auto-ban demo helpers --------------------------------------------------

// Pretends to be a scanner at the given address: requests that do not exist, one after another.
export async function simulateScanner(client: string, count: number) {
  const paths = ["/wp-login.php", "/.env", "/admin", "/phpmyadmin", "/.git/config", "/backup.zip", "/server-status", "/api/v1/users"];
  const seen: Record<string, number> = {};
  for (let i = 0; i < count; i++) {
    try {
      const res = await fetch(PROXY_URL + paths[i % paths.length], { headers: { "X-Forwarded-For": client } });
      await res.arrayBuffer();
      seen[res.status] = (seen[res.status] ?? 0) + 1;
    } catch {
      seen.failed = (seen.failed ?? 0) + 1;
    }
  }
  return seen;
}

export async function unban(client?: string) {
  const query = client ? `?ip=${encodeURIComponent(client)}` : "";
  await fetch(`${ADMIN_URL}/admin/unban${query}`, { method: "POST" });
}

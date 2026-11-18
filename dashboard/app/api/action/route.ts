import {
  applyConfig, killBackend, manager, nextPort, startBackend, startDemo, startProxy, startTraffic,
  simulateScanner, stopProxy, stopTraffic, unban, waitUntilHealthy, type Traffic,
} from "@/lib/manager";

export const dynamic = "force-dynamic";

// One endpoint, many small actions: keeps the control plane easy to read.
export async function POST(req: Request) {
  const body = await req.json();
  const m = manager();
  let error: string | null = null;
  let result: unknown = null;

  switch (body.type) {
    case "start-all": {
      startDemo();
      error = await startProxy();
      break;
    }
    case "start-proxy":
      error = await startProxy();
      break;
    case "stop-proxy":
      stopProxy();
      break;
    case "add-backend": {
      const pool: string = body.pool ?? "api";
      const port = nextPort(pool);
      startBackend(port);
      await waitUntilHealthy(port); // don't give the proxy a backend that isn't listening yet
      m.model.pools[pool].backends.push(port);
      error = await applyConfig();
      break;
    }
    case "remove-backend": {
      for (const pool of Object.values(m.model.pools)) pool.backends = pool.backends.filter((p) => p !== body.port);
      killBackend(body.port);
      error = await applyConfig();
      break;
    }
    case "kill-backend":
      killBackend(body.port);
      break;
    case "start-backend":
      startBackend(body.port);
      break;
    case "chaos": {
      const { port, ...patch } = body;
      delete patch.type;
      await fetch(`http://127.0.0.1:${port}/control`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(patch),
      }).catch((e) => (error = String(e)));
      break;
    }
    case "settings": {
      const pool = m.model.pools[body.pool];
      if (pool) Object.assign(pool.settings, body.settings);
      error = await applyConfig();
      break;
    }
    case "autoban": {
      Object.assign(m.model.autoban, body.settings);
      error = await applyConfig();
      break;
    }
    case "scan": {
      result = await simulateScanner(String(body.client ?? "203.0.113.7"), Math.min(Number(body.count) || 30, 200));
      break;
    }
    case "unban":
      await unban(body.client);
      break;
    case "traffic-start":
      startTraffic(Math.max(1, Math.min(256, Number(body.concurrency) || 8)), (body.mix as Traffic["mix"]) ?? "mixed");
      break;
    case "traffic-stop":
      stopTraffic();
      break;
    default:
      error = `unknown action ${body.type}`;
  }
  return Response.json({ ok: !error, error, result });
}

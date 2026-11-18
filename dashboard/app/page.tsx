"use client";

import { useCallback, useEffect, useRef, useState } from "react";

/* eslint-disable @typescript-eslint/no-explicit-any */

type Sample = { t: number; total: number; hist: number[]; err: number };

const MIX = [
  ["mixed", "Mixed (fast, slow, static, big)"],
  ["fast", "Fast tiny requests"],
  ["work", "Slow work (20-140 ms)"],
  ["payload", "Large streamed bodies"],
] as const;

async function act(body: Record<string, unknown>) {
  const res = await fetch("/api/action", { method: "POST", body: JSON.stringify(body) });
  return (await res.json()) as { ok: boolean; error: string | null; result?: Record<string, number> | null };
}

function quantile(hist: number[], buckets: number[], q: number) {
  const total = hist.reduce((a, b) => a + b, 0);
  if (!total) return 0;
  let cum = 0;
  for (let i = 0; i < hist.length; i++) {
    cum += hist[i];
    if (cum >= q * total) return i < buckets.length ? buckets[i] : buckets[buckets.length - 1] * 2;
  }
  return 0;
}

function Spark({ data, color, max }: { data: number[]; color: string; max?: number }) {
  const w = 200, h = 34;
  const top = Math.max(max ?? 0, ...data, 1);
  const pts = data.map((v, i) => `${(i / Math.max(data.length - 1, 1)) * w},${h - 2 - (v / top) * (h - 6)}`);
  const line = pts.join(" ");
  return (
    <svg viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none">
      {data.length > 1 && (
        <>
          <polygon points={`0,${h} ${line} ${w},${h}`} fill={color} opacity={0.15} />
          <polyline points={line} fill="none" stroke={color} strokeWidth={1.8} vectorEffect="non-scaling-stroke" />
        </>
      )}
    </svg>
  );
}

function Kpi({ label, value, unit, series, color }: { label: string; value: string; unit?: string; series: number[]; color: string }) {
  return (
    <div className="card kpi">
      <div className="label">{label}</div>
      <div className="value">
        {value}
        {unit && <span className="unit">{unit}</span>}
      </div>
      <Spark data={series} color={color} />
    </div>
  );
}

export default function Page() {
  const [s, setS] = useState<any>(null);
  const [sel, setSel] = useState<number | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [conc, setConc] = useState(8);
  const [scan, setScan] = useState<string | null>(null);
  const [mix, setMix] = useState<string>("mixed");
  const hist = useRef<Sample[]>([]);
  const [series, setSeries] = useState({ rps: [] as number[], p50: [] as number[], p99: [] as number[], err: [] as number[], live: { rps: 0, p50: 0, p99: 0, err: 0 } });

  const poll = useCallback(async () => {
    try {
      const data = await (await fetch("/api/state", { cache: "no-store" })).json();
      setS(data);
      const p = data.proxy;
      if (!p) return;
      const sample: Sample = { t: data.now, total: p.total, hist: p.histogram, err: p.classes["5xx"] };
      const h = hist.current;
      if (h.length && sample.total < h[h.length - 1].total) h.length = 0; // proxy restarted
      h.push(sample);
      if (h.length > 120) h.shift();
      if (h.length < 2) return;
      const prev = h[h.length - 2];
      const win = h[Math.max(0, h.length - 6)];
      const dt = (sample.t - prev.t) / 1000 || 1;
      const rps = (sample.total - prev.total) / dt;
      const deltaHist = sample.hist.map((v, i) => v - win.hist[i]);
      const p50 = quantile(deltaHist, p.buckets_ms, 0.5);
      const p99 = quantile(deltaHist, p.buckets_ms, 0.99);
      const err = (sample.err - prev.err) / dt;
      setSeries((o) => ({
        rps: [...o.rps, rps].slice(-60),
        p50: [...o.p50, p50].slice(-60),
        p99: [...o.p99, p99].slice(-60),
        err: [...o.err, err].slice(-60),
        live: { rps, p50, p99, err },
      }));
    } catch {
      /* dashboard server restarting */
    }
  }, []);

  useEffect(() => {
    poll();
    const id = setInterval(poll, 1000);
    return () => clearInterval(id);
  }, [poll]);

  const run = async (body: Record<string, unknown>) => {
    const r = await act(body);
    setMsg(r.error);
    poll();
  };

  if (!s) return <div className="wrap">Connecting to the control plane…</div>;

  const p = s.proxy;
  const running: number[] = s.running;
  const proxyBackends: Record<number, any> = {};
  p?.pools.forEach((pool: any) => pool.backends.forEach((b: any) => (proxyBackends[Number(new URL(b.url).port)] = { ...b, pool: pool.name })));
  const rows: { pool: string; port: number }[] = Object.entries(s.model.pools).flatMap(([pool, v]: any) => v.backends.map((port: number) => ({ pool, port })));
  const maxActive = Math.max(1, ...rows.map((r) => proxyBackends[r.port]?.active ?? 0));
  const selected = sel != null ? rows.find((r) => r.port === sel) : undefined;
  const ctl = sel != null ? s.controls[sel] : null;
  const apiRunning = rows.filter((r) => r.pool === "api" && running.includes(r.port));
  const live = series.live;
  const ab = p?.autoban; // what the proxy reports (bans, counters)
  const abm = s.model.autoban; // what the dashboard has configured
  const share = (port: number) => {
    const total = rows.reduce((a, r) => a + (proxyBackends[r.port]?.requests ?? 0), 0) || 1;
    return ((proxyBackends[port]?.requests ?? 0) / total) * 100;
  };
  const errRate = p && p.total ? (p.classes["5xx"] / p.total) * 100 : 0;

  // ---------- topology geometry ----------
  const rowH = 78, topPad = 16;
  const H = Math.max(rows.length * rowH + topPad * 2, 260);
  const midY = H / 2;
  const bx = 640, px = 290;

  return (
    <div className="wrap">
      <header className="top">
        <h1>Crystal Proxy Lab</h1>
        <span className="sub">least-connections reverse proxy · written in Crystal · shared keep-alive pools</span>
        <div className="spacer" />
        <span className="pill"><span className={`dot ${s.proxyRunning && p ? "ok" : "bad"}`} />{s.proxyRunning && p ? "proxy :8080 up" : "proxy stopped"}</span>
        {!s.proxyRunning ? (
          <button className="btn primary" onClick={() => run({ type: "start-all" })}>Launch demo</button>
        ) : (
          <button className="btn danger" onClick={() => run({ type: "stop-proxy" })}>Stop proxy</button>
        )}
      </header>

      {(!s.built.proxy || !s.built.backend) && (
        <div className="banner">
          Missing builds: {!s.built.proxy && "crystal-proxy/bin/crystal-proxy "}{!s.built.backend && "demo-backend/out/DemoBackend.dll "}
          . Run <code>./scripts/build.ps1</code> from the repo root.
        </div>
      )}
      {msg && <div className="banner">{msg}</div>}

      <div className="grid kpis">
        <Kpi label="Requests / s" value={Math.round(live.rps).toLocaleString()} series={series.rps} color="#7c8cff" />
        <Kpi label="Latency p50" value={String(live.p50)} unit="ms" series={series.p50} color="#36d6c4" />
        <Kpi label="Latency p99" value={String(live.p99)} unit="ms" series={series.p99} color="#ffb454" />
        <Kpi label="5xx / s" value={live.err.toFixed(1)} series={series.err} color="#ff5d6c" />
        <div className="card kpi">
          <div className="label">Total served</div>
          <div className="value">{(p?.total ?? 0).toLocaleString()}</div>
          <div className="logline">{((p?.bytes ?? 0) / 1048576).toFixed(1)} MB streamed</div>
        </div>
        <div className="card kpi">
          <div className="label">Error rate</div>
          <div className="value">{errRate.toFixed(1)}<span className="unit">%</span></div>
          <div className="logline">2xx {p?.classes["2xx"] ?? 0} · 4xx {p?.classes["4xx"] ?? 0} · 5xx {p?.classes["5xx"] ?? 0}</div>
        </div>
      </div>

      <div className="grid two">
        <div className="card">
          <h2>Live topology <span className="logline">click a backend to inject faults</span></h2>
          <svg className="topo" viewBox={`0 0 900 ${H}`}>
            {/* client -> proxy */}
            <path d={`M150 ${midY} L${px} ${midY}`} stroke="#7c8cff" strokeWidth={3} fill="none" className={live.rps > 0 ? "flow" : ""} />
            {rows.map((r, i) => {
              const b = proxyBackends[r.port];
              const y = topPad + i * rowH + rowH / 2;
              const healthy = b ? b.healthy : false;
              const w = 1 + Math.min(6, ((b?.active ?? 0) / maxActive) * 6);
              return (
                <path key={r.port} d={`M${px + 150} ${midY} C ${px + 300} ${midY}, ${bx - 150} ${y}, ${bx} ${y}`}
                  stroke={healthy ? "#3ddc97" : "#ff5d6c"} strokeOpacity={healthy ? 0.85 : 0.35} strokeWidth={w} fill="none"
                  className={healthy && (b?.active ?? 0) > 0 ? "flow" : ""} strokeDasharray={healthy ? undefined : "2 6"} />
              );
            })}
            {/* client */}
            <g>
              <rect x={20} y={midY - 38} width={130} height={76} rx={14} fill="#1a2033" stroke="#262e47" />
              <text x={85} y={midY - 6} textAnchor="middle" fontWeight={600}>Clients</text>
              <text x={85} y={midY + 12} textAnchor="middle" className="dim">{s.traffic.running ? `${s.traffic.concurrency} concurrent` : "idle"}</text>
            </g>
            {/* proxy */}
            <g>
              <rect x={px} y={midY - 62} width={150} height={124} rx={16} fill="#1b2250" stroke="#7c8cff" strokeWidth={1.5} />
              <text x={px + 75} y={midY - 34} textAnchor="middle" fontWeight={700}>crystal-proxy</text>
              {["Router · host + prefix", "Balancer · least conn", "Pool · keep-alive", "Health · failover"].map((t, i) => (
                <text key={t} x={px + 75} y={midY - 10 + i * 17} textAnchor="middle" className="dim">{t}</text>
              ))}
            </g>
            {/* backends */}
            {rows.map((r, i) => {
              const b = proxyBackends[r.port];
              const alive = running.includes(r.port);
              const y = topPad + i * rowH;
              const c = s.controls[r.port];
              const healthy = b?.healthy;
              const color = !alive ? "#ff5d6c" : healthy === false ? "#ff5d6c" : "#3ddc97";
              return (
                <g key={r.port} className="node" onClick={() => setSel(r.port)}>
                  <rect className="body" x={bx} y={y + 4} width={250} height={rowH - 8} rx={12} fill="#131827" stroke={sel === r.port ? "#7c8cff" : "#262e47"} strokeWidth={sel === r.port ? 2 : 1} />
                  <circle cx={bx + 16} cy={y + 24} r={5} fill={color} />
                  <text x={bx + 28} y={y + 28} fontWeight={600}>{r.pool} :{r.port}</text>
                  <text x={bx + 238} y={y + 28} textAnchor="end" className="dim">
                    {!alive ? "process dead" : healthy === false ? "ejected" : c?.sick ? "sick" : c?.delayMs ? `+${c.delayMs}ms` : c?.failPercent ? `${c.failPercent}% fail` : "healthy"}
                  </text>
                  <rect x={bx + 14} y={y + 38} width={222} height={6} rx={3} fill="#262e47" />
                  <rect x={bx + 14} y={y + 38} width={Math.min(222, ((b?.active ?? 0) / maxActive) * 222)} height={6} rx={3} fill="#7c8cff" style={{ transition: "width .4s" }} />
                  <text x={bx + 14} y={y + 60} className="dim">in-flight {b?.active ?? 0} · idle conns {b?.idle_connections ?? 0}</text>
                  <text x={bx + 238} y={y + 60} textAnchor="end" className="dim">{(b?.requests ?? 0).toLocaleString()} req · {share(r.port).toFixed(0)}%</text>
                </g>
              );
            })}
          </svg>
        </div>

        <div className="grid" style={{ alignContent: "start" }}>
          <div className="card">
            <h2>Traffic generator</h2>
            <div className="controls">
              <div className="row">
                <label>Concurrency</label>
                <input type="range" min={1} max={128} value={conc} onChange={(e) => setConc(+e.target.value)} />
                <span className="val">{conc}</span>
              </div>
              <div className="row">
                <label>Request mix</label>
                <select value={mix} onChange={(e) => setMix(e.target.value)}>
                  {MIX.map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                </select>
              </div>
              <div className="row">
                {s.traffic.running ? (
                  <button className="btn danger" onClick={() => run({ type: "traffic-stop" })}>Stop traffic</button>
                ) : (
                  <button className="btn primary" disabled={!p} onClick={() => run({ type: "traffic-start", concurrency: conc, mix })}>Start traffic</button>
                )}
                {s.traffic.running && <span className="logline">{s.traffic.sent.toLocaleString()} sent · {s.traffic.errors} errors</span>}
              </div>
            </div>
          </div>

          <div className="card">
            <h2>Scenarios</h2>
            <div className="scenario">
              <button className="btn" disabled={!p} onClick={() => run({ type: "add-backend", pool: "api" })}>
                Scale out<small>Spawn a new .NET app, add it to the pool, hot-reload the proxy</small>
              </button>
              <button className="btn" disabled={!apiRunning.length} onClick={() => run({ type: "kill-backend", port: apiRunning[Math.floor(Math.random() * apiRunning.length)].port })}>
                Kill a backend<small>Watch 502s appear, then health checks eject it</small>
              </button>
              <button className="btn" disabled={!apiRunning.length} onClick={() => run({ type: "chaos", port: apiRunning[0].port, delayMs: 800 })}>
                Make one node slow<small>+800 ms latency: least-connections routes around it</small>
              </button>
              <button className="btn" disabled={!apiRunning.length} onClick={() => run({ type: "chaos", port: apiRunning[apiRunning.length - 1].port, failPercent: 40 })}>
                Make one node flaky<small>40% of requests return 500</small>
              </button>
              <button className="btn" disabled={!p} onClick={async () => {
                for (const r of rows) {
                  if (!running.includes(r.port)) await act({ type: "start-backend", port: r.port });
                  else await act({ type: "chaos", port: r.port, delayMs: 0, failPercent: 0, sick: false });
                }
                poll();
              }}>
                Heal everything<small>Restart dead nodes, clear injected faults</small>
              </button>
            </div>
          </div>

          <div className="card">
            <h2>Auto-ban <span className="logline">scanner protection</span></h2>
            <div className="controls">
              <div className="row">
                <label>Enabled</label>
                <input type="checkbox" checked={abm.enabled} onChange={(e) => run({ type: "autoban", settings: { enabled: e.target.checked } })} />
                <span className="logline">ban after N responses of 401/403/404 within 30 s</span>
              </div>
              <div className="row">
                <label>Errors to ban</label>
                <input type="range" min={3} max={50} value={abm.threshold} onChange={(e) => run({ type: "autoban", settings: { threshold: +e.target.value } })} />
                <span className="val">{abm.threshold}</span>
              </div>
              <div className="row">
                <label>Cooldown</label>
                <input type="range" min={10} max={300} step={10} value={abm.ban_seconds} onChange={(e) => run({ type: "autoban", settings: { ban_seconds: +e.target.value } })} />
                <span className="val">{abm.ban_seconds} s</span>
              </div>
              <div className="row">
                <button className="btn small" disabled={!p || !abm.enabled} onClick={async () => {
                  const r = await act({ type: "scan", client: "203.0.113.7", count: 40 });
                  setScan(Object.entries(r.result ?? {}).map(([code, n]) => `${code} x${n}`).join(", "));
                  poll();
                }}>Simulate scanner (40 bad requests)</button>
                <button className="btn small" disabled={!ab?.banned?.length} onClick={() => run({ type: "unban" })}>Unban all</button>
              </div>
              {scan && <div className="logline">scanner received: {scan}</div>}
              {(ab?.banned ?? []).map((b: any) => (
                <div className="row" key={b.client}>
                  <label><code>{b.client}</code></label>
                  <span className="val" style={{ textAlign: "left" }}>banned, {b.seconds_left}s left</span>
                  <button className="btn small" onClick={() => run({ type: "unban", client: b.client })}>Unban</button>
                </div>
              ))}
              <div className="logline">bans issued {ab?.bans_total ?? 0} · requests refused {ab?.rejected_total ?? 0}</div>
            </div>
          </div>
        </div>
      </div>

      <div className="grid two">
        <div className="card">
          <h2>{selected ? `Backend :${selected.port} (${selected.pool})` : "Backend controls"}</h2>
          {!selected && <div className="logline">Select a backend in the topology.</div>}
          {selected && (
            <div className="controls">
              {!running.includes(selected.port) ? (
                <div className="row">
                  <span className="logline">Process is not running.</span>
                  <button className="btn small" onClick={() => run({ type: "start-backend", port: selected.port })}>Start it</button>
                </div>
              ) : (
                <>
                  <div className="row">
                    <label>Added latency</label>
                    <input type="range" min={0} max={2000} step={50} value={ctl?.delayMs ?? 0} onChange={(e) => run({ type: "chaos", port: selected.port, delayMs: +e.target.value })} />
                    <span className="val">{ctl?.delayMs ?? 0} ms</span>
                  </div>
                  <div className="row">
                    <label>Failure rate</label>
                    <input type="range" min={0} max={100} step={5} value={ctl?.failPercent ?? 0} onChange={(e) => run({ type: "chaos", port: selected.port, failPercent: +e.target.value })} />
                    <span className="val">{ctl?.failPercent ?? 0} %</span>
                  </div>
                  <div className="row">
                    <label>Health check</label>
                    <button className="btn small" onClick={() => run({ type: "chaos", port: selected.port, sick: !ctl?.sick })}>{ctl?.sick ? "Make healthy" : "Make /health fail"}</button>
                    <button className="btn small danger" onClick={() => run({ type: "kill-backend", port: selected.port })}>Kill process</button>
                  </div>
                </>
              )}
              <div className="row">
                <label>Config</label>
                <button className="btn small danger" onClick={() => { run({ type: "remove-backend", port: selected.port }); setSel(null); }}>Remove from pool</button>
              </div>
            </div>
          )}
          <h2 style={{ marginTop: 18 }}>Proxy settings (hot reload)</h2>
          {["api"].map((name) => {
            const st = s.model.pools[name].settings;
            const set = (k: string, v: number) => run({ type: "settings", pool: name, settings: { [k]: v } });
            return (
              <div className="controls" key={name}>
                <div className="row">
                  <label>Health interval</label>
                  <input type="range" min={200} max={5000} step={100} value={st.health_interval_ms} onChange={(e) => set("health_interval_ms", +e.target.value)} />
                  <span className="val">{st.health_interval_ms} ms</span>
                </div>
                <div className="row">
                  <label>Down after</label>
                  <input type="range" min={1} max={6} value={st.unhealthy_after} onChange={(e) => set("unhealthy_after", +e.target.value)} />
                  <span className="val">{st.unhealthy_after} fails</span>
                </div>
                <div className="row">
                  <label>Read timeout</label>
                  <input type="range" min={200} max={10000} step={100} value={st.read_timeout_ms} onChange={(e) => set("read_timeout_ms", +e.target.value)} />
                  <span className="val">{st.read_timeout_ms} ms</span>
                </div>
              </div>
            );
          })}
        </div>

        <div className="card">
          <h2>Recent requests</h2>
          <table>
            <thead><tr><th>Path</th><th>Status</th><th>Backend</th><th>ms</th></tr></thead>
            <tbody>
              {(p?.recent ?? []).slice(0, 14).map((r: any, i: number) => (
                <tr key={r.t + "-" + i}>
                  <td className="mono">{r.method} {r.path.slice(0, 22)}</td>
                  <td className={r.status >= 500 ? "s5" : r.status >= 400 ? "s4" : "s2"}>{r.status}</td>
                  <td className="mono">{r.backend ? ":" + r.backend.split(":").pop() : "-"}</td>
                  <td>{r.ms}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <h2 style={{ marginTop: 18 }}>Control-plane log</h2>
          {s.log.slice(0, 6).map((l: string, i: number) => <div className="logline" key={i}>{l}</div>)}
        </div>
      </div>

      <div className="card full">
        <h2>How a request travels through the proxy</h2>
        <div className="steps">
          <div className="step"><b>1 · Route</b><p>Host header is matched (exact beats wildcard), then the longest path prefix picks a pool. No match → 404.</p></div>
          <div className="step"><b>2 · Balance</b><p>Each backend counts its in-flight requests as a simple counter. The healthy one with the fewest wins, so slow nodes receive less traffic automatically.</p></div>
          <div className="step"><b>3 · Reuse</b><p>A keep-alive socket is taken from the backend's idle pool (shared by all fibers) or opened if none is free.</p></div>
          <div className="step"><b>4 · Stream</b><p>Headers are cleaned (hop-by-hop out, X-Forwarded-* in). The body is copied in chunks, never buffered whole.</p></div>
          <div className="step"><b>5 · Heal</b><p>A fiber per backend probes /health. After N failures the node is ejected; after M successes it returns. Timeouts → 504, resets → 502.</p></div>
        </div>
      </div>
    </div>
  );
}

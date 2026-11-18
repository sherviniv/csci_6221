# Crystal Proxy Lab

A small **reverse proxy written in Crystal** (about 900 lines, standard library only), a **demo web server in
.NET** to put behind it, and a **Next.js dashboard** that shows and controls it live. Built for CSCI 6221.

## What it does

A reverse proxy sits in front of your servers: clients talk to the proxy, the proxy talks to the servers.

```
browser ──► proxy :8080 ──► demo servers :9001 :9002 :9003 :9101
               ▲
dashboard :3000 ── watches and controls the proxy through its admin port :9090
```

- **Routes** each request by host and path prefix (from a YAML file).
- **Balances load**: sends the request to the server with the fewest requests in flight.
- **Reuses connections** to the servers (a connection pool) instead of opening a new one every time.
- **Health checks**: a dead server is skipped; if a server fails or is too slow the client gets 502 / 504.
- **Live numbers** on the admin port: `/api/state` (JSON), `/metrics` (Prometheus); `POST /admin/reload`
  reloads the config without a restart.
- **Auto-ban** (optional, off by default): a client that keeps getting 401/403/404 responses is blocked for a
  cooldown. Add to `proxy.yml`: `autoban: {threshold: 20, window_seconds: 60, ban_seconds: 300}`.
  Bans are kept in memory, per proxy process.
- **Not included:** TLS, HTTP/2, WebSockets, caching, retries.

The **dashboard** starts and stops the proxy and the demo servers, sends test traffic, and lets you make a
server slow, failing or dead to watch the proxy react.

## Requirements

| Tool | Version | Used for |
|---|---|---|
| Crystal | 1.21 or newer | the proxy |
| .NET SDK | 10 | the demo servers |
| Node.js | 20 or newer | the dashboard |
| Docker | any recent | only for the benchmark |

The commands below are PowerShell on Windows. Run them from the repository root.

## 1. Run everything at once (dashboard)

```powershell
./scripts/build.ps1      # once: builds the proxy and demo server, installs dashboard packages
./scripts/start.ps1      # starts the dashboard (leave this window open)
```

1. Open <http://localhost:3000> and press **Launch demo**.
2. Open <http://localhost:8080/> in a browser. Refresh a few times: the answer comes from a different server.
3. Press **Start traffic** to see the numbers move.

Stop everything with `Ctrl+C` in the window that runs `start.ps1`.

## 2. Run it step by step

Build once (skip if you already ran `build.ps1`):

```powershell
./scripts/build.ps1
```

The dashboard starts the demo servers and the proxy itself (when you press **Launch demo**), so pick **one**
of the two ways below. Do not run both at the same time: they use the same ports.

**A. With the dashboard** (one PowerShell window in the repository root; this is what `start.ps1` runs):

```powershell
cd dashboard; npm run dev      # then open http://localhost:3000 and press "Launch demo"
```

**B. Without the dashboard** (four PowerShell windows in the repository root, one command in each):

```powershell
dotnet demo-backend/out/DemoBackend.dll --port 9001                      # window 1: demo server
dotnet demo-backend/out/DemoBackend.dll --port 9002                      # window 2: demo server
dotnet demo-backend/out/DemoBackend.dll --port 9003                      # window 3: demo server
cd crystal-proxy; .\bin\crystal-proxy.exe --config config/proxy.yml      # window 4: the proxy
```

Make a request. In a browser open <http://localhost:8080/>, or in a new window:

```powershell
curl.exe http://localhost:8080/               # answer from one of the servers
curl.exe -i http://localhost:8080/            # with headers; X-Backend says which server answered
curl.exe http://localhost:8080/headers        # headers the server received (the proxy adds X-Forwarded-*)
curl.exe http://localhost:8080/static/a.css   # served by the second pool (/static route)
curl.exe http://localhost:9090/api/state      # the proxy's live state
curl.exe http://localhost:9090/metrics        # the same numbers for Prometheus
```

Stop each window with `Ctrl+C`. To run the tests:

```powershell
cd crystal-proxy; crystal spec
```

Problems: *"connection refused"* on `:8080` means the proxy is not running; *502* means no demo server is
running; *"address already in use"* means an old run still holds the port; use `curl.exe`, not `curl`, in
PowerShell.

## Benchmark vs nginx

```
Requests per second, higher is better (1 CPU each, median of 5 runs)

100 connections
  nginx          ████████████████████████████████████████  28,190
  crystal-proxy  ████████████████████████████████████      25,047

1000 connections
  nginx          █████████████████████████████             20,393
  crystal-proxy  █████████████████████████                 17,622
```

Measured on a Windows 11 laptop in Docker, with the load generator, both proxies and the backends on one
machine, 5 runs of 10 s each; treat differences under about 10 % as noise. To repeat it (needs Docker and Node,
about 20 minutes):

```bash
cd crystal-proxy
./bench/run.sh 5 10      # raw results and a summary table end up in bench/results/
```

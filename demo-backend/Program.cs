// Demo web server for the Crystal proxy. Start as many copies as you like:
//   dotnet run -- --port 9001 --name app-1
// Everything about its behaviour can be changed live via /control, which is
// what the dashboard uses to inject latency, errors and "sickness".

using System.Diagnostics;

var port = 9001;
var name = "app";
for (var i = 0; i < args.Length - 1; i++)
{
    if (args[i] == "--port") port = int.Parse(args[i + 1]);
    if (args[i] == "--name") name = args[i + 1];
}
if (name == "app") name = $"app-{port}";

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.WebHost.UseUrls($"http://127.0.0.1:{port}");
builder.WebHost.ConfigureKestrel(o => o.Limits.MaxRequestBodySize = null);
var app = builder.Build();

var control = new Control();
var started = DateTime.UtcNow;
long served = 0;

// Chaos middleware: applies to everything except health and control.
app.Use(async (ctx, next) =>
{
    var path = ctx.Request.Path.Value ?? "/";
    if (path == "/health" || path.StartsWith("/control"))
    {
        await next();
        return;
    }
    Interlocked.Increment(ref served);
    if (control.DelayMs > 0) await Task.Delay(control.DelayMs);
    if (control.FailPercent > 0 && Random.Shared.Next(100) < control.FailPercent)
    {
        ctx.Response.StatusCode = 500;
        await ctx.Response.WriteAsync($"{name}: injected failure\n");
        return;
    }
    ctx.Response.Headers["X-Backend"] = name;
    await next();
});

app.MapGet("/", () => Results.Json(new
{
    backend = name,
    port,
    pid = Environment.ProcessId,
    uptimeSeconds = (int)(DateTime.UtcNow - started).TotalSeconds,
}));

// Sick backends fail their health check, so the proxy ejects them.
app.MapGet("/health", () => control.Sick ? Results.StatusCode(503) : Results.Ok("ok"));

// Simulates work: /work?ms=50
app.MapGet("/work", async (int? ms) =>
{
    await Task.Delay(Math.Clamp(ms ?? 50, 0, 30_000));
    return Results.Json(new { backend = name, tookMs = ms ?? 50 });
});

// Streams N KB of data without buffering: /payload?kb=1024
app.MapGet("/payload", async (HttpContext ctx, int? kb) =>
{
    var total = (long)Math.Clamp(kb ?? 64, 1, 1_048_576) * 1024;
    ctx.Response.ContentType = "application/octet-stream";
    ctx.Response.ContentLength = total;
    var buffer = new byte[16 * 1024];
    for (long sent = 0; sent < total; sent += buffer.Length)
        await ctx.Response.Body.WriteAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, total - sent)));
});

// Streams the request body back, counting bytes.
app.MapPost("/echo", async (HttpContext ctx) =>
{
    long n = 0;
    var buffer = new byte[16 * 1024];
    int read;
    while ((read = await ctx.Request.Body.ReadAsync(buffer)) > 0) n += read;
    return Results.Json(new { backend = name, receivedBytes = n });
});

// Shows which headers the proxy forwarded (X-Forwarded-*, no hop-by-hop).
app.MapGet("/headers", (HttpContext ctx) => Results.Json(new
{
    backend = name,
    headers = ctx.Request.Headers.ToDictionary(h => h.Key, h => h.Value.ToString()),
}));

app.MapGet("/static/{**rest}", (string? rest) => Results.Text($"static file '{rest}' served by {name}\n"));

app.MapGet("/control", () => Results.Json(control.Snapshot(name, port, served)));
app.MapPost("/control", (ControlUpdate u) =>
{
    if (u.DelayMs is { } d) control.DelayMs = Math.Clamp(d, 0, 30_000);
    if (u.FailPercent is { } f) control.FailPercent = Math.Clamp(f, 0, 100);
    if (u.Sick is { } s) control.Sick = s;
    return Results.Json(control.Snapshot(name, port, served));
});

Console.WriteLine($"{name} listening on http://127.0.0.1:{port} (pid {Process.GetCurrentProcess().Id})");
app.Run();

class Control
{
    public volatile int DelayMs;
    public volatile int FailPercent;
    public volatile bool Sick;

    public object Snapshot(string name, int port, long served) =>
        new { name, port, delayMs = DelayMs, failPercent = FailPercent, sick = Sick, served };
}

record ControlUpdate(int? DelayMs, int? FailPercent, bool? Sick);

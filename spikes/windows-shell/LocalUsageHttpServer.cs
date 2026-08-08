using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;

namespace OpenUsageShell;

/// <summary>TCP HTTP server on 0.0.0.0:6736 — dashboard + /v1/usage (localhost + LAN, no urlacl).</summary>
internal sealed class LocalUsageHttpServer : IDisposable
{
    private const int Port = 6736;

    private readonly Func<IReadOnlyList<SidecarProvider>> _getProviders;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private byte[]? _dashboardHtml;

    public LocalUsageHttpServer(Func<IReadOnlyList<SidecarProvider>> getProviders)
    {
        _getProviders = getProviders;
    }

    public void Start()
    {
        if (_listener is not null)
        {
            return;
        }

        _dashboardHtml = LoadDashboardHtml();
        _listener = new TcpListener(IPAddress.Any, Port);
        try
        {
            _listener.Start();
            TryEnsureFirewallRule();
        }
        catch (SocketException ex)
        {
            ShellLogger.Instance.Info("localapi", $"disabled: {ex.Message}");
            _listener = null;
            return;
        }

        _cts = new CancellationTokenSource();
        _ = Task.Run(() => ListenLoopAsync(_cts.Token));
        ShellLogger.Instance.Info("localapi", $"Listening on http://0.0.0.0:{Port}/ (LAN + localhost)");
    }

    public void Dispose()
    {
        _cts?.Cancel();
        _listener?.Stop();
        _listener = null;
        _cts?.Dispose();
        _cts = null;
    }

    private async Task ListenLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested && _listener is not null)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (SocketException)
            {
                break;
            }

            _ = Task.Run(() => HandleClient(client), cancellationToken);
        }
    }

    private void HandleClient(TcpClient client)
    {
        try
        {
            using (client)
            using (var stream = client.GetStream())
            {
                var (method, path) = ReadRequestHead(stream);
                var (status, body, contentType) = Route(method, path);
                WriteResponse(stream, status, body, contentType);
            }
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Error("localapi", "request failed", ex);
        }
    }

    private static (string Method, string Path) ReadRequestHead(NetworkStream stream)
    {
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: false,
            bufferSize: 4096, leaveOpen: true);
        var requestLine = reader.ReadLine();
        string? line;
        while (!string.IsNullOrEmpty(line = reader.ReadLine()))
        {
            // Discard headers — GET bodies are irrelevant.
        }

        if (string.IsNullOrWhiteSpace(requestLine))
        {
            return ("", "/");
        }

        var parts = requestLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var method = parts.Length > 0 ? parts[0].ToUpperInvariant() : "";
        var rawPath = parts.Length > 1 ? parts[1] : "/";
        var path = rawPath.Split('?', 2)[0];
        if (string.IsNullOrEmpty(path))
        {
            path = "/";
        }

        return (method, path);
    }

    private (int Status, byte[]? Body, string ContentType) Route(string method, string path)
    {
        if (method == "OPTIONS")
        {
            return (204, null, "text/plain");
        }

        switch (path, method)
        {
            case ("/" or "/dashboard", "GET"):
                if (_dashboardHtml is null)
                {
                    return JsonError(404, "not_found");
                }

                return (200, _dashboardHtml, "text/html; charset=utf-8");

            case ("/v1/usage", "GET"):
                return (200, LocalUsageWireMapper.ToUsageJson(_getProviders()), "application/json");

            default:
                if (path.StartsWith("/v1/usage/", StringComparison.Ordinal))
                {
                    var id = path["/v1/usage/".Length..];
                    var provider = _getProviders().FirstOrDefault(p =>
                        string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase));
                    if (provider is null)
                    {
                        return JsonError(404, "provider_not_found");
                    }

                    if (provider.Status != "ok" || provider.MetricLines.Count == 0)
                    {
                        return (204, null, "application/json");
                    }

                    return (200, LocalUsageWireMapper.ToProviderJson(provider), "application/json");
                }

                return JsonError(method == "GET" ? 404 : 405, method == "GET" ? "not_found" : "method_not_allowed");
        }
    }

    private static (int Status, byte[]? Body, string ContentType) JsonError(int status, string code) =>
        (status, Encoding.UTF8.GetBytes($"{{\"error\":\"{code}\"}}"), "application/json");

    private static void WriteResponse(NetworkStream stream, int status, byte[]? body, string contentType)
    {
        var reason = status switch
        {
            200 => "OK",
            204 => "No Content",
            404 => "Not Found",
            405 => "Method Not Allowed",
            500 => "Internal Server Error",
            _ => "OK"
        };

        var head = new StringBuilder();
        head.Append($"HTTP/1.1 {status} {reason}\r\n");
        head.Append("Access-Control-Allow-Origin: *\r\n");
        head.Append("Access-Control-Allow-Methods: GET, OPTIONS\r\n");
        head.Append("Access-Control-Allow-Headers: Content-Type\r\n");
        head.Append("Connection: close\r\n");
        head.Append($"Content-Type: {contentType}\r\n");
        if (body is null || body.Length == 0)
        {
            head.Append("Content-Length: 0\r\n\r\n");
            var headerBytes = Encoding.UTF8.GetBytes(head.ToString());
            stream.Write(headerBytes);
        }
        else
        {
            head.Append($"Content-Length: {body.Length}\r\n\r\n");
            var headerBytes = Encoding.UTF8.GetBytes(head.ToString());
            stream.Write(headerBytes);
            stream.Write(body);
        }

        stream.Flush();
    }

    private static byte[]? LoadDashboardHtml()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var resourceName = assembly.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith("usage-dashboard.html", StringComparison.OrdinalIgnoreCase));
        if (resourceName is null)
        {
            ShellLogger.Instance.Error("localapi", "usage-dashboard.html embedded resource missing",
                new InvalidOperationException("Embedded resource not found"));
            return null;
        }

        using var stream = assembly.GetManifestResourceStream(resourceName);
        if (stream is null)
        {
            return null;
        }

        using var ms = new MemoryStream();
        stream.CopyTo(ms);
        return ms.ToArray();
    }

    private static void TryEnsureFirewallRule()
    {
        const string ruleName = "OpenUsage Local API";
        try
        {
            if (FirewallRuleExists(ruleName))
            {
                return;
            }

            var psi = new ProcessStartInfo
            {
                FileName = "netsh",
                Arguments = $"advfirewall firewall add rule name=\"{ruleName}\" dir=in action=allow protocol=TCP localport={Port}",
                CreateNoWindow = true,
                UseShellExecute = false,
            };
            using var process = Process.Start(psi);
            process?.WaitForExit(5000);
            ShellLogger.Instance.Info("localapi", $"requested Windows Firewall rule for TCP {Port}");
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Info("localapi", $"firewall rule not added: {ex.Message}");
        }
    }

    private static bool FirewallRuleExists(string ruleName)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "netsh",
                Arguments = $"advfirewall firewall show rule name=\"{ruleName}\"",
                RedirectStandardOutput = true,
                CreateNoWindow = true,
                UseShellExecute = false,
            };
            using var process = Process.Start(psi);
            if (process is null)
            {
                return false;
            }

            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(3000);
            return output.Contains(ruleName, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}

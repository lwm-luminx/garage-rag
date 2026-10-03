using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Garage.App.Core.Mcp;

/// <summary>A call to Garage's MCP server failed: no answer, an HTTP error, or a JSON-RPC error.</summary>
public sealed class McpCallException : Exception
{
    /// <summary>Creates the exception.</summary>
    public McpCallException()
    {
    }

    /// <summary>Creates the exception.</summary>
    public McpCallException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception.</summary>
    public McpCallException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>
/// The smallest MCP client Ask Garage needs (windows-ui.md §6, decision 6): <c>initialize</c> and
/// <c>tools/call</c> over streamable HTTP, keeping the session the server hands out, as the Mac's
/// <c>GarageMCPService</c> does. Replies may come as plain JSON or as server-sent events.
/// </summary>
public sealed class McpHttpClient : IDisposable
{
    /// <summary>How long a corpus tool may take.</summary>
    public static readonly TimeSpan ToolCallTimeout = TimeSpan.FromSeconds(10);

    /// <summary>
    /// How long a generating tool (<c>rag_ask</c>, <c>rag_agent</c>) may take: the local model's first
    /// token can be tens of seconds away while it loads.
    /// </summary>
    public static readonly TimeSpan GenerationTimeout = TimeSpan.FromMinutes(5);

    private readonly HttpClient _http;
    private readonly bool _ownsHttp;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private string? _sessionId;
    private int _nextId = 100;

    /// <summary>A client of the server at <paramref name="endpoint"/>; <paramref name="http"/> is for tests.</summary>
    public McpHttpClient(Uri endpoint, HttpClient? http = null)
    {
        Endpoint = endpoint ?? throw new ArgumentNullException(nameof(endpoint));
        _ownsHttp = http is null;
        // Loopback only, never through a proxy: the server is Garage's own.
        _http = http ?? new HttpClient(new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false }) { Timeout = Timeout.InfiniteTimeSpan };
    }

    /// <summary>The server.</summary>
    public Uri Endpoint { get; }

    /// <summary>Opens a session: <c>initialize</c>, then <c>notifications/initialized</c>.</summary>
    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        _sessionId = null;
        await SendAsync(new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = 1,
            ["method"] = "initialize",
            ["params"] = new JsonObject
            {
                ["protocolVersion"] = "2025-06-18",
                ["capabilities"] = new JsonObject(),
                ["clientInfo"] = new JsonObject { ["name"] = "GarageApp", ["version"] = "1.0.0" },
            },
        }, ToolCallTimeout, cancellationToken).ConfigureAwait(false);
        try
        {
            await SendAsync(new JsonObject { ["jsonrpc"] = "2.0", ["method"] = "notifications/initialized" }, ToolCallTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (McpCallException)
        {
            // A server that does not acknowledge the notification still answers calls.
        }
    }

    /// <summary>
    /// Calls <paramref name="tool"/> and returns its text content. A session the server has dropped is
    /// opened again once.
    /// </summary>
    /// <exception cref="McpCallException">The server did not answer, or answered with an error.</exception>
    public async Task<string> CallToolAsync(string tool, IReadOnlyDictionary<string, object?> arguments, TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        await _lock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_sessionId is null)
            {
                await InitializeAsync(cancellationToken).ConfigureAwait(false);
            }
            JsonObject Payload() => new()
            {
                ["jsonrpc"] = "2.0",
                ["id"] = Interlocked.Increment(ref _nextId),
                ["method"] = "tools/call",
                ["params"] = new JsonObject
                {
                    ["name"] = tool,
                    ["arguments"] = JsonSerializer.SerializeToNode(arguments),
                },
            };
            JsonObject response;
            try
            {
                response = await SendAsync(Payload(), timeout ?? ToolCallTimeout, cancellationToken).ConfigureAwait(false);
            }
            catch (McpCallException ex) when (ex.Message.Contains("session", StringComparison.OrdinalIgnoreCase))
            {
                await InitializeAsync(cancellationToken).ConfigureAwait(false);
                response = await SendAsync(Payload(), timeout ?? ToolCallTimeout, cancellationToken).ConfigureAwait(false);
            }
            return ToolText(response);
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>The text of a <c>tools/call</c> response: its text content joined, else the result as JSON.</summary>
    /// <exception cref="McpCallException">The response is a JSON-RPC error.</exception>
    public static string ToolText(JsonObject response)
    {
        ArgumentNullException.ThrowIfNull(response);
        if (response["error"] is JsonObject error)
        {
            throw new McpCallException($"Tool call failed: {error["message"]?.GetValue<string>() ?? "unknown error"}");
        }
        if (response["result"] is JsonObject result)
        {
            if (result["content"] is JsonArray content)
            {
                List<string> texts = [.. content.OfType<JsonObject>().Select(c => c["text"]).OfType<JsonValue>().Select(t => t.GetValue<string>())];
                if (texts.Count > 0)
                {
                    return string.Join('\n', texts);
                }
            }
            return result.ToJsonString();
        }
        return "Tool executed successfully (empty response).";
    }

    /// <summary>The JSON-RPC message in a reply body: plain JSON, or the first <c>data:</c> line of an event stream.</summary>
    public static JsonObject? ParseReply(string body)
    {
        ArgumentNullException.ThrowIfNull(body);
        if (body.Length == 0)
        {
            return [];
        }
        try
        {
            if (JsonNode.Parse(body) is JsonObject json)
            {
                return json;
            }
        }
        catch (JsonException)
        {
            // An event stream.
        }
        foreach (string line in body.Split('\n'))
        {
            string trimmed = line.Trim();
            if (!trimmed.StartsWith("data:", StringComparison.Ordinal))
            {
                continue;
            }
            try
            {
                if (JsonNode.Parse(trimmed[5..].Trim()) is JsonObject json)
                {
                    return json;
                }
            }
            catch (JsonException)
            {
                // Not this line.
            }
        }
        return null;
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        _lock.Dispose();
        if (_ownsHttp)
        {
            _http.Dispose();
        }
    }

    private async Task<JsonObject> SendAsync(JsonObject payload, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint)
        {
            Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        if (_sessionId is { Length: > 0 } session)
        {
            request.Headers.Add("Mcp-Session-Id", session);
        }
        HttpResponseMessage response;
        string body;
        try
        {
            response = await _http.SendAsync(request, deadline.Token).ConfigureAwait(false);
            body = await response.Content.ReadAsStringAsync(deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            throw new McpCallException(string.Create(CultureInfo.CurrentCulture, $"Garage's MCP server did not answer within {timeout.TotalSeconds:0} seconds."), ex);
        }
        catch (HttpRequestException ex)
        {
            throw new McpCallException($"Garage's MCP server isn't reachable at {Endpoint}: {ex.Message}", ex);
        }
        using (response)
        {
            if (response.Headers.TryGetValues("Mcp-Session-Id", out IEnumerable<string>? ids) && ids.FirstOrDefault() is { Length: > 0 } id)
            {
                _sessionId = id;
            }
            if (!response.IsSuccessStatusCode)
            {
                if ((int)response.StatusCode is 400 or 404 && body.Contains("session", StringComparison.OrdinalIgnoreCase))
                {
                    _sessionId = null;
                }
                throw new McpCallException(string.Create(CultureInfo.InvariantCulture, $"HTTP {(int)response.StatusCode}: {body}"));
            }
            return ParseReply(body) ?? [];
        }
    }
}

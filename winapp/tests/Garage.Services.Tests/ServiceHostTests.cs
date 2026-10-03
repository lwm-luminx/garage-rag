using Garage;
using Garage.App.Core.Services;
using Garage.Grpc;
using Garage.Grpc.Services;
using Grpc.Core;
using Grpc.Net.Client;

namespace Garage.Services.Tests;

/// <summary>
/// The service processes as the app runs them: started by <see cref="ServiceManager"/>, in its Job
/// Object, over their pipes, with the backend on loopback behind this launch's token.
/// </summary>
public sealed class ServiceHostTests
{
    [Fact]
    public async Task Both_services_start_answer_and_report_their_self_tests()
    {
        string data = ServiceFixture.DataDirectory();
        try
        {
            using var manager = new ServiceManager(ServiceFixture.Layout(data), new SerialDispatcher());
            bool started = await manager.StartAsync(TestContext.Current.CancellationToken);
            Assert.True(started, $"core: {manager.Core.Error}; ingest: {manager.Ingest.Error}\n{Logs(manager)}");
            Assert.Equal(ServiceState.Running, manager.Core.State);
            Assert.Equal(ServiceState.Running, manager.Ingest.State);

            // The backend answers with this launch's token, and refuses without it. (Ping, not GetStatus:
            // the scratch config's database is deliberately unreachable.)
            using GrpcChannel channel = manager.Grpc.OpenChannel();
            await manager.Grpc.CreateClient(channel).PingAsync(new PingRequest(), cancellationToken: TestContext.Current.CancellationToken);
            RpcException refused = await Assert.ThrowsAsync<RpcException>(async () =>
                await new GarageEndpoint(manager.Grpc.Address, null).CreateClient(channel).PingAsync(new PingRequest(), cancellationToken: TestContext.Current.CancellationToken));
            Assert.Equal(StatusCode.Unauthenticated, refused.StatusCode);

            ServiceStatusReport? ingest = await manager.RunSelfTestsAsync(manager.Ingest, TestContext.Current.CancellationToken);
            Assert.NotNull(ingest);
            Dictionary<string, SelfTestResult> tests = ingest.Tests.ToDictionary(t => t.Name);
            Assert.Equal(
                ["Python Runtime", "Standard Library Extensions", "Site Packages", "libpq", "libtesseract", "Service Module", "Database Connection", "gRPC Connection", "Logging"],
                ingest.Tests.Select(t => t.Name));
            foreach (string name in (string[])["Python Runtime", "Standard Library Extensions", "Site Packages", "libpq", "Service Module", "gRPC Connection", "Logging"])
            {
                Assert.True(tests[name].Status == "passed", $"{name}: {tests[name].Summary}\n{tests[name].Details}");
            }
            // The scratch config names a server that isn't there.
            Assert.Equal("failed", tests["Database Connection"].Status);
            Assert.StartsWith("Python 3.14", tests["Python Runtime"].Summary, StringComparison.Ordinal);

            // The service's log reaches the app.
            await WaitUntil(() => manager.Core.Log.Any(l => l.Text.Contains("GarageService listening", StringComparison.Ordinal)));
        }
        finally
        {
            ServiceFixture.Delete(data);
        }
    }

    [Fact]
    public async Task A_restarted_service_comes_back_as_a_new_process()
    {
        string data = ServiceFixture.DataDirectory();
        try
        {
            using var manager = new ServiceManager(ServiceFixture.Layout(data), new SerialDispatcher());
            Assert.True(await manager.StartAsync(TestContext.Current.CancellationToken), Logs(manager));
            int before = manager.Ingest.ProcessId!.Value;

            Assert.True(await manager.RestartAsync(manager.Ingest, TestContext.Current.CancellationToken), Logs(manager));

            Assert.Equal(ServiceState.Running, manager.Ingest.State);
            Assert.NotEqual(before, manager.Ingest.ProcessId);
            Assert.Throws<ArgumentException>(() => System.Diagnostics.Process.GetProcessById(before));

            await manager.StopAsync();
            Assert.All(manager.Services, s => Assert.Equal(ServiceState.Stopped, s.State));
        }
        finally
        {
            ServiceFixture.Delete(data);
        }
    }

    [Fact]
    public async Task The_mcp_http_server_runs_only_while_switched_on()
    {
        string data = ServiceFixture.DataDirectory();
        try
        {
            using var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
            listener.Start();
            int port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
            listener.Stop();
            using var manager = new ServiceManager(ServiceFixture.Layout(data), new SerialDispatcher()) { McpPort = port };
            CancellationToken token = TestContext.Current.CancellationToken;
            Assert.True(await manager.StartAsync(token), Logs(manager));
            Assert.Equal(ServiceState.Stopped, manager.Mcp.State);
            Assert.Null(manager.Mcp.ProcessId);

            Assert.True(await manager.SetMcpEnabledAsync(true, token), $"{manager.Mcp.Error}\n{Logs(manager)}");
            Assert.Equal(ServiceState.Running, manager.Mcp.State);
            Assert.Equal($"http://127.0.0.1:{port}/mcp", manager.McpUrl.ToString());

            // An MCP client's first request: initialize, over streamable HTTP.
            using var http = new HttpClient();
            using var request = new HttpRequestMessage(HttpMethod.Post, manager.McpUrl)
            {
                Content = new StringContent(
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"garage-test","version":"1"}}}""",
                    System.Text.Encoding.UTF8, "application/json"),
            };
            request.Headers.Accept.ParseAdd("application/json");
            request.Headers.Accept.ParseAdd("text/event-stream");
            using HttpResponseMessage response = await http.SendAsync(request, token);
            string body = await response.Content.ReadAsStringAsync(token);
            Assert.True(response.IsSuccessStatusCode, $"{(int)response.StatusCode} {body}");
            Assert.Contains("serverInfo", body, StringComparison.Ordinal);

            ServiceStatusReport? report = await manager.RunSelfTestsAsync(manager.Mcp, token);
            Assert.Equal("passed", report!.Tests.Single(t => t.Name == "HTTP Server").Status);

            Assert.True(await manager.SetMcpEnabledAsync(false, token));
            Assert.Equal(ServiceState.Stopped, manager.Mcp.State);
            await Assert.ThrowsAsync<HttpRequestException>(() => http.GetAsync(manager.McpUrl, token));
        }
        finally
        {
            ServiceFixture.Delete(data);
        }
    }

    [Fact]
    public async Task Ingest_reads_a_folder_into_the_database_through_the_backend()
    {
        string server = ServiceFixture.DatabaseServer();
        string name = "garage_test_" + Guid.NewGuid().ToString("N")[..10];
        string admin = server.Replace("postgresql+psycopg://", "postgresql://", StringComparison.Ordinal);
        ServiceFixture.RunPython($"import psycopg; c = psycopg.connect({Py(admin)}, autocommit=True); c.execute('CREATE DATABASE {name}')");
        string url = new UriBuilder(admin) { Path = "/" + name }.Uri.ToString().Replace("postgresql://", "postgresql+psycopg://", StringComparison.Ordinal);
        string data = ServiceFixture.DataDirectory(url);
        string notes = Path.Combine(data, "notes");
        Directory.CreateDirectory(notes);
        File.WriteAllText(Path.Combine(notes, "garage.md"), "# The garage\n\nThe workbench is on the north wall, under the pegboard.\n");
        File.WriteAllText(Path.Combine(notes, "car.md"), "# The car\n\nThe oil was changed in March; the next change is due at 60,000 miles.\n");
        try
        {
            using var manager = new ServiceManager(ServiceFixture.Layout(data), new SerialDispatcher());
            Assert.True(await manager.StartAsync(TestContext.Current.CancellationToken), Logs(manager));
            using GrpcChannel channel = manager.Grpc.OpenChannel();
            GarageService.GarageServiceClient garage = manager.Grpc.CreateClient(channel);
            CancellationToken token = TestContext.Current.CancellationToken;

            await garage.InitDbAsync(new InitDbRequest(), cancellationToken: token);
            await garage.AddSourceAsync(new AddSourceRequest { Slug = "notes", Root = notes }, cancellationToken: token);

            List<IngestProgress> updates = [];
            using (AsyncServerStreamingCall<IngestProgress> call = manager.Ingest.Ingest!.IngestSource(new IngestSourceRequest { Source = "notes" }, cancellationToken: token))
            {
                await foreach (IngestProgress progress in call.ResponseStream.ReadAllAsync(token))
                {
                    updates.Add(progress);
                }
            }

            Assert.Contains(updates, u => u.Phase == "scan" && u.Source == "notes");
            IngestProgress last = updates[^1];
            Assert.Equal("complete", last.Phase);
            Assert.Equal(2, last.Indexed);
            ListDocumentsResponse documents = await garage.ListDocumentsAsync(new ListDocumentsRequest { Source = "notes" }, cancellationToken: token);
            Assert.Equal(2, documents.TotalCount);
            Assert.Contains(manager.Ingest.Log, l => l.Text.Contains("Ingest of notes finished", StringComparison.Ordinal));

            // A second run finds nothing new: the stat check skips both files.
            using (AsyncServerStreamingCall<IngestProgress> again = manager.Ingest.Ingest.IngestSource(new IngestSourceRequest { Source = "notes" }, cancellationToken: token))
            {
                IngestProgress? final = null;
                await foreach (IngestProgress progress in again.ResponseStream.ReadAllAsync(token))
                {
                    final = progress;
                }
                Assert.Equal((0L, 2L), (final!.Indexed, final.Skipped));
            }
            await manager.StopAsync();
        }
        finally
        {
            ServiceFixture.RunPython($"import psycopg; c = psycopg.connect({Py(admin)}, autocommit=True); c.execute('DROP DATABASE IF EXISTS {name} WITH (FORCE)')");
            ServiceFixture.Delete(data);
        }
    }

    private static string Py(string value) => "'" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("'", "\\'", StringComparison.Ordinal) + "'";

    private static string Logs(ServiceManager manager) =>
        string.Join('\n', manager.Services.SelectMany(s => s.Log.Select(l => $"[{s.Id}] {l.Text}")).TakeLast(60));

    private static async Task WaitUntil(Func<bool> condition)
    {
        for (int i = 0; i < 40 && !condition(); i++)
        {
            await Task.Delay(100, TestContext.Current.CancellationToken);
        }
        Assert.True(condition());
    }
}

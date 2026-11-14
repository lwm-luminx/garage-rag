using Garage.App.Core.Presentation;
using Garage.App.Core.Services;

namespace Garage.App.Core.Tests;

// The Status page's service problems: the Mac's StatusHealth.ServiceIssue (StatusPagePresentationTests.swift).
public sealed class ServiceIssuesTests
{
    private static ServiceRowPresentation Row(string id, ServiceState state, bool error = false, string detail = "detail") =>
        new(id, ServiceRowPresentation.NameFor(id), state, detail, error);

    [Fact]
    public void Healthy_and_passing_rows_are_no_issue()
    {
        Assert.Empty(ServiceIssues.From(
        [
            Row("core", ServiceState.Running),
            Row("ingest", ServiceState.Checking),
            Row("embed", ServiceState.Restarting),
            Row("mcp", ServiceState.Stopped),
            Row("llama", ServiceState.Unknown),
        ]));
    }

    [Fact]
    public void An_unreachable_service_is_an_error_and_a_failing_one_a_warning()
    {
        IReadOnlyList<ServiceIssue> failing = ServiceIssues.From([Row("embed", ServiceState.Running, error: true, detail: "Running · 1 failed")]);
        Assert.Equal([new ServiceIssue("embed", "Embeddings", "Running · 1 failed", false)], failing);
        Assert.Equal(StatusSeverity.Warning, ServiceIssues.Severity(failing));
        Assert.Equal("Embeddings fails its self tests", ServiceIssues.Title(failing));
        Assert.Equal("Running · 1 failed", ServiceIssues.Message(failing));

        IReadOnlyList<ServiceIssue> both = ServiceIssues.From(
        [
            Row("ingest", ServiceState.Unreachable, error: true, detail: "Can't be reached: no reply"),
            Row("embed", ServiceState.Running, error: true, detail: "Running · 1 failed"),
        ]);
        Assert.Equal(StatusSeverity.Error, ServiceIssues.Severity(both));
        Assert.Equal("2 services need attention", ServiceIssues.Title(both));
        Assert.Equal("Ingest: Can't be reached: no reply\nEmbeddings: Running · 1 failed", ServiceIssues.Message(both));
        Assert.Equal("Ingest can't be reached", ServiceIssues.Title([both[0]]));
    }

    [Fact]
    public void A_database_that_is_down_stands_for_the_failures_it_causes()
    {
        IReadOnlyList<ServiceIssue> issues = ServiceIssues.From(
        [
            Row("postgres", ServiceState.Unreachable, error: true),
            Row("core", ServiceState.Running, error: true),
            Row("ingest", ServiceState.Unreachable, error: true),
        ]);
        Assert.Equal(["postgres"], issues.Select(i => i.Id));
    }
}

using Garage.App.Core.Operations;
using Grpc.Core;

namespace Garage.App.Core.Tests;

public sealed class OperationRunnerTests
{
    [Fact]
    public async Task Logs_each_line_of_the_output()
    {
        var runner = new OperationRunner("sources");
        OperationResult result = await runner.RunAsync((_, _) => Task.FromResult("added notes\r\n\nscanned 3 files\n"));

        Assert.True(result.Succeeded);
        Assert.Equal(["added notes", "scanned 3 files"], runner.Logs.Select(l => l.Text));
        Assert.All(runner.Logs, l => Assert.Equal("sources", l.Source));
        Assert.False(runner.IsRunning);
    }

    [Fact]
    public async Task Refuses_a_second_operation_while_one_runs()
    {
        var runner = new OperationRunner("garage");
        var release = new TaskCompletionSource<string>();
        Task<OperationResult> first = runner.RunAsync((_, _) => release.Task);
        Assert.True(runner.IsRunning);

        OperationResult second = await runner.RunAsync((_, _) => Task.FromResult("never"));
        Assert.False(second.Succeeded);
        Assert.Equal("garage is already running", second.Output);
        Assert.Equal(LogChannel.Stderr, runner.Logs[^1].Channel);

        release.SetResult("done");
        Assert.True((await first).Succeeded);
        Assert.False(runner.IsRunning);
    }

    [Fact]
    public async Task Cancel_stops_the_operation_and_says_so()
    {
        var runner = new OperationRunner("backfill");
        Task<OperationResult> run = runner.RunAsync(async (_, token) =>
        {
            await Task.Delay(Timeout.Infinite, token);
            return "unreachable";
        });

        runner.Cancel();
        OperationResult result = await run;

        Assert.False(result.Succeeded);
        Assert.Equal("backfill cancelled", result.Output);
        Assert.Equal(["Cancelling backfill...", "backfill cancelled"], runner.Logs.Select(l => l.Text));
    }

    [Fact]
    public async Task A_cancelled_grpc_call_counts_as_cancelled()
    {
        var runner = new OperationRunner("backfill");
        OperationResult result = await runner.RunAsync((_, _) =>
            Task.FromException<string>(new RpcException(new Status(StatusCode.Cancelled, "call cancelled"))));
        Assert.Equal("backfill cancelled", result.Output);
    }

    [Fact]
    public async Task A_failure_is_logged_and_returned()
    {
        var runner = new OperationRunner("models");
        OperationResult result = await runner.RunAsync((_, _) => Task.FromException<string>(new InvalidOperationException("no such model: bge-m3")));
        Assert.False(result.Succeeded);
        Assert.Equal("no such model: bge-m3", result.Output);
        Assert.Equal(LogChannel.Stderr, runner.Logs.Single().Channel);
        Assert.False(runner.IsRunning);
    }

    [Fact]
    public void The_log_keeps_only_the_newest_lines()
    {
        var runner = new OperationRunner();
        for (int i = 0; i < OperationRunner.MaxLogLines + 25; i++)
        {
            runner.AppendLog($"line {i}");
        }
        // Line 4001 took the log past 4000, which trimmed it to 3000 (the oldest 1001 went); 24 more followed.
        Assert.Equal(3024, runner.Logs.Count);
        Assert.Equal("line 1001", runner.Logs[0].Text);
        runner.ClearLogs();
        Assert.Empty(runner.Logs);
    }

    [Fact]
    public void Cancel_when_idle_does_nothing()
    {
        var runner = new OperationRunner();
        runner.Cancel();
        Assert.Empty(runner.Logs);
    }
}

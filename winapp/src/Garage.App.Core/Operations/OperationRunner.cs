using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Logging;

namespace Garage.App.Core.Operations;

/// <summary>Which output a log line came from: the Mac's <c>LogLine.Stream</c>.</summary>
public enum LogChannel
{
    /// <summary>Ordinary output.</summary>
    Stdout,

    /// <summary>Errors, refusals and cancellations.</summary>
    Stderr,
}

/// <summary>
/// One line in a rolling log. <see cref="Level"/> is inferred from the text (<see cref="LogLevels.Infer"/>)
/// unless set: <c>line with { Level = LogLevel.Warning }</c>.
/// </summary>
public sealed record LogLine(LogChannel Channel, string Text, string Source, DateTimeOffset Timestamp)
{
    /// <summary>The line's severity.</summary>
    public LogLevel Level { get; init; } = LogLevels.Infer(Channel, Text);

    /// <summary>The level's name, for display ("Warning").</summary>
    public string LevelName => Level.Name();

    /// <summary>The time of day, to the millisecond, as the Mac's table shows it.</summary>
    public string Time => Timestamp.ToString("HH:mm:ss.fff", System.Globalization.CultureInfo.InvariantCulture);
}

/// <summary>The outcome of one <see cref="OperationRunner.RunAsync"/> call.</summary>
/// <param name="Succeeded">Whether the operation finished without error or cancellation.</param>
/// <param name="Output">What the operation reported on success, or the error message on failure.</param>
public sealed record OperationResult(bool Succeeded, string Output);

/// <summary>
/// Runs one category of app operations (ordinary commands, backfill, fact distillation) one at a
/// time, with its own busy flag and rolling log: a port of the Mac app's <c>OperationRunner</c>.
/// Each category keeps its own runner, so a long backfill never blocks an ordinary command.
/// </summary>
/// <remarks>Call from the UI thread; bound properties change on the calling thread.</remarks>
public sealed partial class OperationRunner(string label = "garage") : ObservableObject
{
    /// <summary>Lines kept before the oldest are trimmed (the Mac keeps as many; see <see cref="LogBuffer"/>).</summary>
    public const int MaxLogLines = LogBuffer.DefaultLimit;

    private CancellationTokenSource? _current;

    /// <summary>Whether an operation is running.</summary>
    [ObservableProperty]
    public partial bool IsRunning { get; private set; }

    /// <summary>The name this runner's log lines carry.</summary>
    public string Label { get; } = label;

    /// <summary>The rolling log, oldest first.</summary>
    public LogBuffer Logs { get; } = new(label, MaxLogLines);

    /// <summary>Appends a line, trimming the oldest past <see cref="MaxLogLines"/>.</summary>
    public void AppendLog(string text, LogChannel channel = LogChannel.Stdout) => Logs.Append(text, channel);

    /// <summary>Empties the log.</summary>
    public void ClearLogs() => Logs.Clear();

    /// <summary>
    /// Cancels the running operation. Cancelling a streaming call ends it on the server too,
    /// which stops the work at its next progress step.
    /// </summary>
    public void Cancel()
    {
        if (!IsRunning || _current is null)
        {
            return;
        }
        AppendLog($"Cancelling {Label}...", LogChannel.Stderr);
        _current.Cancel();
    }

    /// <summary>
    /// Runs <paramref name="operation"/>, logging the text it returns (or its error), and completes
    /// once it finishes. Streaming operations log their own progress through the runner they are
    /// handed. Refuses to start while another operation is running.
    /// </summary>
    public async Task<OperationResult> RunAsync(Func<OperationRunner, CancellationToken, Task<string>> operation)
    {
        ArgumentNullException.ThrowIfNull(operation);
        if (IsRunning)
        {
            string refusal = $"{Label} is already running";
            AppendLog(refusal, LogChannel.Stderr);
            return new OperationResult(false, refusal);
        }

        IsRunning = true;
        using var cancellation = new CancellationTokenSource();
        _current = cancellation;
        try
        {
            string output = await operation(this, cancellation.Token).ConfigureAwait(true);
            foreach (string line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                AppendLog(line.TrimEnd('\r'));
            }
            return new OperationResult(true, output);
        }
        catch (Exception ex) when (ex is OperationCanceledException || IsCancellation(ex) || cancellation.IsCancellationRequested)
        {
            string message = $"{Label} cancelled";
            AppendLog(message, LogChannel.Stderr);
            return new OperationResult(false, message);
        }
#pragma warning disable CA1031 // Every failure becomes a logged result, as on the Mac.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            AppendLog(ex.Message, LogChannel.Stderr);
            return new OperationResult(false, ex.Message);
        }
        finally
        {
            _current = null;
            IsRunning = false;
        }
    }

    // A cancelled gRPC call surfaces as RpcException(StatusCode.Cancelled).
    private static bool IsCancellation(Exception ex) =>
        ex is global::Grpc.Core.RpcException { StatusCode: global::Grpc.Core.StatusCode.Cancelled };
}

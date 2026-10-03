using System.Globalization;
using System.Text;
using System.Threading.Channels;
using Garage.Grpc.Services;

namespace Garage.Services;

/// <summary>
/// A service's log: the ring buffer <c>FetchLogs</c> reads, the live subscribers of
/// <c>SubscribeToLogStream</c>, and a file under the data folder's <c>logs</c>. The counterpart of
/// <c>GarageXPCOutputCapture</c> and the Mac services' file logger.
/// </summary>
internal sealed class ServiceLog : IDisposable
{
    /// <summary>Entries the ring buffer keeps.</summary>
    public const int Capacity = 2000;

    /// <summary>A log file is started afresh beyond this size, keeping one previous file.</summary>
    public const long MaxFileBytes = 8 * 1024 * 1024;

    private readonly Lock _lock = new();
    private readonly Queue<LogEntry> _entries = new();
    private readonly List<Channel<LogEntry>> _subscribers = [];
    private readonly string? _filePath;
    private StreamWriter? _file;

    /// <summary>Creates the log; <paramref name="filePath"/> null keeps it in memory only.</summary>
    public ServiceLog(string source, string? filePath)
    {
        Source = source;
        _filePath = filePath;
        if (filePath is not null)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(filePath)!);
                OpenFile();
            }
            catch (IOException)
            {
                _filePath = null;
            }
            catch (UnauthorizedAccessException)
            {
                _filePath = null;
            }
        }
    }

    /// <summary>The name entries from this process carry.</summary>
    public string Source { get; }

    /// <summary>Whether the log file could be opened.</summary>
    public bool HasFile => _file is not null;

    /// <summary>The log file, when there is one.</summary>
    public string? FilePath => _filePath;

    /// <summary>Records one message (Python's levels: 10 debug … 50 critical).</summary>
    public void Append(int level, string message, string? source = null)
    {
        var entry = new LogEntry
        {
            TimeMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            Level = level,
            Source = source ?? Source,
            Message = message,
        };
        lock (_lock)
        {
            _entries.Enqueue(entry);
            while (_entries.Count > Capacity)
            {
                _entries.Dequeue();
            }
            foreach (Channel<LogEntry> subscriber in _subscribers)
            {
                // A subscriber that falls behind loses its oldest entries (the channel drops them).
                subscriber.Writer.TryWrite(entry);
            }
            WriteFile(entry);
        }
    }

    /// <summary>Informational message.</summary>
    public void Info(string message) => Append(20, message);

    /// <summary>Warning.</summary>
    public void Warning(string message) => Append(30, message);

    /// <summary>Error.</summary>
    public void Error(string message) => Append(40, message);

    /// <summary>The newest <paramref name="limit"/> entries, oldest first.</summary>
    public IReadOnlyList<LogEntry> Recent(int limit)
    {
        lock (_lock)
        {
            int skip = limit > 0 ? Math.Max(0, _entries.Count - limit) : 0;
            return [.. _entries.Skip(skip)];
        }
    }

    /// <summary>A reader of every entry from now on; dispose the subscription to stop.</summary>
    public Subscription Subscribe()
    {
        var channel = Channel.CreateBounded<LogEntry>(new BoundedChannelOptions(Capacity)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
        });
        lock (_lock)
        {
            _subscribers.Add(channel);
        }
        return new Subscription(this, channel);
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        lock (_lock)
        {
            foreach (Channel<LogEntry> subscriber in _subscribers)
            {
                subscriber.Writer.TryComplete();
            }
            _subscribers.Clear();
            _file?.Dispose();
            _file = null;
        }
    }

    private void Unsubscribe(Channel<LogEntry> channel)
    {
        lock (_lock)
        {
            _subscribers.Remove(channel);
        }
        channel.Writer.TryComplete();
    }

    private void OpenFile()
    {
        var stream = new FileStream(_filePath!, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        _file = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true };
    }

    private void WriteFile(LogEntry entry)
    {
        if (_file is null)
        {
            return;
        }
        try
        {
            if (_file.BaseStream.Length > MaxFileBytes)
            {
                _file.Dispose();
                File.Move(_filePath!, _filePath + ".1", overwrite: true);
                OpenFile();
            }
            string time = DateTimeOffset.FromUnixTimeMilliseconds(entry.TimeMs).ToLocalTime()
                .ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture);
            _file!.WriteLine($"{time} {LevelName(entry.Level),-7} [{entry.Source}] {entry.Message}");
        }
        catch (IOException)
        {
            // A full disk or a locked file must never take the service down with it.
        }
    }

    /// <summary>"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL", as Python names them.</summary>
    public static string LevelName(int level) => level switch
    {
        <= 10 => "DEBUG",
        <= 20 => "INFO",
        <= 30 => "WARNING",
        <= 40 => "ERROR",
        _ => "CRITICAL",
    };

    /// <summary>One live reader of the log.</summary>
    public sealed class Subscription(ServiceLog log, Channel<LogEntry> channel) : IDisposable
    {
        /// <summary>The entries, as they are appended.</summary>
        public ChannelReader<LogEntry> Reader => channel.Reader;

        /// <inheritdoc/>
        public void Dispose() => log.Unsubscribe(channel);
    }
}

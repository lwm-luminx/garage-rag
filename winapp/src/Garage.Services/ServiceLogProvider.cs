using Microsoft.Extensions.Logging;

namespace Garage.Services;

/// <summary>Routes ASP.NET Core's own warnings and errors (Kestrel, gRPC) into the <see cref="ServiceLog"/>.</summary>
internal sealed class ServiceLogProvider(ServiceLog log) : ILoggerProvider
{
    public ILogger CreateLogger(string categoryName) => new Logger(log, categoryName);

    public void Dispose()
    {
    }

    private sealed class Logger(ServiceLog log, string category) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Warning;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            ArgumentNullException.ThrowIfNull(formatter);
            if (!IsEnabled(logLevel))
            {
                return;
            }
            string message = formatter(state, exception);
            if (exception is not null)
            {
                message += $": {exception.Message}";
            }
            log.Append(logLevel >= LogLevel.Error ? 40 : 30, message, category);
        }
    }
}

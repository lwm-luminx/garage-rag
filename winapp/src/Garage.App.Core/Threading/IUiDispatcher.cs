namespace Garage.App.Core.Threading;

/// <summary>
/// Runs work on the UI thread, where bound properties must change: a <c>DispatcherQueue</c> in the
/// app, an inline dispatcher in tests. The counterpart of the Mac app's main-actor rule.
/// </summary>
public interface IUiDispatcher
{
    /// <summary>Whether the caller is already on the UI thread.</summary>
    bool HasThreadAccess { get; }

    /// <summary>Queues <paramref name="action"/> to run on the UI thread.</summary>
    void Post(Action action);
}

/// <summary>Runs everything at once on the calling thread: for tests and for code with no UI.</summary>
public sealed class InlineDispatcher : IUiDispatcher
{
    /// <summary>The shared instance.</summary>
    public static InlineDispatcher Instance { get; } = new();

    /// <inheritdoc/>
    public bool HasThreadAccess => true;

    /// <inheritdoc/>
    public void Post(Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        action();
    }
}

/// <summary>Helpers over <see cref="IUiDispatcher"/>.</summary>
public static class UiDispatcherExtensions
{
    /// <summary>Runs <paramref name="action"/> now when on the UI thread, else queues it there.</summary>
    public static void Run(this IUiDispatcher dispatcher, Action action)
    {
        ArgumentNullException.ThrowIfNull(dispatcher);
        ArgumentNullException.ThrowIfNull(action);
        if (dispatcher.HasThreadAccess)
        {
            action();
        }
        else
        {
            dispatcher.Post(action);
        }
    }
}

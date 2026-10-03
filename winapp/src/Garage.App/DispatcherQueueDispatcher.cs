using Garage.App.Core.Threading;
using Microsoft.UI.Dispatching;

namespace Garage.App;

/// <summary>The UI thread's <see cref="DispatcherQueue"/> as Core's <see cref="IUiDispatcher"/>.</summary>
internal sealed class DispatcherQueueDispatcher(DispatcherQueue queue) : IUiDispatcher
{
    public bool HasThreadAccess => queue.HasThreadAccess;

    public void Post(Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        if (!queue.TryEnqueue(() => action()))
        {
            throw new InvalidOperationException("the UI thread's dispatcher queue is shutting down");
        }
    }
}

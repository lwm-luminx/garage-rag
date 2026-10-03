using Garage.Python.Native;

namespace Garage.Python;

/// <summary>
/// Holds the GIL (on a free-threaded build: an attached thread state) until disposed. Obtain one
/// with <see cref="Python.Gil"/>; scopes nest, so a thread that already holds the GIL may take
/// another.
/// </summary>
/// <remarks>
/// A <c>ref struct</c>, so it cannot cross an <c>await</c> or be captured by a lambda: the GIL
/// belongs to the thread that took it. <see cref="PythonObject"/> operations take the GIL
/// themselves; hold a scope explicitly to make several calls atomic with respect to other
/// threads, or to keep the cost of re-entering down in a loop.
/// </remarks>
public ref struct GilScope
{
    private readonly int _state;
    private bool _held;

    internal GilScope(int state)
    {
        _state = state;
        _held = true;
    }

    /// <summary>Releases this scope's hold on the GIL.</summary>
    public void Dispose()
    {
        if (_held)
        {
            _held = false;
            CPython.PyGILState_Release(_state);
        }
    }
}

/// <summary>
/// Releases the GIL held by the current thread until disposed, so Python threads run while this
/// thread blocks in native or managed code. Obtain one with <see cref="Python.AllowThreads"/>; do
/// not touch Python objects inside it.
/// </summary>
public ref struct AllowThreadsScope
{
    private nint _threadState;

    internal AllowThreadsScope(nint threadState) => _threadState = threadState;

    /// <summary>Takes the GIL back.</summary>
    public void Dispose()
    {
        if (_threadState != 0)
        {
            nint state = _threadState;
            _threadState = 0;
            CPython.PyEval_RestoreThread(state);
        }
    }
}

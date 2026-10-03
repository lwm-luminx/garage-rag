using System.Runtime.InteropServices;
using System.Text;

namespace Garage.Python.Interop;

/// <summary>
/// NUL-terminated UTF-8 strings in native memory, for the C functions a host hands Python through
/// ctypes (<c>garage_rag.inference.bridge.install</c>, <c>garage_rag.xpc.host.install_model_loader</c>).
/// The counterpart of the Swift host's <c>strdup</c>/<c>free</c>: a reply allocated with
/// <see cref="Duplicate"/> is released by the host's own release function with <see cref="Free"/>.
/// </summary>
public static unsafe class NativeUtf8
{
    /// <summary>Copies <paramref name="value"/> into newly allocated native memory; free it with <see cref="Free"/>.</summary>
    public static nint Duplicate(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        int length = Encoding.UTF8.GetByteCount(value);
        byte* buffer = (byte*)NativeMemory.Alloc((nuint)length + 1);
        int written = Encoding.UTF8.GetBytes(value, new Span<byte>(buffer, length));
        buffer[written] = 0;
        return (nint)buffer;
    }

    /// <summary>Releases memory from <see cref="Duplicate"/>. Null is ignored.</summary>
    public static void Free(nint utf8)
    {
        if (utf8 != 0)
        {
            NativeMemory.Free((void*)utf8);
        }
    }

    /// <summary>Reads a NUL-terminated UTF-8 string; null for a null pointer.</summary>
    public static string? Read(nint utf8) => Marshal.PtrToStringUTF8(utf8);

    /// <summary>
    /// Writes <paramref name="value"/> into a caller-owned buffer of <paramref name="capacity"/> bytes,
    /// truncating on a character boundary and always NUL-terminating (like the Swift loader's
    /// message buffer). Returns the bytes written, excluding the terminator.
    /// </summary>
    public static int WriteTruncated(string value, nint buffer, nuint capacity)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (buffer == 0 || capacity == 0)
        {
            return 0;
        }
        Span<byte> destination = new((void*)buffer, (int)Math.Min(capacity - 1, int.MaxValue));
        Encoder encoder = Encoding.UTF8.GetEncoder();
        encoder.Convert(value, destination, flush: true, out _, out int written, out _);
        ((byte*)buffer)[written] = 0;
        return written;
    }
}

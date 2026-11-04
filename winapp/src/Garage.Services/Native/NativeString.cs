using System.Runtime.InteropServices;
using System.Text;

namespace Garage.Services.Native;

/// <summary>
/// NUL-terminated UTF-8 strings in native memory: the requests the Rust libraries take, the results
/// they own (freed with their own <c>*_string_free</c>) and the replies a host hands them (allocated
/// here, freed by the host's <c>release</c>). The counterpart of the Swift hosts' <c>strdup</c>/<c>free</c>.
/// </summary>
internal static unsafe class NativeString
{
    /// <summary>Copies <paramref name="value"/> into native memory; free it with <see cref="Free"/>.</summary>
    public static byte* Duplicate(string value)
    {
        int length = Encoding.UTF8.GetByteCount(value);
        byte* buffer = (byte*)NativeMemory.Alloc((nuint)length + 1);
        int written = Encoding.UTF8.GetBytes(value, new Span<byte>(buffer, length));
        buffer[written] = 0;
        return buffer;
    }

    /// <summary>Releases memory from <see cref="Duplicate"/>. Null is ignored.</summary>
    public static void Free(byte* utf8)
    {
        if (utf8 is not null)
        {
            NativeMemory.Free(utf8);
        }
    }

    /// <summary>Reads a NUL-terminated UTF-8 string; null for a null pointer.</summary>
    public static string? Read(byte* utf8) => Marshal.PtrToStringUTF8((nint)utf8);
}

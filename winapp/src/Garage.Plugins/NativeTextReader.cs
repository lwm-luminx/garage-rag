using System.Runtime.InteropServices;
using System.Text;
using Garage.Plugin.V1;
using Google.Protobuf;

namespace Garage.Plugins;

/// <summary>
/// Garage's text reader (plain text, Markdown, source code), linked in-process from
/// <c>garage_text_ffi</c> (<c>rust/garage-text-ffi</c>, declared in <c>include/garage_text.h</c>).
/// </summary>
/// <remarks>
/// The library is found by the runtime's usual probing for <see cref="LibraryName"/>
/// (<c>garage_text_ffi.dll</c> beside the app); a host that keeps it elsewhere registers a
/// resolver with <see cref="NativeLibrary.SetDllImportResolver"/>. Every call is thread-safe.
/// </remarks>
public sealed class NativeTextReader : IExtractorPlugin
{
    /// <summary>The native library's name, without platform prefix or extension.</summary>
    public const string LibraryName = "garage_text_ffi";

    /// <summary>The <see cref="ContractVersion"/> of the messages the library speaks.</summary>
    public static ContractVersion Contract => (ContractVersion)NativeMethods.ContractVersion();

    /// <inheritdoc />
    public DescribeResponse Describe(DescribeRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        unsafe
        {
            return Call(request.ToByteArray(), DescribeResponse.Parser, &NativeMethods.Describe);
        }
    }

    /// <inheritdoc />
    public ExtractResponse Extract(ExtractRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return ExtractSerialized(request.ToByteArray());
    }

    /// <summary>Extract with a request already serialized, as it arrived over a wire.</summary>
    internal static ExtractResponse ExtractSerialized(byte[] request)
    {
        unsafe
        {
            return Call(request, ExtractResponse.Parser, &NativeMethods.Extract);
        }
    }

    private static unsafe T Call<T>(
        byte[] request,
        MessageParser<T> parser,
        delegate*<byte*, nuint, GarageBuffer*, int> entry)
        where T : IMessage<T>
    {
        GarageBuffer response = default;
        int status;
        fixed (byte* data = request)
        {
            status = entry(data, (nuint)request.Length, &response);
        }
        try
        {
            var span = new ReadOnlySpan<byte>(response.Data, checked((int)response.Length));
            if (status != NativeMethods.StatusOk)
            {
                throw new NativePluginException(status, Encoding.UTF8.GetString(span));
            }
            return parser.ParseFrom(span);
        }
        finally
        {
            NativeMethods.BufferFree(response);
        }
    }
}

/// <summary>A native plugin refused a call: the request did not decode, or the plugin panicked.</summary>
public sealed class NativePluginException : Exception
{
    /// <summary>Creates the exception.</summary>
    public NativePluginException()
    {
    }

    /// <summary>Creates the exception with a message.</summary>
    public NativePluginException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with a message and its cause.</summary>
    public NativePluginException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    internal NativePluginException(int status, string message)
        : base(message)
    {
        Status = status;
    }

    /// <summary>The library's status: 1 for a request that did not decode, 2 for a panic.</summary>
    public int Status { get; }
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct GarageBuffer
{
    public byte* Data;
    public nuint Length;
}

internal static unsafe partial class NativeMethods
{
    internal const int StatusOk = 0;

    [LibraryImport(NativeTextReader.LibraryName, EntryPoint = "garage_text_contract_version")]
    internal static partial uint ContractVersion();

    [LibraryImport(NativeTextReader.LibraryName, EntryPoint = "garage_text_describe")]
    internal static partial int Describe(byte* request, nuint requestLength, GarageBuffer* response);

    [LibraryImport(NativeTextReader.LibraryName, EntryPoint = "garage_text_extract")]
    internal static partial int Extract(byte* request, nuint requestLength, GarageBuffer* response);

    [LibraryImport(NativeTextReader.LibraryName, EntryPoint = "garage_text_buffer_free")]
    internal static partial void BufferFree(GarageBuffer buffer);
}

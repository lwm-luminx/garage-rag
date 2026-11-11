using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Garage.Services.Native;

/// <summary>
/// The Rust libraries the services run (<c>rust/garage-service-ffi</c>, <c>rust/garage-ingest-ffi</c>,
/// <c>rust/garage-mcp-ffi</c>), through the C ABIs their <c>include/*.h</c> declare. Each takes a
/// UTF-8 JSON request and returns a JSON result the library owns; a status other than 0 means the
/// result is <c>{"error": "..."}</c> (or the reason as plain text).
/// </summary>
/// <remarks>
/// The DLLs are found by the runtime's usual probing (beside <c>Garage.Services.exe</c>), or in
/// the folder <see cref="UseDirectory"/> names (<c>GARAGE_NATIVE_DIR</c>: a checkout's
/// <c>rust\target\release</c> during development).
/// </remarks>
internal static unsafe partial class GarageNative
{
    /// <summary>The backend's library (<c>garage_service_ffi.dll</c>).</summary>
    public const string ServiceLibrary = "garage_service_ffi";

    /// <summary>The ingest library (<c>garage_ingest_ffi.dll</c>).</summary>
    public const string IngestLibrary = "garage_ingest_ffi";

    /// <summary>The MCP server's library (<c>garage_mcp_ffi.dll</c>).</summary>
    public const string McpLibrary = "garage_mcp_ffi";

    /// <summary>Every library, for the self test that loads them.</summary>
    public static readonly string[] Libraries = [ServiceLibrary, IngestLibrary, McpLibrary];

    private static string? _directory;

    /// <summary>
    /// Resolves the libraries from <paramref name="directory"/> first, when it is set, then as the
    /// runtime would. Called once, before the first native call.
    /// </summary>
    public static void UseDirectory(string? directory)
    {
        _directory = string.IsNullOrEmpty(directory) ? null : directory;
        NativeLibrary.SetDllImportResolver(typeof(GarageNative).Assembly, Resolve);
    }

    /// <summary>Loads <paramref name="library"/> as a native call would, to check it is there.</summary>
    /// <remarks>
    /// <c>NativeLibrary.Load(name, assembly, searchPath)</c> never asks the import resolver (only a
    /// <c>LibraryImport</c> does), so the folder is tried here first, as the resolver would. Before this,
    /// a library no call had loaded yet failed here with "module not found".
    /// </remarks>
    public static string Load(string library)
    {
        if (_directory is { } dir && File.Exists(Path.Combine(dir, library + ".dll")))
        {
            string path = Path.Combine(dir, library + ".dll");
            _ = NativeLibrary.Load(path);
            return path;
        }
        _ = NativeLibrary.Load(library, typeof(GarageNative).Assembly, null);
        return library + ".dll";
    }

    private static nint Resolve(string name, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (_directory is { } dir && Array.IndexOf(Libraries, name) >= 0)
        {
            string path = Path.Combine(dir, name + ".dll");
            if (File.Exists(path))
            {
                return NativeLibrary.Load(path);
            }
        }
        return nint.Zero;
    }

    // --- garage_service.h

    /// <summary>The process GarageService runs in (<c>GarageServiceHost</c>).</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct ServiceHost
    {
        public void* Context;
        public delegate* unmanaged[Cdecl]<void*, byte*, byte**, int> Http;
        public delegate* unmanaged[Cdecl]<void*, byte*, byte**, int> EnsureLlamaModel;
        public delegate* unmanaged[Cdecl]<void*, byte*, byte**, int> EmbedImages;
        public delegate* unmanaged[Cdecl]<void*, byte*, byte**, int> EmbedImageTexts;
        public delegate* unmanaged[Cdecl]<void*, byte*, void> Release;
    }

    [LibraryImport(ServiceLibrary, EntryPoint = "garage_service_start")]
    public static partial int ServiceStart(byte* request, ServiceHost* host, nint* server, byte** result);

    [LibraryImport(ServiceLibrary, EntryPoint = "garage_service_is_running")]
    [return: MarshalAs(UnmanagedType.U1)]
    public static partial bool ServiceIsRunning(nint server);

    [LibraryImport(ServiceLibrary, EntryPoint = "garage_service_stop")]
    public static partial void ServiceStop(nint server, double graceSeconds);

    [LibraryImport(ServiceLibrary, EntryPoint = "garage_service_probe")]
    public static partial int ServiceProbe(byte* request, byte** result);

    [LibraryImport(ServiceLibrary, EntryPoint = "garage_service_version")]
    public static partial byte* ServiceVersionRaw();

    [LibraryImport(ServiceLibrary, EntryPoint = "garage_service_string_free")]
    public static partial void ServiceStringFree(byte* text);

    /// <summary>The backend's version, as <c>GetVersion</c> reports it.</summary>
    public static string ServiceVersion() => NativeString.Read(ServiceVersionRaw()) ?? "";

    // --- garage_ingest.h

    /// <summary>The process an ingest reads files in (<c>GarageIngestHost</c>).</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct IngestHost
    {
        public void* Context;
        public delegate* unmanaged[Cdecl]<void*, byte*, byte**, int> Read;
        public delegate* unmanaged[Cdecl]<void*, byte*, void> Release;
        public delegate* unmanaged[Cdecl]<void*, byte*, void> Progress;
        public delegate* unmanaged[Cdecl]<void*, byte> Cancelled;
        public delegate* unmanaged[Cdecl]<void*, byte*, byte**, int> SharedNames;
        /// <summary>A Dropbox source's HTTPS requests; null here, so a Dropbox source fails as unavailable.</summary>
        public delegate* unmanaged[Cdecl]<void*, byte*, byte**, int> Http;
        /// <summary>A Dropbox source's access token; null here, for the same reason.</summary>
        public delegate* unmanaged[Cdecl]<void*, byte*, byte**, int> AccessToken;
    }

    [LibraryImport(IngestLibrary, EntryPoint = "garage_ingest_run")]
    public static partial int IngestRun(byte* request, IngestHost* host, byte** result);

    [LibraryImport(IngestLibrary, EntryPoint = "garage_ingest_string_free")]
    public static partial void IngestStringFree(byte* text);

    // --- garage_mcp.h

    /// <summary>The process the MCP server runs in (<c>GarageMcpHost</c>).</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct McpHost
    {
        public void* Context;
        public delegate* unmanaged[Cdecl]<void*, byte*, byte**, int> Http;
        public delegate* unmanaged[Cdecl]<void*, byte*, byte**, int> EnsureLlamaModel;
        public delegate* unmanaged[Cdecl]<void*, byte*, void> Release;
    }

    [LibraryImport(McpLibrary, EntryPoint = "garage_mcp_http_start")]
    public static partial int McpHttpStart(byte* request, McpHost* host, nint* server, byte** result);

    [LibraryImport(McpLibrary, EntryPoint = "garage_mcp_http_is_running")]
    [return: MarshalAs(UnmanagedType.U1)]
    public static partial bool McpHttpIsRunning(nint server);

    [LibraryImport(McpLibrary, EntryPoint = "garage_mcp_http_stop")]
    public static partial void McpHttpStop(nint server);

    [LibraryImport(McpLibrary, EntryPoint = "garage_mcp_string_free")]
    public static partial void McpStringFree(byte* text);

    // --- Results

    /// <summary>
    /// Reads a result a library wrote and frees it with <paramref name="free"/>. When <paramref name="status"/>
    /// is not 0, throws <see cref="NativeCallException"/> with the result's <c>error</c> (or its text).
    /// </summary>
    public static JsonObject TakeResult(int status, byte* result, delegate*<byte*, void> free, string what)
    {
        string text;
        try
        {
            text = NativeString.Read(result) ?? "";
        }
        finally
        {
            if (result is not null)
            {
                free(result);
            }
        }
        JsonObject? parsed = null;
        if (text.StartsWith('{'))
        {
            try
            {
                parsed = JsonNode.Parse(text) as JsonObject;
            }
            catch (JsonException)
            {
                parsed = null;
            }
        }
        if (status != 0)
        {
            string reason = parsed?["error"]?.GetValue<string>() ?? (text.Length > 0 ? text : $"status {status}");
            throw new NativeCallException(status, $"{what}: {reason}");
        }
        return parsed ?? new JsonObject();
    }

    /// <summary>A request's JSON, written into native memory for the call; free it with <see cref="NativeString.Free"/>.</summary>
    public static byte* Request(JsonObject request) => NativeString.Duplicate(request.ToJsonString());
}

/// <summary>A Rust library refused a call or failed: the status and its reason.</summary>
internal sealed class NativeCallException(int status, string message) : Exception(message)
{
    /// <summary>The library's status code (1 bad request, 2 panic, 3 failed).</summary>
    public int Status { get; } = status;
}

using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.AspNetCore.Connections;
using Microsoft.AspNetCore.Connections.Features;

namespace Garage.Services;

/// <summary>
/// The <c>GarageXPCPeerRequirement</c> analogue (docs/plans/windows.md §2.1). The pipe's ACL already
/// admits only the signed-in user (Kestrel's <c>CurrentUserOnly</c>); this also refuses any process of
/// that user that is not Garage:
/// <list type="bullet">
/// <item>the app that started this service (<c>--parent</c>);</item>
/// <item>or a process whose executable sits in this service's own folder (a sibling service).</item>
/// </list>
/// The packaged build adds the package-family check once the MSIX exists (§6).
/// </summary>
internal sealed partial class PeerCheck(int parentPid, ServiceLog log)
{
    private readonly string _ownDirectory = Path.GetFullPath(AppContext.BaseDirectory).TrimEnd('\\');

    /// <summary>Connection middleware that closes a connection from any other process.</summary>
    public ConnectionDelegate Middleware(ConnectionDelegate next) => async connection =>
    {
        if (connection.Features.Get<IConnectionNamedPipeFeature>()?.NamedPipe is not { } pipe
            || !TryClientProcessId(pipe, out int pid))
        {
            log.Warning("Refused a connection whose client process could not be identified");
            connection.Abort();
            return;
        }
        if (!IsAllowed(pid, out string? image))
        {
            log.Warning($"Refused a connection from process {pid} ({image ?? "unknown executable"})");
            connection.Abort();
            return;
        }
        await next(connection).ConfigureAwait(false);
    };

    /// <summary>Whether process <paramref name="pid"/> may use this service.</summary>
    public bool IsAllowed(int pid, out string? image)
    {
        image = ImagePath(pid);
        if (pid == parentPid)
        {
            return true;
        }
        return image is not null
            && string.Equals(Path.GetDirectoryName(image)?.TrimEnd('\\'), _ownDirectory, StringComparison.OrdinalIgnoreCase);
    }

    private static bool TryClientProcessId(NamedPipeServerStream pipe, out int pid)
    {
        bool ok = GetNamedPipeClientProcessId(pipe.SafePipeHandle, out uint id);
        pid = (int)id;
        return ok;
    }

    private static string? ImagePath(int pid)
    {
        nint process = OpenProcess(ProcessQueryLimitedInformation, false, (uint)pid);
        if (process == 0)
        {
            return null;
        }
        try
        {
            char[] buffer = new char[1024];
            int size = buffer.Length;
            return QueryFullProcessImageName(process, 0, buffer, ref size) ? new string(buffer, 0, size) : null;
        }
        finally
        {
            CloseHandle(process);
        }
    }

    private const uint ProcessQueryLimitedInformation = 0x1000;

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint clientProcessId);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    private static partial nint OpenProcess(uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

    [LibraryImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryFullProcessImageName(nint process, uint flags, [Out] char[] exeName, ref int size);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(nint handle);
}

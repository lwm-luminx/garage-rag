using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace Garage.App.Core.State;

/// <summary>
/// Where the app keeps secrets it generates, such as the Postgres password: the counterpart of the Mac's
/// Keychain item (<c>GaragePostgresEndpoint</c>). Never written to <c>garage.json</c> or a log.
/// </summary>
public interface ISecretStore
{
    /// <summary>The secret stored under <paramref name="name"/>, or null.</summary>
    string? Read(string name);

    /// <summary>Stores <paramref name="value"/> under <paramref name="name"/>, replacing any value there.</summary>
    void Write(string name, string value);

    /// <summary>Removes <paramref name="name"/>; nothing happens when it is not there.</summary>
    void Delete(string name);
}

/// <summary>Secrets in memory only, for tests.</summary>
public sealed class MemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);

    /// <inheritdoc/>
    public string? Read(string name) => _values.GetValueOrDefault(name);

    /// <inheritdoc/>
    public void Write(string name, string value) => _values[name] = value;

    /// <inheritdoc/>
    public void Delete(string name) => _values.Remove(name);
}

/// <summary>
/// Secrets in Windows Credential Manager, as generic credentials of the signed-in user (the store
/// the packaged build's Credential Locker also uses; windows.md §2.5). Each is named
/// <c>Garage/&lt;name&gt;</c>, so they show as Garage's in Credential Manager.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed partial class WindowsCredentialStore(string prefix = "Garage/") : ISecretStore
{
    private const int CredTypeGeneric = 1;
    private const int CredPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    /// <inheritdoc/>
    public string? Read(string name)
    {
        if (!CredRead(prefix + name, CredTypeGeneric, 0, out nint credential))
        {
            int error = Marshal.GetLastPInvokeError();
            return error == ErrorNotFound ? null : throw new Win32Exception(error, $"could not read the credential {prefix}{name}");
        }
        try
        {
            Credential value = Marshal.PtrToStructure<Credential>(credential);
            if (value.CredentialBlobSize == 0)
            {
                return "";
            }
            byte[] blob = new byte[value.CredentialBlobSize];
            Marshal.Copy(value.CredentialBlob, blob, 0, blob.Length);
            return Encoding.Unicode.GetString(blob);
        }
        finally
        {
            CredFree(credential);
        }
    }

    /// <inheritdoc/>
    public void Write(string name, string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        byte[] blob = Encoding.Unicode.GetBytes(value);
        nint target = Marshal.StringToCoTaskMemUni(prefix + name);
        nint user = Marshal.StringToCoTaskMemUni(Environment.UserName);
        nint data = Marshal.AllocCoTaskMem(Math.Max(1, blob.Length));
        try
        {
            Marshal.Copy(blob, 0, data, blob.Length);
            var credential = new Credential
            {
                Type = CredTypeGeneric,
                TargetName = target,
                CredentialBlobSize = blob.Length,
                CredentialBlob = data,
                Persist = CredPersistLocalMachine,
                UserName = user,
            };
            if (!CredWrite(ref credential, 0))
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), $"could not store the credential {prefix}{name}");
            }
        }
        finally
        {
            // The secret's bytes do not outlive the call.
            Marshal.Copy(new byte[blob.Length], 0, data, blob.Length);
            Marshal.FreeCoTaskMem(data);
            Marshal.FreeCoTaskMem(target);
            Marshal.FreeCoTaskMem(user);
        }
    }

    /// <inheritdoc/>
    public void Delete(string name)
    {
        if (!CredDelete(prefix + name, CredTypeGeneric, 0) && Marshal.GetLastPInvokeError() is var error and not ErrorNotFound)
        {
            throw new Win32Exception(error, $"could not delete the credential {prefix}{name}");
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Credential
    {
        public int Flags;
        public int Type;
        public nint TargetName;
        public nint Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public nint CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public nint Attributes;
        public nint TargetAlias;
        public nint UserName;
    }

    [LibraryImport("advapi32.dll", EntryPoint = "CredReadW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredRead(string target, int type, int flags, out nint credential);

    [LibraryImport("advapi32.dll", EntryPoint = "CredWriteW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredWrite(ref Credential credential, int flags);

    [LibraryImport("advapi32.dll", EntryPoint = "CredDeleteW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredDelete(string target, int type, int flags);

    [LibraryImport("advapi32.dll")]
    private static partial void CredFree(nint buffer);
}

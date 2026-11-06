using System.Runtime.InteropServices;
using Garage.App.Core.Navigation;

namespace Garage.App.Platform;

/// <summary>
/// The taskbar jump list's tasks (Search, Ask Garage, Add Source, Update Everything), through the
/// shell's <c>ICustomDestinationList</c>, which works with or without package identity. Each task
/// starts Garage with <c>--do …</c>; the running instance receives that launch and acts on it.
/// </summary>
internal static partial class JumpList
{
    private static readonly Guid DestinationListClsid = new("77f10cf0-3db5-4966-b520-b7c54fd35ed6");
    private static readonly Guid ShellLinkClsid = new("00021401-0000-0000-c000-000000000046");
    private static readonly Guid ObjectCollectionClsid = new("2d3468c1-36a7-43b6-ac24-d3f02fd9607a");

    /// <summary>Writes the tasks. A shell that refuses leaves the jump list as it was.</summary>
    public static void Register()
    {
        string? exe = Environment.ProcessPath;
        if (exe is null)
        {
            return;
        }
        try
        {
            var list = (ICustomDestinationList)CreateInstance(DestinationListClsid);
            Guid arrayId = typeof(IObjectArray).GUID;
            list.BeginList(out _, ref arrayId, out _);
            var tasks = (IObjectCollection)CreateInstance(ObjectCollectionClsid);
            foreach ((LaunchAction action, string title, string description) in LaunchCommand.JumpListTasks)
            {
                var link = (IShellLinkW)CreateInstance(ShellLinkClsid);
                link.SetPath(exe);
                link.SetArguments(LaunchCommand.Arguments(action));
                link.SetDescription(description);
                link.SetIconLocation(exe, 0);
                var properties = (IPropertyStore)link;
                var key = new PropertyKey(new Guid("f29f85e0-4ff9-1068-ab91-08002b27b3d9"), 2); // PKEY_Title
                using var value = PropVariant.FromString(title);
                properties.SetValue(ref key, value);
                properties.Commit();
                tasks.AddObject(link);
            }
            list.AddUserTasks((IObjectArray)tasks);
            list.CommitList();
        }
        catch (COMException)
        {
            // Explorer not running, or a policy turned jump lists off.
        }
    }

    private static object CreateInstance(Guid clsid) =>
        Activator.CreateInstance(Type.GetTypeFromCLSID(clsid, throwOnError: true)!)!;

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey(Guid format, uint id)
    {
        public Guid Format = format;
        public uint Id = id;
    }

    [StructLayout(LayoutKind.Sequential)]
    private sealed class PropVariant : IDisposable
    {
        private ushort _type;
        private ushort _reserved1;
        private ushort _reserved2;
        private ushort _reserved3;
        private nint _value;
        private nint _padding;

        public static PropVariant FromString(string text) => new() { _type = 31, _value = Marshal.StringToCoTaskMemUni(text) }; // VT_LPWSTR

        public void Dispose()
        {
            if (_value != 0)
            {
                Marshal.FreeCoTaskMem(_value);
                _value = 0;
            }
            _ = (_reserved1, _reserved2, _reserved3, _padding);
        }
    }

#pragma warning disable SYSLIB1096 // These are activated by CLSID through classic COM interop.
    [ComImport, Guid("6332debf-87b5-4670-90c0-5e57b408a49e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ICustomDestinationList
    {
        void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string appId);

        void BeginList(out uint minSlots, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object removed);

        void AppendCategory([MarshalAs(UnmanagedType.LPWStr)] string category, IObjectArray items);

        void AppendKnownCategory(int category);

        void AddUserTasks(IObjectArray tasks);

        void CommitList();
    }

    [ComImport, Guid("92ca9dcd-5622-4bba-a805-5e9f541bd8c9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IObjectArray
    {
        void GetCount(out uint count);

        void GetAt(uint index, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object item);
    }

    [ComImport, Guid("5632b1a4-e38a-400a-928a-d4cd63230295"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IObjectCollection
    {
        void GetCount(out uint count);

        void GetAt(uint index, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object item);

        void AddObject([MarshalAs(UnmanagedType.Interface)] object item);

        void AddFromArray(IObjectArray source);

        void RemoveObjectAt(uint index);

        void Clear();
    }

    [ComImport, Guid("000214f9-0000-0000-c000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath(nint file, int max, nint data, uint flags);

        void GetIDList(out nint list);

        void SetIDList(nint list);

        void GetDescription(nint name, int max);

        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);

        void GetWorkingDirectory(nint dir, int max);

        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);

        void GetArguments(nint args, int max);

        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);

        void GetHotkey(out short hotkey);

        void SetHotkey(short hotkey);

        void GetShowCmd(out int show);

        void SetShowCmd(int show);

        void GetIconLocation(nint path, int max, out int icon);

        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int icon);

        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);

        void Resolve(nint window, uint flags);

        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        void GetCount(out uint count);

        void GetAt(uint index, out PropertyKey key);

        void GetValue(ref PropertyKey key, [Out] PropVariant value);

        void SetValue(ref PropertyKey key, [In] PropVariant value);

        void Commit();
    }
#pragma warning restore SYSLIB1096
}

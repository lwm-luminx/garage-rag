using System.Diagnostics;

namespace Garage.App;

/// <summary>Opening files, folders and links through Windows: the Mac's <c>NSWorkspace</c> calls.</summary>
internal static class Shell
{
    /// <summary>
    /// Show in Explorer (the Mac's Reveal in Finder): a file is selected in its folder, a folder is
    /// opened. Returns false when the path is not there.
    /// </summary>
    public static bool ShowInExplorer(string? path)
    {
        if (string.IsNullOrEmpty(path))
        {
            return false;
        }
        if (File.Exists(path))
        {
            Start("explorer.exe", $"/select,\"{path}\"");
            return true;
        }
        if (Directory.Exists(path))
        {
            Start("explorer.exe", $"\"{path}\"");
            return true;
        }
        return false;
    }

    /// <summary>Opens a file, folder or URL in the app Windows has for it.</summary>
    public static bool Open(string? target)
    {
        if (string.IsNullOrEmpty(target))
        {
            return false;
        }
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true })?.Dispose();
            return true;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // Nothing is registered for it.
            return false;
        }
    }

    private static void Start(string file, string arguments) =>
        Process.Start(new ProcessStartInfo(file, arguments) { UseShellExecute = true })?.Dispose();
}

using Windows.ApplicationModel.DataTransfer;
using WinClipboard = Windows.ApplicationModel.DataTransfer.Clipboard;

namespace Garage.App;

/// <summary>Plain-text clipboard writes (the Mac's <c>NSPasteboard.copy</c>).</summary>
internal static class Clipboard
{
    public static void Copy(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }
        var package = new DataPackage();
        package.SetText(text);
        WinClipboard.SetContent(package);
    }
}

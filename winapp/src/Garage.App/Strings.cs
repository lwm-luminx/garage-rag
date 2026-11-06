using Microsoft.Windows.ApplicationModel.Resources;

namespace Garage.App;

/// <summary>
/// The app's wording from <c>Strings/en-US/Resources.resw</c>, for text code-behind sets (dialogs, rows
/// built in code). XAML finds the same resources through <c>x:Uid</c>.
/// </summary>
internal static class Strings
{
    private static readonly ResourceLoader Loader = new();

    /// <summary>The string named <paramref name="key"/>; the key itself when it is missing, so a gap shows rather than crashes.</summary>
    public static string Get(string key)
    {
        try
        {
            string value = Loader.GetString(key);
            return string.IsNullOrEmpty(value) ? key : value;
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            return key;
        }
    }
}

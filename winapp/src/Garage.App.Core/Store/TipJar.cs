using CommunityToolkit.Mvvm.ComponentModel;

namespace Garage.App.Core.Store;

/// <summary>
/// The Microsoft Store build's tips: consumable add-ons that unlock nothing (the Mac's
/// <c>TipProducts</c>). Each add-on is made in Partner Center as a developer-managed consumable with
/// one of these in-app offer tokens, matching the Mac's App Store product identifiers.
/// </summary>
public static class TipProducts
{
    /// <summary>The small tip.</summary>
    public const string Small = "me.rickmark.garage_rag.tip.small";

    /// <summary>The medium tip.</summary>
    public const string Medium = "me.rickmark.garage_rag.tip.medium";

    /// <summary>The large tip.</summary>
    public const string Large = "me.rickmark.garage_rag.tip.large";

    /// <summary>The max tip.</summary>
    public const string Max = "me.rickmark.garage_rag.tip.max";

    /// <summary>The ultra tip.</summary>
    public const string Ultra = "me.rickmark.garage_rag.tip.ultra";

    /// <summary>Smallest first, the order Settings shows them in.</summary>
    public static IReadOnlyList<string> All { get; } = [Small, Medium, Large, Max, Ultra];

    /// <summary>Whether <paramref name="offerToken"/> is a tip.</summary>
    public static bool Contains(string offerToken) => All.Contains(offerToken);

    /// <summary><paramref name="products"/> in the order of <see cref="All"/>, dropping anything that is not a tip; the Store returns them in no order.</summary>
    public static IReadOnlyList<T> Ordered<T>(IEnumerable<T> products, Func<T, string> offerToken)
    {
        ArgumentNullException.ThrowIfNull(products);
        ArgumentNullException.ThrowIfNull(offerToken);
        List<T> list = [.. products];
        return [.. All.SelectMany(wanted => list.Where(p => offerToken(p) == wanted).Take(1))];
    }
}

/// <summary>A tip as the Store prices it.</summary>
/// <param name="StoreId">The add-on's Store id, which a purchase names.</param>
/// <param name="OfferToken">Its in-app offer token (<see cref="TipProducts"/>).</param>
/// <param name="Price">The price in the buyer's currency, formatted by the Store.</param>
public sealed record TipProduct(string StoreId, string OfferToken, string Price);

/// <summary>How a purchase ended.</summary>
public enum TipPurchaseOutcome
{
    /// <summary>Paid.</summary>
    Succeeded,

    /// <summary>Waiting for approval.</summary>
    Pending,

    /// <summary>The buyer backed out.</summary>
    Cancelled,

    /// <summary>It failed.</summary>
    Failed,
}

/// <summary>The Store, as the tip jar uses it.</summary>
public interface ITipStore
{
    /// <summary>The tip add-ons; empty when there are none or no connection.</summary>
    Task<IReadOnlyList<TipProduct>> LoadAsync();

    /// <summary>Buys <paramref name="product"/>, showing the Store's dialog, and reports it fulfilled (a tip is consumed at once).</summary>
    Task<(TipPurchaseOutcome Outcome, string? Message)> PurchaseAsync(TipProduct product);
}

/// <summary>Where the tip jar is.</summary>
public enum TipJarPhase
{
    /// <summary>Loading the products.</summary>
    Loading,

    /// <summary>Loaded, nothing being bought.</summary>
    Ready,

    /// <summary>The Store returned no tips; nothing shows.</summary>
    Unavailable,

    /// <summary>A purchase is in progress.</summary>
    Purchasing,

    /// <summary>Waiting on approval.</summary>
    Pending,

    /// <summary>Thank you.</summary>
    Thanked,

    /// <summary>The tip did not go through.</summary>
    Failed,
}

/// <summary>The tip jar on the Settings page of the Store build (the Mac's <c>TipJar</c>).</summary>
public sealed partial class TipJarViewModel(ITipStore store) : ObservableObject
{
    /// <summary>The tips, smallest first.</summary>
    [ObservableProperty]
    public partial IReadOnlyList<TipProduct> Products { get; private set; } = [];

    /// <summary>Where it is.</summary>
    [ObservableProperty]
    public partial TipJarPhase Phase { get; private set; }

    /// <summary>The failure, when <see cref="Phase"/> is <see cref="TipJarPhase.Failed"/>.</summary>
    [ObservableProperty]
    public partial string? FailureMessage { get; private set; }

    /// <summary>The line under the buttons.</summary>
    public string? Note => Phase switch
    {
        TipJarPhase.Pending => "Your tip is waiting for approval.",
        TipJarPhase.Failed => $"The tip didn't go through: {FailureMessage}",
        TipJarPhase.Thanked => "Thank you! Your tip keeps Garage going.",
        _ => null,
    };

    /// <summary>Whether the tip jar shows at all.</summary>
    public bool IsOffered => Phase != TipJarPhase.Unavailable;

    /// <summary>Loads the tips.</summary>
    public async Task LoadAsync()
    {
        Phase = TipJarPhase.Loading;
        IReadOnlyList<TipProduct> found = await (store ?? throw new InvalidOperationException("no store")).LoadAsync().ConfigureAwait(true);
        Products = TipProducts.Ordered(found, p => p.OfferToken);
        Phase = Products.Count == 0 ? TipJarPhase.Unavailable : TipJarPhase.Ready;
    }

    /// <summary>Buys one tip.</summary>
    public async Task PurchaseAsync(TipProduct product)
    {
        ArgumentNullException.ThrowIfNull(product);
        Phase = TipJarPhase.Purchasing;
        (TipPurchaseOutcome outcome, string? message) = await store.PurchaseAsync(product).ConfigureAwait(true);
        FailureMessage = message;
        Phase = outcome switch
        {
            TipPurchaseOutcome.Succeeded => TipJarPhase.Thanked,
            TipPurchaseOutcome.Pending => TipJarPhase.Pending,
            TipPurchaseOutcome.Failed => TipJarPhase.Failed,
            _ => TipJarPhase.Ready,
        };
    }

    partial void OnPhaseChanged(TipJarPhase value)
    {
        OnPropertyChanged(nameof(Note));
        OnPropertyChanged(nameof(IsOffered));
    }
}

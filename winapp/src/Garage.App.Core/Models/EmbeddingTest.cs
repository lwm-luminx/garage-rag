using System.Globalization;
using System.Text;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Grpc.Core;

namespace Garage.App.Core.Models;

/// <summary>
/// One embedded sentence and what is worth seeing about its vector: the Mac's Test an Embedding
/// result (<c>ModelsView+EmbeddingInspection</c>), with the whole vector to copy as CSV or JSON.
/// </summary>
public sealed record EmbeddingInspection(string Model, string Provider, int NativeDims, IReadOnlyList<float> Vector)
{
    /// <summary>From an <c>EmbedText</c> reply.</summary>
    public static EmbeddingInspection From(EmbedTextResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        return new(response.Model, response.Provider, response.NativeDims, [.. response.Vector]);
    }

    /// <summary>The vector's width as returned (after any truncation).</summary>
    public int Dimensions => Vector.Count;

    /// <summary>The Euclidean length: 1 for a normalized vector.</summary>
    public double Norm => Math.Sqrt(Vector.Sum(v => (double)v * v));

    /// <summary>The smallest value.</summary>
    public double Min => Vector.Count == 0 ? 0 : Vector.Min();

    /// <summary>The largest value.</summary>
    public double Max => Vector.Count == 0 ? 0 : Vector.Max();

    /// <summary>The mean value.</summary>
    public double Mean => Vector.Count == 0 ? 0 : Vector.Average(v => (double)v);

    /// <summary>"bge-m3 via ollama · 1,024 dimensions" (and "of 1,024" when truncated).</summary>
    public string Caption => string.Create(CultureInfo.CurrentCulture,
        $"{Model} via {Provider} · {Dimensions:N0} {(Dimensions == 1 ? "dimension" : "dimensions")}{(Dimensions < NativeDims ? string.Create(CultureInfo.CurrentCulture, $" of {NativeDims:N0}") : "")}");

    /// <summary>The figures under the caption: norm, min, max, mean.</summary>
    public IReadOnlyList<(string Title, string Value)> Figures =>
    [
        ("Norm", Norm.ToString("0.0000", CultureInfo.CurrentCulture)),
        ("Min", Min.ToString("0.0000", CultureInfo.CurrentCulture)),
        ("Max", Max.ToString("0.0000", CultureInfo.CurrentCulture)),
        ("Mean", Mean.ToString("0.00000", CultureInfo.CurrentCulture)),
    ];

    /// <summary>The first few values, for the page: "0.0123, -0.0456, … (1,024 values)".</summary>
    public string Preview(int count = 12)
    {
        string head = string.Join(", ", Vector.Take(count).Select(v => v.ToString("0.0000", CultureInfo.InvariantCulture)));
        return Vector.Count > count
            ? string.Create(CultureInfo.CurrentCulture, $"{head}, … ({Vector.Count:N0} values)")
            : head;
    }

    /// <summary>One value per line, invariant culture: Copy CSV.</summary>
    public string Csv()
    {
        var builder = new StringBuilder();
        builder.Append("index,value\n");
        for (int i = 0; i < Vector.Count; i++)
        {
            builder.Append(CultureInfo.InvariantCulture, $"{i},{Vector[i].ToString("R", CultureInfo.InvariantCulture)}\n");
        }
        return builder.ToString();
    }

    /// <summary>A JSON array of the values: Copy JSON.</summary>
    public string Json() => "[" + string.Join(",", Vector.Select(v => v.ToString("R", CultureInfo.InvariantCulture))) + "]";
}

/// <summary>
/// Test an Embedding on the Models page: embeds a sentence with a registered model (<c>EmbedText</c>,
/// through the backend, so the egress allowlist applies) and shows the vector.
/// </summary>
public sealed partial class EmbeddingTestViewModel(GarageService.GarageServiceClient client) : ObservableObject
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromMinutes(2);

    /// <summary>The sentence.</summary>
    [ObservableProperty]
    public partial string Text { get; set; } = "The quick brown fox jumps over the lazy dog.";

    /// <summary>A registered model's slug; empty for the default model.</summary>
    [ObservableProperty]
    public partial string Model { get; set; } = "";

    /// <summary>Keep only this many values (Matryoshka models); null for the model's own width.</summary>
    [ObservableProperty]
    public partial int? Dimensions { get; set; }

    /// <summary>A call is in flight.</summary>
    [ObservableProperty]
    public partial bool IsRunning { get; private set; }

    /// <summary>Why the last call failed.</summary>
    [ObservableProperty]
    public partial string? Error { get; private set; }

    /// <summary>The last vector.</summary>
    [ObservableProperty]
    public partial EmbeddingInspection? Result { get; private set; }

    /// <summary>Whether Embed has what it needs.</summary>
    public bool CanRun => !IsRunning && Text.Trim().Length > 0;

    /// <summary>Embeds <see cref="Text"/>.</summary>
    public async Task RunAsync(CancellationToken cancellationToken = default)
    {
        if (!CanRun)
        {
            return;
        }
        IsRunning = true;
        Error = null;
        OnPropertyChanged(nameof(CanRun));
        try
        {
            EmbedTextResponse response = await client.EmbedTextAsync(
                new EmbedTextRequest { Text = Text, Model = Model, Dimensions = Dimensions ?? 0 },
                new CallOptions(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken)).ConfigureAwait(true);
            Result = EmbeddingInspection.From(response);
        }
        catch (RpcException ex)
        {
            Error = RpcErrors.Describe(ex);
            Result = null;
        }
        finally
        {
            IsRunning = false;
            OnPropertyChanged(nameof(CanRun));
        }
    }

    partial void OnTextChanged(string value) => OnPropertyChanged(nameof(CanRun));
}

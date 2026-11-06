using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Garage.App.Core.Models;
using Garage.App.Core.Operations;
using Grpc.Core;

namespace Garage.App.Core.Settings;

/// <summary>
/// One setting the Settings page edits: a <c>SECTION.KEY</c> name from <c>config/__init__.py</c>, a
/// label, what it does, and, for a closed set, the values on offer.
/// </summary>
public sealed partial class SettingField(string name, string label, string description, IReadOnlyList<string>? choices = null) : ObservableObject
{
    /// <summary><c>SECTION.KEY</c>, as <c>garage config set</c> takes it.</summary>
    public string Name { get; } = name;

    /// <summary>The label.</summary>
    public string Label { get; } = label;

    /// <summary>What it controls.</summary>
    public string Description { get; } = description;

    /// <summary>The allowed values, or null for free text.</summary>
    public IReadOnlyList<string>? Choices { get; } = choices;

    /// <summary>The value being edited.</summary>
    [ObservableProperty]
    public partial string Value { get; set; } = "";

    /// <summary>The value last read from or written to the config.</summary>
    [ObservableProperty]
    public partial string SavedValue { get; set; } = "";

    /// <summary>Whether the edit differs from the saved value.</summary>
    public bool IsChanged => Value != SavedValue;

    partial void OnValueChanged(string value) => OnPropertyChanged(nameof(IsChanged));

    partial void OnSavedValueChanged(string value) => OnPropertyChanged(nameof(IsChanged));
}

/// <summary>
/// The Settings page's configuration section: the model servers and the models behind fact
/// distillation and Ask Garage, read with <c>GetSetting</c> and saved with <c>SetSetting</c>, which
/// validates each value before writing (a bad value is refused with the server's reason).
/// </summary>
public sealed partial class SettingsViewModel(GarageService.GarageServiceClient client, OperationRunner runner) : ObservableObject
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(30);
    private static readonly string[] Providers = [.. ModelProviders.All.Select(p => p.CliValue())];

    /// <summary>The settings, in page order.</summary>
    public ObservableCollection<SettingField> Fields { get; } =
    [
        new("embedding.ollama_host", "Ollama address", "The Ollama server for embeddings, facts and answers. May be another machine; communications only ever go to one on this PC."),
        new("embedding.lmstudio_host", "LM Studio address", "LM Studio's OpenAI-compatible API, including /v1. May be another machine; communications only ever go to one on this PC."),
        new("facts.provider", "Distillation provider", "The server that distills documents into facts.", Providers),
        new("facts.model", "Distillation model", "The model that distills documents into facts, as that server names it."),
        new("inference.provider", "Answer provider", "The server behind Ask Garage and rag_ask; empty uses the distillation model.", ["", .. Providers]),
        new("inference.model", "Answer model", "The model behind Ask Garage and rag_ask; empty uses the distillation model."),
    ];

    /// <summary>Why a read or save failed.</summary>
    [ObservableProperty]
    public partial string? ErrorMessage { get; private set; }

    /// <summary>The last save's outcome.</summary>
    [ObservableProperty]
    public partial string? LastResult { get; private set; }

    /// <summary>Reads every field's current value.</summary>
    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        ErrorMessage = null;
        try
        {
            foreach (SettingField field in Fields)
            {
                GetSettingResponse setting = await client.GetSettingAsync(new GetSettingRequest { Name = field.Name }, Options(cancellationToken)).ConfigureAwait(true);
                string value = SettingValue.Text(setting.ValueJson) ?? "";
                field.SavedValue = value;
                field.Value = value;
            }
        }
        catch (RpcException ex)
        {
            ErrorMessage = RpcErrors.Describe(ex);
        }
    }

    /// <summary>Writes every changed field; stops at the first the server refuses.</summary>
    public async Task<OperationResult> SaveAsync()
    {
        List<SettingField> changed = [.. Fields.Where(f => f.IsChanged)];
        OperationResult result = await runner.RunAsync(async (_, token) =>
        {
            List<string> lines = [];
            foreach (SettingField field in changed)
            {
                SetSettingResponse saved = await client.SetSettingAsync(new SetSettingRequest { Name = field.Name, Value = field.Value.Trim() }, Options(token)).ConfigureAwait(true);
                field.SavedValue = SettingValue.Text(saved.ValueJson) ?? "";
                field.Value = field.SavedValue;
                lines.Add($"{field.Name} = {field.SavedValue} (in {saved.Path})");
            }
            return lines.Count == 0 ? "Nothing changed" : string.Join('\n', lines);
        }).ConfigureAwait(true);
        LastResult = result.Output;
        ErrorMessage = result.Succeeded ? null : result.Output;
        return result;
    }

    /// <summary>Puts every field back to its saved value.</summary>
    public void Revert()
    {
        foreach (SettingField field in Fields)
        {
            field.Value = field.SavedValue;
        }
    }

    private static CallOptions Options(CancellationToken cancellationToken) =>
        new(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken);
}

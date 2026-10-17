using Garage.Plugin.V1;

namespace Garage.Plugins;

/// <summary>
/// A reader plugin: the two calls of <c>garage.plugin.v1.ExtractorPlugin</c>, however the plugin is
/// reached (linked in-process, as <see cref="NativeTextReader"/> is, or over gRPC).
/// </summary>
public interface IExtractorPlugin
{
    /// <summary>What the plugin reads: its extractors, with the extensions and names each takes.</summary>
    DescribeResponse Describe(DescribeRequest request);

    /// <summary>
    /// Reads one file. A file the plugin cannot read is answered in the response
    /// (<see cref="ExtractResponse.OutcomeOneofCase.Failure"/>), not thrown.
    /// </summary>
    ExtractResponse Extract(ExtractRequest request);
}

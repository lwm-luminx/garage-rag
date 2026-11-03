import Foundation
import GarageXPCKit

/// What GarageEmbedXPCService tells the client that asked for a backfill, beside the common log stream.
@objc(GarageEmbedProgressReceiverProtocol)
public protocol GarageEmbedProgressReceiverProtocol: GarageXPCLogReceiverProtocol {
    /// One step of the backfill, as JSON (`EmbedBackfillEvent`).
    func didUpdateBackfill(eventJson: String)
}

/// Objective-C protocol of GarageEmbedXPCService. It receives the LlamaXPCService endpoint because
/// embedding with a llama_xpc model loads it on demand, and the GarageImageEmbedXPCService endpoint
/// because the embed worker embeds image models there.
@objc(GarageEmbedXPCServiceProtocol)
public protocol GarageEmbedXPCServiceProtocol: GarageCommonXPCServiceProtocol, GarageLlamaEndpointReceiverProtocol, GarageImageEmbedEndpointReceiverProtocol {
    /// Embeds `texts` with `model` (`provider:model_ref`, or a llama_xpc slug), as a diagnostic.
    func embedTexts(_ texts: [String], model: String?, with reply: @escaping (Bool, String?) -> Void)

    /// Embeds the chunks each model (or the one named) has no vectors for, through GarageService
    /// at the address and with the token the app configured (`updateConfiguration`).
    /// `requestJson` is an `EmbedBackfillRequest`; the reply is an `EmbedBackfillReply` as JSON.
    /// The calling connection hears each step (`GarageEmbedProgressReceiverProtocol`).
    func backfill(requestJson: String, with reply: @escaping (String) -> Void)

    /// Stops the backfill in progress at its next batch.
    func cancelBackfill(with reply: @escaping (Bool) -> Void)
}

public enum EmbedXPCConstants {
    public static let serviceName = "me.rickmark.garage-rag.embed-xpc"
}

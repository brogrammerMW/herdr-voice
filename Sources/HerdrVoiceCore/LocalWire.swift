import CryptoKit
import Foundation

public struct ToolManifest: Equatable {
    public struct Profile: Equatable {
        public let name: String
        public let count: Int
        public let digest: String
    }

    public let profile: Profile
    public let names: [String]
}

public extension HerdrTools {
    /// Ordered handshake summary. The complete schemas are sent with it.
    static var toolManifest: ToolManifest {
        toolManifest(for: schemas)
    }

    static func toolManifest(includeShell: Bool) -> ToolManifest {
        toolManifest(for: schemas(includeShell: includeShell))
    }

    private static func toolManifest(for definitions: [[String: Any]]) -> ToolManifest {
        let names = definitions.compactMap { $0["name"] as? String }
        let data = (try? JSONSerialization.data(withJSONObject: definitions,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolManifest(
            profile: .init(name: definitions.count == 32 ? "shell32" : "base30",
                           count: definitions.count, digest: digest),
            names: names)
    }
}

/// Herdr's authenticated loopback protocol for the OpenLive inference host.
/// Every turn event carries an epoch. The epoch drops results from cancelled GPU work.
public final class LocalWire: Wire {
    public let capabilities = WireCapabilities(explicitReplies: true, nativeResumption: false)

    private let lock = NSLock()
    private var epoch = 0
    private var utteranceID: String?

    public init() {}

    public func isCurrent(epoch candidate: Int) -> Bool {
        lock.withLock { candidate == epoch }
    }

    public static func sessionUpdate(instructions: String, voice: String) -> [String: Any] {
        let manifest = HerdrTools.toolManifest
        return ["type": "session.update", "session": [
            "protocol_version": 1,
            "instructions": instructions,
            "voice": voice,
            "tools": HerdrTools.schemas,
            "tool_manifest": [
                "profile": manifest.profile.name,
                "count": manifest.profile.count,
                "names": manifest.names,
                "digest": manifest.profile.digest,
            ] as [String: Any],
        ] as [String: Any]]
    }

    public func encode(_ command: WireCommand) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        switch command {
        case .setup(let instructions, let voice, _):
            return [Self.sessionUpdate(instructions: instructions, voice: voice)]
        case .inputStarted(let id):
            epoch += 1
            utteranceID = id
            return [["type": "input.begin", "utterance_id": id, "epoch": epoch]]
        case .appendAudio(let audio):
            guard let utteranceID else { return [] }
            return [["type": "input.append", "utterance_id": utteranceID, "epoch": epoch, "audio": audio]]
        case .audioPaused:
            guard let utteranceID else { return [] }
            return [["type": "input.commit", "utterance_id": utteranceID, "epoch": epoch]]
        case .clearInput:
            epoch += 1
            utteranceID = nil
            return [["type": "input.clear", "epoch": epoch]]
        case .userText(let text, let expectsReply):
            return [["type": "conversation.text", "epoch": epoch, "text": text, "expects_reply": expectsReply]]
        case .toolOutputs(let outputs):
            guard let outputEpoch = outputs.first?.epoch,
                  outputs.allSatisfy({ $0.epoch == outputEpoch })
            else { return [] }
            return [[
                "type": "tool.outputs",
                "epoch": outputEpoch,
                "outputs": outputs.map { ["call_id": $0.callID, "name": $0.name, "output": $0.output] },
            ]]
        case .requestReply:
            return [["type": "response.create", "epoch": epoch]]
        case .cancelReply:
            return [["type": "response.cancel", "epoch": epoch]]
        case .truncate(let itemID, let audioEndMs):
            return [["type": "response.truncate", "epoch": epoch, "item_id": itemID, "audio_end_ms": audioEndMs]]
        }
    }

    public func decode(_ text: String) -> [ServerEvent] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return [.error("undecodable local event")] }

        lock.lock()
        defer { lock.unlock() }
        if type == "session.updated" { return [.sessionReady] }
        if type == "error", object["epoch"] == nil { return [.error(Self.errorMessage(object, fallback: text))] }
        guard let eventEpoch = object["epoch"] as? Int, eventEpoch == epoch else { return [] }

        if type == "input.transcription.completed" {
            guard object["source"] as? String == "microphone",
                  object["utterance_id"] as? String == utteranceID
            else { return [] }
            return [.userTranscript(object["transcript"] as? String ?? "")]
        }
        if type == "response.transcript.truncated" {
            return [.assistantTranscriptTruncated(itemID: object["item_id"] as? String ?? "",
                                                  text: object["transcript"] as? String ?? "")]
        }
        if type == "response.audio_transcript.done" {
            return [.assistantTranscriptItem(itemID: object["item_id"] as? String ?? "",
                                             text: object["transcript"] as? String ?? "")]
        }
        if type == "response.function_call_arguments.done" {
            return [.localFunctionCall(
                epoch: eventEpoch,
                callID: object["call_id"] as? String ?? "",
                name: object["name"] as? String ?? "",
                arguments: object["arguments"] as? String ?? "{}")]
        }
        return [ServerEvent.decode(text)]
    }

    private static func errorMessage(_ object: [String: Any], fallback: String) -> String {
        (object["error"] as? [String: Any])?["message"] as? String ?? fallback
    }
}

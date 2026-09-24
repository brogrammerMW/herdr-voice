import Foundation

/// Holds one pending risky action until the developer's own speech confirms it.
/// The model cannot confirm on its own: only `heard(_:)`, fed from the mic transcript, flips the flag.
/// Terminal output the model reads can contain injected instructions, so every action that could
/// approve, send or destroy something goes through here.
public final class ConfirmGate {
    public static let shared = ConfirmGate()

    private struct Pending {
        let action: String
        let question: String
        let at: Date
        var confirmed = false
        /// The first transcript after the question decides; anything but a clear yes drops it.
        var answered = false
    }

    private let lock = NSLock()
    private var pending: Pending?
    private let ttl: TimeInterval
    private let minDelay: TimeInterval
    private let clock: () -> Date
    private let wait: TimeInterval

    /// `minDelay` ignores transcripts that land right after the request, which are usually the
    /// request itself ("yes, close forge") arriving late rather than an answer to the question.
    public init(ttl: TimeInterval = 20, minDelay: TimeInterval = 2, wait: TimeInterval = 4,
                clock: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.wait = wait
        self.minDelay = minDelay
        self.clock = clock
    }

    /// Arms `action`. Returns the question already waiting if a different action is still pending,
    /// so one "yes" can never be redirected to a newer request.
    func request(_ action: String, question: String) -> String? {
        lock.withLock {
            if let p = pending, p.action != action, !p.answered, clock().timeIntervalSince(p.at) < ttl {
                return p.question
            }
            pending = Pending(action: action, question: question, at: clock())
            return nil
        }
    }

    /// Feed every user transcript here.
    public func heard(_ transcript: String) {
        let words = Set(transcript.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init))
        let text = transcript.lowercased()
        lock.withLock {
            guard var p = pending, !p.answered else { return }
            let age = clock().timeIntervalSince(p.at)
            guard age >= minDelay else { return }
            guard age < ttl else { pending = nil; return }
            p.answered = true
            // ponytail: English keyword heuristic; a "no" anywhere cancels, so mixed answers fail safe.
            let no = !words.isDisjoint(with: ["no", "nope", "don't", "cancel", "stop", "wait", "never", "not"])
            let yes = !words.isDisjoint(with: ["yes", "yeah", "yep", "yup", "sure", "confirm", "confirmed", "correct",
                                               "affirmative", "ok", "okay", "approve", "approved", "allow", "accept"])
                || text.contains("go ahead")
            p.confirmed = yes && !no
            pending = p.confirmed ? p : nil
        }
    }

    /// True once if `action` was confirmed. Waits briefly because the "yes" transcript can arrive
    /// after the model has already issued the confirmed call.
    func consume(_ action: String) -> Bool {
        let deadline = clock().addingTimeInterval(wait)
        repeat {
            let state: Bool? = lock.withLock {
                guard let p = pending, clock().timeIntervalSince(p.at) < ttl else { return false }
                // A confirmed call for anything else voids the "yes": it was given for a different question.
                guard p.action == action else { pending = nil; return false }
                if p.confirmed { pending = nil; return true }
                return nil
            }
            if let state { return state }
            Thread.sleep(forTimeInterval: 0.1)
        } while clock() < deadline
        return false
    }
}

extension HerdrTools {
    /// Shared two-step flow. Returns the message to hand back to the model, or nil when the developer
    /// confirmed and the caller may act.
    static func confirmStep(_ tool: String, action: String, question: String, confirmed: Bool, _ gate: ConfirmGate) -> String? {
        guard confirmed else {
            if let waiting = gate.request(action, question: question) {
                return "error: another confirmation is still waiting (\(waiting)). Get the developer's answer to that first."
            }
            return "CONFIRMATION REQUIRED. Ask the developer, in one short sentence: \(question)? "
                + "Only after they say yes, call \(tool) again with the same arguments and confirmed=true."
        }
        guard gate.consume(action) else {
            return "error: the developer has not confirmed (\(question)). Call \(tool) without confirmed and ask again."
        }
        return nil
    }
}

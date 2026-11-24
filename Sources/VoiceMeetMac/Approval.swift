import AppKit
import LocalAuthentication
import VoiceMeetCore

/// The person's approval of one use, for a thing whose choice is "Ask". The app says
/// what a mind wants to do; the person approves it once or for half an hour, with Touch ID (or the
/// Mac's password where there is no Touch ID), or denies it. A caller that gets no answer in a
/// minute is refused. An approval holds in its round only (`ApprovalGrants`): another mind, none,
/// or a refusal of this Mac's key ends every approval, and the answer to a question of an older
/// round approves nothing.
///
/// In a test copy with a home of its own and its control socket (`ControlSocket`), a question shows
/// no alert and asks for no Touch ID: it waits for `approval.answer` on that socket, with the same
/// patience. The installed app, in the default home, always asks with the alert and Touch ID.
@MainActor
final class Approval {
    private static let window: TimeInterval = 30 * 60
    private static let patience: TimeInterval = 60

    /// True when the control socket answers the questions; never in the default home.
    var answersByControl = false
    /// The question that waits for `approval.answer` now.
    private(set) var waiting: (question: String, answer: CheckedContinuation<(allow: Bool, keep: Bool)?, Never>)?

    private let log = AppLog("approval")
    private var grants = ApprovalGrants()
    private var isAsking = false
    private var questions = 0

    /// Another mind session, or none: every approval ends, and a question that waits on the
    /// control socket is answered with no answer.
    func use(_ session: MindSession?) {
        grants.use(generation: session?.generation)
        _ = answer(allow: nil)
    }

    /// The mind refused this Mac's key: every approval ends, and so does a question that waits.
    func refuse() {
        grants.refuse()
        _ = answer(allow: nil)
        log.info("the mind refused this Mac's key: every approval ends")
    }

    /// Until when the person approved a thing in this session without another question; nil when they did not.
    func isApproved(_ thing: Shareable) -> Date? {
        grants.isApproved(thing.id, now: Date())
    }

    func end(_ thing: Shareable) {
        grants.end(thing.id)
        log.info("the person ended the approval to \(thing.does)")
    }

    /// Returns when the person approved; throws the refusal a caller reads when they did not.
    func ask(for thing: Shareable, what: String) async throws {
        try await ask(for: [thing], does: thing.does, what: what)
    }

    /// One question for several things (a live watch: the screens, the camera, the microphone).
    /// "Approve for 30 Minutes" holds for each of them.
    func ask(for things: [Shareable], does: String, what: String) async throws {
        // One question at a time: a second caller waits for the first answer, which may cover it.
        while isAsking { try await Task.sleep(nanoseconds: 200_000_000) }
        if things.allSatisfy({ isApproved($0) != nil }) { return }
        isAsking = true
        defer { isAsking = false }
        let round = grants.round
        if answersByControl, AppEnvironment.current.hasOwnHome {
            let keeps: Bool
            do {
                keeps = try await askControl(does: does, what: what)
            } catch {
                try stillTheRound(round, does: does)
                throw error
            }
            try stillTheRound(round, does: does)
            if keeps { approve(things, round: round, does: does) }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Your mind wants to \(does)"
        alert.informativeText = what
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Approve Once")
        alert.addButton(withTitle: "Approve for 30 Minutes")
        alert.addButton(withTitle: "Deny")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        // Bounded: with no answer the question goes away and the caller is refused.
        let giveUp = DispatchWorkItem { NSApp.abortModal() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience, execute: giveUp)
        let answer = alert.runModal()
        giveUp.cancel()
        alert.window.orderOut(nil)

        guard answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn else {
            let words = answer == .alertThirdButtonReturn ? "denied it" : "gave no answer in \(Int(Self.patience)) seconds"
            log.info("to \(does): the person \(words)")
            throw EndpointRefusal("The Mac's owner \(words) to \(does).")
        }
        do {
            let reason = "approve that your mind may \(does)"
            guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw EndpointRefusal("The Mac's owner did not confirm with Touch ID to \(does).")
            }
        } catch let refusal as EndpointRefusal {
            throw refusal
        } catch {
            log.info("to \(does): no confirmation: \(AppLog.describe(error))")
            throw EndpointRefusal("The Mac's owner did not confirm with Touch ID to \(does).")
        }
        try stillTheRound(round, does: does)
        if answer == .alertSecondButtonReturn {
            approve(things, round: round, does: does)
        } else {
            log.info("to \(does): the person approved this one use")
        }
    }

    /// The question was asked for another mind than the one this Mac is lent to now, or before the
    /// mind refused this Mac's key: its answer is no answer now.
    private func stillTheRound(_ round: ApprovalGrants.Round, does: String) throws {
        guard round != grants.round else { return }
        log.info("to \(does): the answer came after the mind changed or refused the key; the use is refused")
        throw EndpointRefusal("The question to \(does) was asked before the mind changed or refused this Mac's key.")
    }

    private func approve(_ things: [Shareable], round: ApprovalGrants.Round, does: String) {
        grants.approve(things.map(\.id), round: round, until: Date().addingTimeInterval(Self.window))
        log.info("to \(does): the person approved for 30 minutes")
    }

    /// The answer of the control socket: true approves, for 30 minutes with `keep`, else this one
    /// use; false denies it. False when no question waits.
    func answer(allow: Bool?, keep: Bool = false) -> Bool {
        guard let waiting else { return false }
        self.waiting = nil
        waiting.answer.resume(returning: allow.map { (allow: $0, keep: keep) })
        return true
    }

    /// True when the answer approves for 30 minutes.
    private func askControl(does: String, what: String) async throws -> Bool {
        questions += 1
        let question = questions
        log.info("to \(does): the question waits for approval.answer on the control socket")
        let allowed = await withCheckedContinuation { continuation in
            waiting = ("Your mind wants to \(does)\n\n\(what)", continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience) { [weak self] in
                if self?.questions == question { _ = self?.answer(allow: nil) }
            }
        }
        guard let allowed, allowed.allow else {
            let words = allowed != nil ? "denied it" : "gave no answer in \(Int(Self.patience)) seconds"
            log.info("to \(does): the control socket \(words)")
            throw EndpointRefusal("The Mac's owner \(words) to \(does).")
        }
        if !allowed.keep { log.info("to \(does): the control socket approved this one use") }
        return allowed.keep
    }
}

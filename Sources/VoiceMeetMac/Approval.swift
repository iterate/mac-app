import AppKit
import LocalAuthentication

/// The person's approval of one use, for a thing whose choice is "Ask". The app says
/// what a mind wants to do; the person approves it once or for half an hour, with Touch ID (or the
/// Mac's password where there is no Touch ID), or denies it. A caller that gets no answer in a
/// minute is refused.
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
    private(set) var waiting: (question: String, answer: CheckedContinuation<Bool?, Never>)?

    private let log = AppLog("approval")
    private var approvedUntil: [String: Date] = [:]
    private var isAsking = false
    private var questions = 0

    /// Until when the person approved a thing without another question; nil when they did not.
    func isApproved(_ thing: Shareable) -> Date? {
        approvedUntil[thing.id].flatMap { $0 > Date() ? $0 : nil }
    }

    func end(_ thing: Shareable) {
        approvedUntil[thing.id] = nil
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
        if answersByControl, AppEnvironment.current.hasOwnHome { return try await askControl(does: does, what: what) }

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
        if answer == .alertSecondButtonReturn {
            for thing in things { approvedUntil[thing.id] = Date().addingTimeInterval(Self.window) }
        }
        log.info("to \(does): the person approved \(answer == .alertSecondButtonReturn ? "for 30 minutes" : "this one use")")
    }

    /// The answer of the control socket: true approves this one use, false denies it. False when
    /// no question waits.
    func answer(allow: Bool?) -> Bool {
        guard let waiting else { return false }
        self.waiting = nil
        waiting.answer.resume(returning: allow)
        return true
    }

    private func askControl(does: String, what: String) async throws {
        questions += 1
        let question = questions
        log.info("to \(does): the question waits for approval.answer on the control socket")
        let allowed = await withCheckedContinuation { continuation in
            waiting = ("Your mind wants to \(does)\n\n\(what)", continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience) { [weak self] in
                if self?.questions == question { _ = self?.answer(allow: nil) }
            }
        }
        guard allowed == true else {
            let words = allowed == false ? "denied it" : "gave no answer in \(Int(Self.patience)) seconds"
            log.info("to \(does): the control socket \(words)")
            throw EndpointRefusal("The Mac's owner \(words) to \(does).")
        }
        log.info("to \(does): the control socket approved this one use")
    }
}

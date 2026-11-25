import AppKit
import LocalAuthentication
import VoiceMeetCore

/// The person's approval of one use, for a thing whose choice is "Ask". The app's own floating
/// panel (`ApprovalWindow`) says which mind wants what, and what exactly in monospace; the person
/// approves it once or for a while (Settings › General, "An approval can last": `approval.minutes`,
/// 30 unless set), with Touch ID (or the Mac's password where there is no Touch ID), or denies it.
/// A caller that gets no answer in a minute is refused. An approval holds in its round only
/// (`ApprovalGrants`): another mind, none, or a refusal of this Mac's key ends every approval, and
/// the answer to a question of an older round approves nothing. The round is the caller's from its
/// call on: a caller that waited behind another question, or for Touch ID, while the round ended
/// is refused, and Touch ID ends with the round.
///
/// In a test copy with a home of its own and its control socket (`ControlSocket`), the panel shows
/// as well and its buttons answer (`ui.press` on `approval.once`, `approval.minutes`,
/// `approval.deny`), and so does `approval.answer` on that socket; no Touch ID is asked. The
/// installed app, in the default home, always confirms an approval with Touch ID.
@MainActor
final class Approval {
    /// How long "Approve for N Minutes" lasts: the person's choice, read when the question is asked.
    private static var minutes: Int { Choices.shared.approvalMinutes }
    nonisolated static let patience: TimeInterval = 60

    /// One question, as the panel shows it.
    struct Question: Equatable {
        /// The mind of the session, by its address, and this Mac's name there; nil with no session.
        let mind: String?
        let name: String?
        /// What a use is: "run commands".
        let does: String
        /// Why it is asked, in a sentence or two.
        let note: String
        /// What exactly is asked, in monospace: the command, the display's name.
        let detail: String?
        /// The words of the second button's length: "30 Minutes".
        let keepWords: String
        let askedAt: Date
        /// A test copy's question: the control socket stands in for Touch ID.
        let byControl: Bool

        var deadline: Date { askedAt.addingTimeInterval(Approval.patience) }

        /// The question in words, for `ui.state`.
        var words: String {
            ["Your mind wants to \(does)", note, detail].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    typealias Answer = (allow: Bool, keep: Bool)

    /// True when the control socket answers the questions too; never in the default home.
    var answersByControl = false
    /// The question that waits for an answer now.
    private(set) var waiting: (question: Question, answer: CheckedContinuation<Answer?, Never>)?

    private let log = AppLog("approval")
    private var grants = ApprovalGrants()
    private var isAsking = false
    /// The callers that wait for their turn, in order: one question at a time.
    private var turns: [CheckedContinuation<Void, Never>] = []
    private var questions = 0
    private var session: MindSession?
    /// Touch ID while it asks: a new round ends it.
    private var confirming: LAContext?
    private lazy var window = ApprovalWindow { [weak self] allow, keep in _ = self?.answer(allow: allow, keep: keep) }

    /// Another mind session, or none: every approval ends, and a question that waits is answered
    /// with no answer.
    func use(_ session: MindSession?) {
        self.session = session
        grants.use(generation: session?.generation)
        endRound()
    }

    /// The mind refused this Mac's key: every approval ends, and so does a question that waits.
    func refuse() {
        grants.refuse()
        endRound()
        log.info("the mind refused this Mac's key: every approval ends")
    }

    /// The round now: a use that waited for a question goes on only while it holds (`holds`).
    var round: ApprovalGrants.Round { grants.round }

    func holds(_ round: ApprovalGrants.Round) -> Bool { grants.holds(round) }

    /// The question on the screen and Touch ID end: no answer. The callers that wait for their
    /// turn wake one after the other and end too, their round being an older one.
    private func endRound() {
        _ = answer(allow: nil)
        confirming?.invalidate()
        confirming = nil
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
    func ask(for thing: Shareable, what: String, detail: String? = nil) async throws {
        try await ask(for: [thing], does: thing.does, what: what, detail: detail)
    }

    /// One question for several things (a live watch: the screens, the camera, the microphone).
    /// "Approve for N Minutes" holds for each of them.
    func ask(for things: [Shareable], does: String, what: String, detail: String? = nil) async throws {
        // The round of the call, before any wait: a caller of the mind before is no caller now.
        let round = grants.round
        // One question at a time: a second caller waits for the first answer, which may cover it.
        await takeTurn()
        defer { endTurn() }
        try stillTheRound(round, does: does)
        if things.allSatisfy({ isApproved($0) != nil }) { return }
        let byControl = answersByControl && AppEnvironment.current.hasOwnHome
        let names = things.map(\.title).joined(separator: ", ")
        let question = Question(
            mind: session?.mind, name: session?.name, does: does,
            note: "\(names) \(things.count == 1 ? "is" : "are") set to Ask. \(what)", detail: detail,
            keepWords: Choices.approvalWords(Self.minutes), askedAt: Date(), byControl: byControl)

        let answer = await wait(for: question)
        // a switch or a refusal ended the question: that is the reason, not the person
        try stillTheRound(round, does: does)
        guard let answer, answer.allow else {
            let words = answer != nil ? "denied it" : "gave no answer in \(Int(Self.patience)) seconds"
            log.info("to \(does): the person \(words)")
            throw EndpointRefusal("The Mac's owner \(words) to \(does).")
        }
        if !byControl {
            // LocalAuthentication shows its own window, from a process of the system: the app need
            // not be the active one for it
            do {
                let reason = "approve that your mind may \(does)"
                let context = LAContext()
                confirming = context
                defer { if confirming === context { confirming = nil } }
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                    throw EndpointRefusal("The Mac's owner did not confirm with Touch ID to \(does).")
                }
            } catch let refusal as EndpointRefusal {
                throw refusal
            } catch {
                log.info("to \(does): no confirmation: \(AppLog.describe(error))")
                throw EndpointRefusal("The Mac's owner did not confirm with Touch ID to \(does).")
            }
        }
        try stillTheRound(round, does: does)
        if answer.keep {
            approve(things, round: round, does: does)
        } else {
            log.info("to \(does): the person approved this one use")
        }
    }

    /// The caller's turn to ask: at once when no question is asked, else after the ones before it.
    private func takeTurn() async {
        guard isAsking else { return isAsking = true }
        await withCheckedContinuation { turns.append($0) }
    }

    /// The turn passes to the next caller, which then holds `isAsking`.
    private func endTurn() {
        if turns.isEmpty { isAsking = false } else { turns.removeFirst().resume() }
    }

    /// Shows the question and waits for a button, the control socket, the end of the patience, or
    /// the end of the round. The panel goes with the answer.
    private func wait(for question: Question) async -> Answer? {
        questions += 1
        let number = questions
        log.info("to \(question.does): the question waits\(question.byControl ? " (a test copy: the control socket answers too)" : "")")
        let answer = await withCheckedContinuation { continuation in
            waiting = (question, continuation)
            window.show(question)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience) { [weak self] in
                if self?.questions == number { _ = self?.answer(allow: nil) }
            }
        }
        // the next question, if one waits, is a new one: this one's timer must not end it
        questions += 1
        return answer
    }

    /// The question was asked for another mind than the one this Mac is lent to now, or before the
    /// mind refused this Mac's key: its answer is no answer now.
    private func stillTheRound(_ round: ApprovalGrants.Round, does: String) throws {
        guard !grants.holds(round) else { return }
        log.info("to \(does): the answer came after the mind changed or refused the key; the use is refused")
        throw EndpointRefusal("The question to \(does) was asked before the mind changed or refused this Mac's key.")
    }

    private func approve(_ things: [Shareable], round: ApprovalGrants.Round, does: String) {
        let minutes = Self.minutes
        grants.approve(things.map(\.id), round: round, until: Date().addingTimeInterval(TimeInterval(minutes) * 60))
        log.info("to \(does): the person approved for \(minutes) minutes")
    }

    /// The answer of a button or of the control socket: true approves, for `approval.minutes` with
    /// `keep`, else this one use; false denies it; nil is no answer. False when no question waits.
    func answer(allow: Bool?, keep: Bool = false) -> Bool {
        guard let waiting else { return false }
        self.waiting = nil
        window.close()
        waiting.answer.resume(returning: allow.map { (allow: $0, keep: keep) })
        return true
    }
}

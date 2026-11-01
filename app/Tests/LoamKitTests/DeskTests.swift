import Foundation
import Testing

@testable import LoamKit

/// Ticket 207: the desk takes the runs that wait for you one at a time: Land first, then Stopped.
@MainActor
@Suite(.waitLimit) struct DeskTests {
    static func run(_ id: String, _ state: RunState, updated: String) -> Run {
        TodayContentTests.run(id, plot: "plotaaaaae", state, updated: updated)
    }

    /// r1 and r3 are ready, r1 the longer. r2 stopped. r4 runs.
    func model(_ fixtures: [(String, Int32)]) throws -> (AppModel, FakeLoam) {
        let fake = try FakeLoam(fixtures)
        let model = AppModel(client: fake.client())
        model.apply([PlotSummary(id: "plotaaaaae", name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z")])
        model.runs = [
            Self.run("r4", .running, updated: "2026-10-27T18:00:00Z"),
            Self.run("r3", .ready, updated: "2026-10-27T17:00:00Z"),
            Self.run("r2", .stopped, updated: "2026-10-27T16:30:00Z"),
            Self.run("r1", .ready, updated: "2026-10-27T16:00:00Z"),
        ]
        return (model, fake)
    }

    @Test func theQueueIsLandThenStoppedTheLongestWaitFirst() throws {
        let (model, _) = try model([])
        #expect(model.deskQueue.map(\.id) == ["r1", "r3", "r2"])
    }

    @Test func theDeskOpensOnTheFirstItemAndReadsItsDiff() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0)])
        await model.openDesk()
        #expect(model.page == .desk)
        #expect(model.desk.runID == "r1")
        #expect(model.desk.diff?.files.map(\.path) == ["README.md"])
        #expect(model.desk.file == "README.md")
        #expect(fake.args() == ["run diff --json -- r1", "run status --json -- r1"])
        model.leaveDesk()
        #expect(model.page == .today)
    }

    /// TAS-49: ] goes through every file in the order to read them, and from the last file back to the first.
    @Test func nextFileGoesThroughEveryFileAndWraps() throws {
        let (model, _) = try model([])
        let files = ["a.go", "b.go", "c.go"].map { RunDiff.File(path: $0, status: "modified", added: 1, deleted: 0, hunks: []) }
        model.desk.runID = "r1"
        model.desk.diff = RunDiff(base: "main", head: "abc", files: files)
        model.desk.file = "a.go"
        var shown: [String?] = []
        for _ in files {
            model.showNextDeskFile()
            shown.append(model.desk.file)
        }
        #expect(shown == ["b.go", "c.go", "a.go"])
        // One file has no next file.
        model.desk.diff = RunDiff(base: "main", head: "abc", files: [files[0]])
        #expect(model.nextDeskFile == nil)
    }

    @Test func nextAndPreviousStayInTheQueue() async throws {
        let (model, _) = try model(Array(repeating: ("run_diff", 0), count: 8))
        await model.openDesk()
        await model.moveDesk(by: -1)
        #expect(model.desk.runID == "r1")
        await model.moveDesk(by: 1)
        await model.moveDesk(by: 1)
        #expect(model.desk.runID == "r2")
        await model.moveDesk(by: 1)
        #expect(model.desk.runID == "r2")
    }

    @Test func notesGoBackAsOneBatch() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0), ("run_send_back", 0), ("run_list", 0)])
        await model.openDesk()
        model.addDeskNote(file: "README.md", line: 3, text: "Say what a plot is.")
        model.addDeskNote(file: nil, line: nil, text: "  Keep the README short. ")
        model.addDeskNote(file: nil, line: nil, text: "   ")
        #expect(model.desk.notes["r1"]?.count == 2)
        let first = try #require(model.desk.notes["r1"]?.first)
        model.removeDeskNote(first.id)
        model.addDeskNote(file: "README.md", line: 3, text: "Say what a plot is.")
        await model.sendBackDeskNotes()
        #expect(fake.args().dropFirst(2).first == "run send-back --note Keep the README short. "
            + "--note README.md:3: Say what a plot is. --json -- r1")
        #expect(model.desk.notes["r1"] == nil)
        #expect(model.desk.error == nil)
    }

    @Test func aMergeNamesTheHeadThatYouRead() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0), ("run_land", 0), ("run_list", 0)])
        await model.openDesk()
        model.desk.keepWorktree = true
        await model.landDeskRun()
        #expect(fake.args().dropFirst(2).first
            == "run land --head 1234512345123451234512345123451234512345 --keep-worktree --json -- r1")
        #expect(model.desk.error == nil)
    }

    /// The merge can remove the worktree of the run, so the sidebar reads the worktrees again. The toast says
    /// what the merge did, as at the Land sheet.
    /// When you merge: a run from Linear reads the Linear updates, and its issue moves to Done as the Done switch
    /// says, unless you say no. Where it stands moves on to the text of the ship notes, unless you say no.
    @Test func aMergeDoesWhatWhenYouMergeSays() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0), ("linear_updates", 0), ("run_land", 0),
                                       ("run_list", 0)])
        model.runs[3].source = RunSource(kind: "linear", key: "ENG-517", url: "")
        model.runs[3].notes = RunNotes(walkthrough: "Search matches labels.", files: [], risk: .init(level: "low", reasons: []),
                                       whereItStands: "Search matches labels now.", writtenAt: "2026-10-27T16:00:00Z")
        await model.openDesk()
        #expect(fake.args().last == "linear updates --json")
        #expect(model.deskLinearDone && model.desk.moveWhereItStands)
        model.setDeskLinearDone(false)
        await model.landDeskRun()
        #expect(fake.args().dropFirst(3).first == "run land --head 1234512345123451234512345123451234512345 "
            + "--no-linear-done --where-it-stands --json --actor app -- r1")

        // The next item starts from the switch again.
        await model.openDesk("r3")
        #expect(model.desk.linearDone == nil && model.desk.moveWhereItStands)
    }

    @Test func aMergeReadsTheWorktreesAgainAndSaysWhatItDid() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0), ("run_land", 0), ("run_list", 0),
                                       ("run_diff", 0), ("run_status", 0), ("worktree_list", 0)])
        var toasts: [String] = []
        model.onToast = { text, _ in toasts.append(text) }
        await model.openDesk()
        await model.landDeskRun()
        #expect(fake.args().last?.contains("worktree list") == true)
        #expect(toasts == ["Merged #25. Removed the worktree tidy-the-readme."])
    }

    /// A tick can land a run that the desk shows, when its PR merged on GitHub. The desk then shows the next
    /// run, or nothing.
    @Test func aRunThatLeavesTheQueueLeavesTheDesk() async throws {
        let (model, _) = try model([("run_diff", 0), ("run_status", 0), ("run_list", 0)])
        await model.openDesk()
        #expect(model.desk.runID == "r1")
        await model.reloadRuns()
        #expect(model.desk.runID == nil && model.desk.diff == nil)
    }

    /// TAS-61: a ready run with a PR reads the review of its PR when the desk shows it, and the row starts closed.
    @Test func aReadyRunWithAPRReadsItsReview() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0), ("run_send_review_dry_run", 0)])
        model.runs[3].pr = RunPR(number: 25, url: "https://github.com/example/widgets/pull/25")
        await model.openDesk()
        #expect(fake.args().last == "run send-review --dry-run --json -- r1")
        let review = try #require(model.desk.review)
        #expect(review.number == 25 && review.threads == 1 && review.canSendBack && review.comments.map(\.place) == ["README.md:3"])
        #expect(model.desk.reviewError == nil && !model.desk.reviewOpen)
        model.toggleDeskReview()
        #expect(model.desk.reviewOpen)
        // The next item starts with its row closed and with no review of the last one.
        await model.openDesk("r3")
        #expect(model.desk.review == nil && !model.desk.reviewOpen)
    }

    @Test func aRunWithNoPRHasNoReviewRow() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0)])
        await model.openDesk()
        #expect(model.desk.review == nil && model.desk.reviewError == nil && fake.args().count == 2)
    }

    @Test func aReviewThatCannotBeReadSaysWhyAndKeepsTheItem() async throws {
        let (model, _) = try model([("run_diff", 0), ("run_status", 0), ("error_run_send_review_nothing", 2)])
        model.runs[3].pr = RunPR(number: 25, url: "")
        await model.openDesk()
        #expect(model.desk.review == nil && model.desk.reviewError?.contains("no review to send back") == true)
        #expect(model.desk.runID == "r1" && model.desk.diff != nil)
    }

    @Test func sendReviewBackAsksTheCoreAndShowsTheNextRun() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0), ("run_send_review_dry_run", 0),
                                       ("run_send_review", 0), ("run_list", 0)])
        model.runs[3].pr = RunPR(number: 25, url: "")
        await model.openDesk()
        await model.sendBackDeskReview()
        #expect(fake.args().dropFirst(3).first == "run send-review --json -- r1")
        #expect(model.desk.error == nil && !model.desk.busy)
    }

    @Test func sendReviewBackDoesNothingWithoutAReviewToSend() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0)])
        await model.openDesk()
        await model.sendBackDeskReview()
        #expect(fake.args().count == 2)
    }

    @Test func aMergeThatFailsKeepsTheItemAndSaysWhy() async throws {
        let (model, _) = try model([("run_diff", 0), ("run_status", 0), ("error_run_land_not_ready", 2)])
        await model.openDesk()
        await model.landDeskRun()
        #expect(model.page == .desk && model.desk.runID == "r1")
        #expect(model.desk.error?.contains("Ready to land") == true)
        #expect(!model.desk.busy)
    }

    // MARK: Shape

    /// A run in Shaping that Claude drafted, with one assumption.
    static func shaping(_ id: String = "s1") -> Run {
        var run = Self.run(id, .shaping, updated: "2026-10-27T18:30:00Z")
        run.goal = "The run page shows the plan of the run."
        run.doneWhen = [RunCheck(name: "Go tests", command: "go test ./...")]
        run.shape = RunShape(assumptions: [RunAssumption(text: "The plan shows as a numbered list.")],
                             plan: ["Read the plan.", "Show it."], size: "About 60 lines.",
                             draftedAt: "2026-10-27T18:30:00Z", repo: "repoaaaaag", base: "", link: "", model: "")
        return run
    }

    /// The steps of the draft that Claude makes now: the draft events after the last shape event. The steps of an
    /// earlier draft do not show again when you ask Claude to change it.
    @Test func theDraftStepsAreTheStepsOfTheLastDraft() {
        func event(_ id: Int, _ kind: String, _ detail: String) -> RunEvent {
            RunEvent(id: id, runID: "s1", at: "2026-10-27T18:30:00Z", kind: kind, detail: detail)
        }
        var status = RunStatus(run: Self.shaping(), events: [event(1, "draft", "Read a.go"), event(2, "shape", "Claude drafted it")])
        #expect(status.draftSteps.isEmpty)
        status.events += [event(3, "draft", "Read b.go"), event(4, "state", "shaping"), event(5, "draft", "Wrote the draft")]
        #expect(status.draftSteps.map(\.detail) == ["Read b.go", "Wrote the draft"])
    }

    /// Shape with Claude opens the desk on the new run as soon as the core records it, so you see Claude draft it.
    @Test func aShapeOpensTheDeskOnItsRunWhenTheRunShowsUp() async throws {
        let (model, _) = try model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0)])
        model.pendingShape = AppModel.PendingShape(plot: "plotaaaaae", before: Set(model.runs.map(\.id)))
        #expect(await model.openNewDraft() == false)
        var draft = Self.shaping("s9")
        draft.plotID = "plotaaaaae"
        model.runs.insert(draft, at: 0)
        #expect(await model.openNewDraft())
        #expect(model.page == .desk && model.desk.runID == "s9" && model.pendingShape == nil)
    }

    /// Nothing starts until you approve a draft, so Shaping comes first. A draft has no diff to read.
    @Test func shapingComesFirstAndShowsItsDraftWithNoDiff() async throws {
        let (model, fake) = try model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0)])
        model.runs.append(Self.shaping())
        #expect(model.deskQueue.map(\.id) == ["s1", "r1", "r3", "r2"])
        await model.openDesk()
        #expect(model.desk.runID == "s1" && model.desk.diff == nil && model.desk.error == nil)
        // The rules of the plot join the checks of the draft.
        #expect(model.desk.rules.map(\.name) == ["Short README"])
        #expect(fake.args() == ["run status --json -- s1", "rule list --json -- plotaaaaae", "show plotaaaaae --json",
                                "run limits --json"])
        // What an approval does: the limits of the run, and no setup command, as the repo has none.
        #expect(model.desk.limits?.maxTurns == 40 && model.desk.setup == nil)
    }

    /// The desk shows the setup command of the repo under If you approve, so the approval approves it.
    @Test func anApprovalApprovesTheSetupThatTheDeskShows() async throws {
        let (model, fake) = try model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0),
                                       ("run_approve", 0), ("run_list", 0)])
        model.runs.append(Self.shaping())
        await model.openDesk()
        model.desk.setup = "scripts/link-vendor.sh"
        await model.approveDeskRun()
        #expect(fake.args().dropFirst(4).first == "run approve --approve-setup --json -- s1")
    }

    /// The run of a Shaping row on Today opens at the desk, where you can approve it.
    @Test func aShapingRunOpensAtTheDesk() async throws {
        let (model, _) = try model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0)])
        model.runs.append(Self.shaping())
        await model.openRun("s1")
        #expect(model.page == .desk && model.desk.runID == "s1")
    }

    /// Only what you changed goes to the core: a goal that you set back to the draft is not sent.
    @Test func anApprovalSendsYourEditsOfTheDraft() async throws {
        let (model, fake) = try model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0), ("run_approve", 0), ("run_list", 0)])
        model.runs.append(Self.shaping())
        await model.openDesk()
        model.editDeskGoal("The run page shows the plan.")
        model.answerDeskAssumption(0, "  Bullets, not numbers. ")
        model.editDeskChecks([RunCheck(name: "All tests", command: "go test ./...")])
        await model.approveDeskRun()
        #expect(fake.args().dropFirst(4).first == "run approve --goal The run page shows the plan. "
            + "--check All tests=go test ./... --answer 1=Bullets, not numbers. --json -- s1")
        #expect(model.desk.error == nil && model.desk.shapeEdits["s1"] == nil)

        let (again, fake2) = try self.model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0), ("run_approve", 0), ("run_list", 0)])
        again.runs.append(Self.shaping())
        await again.openDesk()
        again.editDeskGoal("The run page shows the plan.")
        again.editDeskGoal("The run page shows the plan of the run.")
        again.answerDeskAssumption(0, "Bullets.")
        again.answerDeskAssumption(0, "")
        await again.approveDeskRun()
        #expect(fake2.args().dropFirst(4).first == "run approve --json -- s1")
    }

    /// A follow-up is kept until you drop it. A drop goes to the core by number from 1, and a drop that you take back is not sent.
    @Test func aDroppedFollowUpGoesToTheCoreAsADrop() async throws {
        let (model, fake) = try model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0), ("run_approve", 0), ("run_list", 0)])
        var run = Self.shaping()
        let target = RunFollowUp.Target(kind: "linear", label: "Roadmap")
        run.shape?.followUps = [RunFollowUp(title: "A picker", target: target), RunFollowUp(title: "Docs", target: target)]
        model.runs.append(run)
        await model.openDesk()
        model.setDeskFollowUp(1, kept: false)
        model.setDeskFollowUp(0, kept: false)
        model.setDeskFollowUp(0, kept: true)
        model.setDeskFollowUp(5, kept: false)
        #expect(model.desk.currentEdit.droppedFollowUps == [1])
        await model.approveDeskRun()
        #expect(fake.args().dropFirst(4).first == "run approve --drop-follow-up 2 --json -- s1")
        #expect(model.desk.shapeEdits["s1"] == nil)
    }

    /// When you remove every check of the draft, the run starts with no checks, not with the draft's.
    @Test func anApprovalWithNoChecksRemovesTheDraftedChecks() async throws {
        let (model, fake) = try model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0), ("run_approve", 0), ("run_list", 0)])
        model.runs.append(Self.shaping())
        await model.openDesk()
        model.editDeskChecks([])
        await model.approveDeskRun()
        #expect(fake.args().dropFirst(4).first == "run approve --no-checks --json -- s1")
    }

    /// When the core refuses a new setup command, the next approval approves it, as at Intake.
    @Test func anApprovalThatTheSetupStopsOffersToApproveIt() async throws {
        let (model, fake) = try model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0), ("run_approve", 0), ("run_list", 0)])
        model.runs.append(Self.shaping())
        await model.openDesk()
        model.desk.error = "the setup command of web is new or changed: make. add --approve-setup to approve it"
        #expect(model.desk.needsSetupApproval)
        await model.approveDeskRun()
        #expect(fake.args().dropFirst(4).first == "run approve --approve-setup --json -- s1")
    }

    @Test func aChangeGoesToClaudeForANewDraft() async throws {
        let (model, fake) = try model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0), ("run_shape", 0), ("run_list", 0),
                                       ("run_status", 0)])
        model.runs.append(Self.shaping())
        await model.openDesk()
        await model.redraftDeskRun(change: "  Add a check for the app. ")
        #expect(fake.args().dropFirst(4).first == "run redraft --change Add a check for the app. --json -- s1")
        #expect(model.desk.drafting.isEmpty && model.desk.error == nil)
    }

    /// Not now cancels the run, and the desk shows the next item.
    @Test func notNowCancelsTheDraft() async throws {
        let (model, fake) = try model([("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0), ("run_cancel", 0), ("run_list", 0)])
        model.runs.append(Self.shaping())
        await model.openDesk()
        await model.notNowDeskRun()
        #expect(fake.args().dropFirst(4).first == "run cancel --json -- s1")
    }

    /// Shape with Claude at Intake drafts the run, then shows the draft at the desk.
    @Test func shapeWithClaudeOpensTheDraftAtTheDesk() async throws {
        let (model, fake) = try model([("run_shape", 0), ("run_list", 0), ("run_status", 0), ("rule_list", 0), ("show", 0), ("run_limits_get", 0)])
        var draft = RunDraft(item: IntakeItem(source: "map", key: "map 12", title: "Show the plan on the run page",
                                              status: "", priority: "", labels: [],
                                              url: "/tmp/loam-contract/build/issues/12-run-page-plan.md",
                                              updatedAt: "", runID: ""))
        draft.maxTries = 4
        #expect(await model.shapeRun(plot: "plotaaaaae", draft: draft))
        #expect(fake.args().first == "run shape --title Show the plan on the run page --max-tries 4 "
            + "--ticket /tmp/loam-contract/build/issues/12-run-page-plan.md --json -- plotaaaaae")
        #expect(model.page == .desk && model.desk.runID == "runraaaaad")
    }

    // MARK: Rules

    /// Ticket 209: a note like a note on another run of the plot offers a rule, and Add rule makes it one, with
    /// the note that it came from.
    @Test func aNoteLikeAnEarlierOneOffersARule() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0), ("run_send_back_rule_offer", 0), ("run_list", 0),
                                       ("rule_add", 0)])
        var toasts: [String] = []
        model.onToast = { text, _ in toasts.append(text) }
        await model.openDesk()
        model.addDeskNote(file: nil, line: nil, text: "Keep the README short, please.")
        await model.sendBackDeskNotes()
        let offer = try #require(model.desk.ruleOffer)
        #expect(offer.plotID == "plotaaaaae" && offer.offer.earlier == "Keep the README short.")
        #expect(await model.addDeskRule(name: " Short README ", command: "test $(wc -l < README.md) -lt 40"))
        #expect(fake.args().last == "rule add --name Short README --command test $(wc -l < README.md) -lt 40 "
            + "--note Keep the README short, please. --json -- plotaaaaae")
        #expect(model.desk.ruleOffer == nil)
        #expect(toasts == ["Rule added: every run of the plot must pass \u{201C}Short README\u{201D}"])
    }

    @Test func aRuleThatTheCoreRefusesKeepsTheOfferAndSaysWhy() async throws {
        let (model, _) = try model([("run_diff", 0), ("run_status", 0), ("run_send_back_rule_offer", 0), ("run_list", 0),
                                    ("error_rule_add_no_command", 2)])
        await model.openDesk()
        model.addDeskNote(file: nil, line: nil, text: "Keep the README short, please.")
        await model.sendBackDeskNotes()
        #expect(await model.addDeskRule(name: "Short README", command: "") == false)
        #expect(model.desk.ruleOffer?.error?.contains("a name and a command") == true)
        model.dismissDeskRuleOffer()
        #expect(model.desk.ruleOffer == nil)
    }

    @Test func aSendBackWithNoOfferOffersNoRule() async throws {
        let (model, _) = try model([("run_diff", 0), ("run_status", 0), ("run_send_back", 0), ("run_list", 0)])
        await model.openDesk()
        model.addDeskNote(file: nil, line: nil, text: "Keep the README short.")
        await model.sendBackDeskNotes()
        #expect(model.desk.ruleOffer == nil && model.desk.error == nil)
    }
}

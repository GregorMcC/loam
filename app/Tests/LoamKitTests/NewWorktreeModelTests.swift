import Foundation
import Testing

@testable import LoamKit

/// Ticket 115: the state of the New worktree sheet and the words it shows. The data is made up: the example/widgets
/// repo, and issues with made-up keys.
@MainActor
@Suite struct NewWorktreeModelTests {
    let linear = PlotLink(id: "lnkaaaaaaa", label: "ENG-482 Link kinds for Figma",
                          target: "https://linear.app/example/issue/ENG-482/link-kinds-for-figma",
                          note: "", position: 0, version: 3, kind: .linear, exists: nil)
    let issue = PlotLink(id: "lnkaaaaaab", label: "#57 Fix the switcher width",
                         target: "https://github.com/example/widgets/issues/57", note: "", position: 1, version: 1,
                         kind: .github, exists: nil)
    let notion = PlotLink(id: "lnkaaaaaac", label: "Figma plan", target: "https://notion.so/Figma-plan-0123456789abcdef",
                          note: "", position: 2, version: 1, kind: .notion, exists: nil)

    func plot(repos: [Repo]? = nil) -> Plot {
        Plot(id: "plotaaaaab", name: "Widgets", what: "", why: "", whereItStands: "", createdAt: "2026-01-01T00:00:00Z",
             archived: false, links: [linear, issue, notion],
             repos: repos ?? [Repo(id: "repoaaaaaa", path: "/tmp/example/widgets", note: "", main: true, version: 1),
                              Repo(id: "repoaaaaab", path: "/tmp/example/widgets-api", note: "", main: false, version: 1)],
             versions: [:], revision: 1)
    }

    func check(_ name: String, valid: Bool = true, error: String? = nil, worktree: Bool = false, branch: Bool = false,
               defaultBase: String = "origin/main", bases: [String] = ["origin/main", "origin/develop", "main"],
               seed: String? = nil) -> WorktreeCheck {
        WorktreeCheck(name: name, folder: "widgets-\(name)", validName: valid, nameError: error, worktreeExists: worktree,
                      branchExists: branch, defaultBase: defaultBase, bases: bases, seedLine: valid ? (seed ?? "- widgets-\(name)") : nil)
    }

    /// An open sheet whose plot is read.
    func open(from link: PlotLink? = nil) -> NewWorktreeModel {
        let model = NewWorktreeModel()
        model.open(plot: "plotaaaaab", link: link)
        model.loaded(plot())
        return model
    }

    /// Gives the answer of the check for the fields as they are now.
    func answer(_ model: NewWorktreeModel, _ result: WorktreeCheck) {
        model.checked(result, stamp: model.stamp)
    }

    // MARK: From a link

    @Test func startWorkFromALinearIssueFillsTheSheet() {
        let model = open(from: linear)
        let content = NewWorktreeContent(model)
        #expect(model.branch == "eng-482-link-kinds-for-figma")
        #expect(model.goal == "Link kinds for Figma")
        #expect(model.linkChoice == .plot(linear.id))
        #expect(content.linkCard?.label == "ENG-482 Link kinds for Figma")
        #expect(content.linkCard?.note == "Loam does not copy the issue. The session reads it through its Linear connector.")
        #expect(content.linkTitle == "ENG-482 Link kinds for Figma")
        #expect(content.branchNote == .init(text: "From the issue key and the link label.", tone: .hint))
        #expect(content.goalNote == .init(text: "One line. You can leave it empty.", tone: .hint))
        #expect(content.repoName == "widgets" && content.repoIsMain)
    }

    @Test func startWorkFromAGitHubIssueNamesTheGitHubConnector() {
        let model = open(from: issue)
        #expect(model.branch == "57-fix-the-switcher-width")
        #expect(model.goal == "Fix the switcher width")
        #expect(NewWorktreeContent(model).linkCard?.note
                == "Loam does not copy the issue. The session reads it through its GitHub connector.")
    }

    @Test func thePlusStartsEmptyWithNoCard() {
        let model = open()
        let content = NewWorktreeContent(model)
        #expect(model.branch.isEmpty && model.goal.isEmpty)
        #expect(model.linkChoice == .none)
        #expect(content.linkCard == nil)
        #expect(content.linkTitle == "None")
        #expect(content.branchNote == nil)
        #expect(model.branchState == .empty)
        #expect(!model.canStart)
    }

    @Test func theMainRepoIsTheDefaultWhateverItsPlace() {
        let model = NewWorktreeModel()
        model.open(plot: "plotaaaaab", link: nil)
        model.loaded(plot(repos: [Repo(id: "repoaaaaab", path: "/tmp/example/widgets-api", note: "", main: false, version: 1),
                                  Repo(id: "repoaaaaaa", path: "/tmp/example/widgets", note: "", main: true, version: 1)]))
        #expect(model.repoID == "repoaaaaaa")
        #expect(model.request?.repo == "repoaaaaaa")
    }

    @Test func theLinkItemsAreTheLinksOfThePlot() {
        let content = NewWorktreeContent(open())
        #expect(content.linkItems.map(\.title) == ["ENG-482 Link kinds for Figma", "#57 Fix the switcher width", "Figma plan"])
    }

    // MARK: Fields that you typed

    @Test func aBranchThatYouTypedStaysWhenTheLinkChanges() {
        let model = open(from: linear)
        model.setBranch("my-own-branch")
        model.chooseLink(.plot(issue.id))
        #expect(model.branch == "my-own-branch")
        // The goal was not typed, so it follows the link.
        #expect(model.goal == "Fix the switcher width")
    }

    @Test func aFieldThatYouEmptyTakesTheLinkAgain() {
        let model = open(from: linear)
        model.setBranch("my-own-branch")
        model.setBranch("")
        #expect(model.branch == "")
        model.chooseLink(.plot(issue.id))
        #expect(model.branch == "57-fix-the-switcher-width")
    }

    @Test func noLinkEmptiesTheFieldsThatCameFromTheLink() {
        let model = open(from: linear)
        model.setGoal("Make Figma a kind")
        model.chooseLink(.none)
        #expect(model.branch == "")
        #expect(model.goal == "Make Figma a kind")
    }

    @Test func aLinkThatIsNotAnIssueGivesNoNameAndNoGoal() {
        let model = open()
        model.chooseLink(.plot(notion.id))
        #expect(model.branch == "" && model.goal == "")
        #expect(model.request?.link == notion.id)
    }

    @Test func aPastedIssueGivesTheKeyAsTheBranch() {
        let model = open()
        model.chooseLink(.pasted)
        model.setPastedURL("https://github.com/example/widgets/issues/57")
        #expect(model.branch == "57")
        #expect(model.request?.link == "https://github.com/example/widgets/issues/57")
        #expect(NewWorktreeContent(model).linkNote == .init(text: NewWorktreeContent.pasteHint, tone: .hint))
        #expect(NewWorktreeContent(model).branchNote == .init(text: "From the issue key.", tone: .hint))
    }

    @Test func aPastedUrlThatIsNotAnIssueBlocksStart() {
        let model = open()
        model.chooseLink(.pasted)
        model.setBranch("fix-it")
        model.setPastedURL("https://example.com/not-an-issue")
        answer(model, check("fix-it"))
        #expect(model.pastedURLIsWrong)
        #expect(!model.canStart)
        #expect(model.request?.link == nil)
        #expect(NewWorktreeContent(model).linkNote == .init(text: NewWorktreeContent.pasteProblem, tone: .problem))
        // An empty field is no link, so it blocks nothing.
        model.setPastedURL("")
        answer(model, check("fix-it"))
        #expect(!model.pastedURLIsWrong && model.canStart)
    }

    // MARK: The check

    @Test func theBranchStatesFollowTheAnswerOfTheCheck() {
        let model = open()
        model.setBranch("fix-login")
        #expect(model.branchState == .checking)
        #expect(!model.canStart)

        answer(model, check("fix-login"))
        #expect(model.branchState == .new)
        #expect(model.canStart)
        #expect(NewWorktreeContent(model).baseApplies)

        answer(model, check("fix-login", branch: true))
        #expect(model.branchState == .exists)
        #expect(model.canStart)
        let content = NewWorktreeContent(model)
        #expect(content.branchNote == .init(text: "A branch with this name exists. Loam uses it as it is.", tone: .problem))
        #expect(!content.baseApplies)

        answer(model, check("fix login", valid: false, error: "\"fix login\" is not a good worktree name. Use a branch name"))
        #expect(model.branchState == .invalid("\"fix login\" is not a good worktree name. Use a branch name"))
        #expect(!model.canStart)
        #expect(NewWorktreeContent(model).branchNote
                == .init(text: "\"fix login\" is not a good worktree name. Use a branch name.", tone: .problem))

        answer(model, check("fix-login", worktree: true))
        #expect(model.branchState == .taken("widgets-fix-login"))
        #expect(!model.canStart)
        #expect(NewWorktreeContent(model).branchNote?.text == "A worktree or a folder named widgets-fix-login exists already.")

        model.checkFailed("No link has the ID lnkaaaaaaa", stamp: model.stamp)
        #expect(model.branchState == .failed("No link has the ID lnkaaaaaaa"))
        #expect(!model.canStart)
        #expect(NewWorktreeContent(model).branchNote == .init(text: "No link has the ID lnkaaaaaaa.", tone: .problem))
    }

    @Test func aTypedLetterMakesTheOldAnswerOld() {
        let model = open()
        model.setBranch("fix-logi")
        answer(model, check("fix-logi"))
        #expect(model.canStart)
        model.setBranch("fix-login")
        #expect(model.branchState == .checking)
        #expect(!model.canStart)
    }

    @Test func anAnswerForOlderFieldsIsDropped() {
        let model = open()
        model.setBranch("fix-logi")
        let old = model.stamp
        model.setBranch("fix-login")
        model.checked(check("fix-logi", branch: true), stamp: old)
        model.checkFailed("late", stamp: old)
        #expect(model.branchState == .checking)
        #expect(model.bases.isEmpty)
    }

    // MARK: Goal and link keep the answer for the branch (ticket 115, round 2)

    @Test func aGoalChangeKeepsTheBranchAnswerAndStart() {
        let model = open(from: linear)
        answer(model, check("eng-482-link-kinds-for-figma"))
        #expect(model.canStart)
        model.setGoal("Another goal")
        #expect(model.branchState == .new)
        #expect(model.canStart, "Start stays on while the seed line is checked again")
    }

    @Test func aLinkChangeKeepsTheAnswerWhenTheBranchStays() {
        let model = open()
        model.setBranch("fix-login")
        answer(model, check("fix-login"))
        model.chooseLink(.plot(linear.id))
        #expect(model.branch == "fix-login")
        #expect(model.branchState == .new && model.canStart)
    }

    @Test func aLinkThatChangesTheBranchChecksTheNameAgain() {
        let model = open(from: linear)
        answer(model, check(model.branch))
        model.chooseLink(.plot(issue.id))
        #expect(model.branch == "57-fix-the-switcher-width")
        #expect(model.branchState == .checking)
        #expect(!model.canStart)
    }

    @Test func aFailureForOlderFieldsIsNotShownForNewOnes() {
        let model = open()
        model.setBranch("fix-login")
        model.checkFailed("No link has the ID lnkaaaaaaa", stamp: model.stamp)
        #expect(model.branchState == .failed("No link has the ID lnkaaaaaaa"))
        // The failure may be about the link or the goal, so it waits for a new check.
        model.setGoal("Fix it")
        #expect(model.branchState == .checking)
    }

    @Test func anAnswerForAnOlderGoalStillCountsAndAnOlderNameDoesNot() {
        let model = open()
        model.setBranch("fix-login")
        let old = model.stamp
        model.setGoal("Fix it")
        model.checked(check("fix-login", seed: "- widgets-fix-login: Fix it"), stamp: old)
        #expect(model.branchState == .new)
        #expect(model.seedLine == "- widgets-fix-login: Fix it")
        model.setBranch("fix-logout")
        model.checked(check("fix-login"), stamp: old)
        #expect(model.branchState == .checking)
    }

    @Test func aNameThatStartsWithAHyphenIsRefusedWithTheWordsOfTheCore() {
        let model = open()
        model.setBranch("-x")
        let words = "\"-x\" is not a good worktree name. Use a branch name"
        #expect(model.branchState == .invalid(words))
        #expect(!model.canStart)
        #expect(NewWorktreeContent(model).branchNote == .init(text: words + ".", tone: .problem))
        // Even an answer that says the name is good does not turn Start on.
        answer(model, check("-x"))
        #expect(!model.canStart)
        model.setBranch(" -h")
        #expect(model.branchState == .invalid("\"-h\" is not a good worktree name. Use a branch name"))
    }

    @Test func aStartThatMustWaitIsQueuedAndAnyInputTakesItBack() {
        let model = open(from: linear)
        #expect(model.branchState == .checking)
        #expect(model.queueStart())
        #expect(model.startQueued)
        model.setGoal("Another goal")
        #expect(!model.startQueued)
        // Nothing to wait for: an empty name, a bad name and a wrong URL are in the notes already.
        let plain = open()
        #expect(!plain.queueStart())
        plain.setBranch("a b")
        answer(plain, check("a b", valid: false, error: "bad"))
        #expect(!plain.queueStart() && !plain.startQueued)
    }

    @Test func everyChangeOfAFieldAsksForACheck() {
        let model = NewWorktreeModel()
        var asked = 0
        model.onInput = { asked += 1 }
        model.open(plot: "plotaaaaab", link: linear)
        model.loaded(plot())
        #expect(asked == 1)
        model.setBranch("x")
        model.setGoal("y")
        model.chooseBase("main")
        model.chooseRepo("repoaaaaab")
        model.chooseLink(.none)
        model.setPastedURL("z")
        #expect(asked == 7)
        // The same value is no change.
        model.setBranch("x")
        model.chooseBase(nil)
        #expect(asked == 7)
    }

    @Test func theRequestHasTheTrimmedFieldsAndTheChosenBase() throws {
        let model = open(from: linear)
        model.setBranch("  eng-482-figma ")
        model.setGoal("  Make Figma a kind  ")
        model.chooseBase("origin/develop")
        let request = try #require(model.request)
        #expect(request == .init(plot: "plotaaaaab", repo: "repoaaaaaa", name: "eng-482-figma", base: "origin/develop",
                                 goal: "Make Figma a kind", link: linear.id))
        model.setGoal("   ")
        #expect(model.request?.goal == nil)
    }

    @Test func aBranchThatExistsTakesNoBase() {
        let model = open()
        model.setBranch("link-labels")
        model.chooseBase("origin/develop")
        answer(model, check("link-labels", branch: true))
        #expect(model.request?.base == "origin/develop")
        #expect(model.startRequest?.base == nil)
        // A new branch takes the base that you chose.
        model.setBranch("link-labels-2")
        answer(model, check("link-labels-2"))
        #expect(model.startRequest?.base == "origin/develop")
    }

    @Test func noRequestUntilThePlotIsRead() {
        let model = NewWorktreeModel()
        model.open(plot: "plotaaaaab", link: linear)
        #expect(model.request == nil)
        #expect(model.phase == .loading)
        model.loaded(plot())
        #expect(model.request != nil)
    }

    @Test func aPlotWithNoRepoCannotStart() {
        let model = NewWorktreeModel()
        model.open(plot: "plotaaaaab", link: linear)
        model.loaded(plot(repos: []))
        #expect(model.phase == .failed("The plot has no repo. Add a repo first."))
        #expect(model.request == nil)
        #expect(!model.canStart)
    }

    @Test func aPlotWithNoRepoTakesBackAStartThatWaitedForIt() {
        let model = NewWorktreeModel()
        model.open(plot: "plotaaaaab", link: linear)
        #expect(model.queueStart(), "Return while the plot is read")
        #expect(NewWorktreeContent(model).primaryTitle == "Starting\u{2026}")
        model.loaded(plot(repos: []))
        #expect(!model.startQueued, "nothing can start in a plot with no repo")
        #expect(NewWorktreeContent(model).primaryTitle != "Starting\u{2026}", "the button does not say Starting beside the problem")
        #expect(model.takeQueuedStart() == false)
    }

    // MARK: Repo and base

    @Test func theMainRepoIsTheDefaultAndOtherReposAreNamedByFolder() {
        let content = NewWorktreeContent(open())
        #expect(content.repos == [.init(id: "repoaaaaaa", name: "widgets", isMain: true),
                                  .init(id: "repoaaaaab", name: "widgets-api", isMain: false)])
    }

    @Test func aPlotWithNoMainRepoTakesTheFirst() {
        let model = NewWorktreeModel()
        model.open(plot: "plotaaaaab", link: nil)
        model.loaded(plot(repos: [Repo(id: "repoaaaaab", path: "/tmp/example/widgets-api", note: "", main: false, version: 1)]))
        #expect(model.repoID == "repoaaaaab")
    }

    @Test func anotherRepoHasItsOwnBases() {
        let model = open()
        model.setBranch("fix-login")
        answer(model, check("fix-login"))
        model.chooseBase("origin/develop")
        #expect(model.bases == ["origin/main", "origin/develop", "main"])
        model.chooseRepo("repoaaaaab")
        #expect(model.baseChoice == nil)
        #expect(model.bases.isEmpty)
        #expect(model.request?.repo == "repoaaaaab")
    }

    @Test func theBaseMenuHasTheDefaultFirst() {
        let model = open()
        model.setBranch("fix-login")
        answer(model, check("fix-login"))
        var content = NewWorktreeContent(model)
        #expect(content.baseTitle == "origin/main")
        #expect(content.baseItems == [.init(title: "origin/main", value: nil), .init(title: "origin/develop", value: "origin/develop"),
                                      .init(title: "main", value: "main")])
        model.chooseBase("main")
        content = NewWorktreeContent(model)
        #expect(content.baseTitle == "main")
    }

    @Test func aRepoWithNoDefaultBaseOffersTheDefaultOfOrigin() {
        let model = open()
        model.setBranch("fix-login")
        answer(model, check("fix-login", defaultBase: "", bases: ["main", "develop"]))
        let content = NewWorktreeContent(model)
        #expect(content.baseTitle == "Default branch of origin")
        #expect(content.baseItems == [.init(title: "Default branch of origin", value: nil), .init(title: "main", value: "main"),
                                      .init(title: "develop", value: "develop")])
    }

    // MARK: Goal

    @Test func aLongGoalWarnsAndStillStarts() {
        let model = open()
        model.setBranch("fix-login")
        model.setGoal(Array(repeating: "word", count: 24).joined(separator: " "))
        answer(model, check("fix-login"))
        #expect(NewWorktreeContent(model).goalNote
                == .init(text: "The goal has 24 words. The soft limit is 20 words.", tone: .warning))
        #expect(model.canStart)
    }

    // MARK: Seed

    @Test func theSeedLineIsTheLineOfTheLastAnswer() {
        let model = open()
        model.setBranch("fix-login")
        #expect(NewWorktreeContent(model).seedText == NewWorktreeContent.seedWaiting)
        answer(model, check("fix-login", seed: "- widgets-fix-login: Fix it (from origin/main)"))
        #expect(NewWorktreeContent(model).seedText == "- widgets-fix-login: Fix it (from origin/main)")
        model.setBranch("a b")
        answer(model, check("a b", valid: false, error: "bad"))
        #expect(NewWorktreeContent(model).seedText == NewWorktreeContent.seedWaiting)
    }

    /// The line names the branch, the repo and the base of its answer. A change of one of them makes the line old, so the
    /// sheet waits for the next answer and never shows the line of another branch, repo or base.
    @Test func theSeedLineOfAnOldNameRepoOrBaseDoesNotShow() {
        let model = open()
        let line = "- widgets-fix-login: Fix it (from origin/main)"
        func good() {
            answer(model, check(model.branch, seed: line))
            #expect(NewWorktreeContent(model).seedText == line)
        }
        model.setBranch("fix-login")
        good()
        model.chooseRepo("repoaaaaab")
        #expect(NewWorktreeContent(model).seedText == NewWorktreeContent.seedWaiting, "the line of the other repo shows")
        good()
        model.chooseBase("origin/develop")
        #expect(NewWorktreeContent(model).seedText == NewWorktreeContent.seedWaiting, "the line of the other base shows")
        good()
        model.setBranch("fix-login-2")
        #expect(NewWorktreeContent(model).seedText == NewWorktreeContent.seedWaiting, "the line of the other name shows")
        good()
        // A name that starts with a hyphen never goes to the core, so no answer replaces the line.
        model.setBranch("-fix-login")
        #expect(NewWorktreeContent(model).seedText == NewWorktreeContent.seedWaiting, "the line of a good name shows for a bad one")
        model.setBranch("fix-login")
        good()
        // A goal is not a question about the branch: the line stands until the next answer (115 decision 21).
        model.setGoal("Fix the login form")
        #expect(NewWorktreeContent(model).seedText == line)
    }

    // MARK: Start

    @Test func startLocksTheSheetAndAFailureShowsTheMessage() {
        let model = open()
        model.setBranch("fix-login")
        answer(model, check("fix-login"))
        model.beginStarting()
        #expect(model.isStarting && !model.canStart)
        #expect(NewWorktreeContent(model).primaryTitle == "Starting\u{2026}")
        model.startFailed("git could not make the worktree")
        #expect(!model.isStarting && model.canStart)
        #expect(model.startError == "git could not make the worktree")
        #expect(NewWorktreeContent(model).primaryTitle == "Start session")
        // A change of a field clears the message.
        model.setGoal("x")
        #expect(model.startError == nil)
    }

    @Test func aNewOpenStartsFromNothing() {
        let model = open(from: linear)
        model.setBranch("mine")
        model.chooseBase("main")
        model.showsSeed = true
        let count = model.openCount
        model.open(plot: "plotaaaaab", link: nil)
        #expect(model.openCount == count + 1)
        #expect(model.branch == "" && model.goal == "" && model.baseChoice == nil && !model.showsSeed)
        #expect(model.linkChoice == .none && model.startLink == nil && model.repos.isEmpty)
    }

    // MARK: Tab order (ticket 123)

    @Test func theStopsOfTabAreTheFieldsInTheOrderThatTheSheetDrawsThem() {
        let model = open()
        #expect(NewWorktreeContent.fields(of: model) == [.branch, .goal])
        model.chooseLink(.pasted)
        #expect(NewWorktreeContent.fields(of: model) == [.branch, .goal, .url], "the URL field is under the Link popup")
        model.chooseLink(.plot(linear.id))
        #expect(NewWorktreeContent.fields(of: model) == [.branch, .goal])
    }

    @Test func noFieldIsAStopWhileTheWorktreeIsMadeOrWhenThePlotFailed() {
        let starting = open()
        starting.beginStarting()
        #expect(NewWorktreeContent.fields(of: starting).isEmpty)
        starting.startFailed("The worktree was not made.")
        #expect(NewWorktreeContent.fields(of: starting) == [.branch, .goal])

        let failed = NewWorktreeModel()
        failed.open(plot: "plotaaaaab", link: nil)
        #expect(NewWorktreeContent.fields(of: failed) == [.branch, .goal], "the fields show while the plot is read")
        failed.failedToLoad("The plot is gone.")
        #expect(NewWorktreeContent.fields(of: failed).isEmpty)
    }

    @Test func theSheetReportsItsOpensAndCloses() {
        let model = NewWorktreeModel()
        var events: [Bool] = []
        model.onOpenChange = { events.append($0) }
        model.open(plot: "plotaaaaab", link: nil)
        model.open(plot: "plotaaaaab", link: linear)
        model.close()
        model.close()
        #expect(events == [true, false])
        #expect(!model.isOpen)
    }
}

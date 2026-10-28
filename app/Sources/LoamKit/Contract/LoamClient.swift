import Foundation

/// The app's only path to the core. It runs the `loam` binary, reads stdout and the exit code,
/// and never parses message text. Every call is async and runs the process off the main actor.
public struct LoamClient: Sendable {
    public enum TextField: String, Sendable {
        case name, what, why
        case whereItStands = "where-it-stands"
    }

    /// The binary that `loam_path` in the settings file gives, or the one that Automatic finds.
    public static var defaultBinary: URL {
        URL(fileURLWithPath: LoamBinary.resolve(setting: SettingsFile().read().settings.loamPath).path)
    }

    public let binary: URL
    /// The contract version this client accepts. Tests change it.
    public let expectedContract: Int
    /// Extra environment for the process, such as `LOAM_HOME`.
    public let environment: [String: String]

    public init(
        binary: URL = LoamClient.defaultBinary,
        expectedContract: Int = LoamKit.contractVersion,
        environment: [String: String] = [:]
    ) {
        self.binary = binary
        self.expectedContract = expectedContract
        self.environment = environment
    }

    // MARK: Launch checks

    public func version() async throws -> VersionInfo {
        try await read(["version"])
    }

    /// Throws `LoamError.contractVersionMismatch` when the core reads another contract version.
    @discardableResult
    public func checkContract() async throws -> VersionInfo {
        let info = try await version()
        guard info.contractVersion == expectedContract else {
            throw LoamError.contractVersionMismatch(core: info.contractVersion, app: expectedContract)
        }
        return info
    }

    public func setupCheck() async throws -> SetupCheck {
        try await read(["setup", "--check"])
    }

    // MARK: Reads

    public func list() async throws -> [PlotSummary] {
        try await read(["list"])
    }

    /// Only the archived plots, in the stored order.
    public func listArchived() async throws -> [PlotSummary] {
        try await read(["list", "--archived"])
    }

    public func show(plot: String) async throws -> Plot {
        try await read(["show", plot])
    }

    /// The change log, oldest first. Without `plot` it covers every plot.
    public func changes(plot: String? = nil, since: Int? = nil) async throws -> [Change] {
        var args = ["changes"]
        if let plot { args.append(plot) }
        if let since { args += ["--since", String(since)] }
        let response: ChangesResponse = try await read(args)
        return response.changes
    }

    public func sessions(plot: String? = nil) async throws -> [SessionRecord] {
        try await read(["sessions"] + (plot.map { [$0] } ?? []))
    }

    public func export(includeChanges: Bool = false) async throws -> ExportResponse {
        try await read(["export"] + (includeChanges ? ["--changes"] : []))
    }

    /// The worktrees of one plot, or of every plot, with their checks. Oldest first. With `refresh`,
    /// the core asks GitHub for the ship state first. That takes seconds and writes only the PR cache,
    /// not `loam.changed`, so the answer is the only way the app learns of it. Without `refresh`, the
    /// core reads the cache.
    public func worktrees(plot: String? = nil, refresh: Bool = false) async throws -> [WorktreeStatus] {
        try await read(["worktree", "list"] + (plot.map { [$0] } ?? []) + (refresh ? ["--refresh"] : []))
    }

    /// `loam worktree list <plot> --refresh --worktree <id>`: asks GitHub about one worktree (an ID).
    /// The answer is still the whole list of the plot.
    public func refreshWorktree(plot: String, worktree: String) async throws -> [WorktreeStatus] {
        try await read(["worktree", "list", plot, "--refresh", "--worktree", worktree])
    }

    /// `loam run list [<plot>]`: the runs of a plot, or of every plot, newest first.
    public func runs(plot: String? = nil) async throws -> [Run] {
        try await read(["run", "list"] + (plot.map { [$0] } ?? []))
    }

    /// `loam run status <run>`: a run and its history.
    public func runStatus(_ id: String) async throws -> RunStatus {
        try await read(["run", "status"], positionals: [id])
    }

    // MARK: Writes (all with `--actor app`)

    public func new(name: String) async throws -> Plot {
        try await write(["new", name])
    }

    /// Sets a text field. The text goes on stdin, so it can hold any characters.
    public func set(plot: String, field: TextField, text: String, expect: [String: Int] = [:]) async throws -> Plot {
        try await write(["set", plot, field.rawValue, "-"] + expectArgs(expect), stdin: text)
    }

    /// An empty label leaves it out, so the core takes the label from the target.
    public func linkAdd(plot: String, label: String, target: String, note: String? = nil, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["link", "add", plot] + (label.isEmpty ? [] : [label]) + [target] + noteArg(note) + expectArgs(expect))
    }

    public func linkEdit(plot: String, link: String, label: String? = nil, target: String? = nil, note: String? = nil, expect: [String: Int] = [:]) async throws -> WriteResult {
        var args = ["link", "edit", plot, link]
        if let label { args += ["--label", label] }
        if let target { args += ["--target", target] }
        return try await write(args + noteArg(note) + expectArgs(expect))
    }

    public func linkRemove(plot: String, link: String, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["link", "rm", plot, link] + expectArgs(expect))
    }

    public func repoAdd(plot: String, path: String, note: String? = nil, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["repo", "add", plot, path] + noteArg(note) + expectArgs(expect))
    }

    /// `afterMerge` sets what the app does when GitHub merged the PR of a worktree of the repo (ticket 113).
    public func repoEdit(plot: String, repo: String, note: String? = nil, afterMerge: AfterMerge? = nil,
                         expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["repo", "edit", plot, repo] + noteArg(note) + (afterMerge.map { ["--after-merge", $0.rawValue] } ?? [])
            + expectArgs(expect))
    }

    public func repoMain(plot: String, repo: String, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["repo", "main", plot, repo] + expectArgs(expect))
    }

    /// Removing the main repo needs `newMain`, because `--json` cannot ask.
    public func repoRemove(plot: String, repo: String, newMain: String? = nil, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["repo", "rm", plot, repo] + (newMain.map { ["--main", $0] } ?? []) + expectArgs(expect))
    }

    /// `loam worktree new`. `repo` is a repo ID or a path. `goal` and `link` are as in `worktreeCheck`. The flags come
    /// first and `--` comes before the plot, the repo and the name: the name is typed text, so "-h" is a name and not
    /// the help flag.
    public func worktreeNew(plot: String, repo: String, name: String, base: String? = nil, goal: String? = nil,
                            link: String? = nil) async throws -> WorktreeNewResult {
        try await write(["worktree", "new"] + newArgs(base: base, goal: goal, link: link), positionals: [plot, repo, name])
    }

    /// `loam worktree new --dry-run`: changes nothing and never asks origin, so the New worktree sheet can run it as you
    /// type. A name that is not a good branch name is a result. A repo, a link or a base that `worktreeNew` would refuse
    /// throws, as `worktreeNew` does. `link` is the ID of a link of the plot, or the URL of an issue.
    public func worktreeCheck(plot: String, repo: String, name: String, base: String? = nil, goal: String? = nil,
                              link: String? = nil) async throws -> WorktreeCheck {
        try await read(["worktree", "new", "--dry-run"] + newArgs(base: base, goal: goal, link: link), positionals: [plot, repo, name])
    }

    /// `loam worktree edit --goal`: sets the goal of a worktree as one change. An empty goal clears it. `expect` is the
    /// version of the goal that you read (`Worktree.version`), so a goal that changed meanwhile throws `.stale`.
    public func worktreeEdit(plot: String, worktree: String, goal: String, expect: Int? = nil) async throws -> WorktreeEditResult {
        try await write(["worktree", "edit", plot, worktree, "--goal", goal]
            + (expect.map { ["--expect", "worktree:\(worktree)=\($0)"] } ?? []))
    }

    /// The flags of `worktree new`, with and without `--dry-run`. A goal or a link that is empty is left out.
    private func newArgs(base: String?, goal: String?, link: String?) -> [String] {
        (base.map { ["--base", $0] } ?? []) + ((goal?.isEmpty ?? true) ? [] : ["--goal", goal!])
            + ((link?.isEmpty ?? true) ? [] : ["--link", link!])
    }

    /// `loam worktree rm`. `openPanes` are the folders of the panes that are open or saved, so the core
    /// can refuse. `force` skips the checks for changes and unpushed commits, never the pane check.
    /// `dryRun` checks the work, changes nothing, and does not check the panes (ticket 113).
    public func worktreeRemove(plot: String, worktree: String, force: Bool = false, dryRun: Bool = false,
                               openPanes: [String] = []) async throws -> WorktreeRmResult {
        try await write(["worktree", "rm", plot, worktree] + (force ? ["--force"] : []) + (dryRun ? ["--dry-run"] : [])
            + openPanes.flatMap { ["--open-pane", $0] })
    }

    /// `loam worktree land`: merges the PR of the worktree on GitHub, then deletes the branch on GitHub
    /// and removes the worktree. `method` nil takes the default method of the repo. `openPanes` are as in
    /// `worktreeRemove`. With `dryRun`, the core changes nothing and returns the plan, also when a check
    /// blocks. Without it, a check that blocks throws `.notReady`. Throws `.ghUnavailable` when gh cannot
    /// act on the repo. `head` is the PR head that the caller looked at (`--head`): a land that merges throws
    /// `.notReady` when GitHub has another head, so a commit that came after the plan is never merged unseen.
    public func worktreeLand(plot: String, worktree: String, method: MergeMethod? = nil, auto: Bool = false,
                             keepWorktree: Bool = false, keepRemoteBranch: Bool = false, dryRun: Bool = false,
                             head: String? = nil, openPanes: [String] = []) async throws -> LandResult {
        var args = ["worktree", "land", plot, worktree]
        if let method { args += ["--method", method.rawValue] }
        if auto { args.append("--auto") }
        if keepWorktree { args.append("--keep-worktree") }
        if keepRemoteBranch { args.append("--keep-remote-branch") }
        if dryRun { args.append("--dry-run") }
        if let head { args += ["--head", head] }
        return try await write(args + openPanes.flatMap { ["--open-pane", $0] })
    }

    /// `loam worktree rerun`: runs the failed GitHub Actions runs of the PR of the worktree again.
    public func worktreeRerun(plot: String, worktree: String) async throws -> RerunResult {
        try await write(["worktree", "rerun", plot, worktree])
    }

    /// `loam worktree update`: brings the PR of the worktree up to date with its base branch on GitHub,
    /// then fetches the branch.
    public func worktreeUpdate(plot: String, worktree: String) async throws -> UpdateResult {
        try await write(["worktree", "update", plot, worktree])
    }

    /// `loam archive`. Does nothing when the plot is archived already. It ends no session: the app does that.
    public func archive(plot: String) async throws -> Plot {
        try await write(["archive", plot])
    }

    /// `loam unarchive`. The plot goes back to its old place in the order.
    public func unarchive(plot: String) async throws -> Plot {
        try await write(["unarchive", plot])
    }

    /// `loam delete`. Works only on an archived plot with no worktrees. There is no undo.
    public func delete(plot: String) async throws -> DeleteResult {
        try await write(["delete", plot])
    }

    /// `loam open`. `link` is a link ID or an exact label. A missing local path throws `.linkPathMissing`.
    public func open(plot: String, link: String) async throws -> OpenResult {
        try await write(["open", plot, link])
    }

    /// Moves a plot in the plot order. `position` starts at 1.
    public func move(plot: String, position: Int) async throws -> MoveResult {
        try await write(["move", plot, String(position)])
    }

    /// Throws `LoamError.undoClash` when a later change touched the same items.
    /// Call again with `overwrite: true` to write anyway.
    public func undo(changeID: Int, overwrite: Bool = false) async throws -> UndoResult {
        try await write(["undo", String(changeID)] + (overwrite ? ["--overwrite"] : []))
    }

    // MARK: Plumbing

    private func expectArgs(_ expect: [String: Int]) -> [String] {
        expect.sorted { $0.key < $1.key }.flatMap { ["--expect", "\($0.key)=\($0.value)"] }
    }

    private func noteArg(_ note: String?) -> [String] {
        note.map { ["--note", $0] } ?? []
    }

    /// `positionals` are the arguments that are not flags. They go after `--`, so none of them can be read as a flag.
    /// `loam run start <plot>`: starts a run in a new worktree of the plot's main repo. Like the other run commands, it is
    /// not in the change log, so it takes no `--actor`.
    public func runStart(plot: String, draft: RunDraft) async throws -> RunStartResult {
        var args = ["run", "start", "--title", draft.title, "--goal", draft.goal]
        for check in draft.checks { args += ["--check", "\(check.name)=\(check.command)"] }
        args += ["--max-tries", String(draft.maxTries)]
        if let repo = draft.repo { args += ["--repo", repo] }
        if let base = draft.base { args += ["--base", base] }
        if let link = draft.link { args += ["--link", link] }
        if let ticket = draft.ticket { args += ["--ticket", ticket] }
        args += Self.modelArgs(model: draft.model, effort: draft.effort)
        if draft.approveSetup { args.append("--approve-setup") }
        return try await read(args, positionals: [plot])
    }

    /// `--model` and `--effort` for the ones that are set. An empty one leaves the choice to the plot default.
    static func modelArgs(model: String, effort: String) -> [String] {
        (model.isEmpty ? [] : ["--model", model]) + (effort.isEmpty ? [] : ["--effort", effort])
    }

    /// `loam run shape <plot>`: records a run in Shaping, and Claude drafts its goal, checks, assumptions and plan
    /// (ticket 207). Nothing starts until you approve the run. The command returns when the draft is done or failed.
    public func runShape(plot: String, draft: RunDraft) async throws -> RunResult {
        var args = ["run", "shape", "--title", draft.title, "--max-tries", String(draft.maxTries)]
        if draft.split {
            args.append("--split")
        } else if let repo = draft.repo {
            args += ["--repo", repo]
        }
        if let base = draft.base { args += ["--base", base] }
        if let link = draft.link { args += ["--link", link] }
        if let ticket = draft.ticket { args += ["--ticket", ticket] }
        args += Self.modelArgs(model: draft.model, effort: draft.effort)
        return try await read(args, positionals: [plot])
    }

    /// `loam run redraft <run>`: Claude drafts the run again, with your change to the last draft.
    public func runRedraft(_ id: String, change: String) async throws -> RunResult {
        try await read(["run", "redraft", "--change", change], positionals: [id])
    }

    /// `loam run approve <run>`: starts a run in Shaping with its draft and your edits. A nil goal or nil checks
    /// keep the draft, and empty checks remove the draft's. `answers` maps the index of an assumption, from 0, to what you want instead.
    public func runApprove(_ id: String, goal: String? = nil, checks: [RunCheck]? = nil, answers: [Int: String] = [:],
                           approveSetup: Bool = false) async throws -> RunStartResult {
        var args = ["run", "approve"]
        if let goal { args += ["--goal", goal] }
        if checks?.isEmpty == true { args.append("--no-checks") }
        for check in checks ?? [] { args += ["--check", "\(check.name)=\(check.command)"] }
        for (index, answer) in answers.sorted(by: { $0.key < $1.key }) { args += ["--answer", "\(index + 1)=\(answer)"] }
        if approveSetup { args.append("--approve-setup") }
        return try await read(args, positionals: [id])
    }

    /// `loam recurring list [<plot>]`: the recurring runs of a plot, or of every plot (ticket 208).
    public func recurringList(plot: String? = nil) async throws -> [Recurring] {
        let list: RecurringList = try await read(["recurring", "list"], positionals: plot.map { [$0] } ?? [])
        return list.recurring
    }

    /// `loam recurring add <plot>`: a run that starts on a timetable.
    public func recurringAdd(plot: String, draft: RecurringDraft) async throws -> Recurring {
        var args = ["recurring", "add", "--title", draft.title, "--prompt", draft.prompt, "--kind", draft.kind.rawValue,
                    "--days", draft.days.joined(separator: ","), "--at", draft.at, "--if-asleep", draft.ifAsleep.rawValue]
        let precheck = draft.precheck.trimmingCharacters(in: .whitespacesAndNewlines)
        if !precheck.isEmpty { args += ["--precheck", precheck] }
        args += Self.modelArgs(model: draft.model, effort: draft.effort)
        if draft.approveSetup { args.append("--approve-setup") }
        let one: RecurringOne = try await read(args, positionals: [plot])
        return one.recurring
    }

    /// `loam recurring rm <recurring>`. Its runs stay.
    public func recurringRemove(_ id: String) async throws -> Recurring {
        let one: RecurringOne = try await read(["recurring", "rm"], positionals: [id])
        return one.recurring
    }

    /// `loam recurring run <recurring>`: starts it now, with its precheck, as a tick does.
    public func recurringRun(_ id: String) async throws -> RecurringResult {
        try await read(["recurring", "run"], positionals: [id])
    }

    /// `loam run defaults <plot>`: the model and the effort that a run of the plot gets when it names none.
    public func runDefaults(plot: String) async throws -> RunDefaults {
        let one: RunDefaultsOne = try await read(["run", "defaults"], positionals: [plot])
        return one.defaults
    }

    /// `loam run defaults <plot> --model <model> --effort <level>`. An empty value clears it.
    public func setRunDefaults(plot: String, model: String, effort: String) async throws -> RunDefaults {
        let one: RunDefaultsOne = try await read(["run", "defaults", "--model", model, "--effort", effort], positionals: [plot])
        return one.defaults
    }

    /// `loam rule list [<plot>]`: the rules of the plot, or of every plot, oldest first.
    public func ruleList(plot: String? = nil) async throws -> [Rule] {
        let list: RuleList = try await read(["rule", "list"], positionals: plot.map { [$0] } ?? [])
        return list.rules
    }

    /// `loam rule add <plot>`: a check that every run of the plot must pass. `note` is the note that it came from.
    public func ruleAdd(plot: String, name: String, command: String, note: String = "") async throws -> Rule {
        var args = ["rule", "add", "--name", name, "--command", command]
        if !note.isEmpty { args += ["--note", note] }
        let one: RuleOne = try await read(args, positionals: [plot])
        return one.rule
    }

    /// `loam rule rm <rule>`. The gate stops running it.
    public func ruleRemove(_ id: String) async throws -> Rule {
        let one: RuleOne = try await read(["rule", "rm"], positionals: [id])
        return one.rule
    }

    /// `loam tick`: starts the recurring runs that are due, then ships runs as `loam run tick` does.
    public func tick() async throws -> TickResult {
        try await read(["tick"])
    }

    /// `loam tick status`, or with `installed`, `loam tick install` or `uninstall`: the launchd agent that runs
    /// `loam tick` while the app is closed.
    public func tickStatus(set installed: Bool? = nil) async throws -> TickStatus {
        switch installed {
        case nil: try await read(["tick", "status"])
        case true?: try await read(["tick", "install"])
        case false?: try await read(["tick", "uninstall"])
        }
    }

    /// `loam intake list <plot>`: the open issues and map tickets of the plot.
    public func intake(plot: String) async throws -> IntakeList {
        try await read(["intake", "list"], positionals: [plot])
    }

    /// `loam linear status`: whether a Linear API key is stored, and its person.
    public func linearStatus() async throws -> LinearStatus {
        try await read(["linear", "status"])
    }

    /// `loam linear key set`: checks the key with Linear, then stores it in the Keychain. The key goes on stdin, so
    /// it is never in the arguments of a process.
    public func linearSetKey(_ key: String) async throws -> LinearStatus {
        try decode(await run(["linear", "key", "set", "--json"], stdin: key + "\n"))
    }

    /// `loam linear key rm`: removes the key from the Keychain.
    public func linearRemoveKey() async throws -> LinearStatus {
        try await read(["linear", "key", "rm"])
    }

    /// `loam linear updates`: the switches for the updates that Loam makes to Linear.
    public func linearUpdates() async throws -> LinearUpdates {
        let one: LinearUpdatesOne = try await read(["linear", "updates"])
        return one.updates
    }

    /// `loam linear updates --<switch> on|off`: sets each switch that is not nil, and leaves the others.
    public func setLinearUpdates(inProgress: Bool? = nil, attachPR: Bool? = nil, done: Bool? = nil,
                                 walkthroughComment: Bool? = nil) async throws -> LinearUpdates {
        var args = ["linear", "updates"]
        for (flag, value) in [("--in-progress", inProgress), ("--attach-pr", attachPR), ("--done", done),
                              ("--walkthrough", walkthroughComment)] {
            if let value { args += [flag, value ? "on" : "off"] }
        }
        let one: LinearUpdatesOne = try await read(args)
        return one.updates
    }

    /// `loam run stop <run>`: stops the background session of a run.
    public func runStop(_ id: String) async throws -> RunResult {
        try await read(["run", "stop"], positionals: [id])
    }

    /// `loam run diff`: the work that a run committed (ticket 207).
    public func runDiff(_ id: String) async throws -> RunDiff {
        try await read(["run", "diff"], positionals: [id])
    }

    /// `loam run send-back`: resumes the session of a run with your notes. A note is `<file>:<line>: <text>`, or
    /// text alone.
    public func runSendBack(_ id: String, notes: [String]) async throws -> RunResult {
        try await read(["run", "send-back"] + notes.flatMap { ["--note", $0] }, positionals: [id])
    }

    /// `loam run land`: merges the PR of a run that is ready to land. `head` is the PR head that you read: the
    /// merge throws `.notReady` when GitHub has another head. `linearDone` false leaves the Linear issue where it is.
    /// `whereItStands` sets Where it stands of the plot to the text of the ship notes, as a change by you in the app.
    public func runLand(_ id: String, head: String? = nil, keepWorktree: Bool = false, linearDone: Bool = true,
                        whereItStands: Bool = false, openPanes: [String] = []) async throws -> RunLandResult {
        var args = ["run", "land"]
        if let head { args += ["--head", head] }
        if keepWorktree { args.append("--keep-worktree") }
        if !linearDone { args.append("--no-linear-done") }
        args += openPanes.flatMap { ["--open-pane", $0] }
        if whereItStands { return try await write(args + ["--where-it-stands"], positionals: [id]) }
        return try await read(args, positionals: [id])
    }

    /// `loam run tick`: ships the runs whose checks passed. It pushes, opens the PR, and reads CI.
    public func runTick() async throws -> RunTickResult {
        try await read(["run", "tick"])
    }

    private func read<T: Decodable>(_ args: [String], positionals: [String] = []) async throws -> T {
        try decode(await run(args + ["--json"] + Self.afterFlags(positionals), stdin: nil))
    }

    private func write<T: Decodable>(_ args: [String], positionals: [String] = [], stdin: String? = nil) async throws -> T {
        try decode(await run(args + ["--json", "--actor", "app"] + Self.afterFlags(positionals), stdin: stdin))
    }

    private static func afterFlags(_ positionals: [String]) -> [String] { positionals.isEmpty ? [] : ["--"] + positionals }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LoamError.undecodable(String(describing: error))
        }
    }

    /// The environment of a `loam` process: the app's environment without the Ghostty resources
    /// folder (ticket 59), then `extra`. The app sets that variable for libghostty only.
    static func childEnvironment(inherited: [String: String], extra: [String: String]) -> [String: String] {
        var result = inherited
        result["GHOSTTY_RESOURCES_DIR"] = nil
        return result.merging(extra) { $1 }
    }

    /// Runs the binary on a background queue. Returns stdout on exit 0, and throws otherwise.
    private func run(_ args: [String], stdin: String?) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw LoamError.binaryMissing(path: binary.path)
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = Self.childEnvironment(inherited: ProcessInfo.processInfo.environment, extra: environment)
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inPipe
        let input = Data((stdin ?? "").utf8)
        let box = ProcessBox(process: process, out: out, err: err, inPipe: inPipe)

        try Task.checkCancellation()
        let result: (status: Int32, signaled: Bool, stdout: Data, stderr: Data) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.start(input: input) { result in
                    cont.resume(with: result.mapError {
                        $0 is CancellationError ? $0 : LoamError.launchFailed($0.localizedDescription)
                    })
                }
            }
        } onCancel: {
            box.terminate()
        }
        if Task.isCancelled { throw CancellationError() }
        if result.signaled {
            // A signal number is not a contract exit code.
            throw LoamError.failed(message: "The loam command stopped with signal \(result.status).")
        }
        if result.status == 0 { return result.stdout }

        // The exit code decides the case. The JSON error supplies the message and details.
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: result.stdout)
        let message = envelope?.error.message
            ?? String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw LoamError.from(exitCode: result.status, message: message, details: envelope?.error.details?.data)
    }
}

/// Runs one process to the end. Reads both pipes at once, so a full pipe cannot block the child.
/// No thread waits: handlers collect the output and the exit. A runner that blocked dispatch
/// threads deadlocked when many calls ran at once, because the reads it waited on had no thread.
private final class ProcessBox: @unchecked Sendable {
    typealias Output = (status: Int32, signaled: Bool, stdout: Data, stderr: Data)

    let process: Process
    let out: Pipe, err: Pipe, inPipe: Pipe
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    private var cancelled = false

    init(process: Process, out: Pipe, err: Pipe, inPipe: Pipe) {
        self.process = process; self.out = out; self.err = err; self.inPipe = inPipe
    }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    /// Calls `completion` once, after the process exits and both pipes reach end of file.
    func start(input: Data, completion: @escaping @Sendable (Result<Output, Error>) -> Void) {
        signal(SIGPIPE, SIG_IGN)  // A child that exits early must not kill the app on the stdin write.
        let group = DispatchGroup()
        group.enter(); group.enter(); group.enter()  // stdout, stderr, exit
        collect(out.fileHandleForReading, group: group) { $0.stdout.append($1) }
        collect(err.fileHandleForReading, group: group) { $0.stderr.append($1) }
        process.terminationHandler = { _ in group.leave() }

        lock.lock()
        let launch: Result<Void, Error> = cancelled ? .failure(CancellationError()) : Result { try process.run() }
        lock.unlock()
        if case .failure(let error) = launch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            completion(.failure(error))
            return
        }

        let writer = inPipe.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        group.notify(queue: .global()) { [self] in
            lock.lock(); defer { lock.unlock() }
            completion(.success((process.terminationStatus, process.terminationReason == .uncaughtSignal, stdout, stderr)))
        }
    }

    private func collect(_ handle: FileHandle, group: DispatchGroup, append: @escaping @Sendable (ProcessBox, Data) -> Void) {
        handle.readabilityHandler = { [self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                group.leave()
            } else {
                lock.lock(); append(self, data); lock.unlock()
            }
        }
    }
}

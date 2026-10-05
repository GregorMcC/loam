import Foundation
import Observation

/// A text part of the brief.
public enum BriefField: String, CaseIterable, Sendable {
    case what, why, whereItStands

    /// The key in `versions` and in `--expect`.
    public var itemKey: String { self == .whereItStands ? "where" : rawValue }

    var clientField: LoamClient.TextField {
        switch self {
        case .what: .what
        case .why: .why
        case .whereItStands: .whereItStands
        }
    }

    public var title: String {
        switch self {
        case .what: "What"
        case .why: "Why"
        case .whereItStands: "Where it stands"
        }
    }
}

/// A write that a stale error stopped. The clash can send it again.
public enum PendingWrite: Equatable, Sendable {
    case text(BriefField, String)
    case linkEdit(id: String, label: String, target: String, note: String)
    case linkRemove(id: String)
    case repoNote(id: String, note: String)
    case repoRemove(id: String)
}

/// A stale write. It holds what the person tried to save and what is in the plot now.
public struct EditClash: Equatable, Sendable {
    /// The stale item, such as `what` or `link:abc`.
    public var item: String
    /// A name for the item, for the message.
    public var title: String
    /// What the person tried to save. For a link or repo, a short description.
    public var yours: String
    /// The current value. Nil when the item is gone.
    public var current: String?
    public var pending: PendingWrite
}

/// The message that opening a link with a missing path shows. It offers Edit link.
public struct MissingLink: Equatable, Sendable {
    public var linkID: String
    public var path: String
}

/// An action that the actions menu asks the panel view to run.
public enum PanelRequest: Equatable, Sendable { case editBrief, addLink, addRepo }

/// The plot panel's edit model: the brief, the repos, and the links of one plot.
/// Each save is one `loam` write with `--expect` and `--actor app`.
@MainActor
@Observable
public final class PlotPanelModel {
    /// The word count above which the panel warns about the brief.
    public static let briefWordLimit = 300

    @ObservationIgnored public let client: LoamClient
    public private(set) var plot: Plot?
    /// An open draft for each brief field the person has changed since the last save.
    public private(set) var drafts: [BriefField: Draft] = [:]
    public private(set) var clash: EditClash?
    public private(set) var missingLink: MissingLink?
    private var openCount = 0
    public var errorMessage: String?
    /// The warnings of the last repo add, such as a checkout that kept its branch (ticket 91).
    public var notice: String?
    /// Set by the window when the panel shows. The app model loads the plot only while it shows.
    public var visible = false
    /// An action from the actions menu (ticket 89) that the panel view runs when it shows: edit the
    /// brief, or open the add link or add repo row. The view sets it back to nil.
    public var request: PanelRequest?
    /// The plot that `request` is for. A hidden panel keeps its last plot until it shows again.
    public var requestPlot: String?
    /// The request, once its plot has loaded. Before that, the panel shows the plot it had.
    public var readyRequest: PanelRequest? {
        guard let plot, plot.id == requestPlot else { return nil }
        return request
    }
    @ObservationIgnored private var loadToken = 0
    /// The repos that the add repo row can offer. `loadRepoSuggestions` fills it.
    public private(set) var repoCandidates: [RepoSuggestion] = []
    /// The folders whose git checkouts the add repo row offers, next to the folders of known repos.
    /// The app model sets them from `repo_folders` in the settings file.
    @ObservationIgnored public var suggestionRoots: [String] = LoamSettings.defaults
        .expandedRepoFolders(home: FileManager.default.homeDirectoryForCurrentUser.path)

    /// The text and the version it was edited from. A save expects `base`, so a change by another
    /// writer after the edit began shows as a clash.
    public struct Draft: Equatable, Sendable {
        public var text: String
        public var base: Int?
    }

    public init(client: LoamClient) {
        self.client = client
    }

    // MARK: Load

    /// Reads the plot. A different plot drops the drafts. The same plot keeps them.
    public func load(plotID: String?) async {
        guard let plotID else {
            plot = nil; drafts = [:]; clash = nil; missingLink = nil
            return
        }
        loadToken += 1
        let token = loadToken
        do {
            let fresh = try await client.show(plot: plotID)
            // A newer load started while this one ran. The newer result wins.
            guard token == loadToken else { return }
            if plot?.id != fresh.id { drafts = [:]; clash = nil; missingLink = nil; notice = nil }
            plot = fresh
            // A draft equal to the stored text is no draft.
            for (field, draft) in drafts where draft.text == text(of: field) { drafts[field] = nil }
        } catch {
            guard token == loadToken else { return }
            // A failed read of another plot must not leave the old plot open for a save.
            if plot?.id != plotID { plot = nil; drafts = [:]; clash = nil; missingLink = nil }
            report(error)
        }
    }

    // MARK: Brief

    public func text(of field: BriefField) -> String {
        guard let plot else { return "" }
        switch field {
        case .what: return plot.what
        case .why: return plot.why
        case .whereItStands: return plot.whereItStands
        }
    }

    /// The draft text, or the stored text when there is no draft.
    public func shownText(of field: BriefField) -> String {
        drafts[field]?.text ?? text(of: field)
    }

    public func isDirty(_ field: BriefField) -> Bool {
        guard let draft = drafts[field] else { return false }
        return draft.text != text(of: field)
    }

    public func edit(_ field: BriefField, to text: String) {
        guard let plot else { return }
        let base = drafts[field]?.base ?? plot.versions[field.itemKey]
        drafts[field] = Draft(text: text, base: base)
    }

    public func revert(_ field: BriefField) { drafts[field] = nil }

    /// Words in the brief: what, why, and where it stands, as shown (drafts included).
    public var briefWordCount: Int {
        BriefField.allCases.reduce(0) { $0 + Self.wordCount(shownText(of: $1)) }
    }

    public var briefWarning: String? {
        let count = briefWordCount
        guard count > Self.briefWordLimit else { return nil }
        return "The brief has \(count) words. A brief over about \(Self.briefWordLimit) words is hard to read. Cut it down."
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// One `loam set`, with `--expect` of the version that the edit began from.
    public func save(_ field: BriefField) async {
        guard let plot, let draft = drafts[field], draft.text != text(of: field) else { return }
        let expect = draft.base.map { [field.itemKey: $0] } ?? [:]
        await perform(.text(field, draft.text), plotID: plot.id, expect: expect)
    }

    // MARK: Links and repos

    /// Adds a link. With no label, the core takes one from the target.
    public func addLink(label: String, target: String, note: String = "") async {
        guard let plot else { return }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            errorMessage = "A link needs a target."
            return
        }
        do {
            _ = try await client.linkAdd(plot: plot.id, label: label, target: target, note: note.isEmpty ? nil : note)
            errorMessage = nil
            await load(plotID: plot.id)
        } catch {
            report(error)
        }
    }

    public func editLink(id: String, label: String, target: String, note: String) async {
        guard let plot, let link = plot.links.first(where: { $0.id == id }) else { return }
        await perform(.linkEdit(id: id, label: label, target: target, note: note), plotID: plot.id,
                      expect: ["link:\(id)": link.version])
    }

    public func removeLink(id: String) async {
        guard let plot, let link = plot.links.first(where: { $0.id == id }) else { return }
        await perform(.linkRemove(id: id), plotID: plot.id, expect: ["link:\(id)": link.version])
    }

    public func addRepo(path: String, note: String = "") async {
        guard let plot else { return }
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        do {
            let result = try await client.repoAdd(plot: plot.id, path: path, note: note.isEmpty ? nil : note)
            errorMessage = nil
            notice = result.warnings.flatMap { $0.isEmpty ? nil : $0.joined(separator: "\n") }
            await load(plotID: plot.id)
        } catch {
            report(error)
        }
    }

    /// Reads the repos of every plot, then looks for git checkouts next to them and in
    /// `suggestionRoots`. The add repo row calls it when it opens.
    public func loadRepoSuggestions() async {
        let known = ((try? await client.export())?.plots ?? []).flatMap { $0.repos.map(\.path) }
        let roots = suggestionRoots
        repoCandidates = await Task.detached { AddSources.scan(known: known, roots: roots) }.value
    }

    /// The suggestions for what the add repo row holds, without the repos of this plot.
    public func repoSuggestions(matching query: String) -> [RepoSuggestion] {
        AddSources.matching(query, in: repoCandidates, excluding: Set(plot?.repos.map(\.path) ?? []))
    }

    /// What Return in the add repo row adds: a path as typed, else the first suggestion for the name.
    /// A name with no suggestion goes to the core as typed, so its error names it.
    public func repoPath(forInput text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !AddSources.isPath(text), let first = repoSuggestions(matching: text).first else { return text }
        return first.path
    }

    /// Adds what was dropped on the panel, in order: a git checkout as a repo, anything else as a link.
    /// It stops at the first error, so a later add does not clear the message.
    public func addDropped(_ urls: [URL]) async {
        for url in urls {
            switch AddSources.dropped(url) {
            case .repo(let path): await addRepo(path: path)
            case .link(let target): await addLink(label: "", target: target)
            case nil: continue
            }
            if errorMessage != nil { return }
        }
    }

    public func editRepoNote(id: String, note: String) async {
        guard let plot, let repo = plot.repos.first(where: { $0.id == id }) else { return }
        await perform(.repoNote(id: id, note: note), plotID: plot.id, expect: ["repo:\(id)": repo.version])
    }

    public func removeRepo(id: String) async {
        guard let plot, let repo = plot.repos.first(where: { $0.id == id }) else { return }
        await perform(.repoRemove(id: id), plotID: plot.id, expect: ["repo:\(id)": repo.version])
    }

    // MARK: Open

    /// A local link whose path is gone gets a mark. `exists` is nil for a link that is not local.
    public func isMissing(_ link: PlotLink) -> Bool { link.exists == false }

    /// `loam open`. A missing path sets `missingLink`, and the panel shows a message with Edit link.
    public func open(linkID: String) async {
        guard let plot else { return }
        // Clicks can overlap. Only the newest open may change the panel state.
        openCount += 1
        let mine = openCount
        do {
            _ = try await client.open(plot: plot.id, link: linkID)
            guard mine == openCount else { return }
            errorMessage = nil
            missingLink = nil
        } catch LoamError.linkPathMissing(let details, _) {
            guard mine == openCount else { return }
            let path = details?.path ?? plot.links.first { $0.id == linkID }?.target ?? ""
            missingLink = MissingLink(linkID: linkID, path: path)
            // Read again, so the mark shows now.
            await load(plotID: plot.id)
        } catch {
            guard mine == openCount else { return }
            report(error)
        }
    }

    public func dismissMissingLink() { missingLink = nil }

    // MARK: Clash

    /// Writes what the person tried to save over the current value. It reads the plot again first,
    /// so the write expects the version that the other writer made.
    public func keepMine() async {
        guard let clash, let plot else { return }
        self.clash = nil
        await load(plotID: plot.id)
        guard let fresh = self.plot else { return }
        switch clash.pending {
        case .text(let field, let text):
            drafts[field] = Draft(text: text, base: fresh.versions[field.itemKey])
            await save(field)
        case .linkEdit(let id, let label, let target, let note):
            await editLink(id: id, label: label, target: target, note: note)
        case .linkRemove(let id): await removeLink(id: id)
        case .repoNote(let id, let note): await editRepoNote(id: id, note: note)
        case .repoRemove(let id): await removeRepo(id: id)
        }
    }

    /// Drops what the person tried to save and shows the current value.
    public func useCurrent() async {
        guard let clash, let plot else { return }
        self.clash = nil
        if case .text(let field, _) = clash.pending { drafts[field] = nil }
        await load(plotID: plot.id)
    }

    // MARK: Plumbing

    private func perform(_ write: PendingWrite, plotID: String, expect: [String: Int]) async {
        do {
            switch write {
            case .text(let field, let text):
                plot = try await client.set(plot: plotID, field: field.clientField, text: text, expect: expect)
                drafts[field] = nil
            case .linkEdit(let id, let label, let target, let note):
                _ = try await client.linkEdit(plot: plotID, link: id, label: label, target: target, note: note, expect: expect)
                await load(plotID: plotID)
            case .linkRemove(let id):
                _ = try await client.linkRemove(plot: plotID, link: id, expect: expect)
                await load(plotID: plotID)
            case .repoNote(let id, let note):
                _ = try await client.repoEdit(plot: plotID, repo: id, note: note, expect: expect)
                await load(plotID: plotID)
            case .repoRemove(let id):
                // The core cannot ask which repo becomes main in --json, so name the first other repo.
                let removing = plot?.repos.first { $0.id == id }
                let newMain = removing?.main == true ? plot?.repos.first { $0.id != id }?.id : nil
                _ = try await client.repoRemove(plot: plotID, repo: id, newMain: newMain, expect: expect)
                await load(plotID: plotID)
            }
            errorMessage = nil
            clash = nil
        } catch LoamError.stale(let details, let message) {
            clash = makeClash(write, details: details)
            errorMessage = clash == nil ? message : nil
            await load(plotID: plotID)
        } catch {
            report(error)
        }
    }

    private func makeClash(_ write: PendingWrite, details: StaleDetails?) -> EditClash? {
        guard let item = details?.items.first else { return nil }
        switch write {
        case .text(let field, let text):
            return EditClash(item: item.item, title: field.title, yours: text,
                             current: item.exists ? (item.value ?? "") : nil, pending: write)
        case .linkEdit(_, let label, let target, _):
            return EditClash(item: item.item, title: "Link", yours: "\(label): \(target)",
                             current: item.link.map { "\($0.label): \($0.target)" }, pending: write)
        case .linkRemove:
            return EditClash(item: item.item, title: "Link", yours: "Remove the link",
                             current: item.link.map { "\($0.label): \($0.target)" }, pending: write)
        case .repoNote(_, let note):
            return EditClash(item: item.item, title: "Repo", yours: note, current: item.repo?.note, pending: write)
        case .repoRemove:
            return EditClash(item: item.item, title: "Repo", yours: "Remove the repo",
                             current: item.repo?.path, pending: write)
        }
    }

    private func report(_ error: Error) {
        errorMessage = (error as? LoamError)?.userMessage ?? String(describing: error)
    }
}

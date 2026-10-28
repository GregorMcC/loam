import Foundation

extension AppModel {
    /// True when the app ticks the recurring runs itself: a plot has one, and launchd does not tick while the app is
    /// closed (ticket 208).
    public var appTicksRecurring: Bool { hasRecurring && tickStatus?.installed == false }

    /// Shows the Recurring page of the plot, and reads its recurring runs, the launchd agent, and its rules.
    public func showRecurring(plot: String) async {
        if page != .recurring(plot) {
            recurring = []
            rules = []
        }
        recurringError = nil
        page = .recurring(plot)
        await reloadRecurring()
        await readTickStatus()
        await reloadRules()
    }

    /// Reads the recurring runs of the plot that the Recurring page shows. A failed read keeps the last list.
    public func reloadRecurring() async {
        guard case .recurring(let plot) = page else { return }
        do {
            let list = try await client.recurringList(plot: plot)
            guard page == .recurring(plot) else { return }
            recurring = list
            if !list.isEmpty { hasRecurring = true }
        } catch {
            report(error)
        }
    }

    /// Clears the error of the form, for Cancel.
    public func clearRecurringError() { recurringError = nil }

    /// `loam recurring add` for the plot of the page. On a failure, `recurringError` says why, and it returns false.
    public func addRecurring(_ draft: RecurringDraft) async -> Bool {
        guard case .recurring(let plot) = page else { return false }
        recurringError = nil
        do {
            _ = try await client.recurringAdd(plot: plot, draft: draft)
        } catch {
            recurringError = Self.message(for: error)
            return false
        }
        hasRecurring = true
        await reloadRecurring()
        return true
    }

    public func removeRecurring(_ id: String) async {
        recurringError = nil
        do {
            _ = try await client.recurringRemove(id)
        } catch {
            recurringError = Self.message(for: error)
            return
        }
        await reloadRecurring()
    }

    /// Starts the recurring run now, as a tick does, and says what happened.
    public func runRecurringNow(_ id: String) async {
        recurringError = nil
        do {
            let result = try await client.recurringRun(id)
            onToast?("\(result.recurring.title): \(result.note)", result.run == nil ? .notice : .done)
        } catch {
            recurringError = Self.message(for: error)
            return
        }
        await reloadRuns()
        await reloadRecurring()
    }

    /// Installs or removes the launchd agent that runs `loam tick` while the app is closed.
    public func setTickAgent(installed: Bool) async {
        recurringError = nil
        do {
            tickStatus = try await client.tickStatus(set: installed)
        } catch {
            recurringError = Self.message(for: error)
        }
    }

    /// Reads whether launchd runs `loam tick`. With `lookForRecurring`, it also reads whether any plot has a
    /// recurring run, so the app knows whether to tick them itself.
    func readTickStatus(lookForRecurring: Bool = false) async {
        if let status = try? await client.tickStatus() { tickStatus = status }
        if lookForRecurring, let all = try? await client.recurringList() { hasRecurring = !all.isEmpty }
    }

    /// `loam tick`: starts the recurring runs that are due and ships runs. A tick that started or skipped a run
    /// reads the runs again, and the page its list. A failed tick changes nothing: the next one tries again.
    public func tickRecurring() async {
        guard let result = try? await client.tick() else { return }
        if !result.runs.isEmpty || result.recurring.contains(where: { $0.run != nil }) { await reloadRuns() }
        if !result.recurring.isEmpty { await reloadRecurring() }
    }
}

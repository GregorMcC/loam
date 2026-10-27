import Foundation

/// Rules (ticket 209): checks that every run of a plot must pass. The Recurring page lists them, and the desk offers
/// one when you send back a note like a note on another run of the plot.
extension AppModel {
    /// Reads the rules of the plot that the Recurring page shows. A failed read keeps the last list.
    public func reloadRules() async {
        guard case .recurring(let plot) = page else { return }
        do {
            let list = try await client.ruleList(plot: plot)
            guard page == .recurring(plot) else { return }
            rules = list
        } catch {
            report(error)
        }
    }

    /// `loam rule add` for the plot of the page. On a failure, `recurringError` says why, and it returns false.
    public func addRule(name: String, command: String) async -> Bool {
        guard case .recurring(let plot) = page else { return false }
        recurringError = nil
        do {
            _ = try await client.ruleAdd(plot: plot, name: Self.trimmed(name), command: Self.trimmed(command))
        } catch {
            recurringError = Self.message(for: error)
            return false
        }
        await reloadRules()
        return true
    }

    public func removeRule(_ id: String) async {
        recurringError = nil
        do {
            _ = try await client.ruleRemove(id)
        } catch {
            recurringError = Self.message(for: error)
            return
        }
        await reloadRules()
    }

    /// Makes the note of the desk's offer a rule of its plot, and says so. On a failure, the offer stays and says
    /// why, and it returns false.
    public func addDeskRule(name: String, command: String) async -> Bool {
        guard let offer = desk.ruleOffer else { return false }
        let name = Self.trimmed(name)
        do {
            _ = try await client.ruleAdd(plot: offer.plotID, name: name, command: Self.trimmed(command), note: offer.offer.note)
        } catch {
            desk.ruleOffer?.error = Self.message(for: error)
            return false
        }
        desk.ruleOffer = nil
        onToast?("Rule added: every run of the plot must pass \u{201C}\(name)\u{201D}", .done)
        return true
    }

    /// Not now: Loam offers the rule again the next time that you send back a note like it.
    public func dismissDeskRuleOffer() {
        desk.ruleOffer = nil
    }

    /// Reads the rules of the plot of the run in Shaping at the desk. A failed read shows none.
    func readDeskRules(plot: String) async {
        let rules = (try? await client.ruleList(plot: plot)) ?? []
        guard deskRun?.plotID == plot else { return }
        desk.rules = rules
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

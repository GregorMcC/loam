import AppKit
import LoamKit

/// The staged work of the README and site shots (`readme-shots`): a small product team, not Loam itself.
///
/// - "Checkout": the repos storefront and payments-api, the Linear team SHOP, and runs at each station of the line.
/// - "Mobile app": the repo ios-app and the Linear team MOB.
///
/// The repos are in `~/Code` of the rig's home. Each repo on GitHub has a local bare origin, and a fake ssh serves
/// it. The core's fake gh stands in for GitHub, its fake Linear for Linear (with the issues of `linearIssues`), and a
/// stand-in claude for the background sessions of runs and for `claude -p`. Your own sessions in the panes still
/// get Claude Code: `bin/claude` sends only `--bg`, `-p`, `stop`, `attach`, and `logs` to the stand-in.
@MainActor
struct ReadmeShotStage {
    let checkout: String
    let mobile: String
    /// The main repo of Checkout, where the session of the hero works.
    let storefront: URL
    /// The runs, by their short name: webhook, applePay, delivery, vat, discount, savedBasket, postcode, history,
    /// ipad, darkMode, refunds, address, paypal, orderLinks.
    let runs: [String: String]
    /// The file and the line of the note on the desk-land shot.
    let noteFile = "webhook/deliver.go"
    let noteLine: Int
    /// The Linear issue that the intake shots select.
    let intakeKey = "SHOP-160"
    /// The fake Linear server. The scenario stops it at the end.
    let linear: Process

    /// Builds the repos, the plots, and the runs. `environment` is the environment of each `loam` call, and it gets
    /// the fakes. `bin` is on its PATH, and gets `claude`. `claude` is the path of Claude Code.
    static func make(rig: PanelRig, environment: inout [String: String], home: URL, bin: URL, claude: String) throws -> ReadmeShotStage {
        let fm = FileManager.default
        let launch = ProcessInfo.processInfo.environment
        guard let fakeGH = launch["LOAM_DRIVER_FAKE_GH"] else { throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh") }
        guard let fakeLinear = launch["LOAM_DRIVER_FAKE_LINEAR"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_LINEAR does not name the fake Linear")
        }
        let root = rig.root
        func executable(_ file: URL, _ text: String) throws {
            try text.write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        // Linear: the fake, with the issues of SHOP and MOB, and a key in a temp secrets file, not the Keychain.
        let issuesFile = root.appendingPathComponent("linear-issues.json")
        try linearIssues.write(to: issuesFile, atomically: true, encoding: .utf8)
        let linear = Process()
        linear.executableURL = URL(fileURLWithPath: fakeLinear)
        linear.environment = launch.merging(["LOAM_FAKE_LINEAR_ISSUES": issuesFile.path]) { $1 }
        let out = Pipe()
        linear.standardOutput = out
        try linear.run()
        // A step below that throws ends the fake: only the stage that this returns stops it later.
        var handedOver = false
        defer { if !handedOver { linear.terminate() } }
        var line = Data()
        while let byte = try out.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) { line.append(byte) }
        let apiURL = String(decoding: line, as: UTF8.self)
        guard apiURL.hasPrefix("http://127.0.0.1:") else { throw DriverFailure("the fake Linear printed \(apiURL)") }
        let secrets = root.appendingPathComponent("secrets.json")
        try #"{"linear-api-key":"lin_api_good"}"#.write(to: secrets, atomically: true, encoding: .utf8)

        // GitHub: one state for the PRs, and the issues of each repo in a file of its own, because the fake gh
        // lists the same issues for every repo. A wrapper picks the file by the --repo of gh issue list.
        let ghState = root.appendingPathComponent("gh-state.json")
        let ghIssues = root.appendingPathComponent("gh-issues")
        try fm.createDirectory(at: ghIssues, withIntermediateDirectories: true)
        var allIssues: [[String: Any]] = []
        for (repo, issues) in githubIssues {
            let nodes = issues.map { issue -> [String: Any] in
                ["number": issue.number, "title": issue.title, "url": "https://github.com/acme/\(repo)/issues/\(issue.number)",
                 "labels": issue.labels.map { ["name": $0] }, "updatedAt": issue.updated, "createdAt": issue.updated,
                 "body": issue.body, "assignees": [Any]()]
            }
            allIssues += nodes
            try JSONSerialization.data(withJSONObject: ["issues": nodes]).write(to: ghIssues.appendingPathComponent("\(repo).json"))
        }
        // A merged PR, so the PRs of the runs get believable numbers.
        let state: [String: Any] = [
            "issues": allIssues, "refs": [String](),
            "pulls": [["number": 215, "title": "Bump Go to 1.23", "url": "https://github.com/acme/storefront/pull/215",
                       "state": "MERGED", "headRefName": "bump-go"]],
            "repository": ["mergeCommitAllowed": false, "squashMergeAllowed": true, "rebaseMergeAllowed": false,
                           "viewerDefaultMergeMethod": "SQUASH"],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: ghState)
        let gh = root.appendingPathComponent("gh")
        try executable(gh, """
            #!/bin/sh
            if [ "$1 $2" = "issue list" ]; then
              for a in "$@"; do case "$a" in */acme/*) name=${a##*/};; esac; done
              export LOAM_FAKE_GH_STATE='\(ghIssues.path)/'"$name"'.json'
            fi
            exec '\(fakeGH)' "$@"

            """)
        // git runs: <ssh> <host> "<git program> '<owner>/<repo>.git'". The fake serves the bare origin of the repo.
        let origins = root.appendingPathComponent("origins")
        let ssh = root.appendingPathComponent("fake-ssh")
        try executable(ssh, """
            #!/bin/sh
            prog=${2%% *}
            name=$(printf '%s' "$2" | sed -E "s/'//g; s/.* //; s/.*\\///; s/\\.git$//")
            exec git "${prog#git-}" '\(origins.path)/'"$name"'.git'

            """)

        // claude: the stand-in for runs and claude -p, and Claude Code for everything else.
        let standIn = root.appendingPathComponent("claude-stand-in")
        let answers = root.appendingPathComponent("claude-answers")
        try fm.createDirectory(at: answers, withIntermediateDirectories: true)
        var cases = ""
        for (n, answer) in claudeAnswers.enumerated() {
            let file = answers.appendingPathComponent("\(n).json")
            try answer.json.write(to: file, atomically: true, encoding: .utf8)
            cases += "    *'\(answer.key)'*) exec cat '\(file.path)';;\n"
        }
        // The usage probe ("Reply with ok"): 41% of the week, which resets in 4 days.
        let resets = Int(Date().addingTimeInterval(4 * 24 * 3600).timeIntervalSince1970)
        let usage = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.41,"resetsAt":\#(resets)}}}}"#
        try executable(standIn, """
            #!/bin/sh
            printf '%s\n' "$*" >> '\(answers.path)/calls.log'
            for a in "$@"; do [ "$a" = -p ] && print=1; done
            if [ -n "$print" ]; then
              case "$*" in
            \(cases)    *'Reply with ok'*) echo '\(usage)'; exit 0;;
              esac
              echo 'claude stand-in: no answer for this prompt' >&2
              exit 1
            fi
            exit 0

            """)
        try? fm.removeItem(at: bin.appendingPathComponent("claude"))
        try executable(bin.appendingPathComponent("claude"), """
            #!/bin/sh
            for a in "$@"; do case "$a" in --bg|-p) exec '\(standIn.path)' "$@";; esac; done
            case "$1" in stop|attach|logs) exec '\(standIn.path)' "$@";; esac
            exec '\(claude)' "$@"

            """)

        environment.merge([
            "LOAM_GH": gh.path, "LOAM_FAKE_GH_STATE": ghState.path,
            "LOAM_FAKE_GH_LOG": root.appendingPathComponent("gh-calls.jsonl").path,
            "GIT_SSH_COMMAND": ssh.path,
            "LOAM_LINEAR_URL": apiURL, "LOAM_SECRETS_FILE": secrets.path,
        ]) { $1 }
        let env = environment

        // The repos.
        let code = home.appendingPathComponent("Code")
        try fm.createDirectory(at: origins, withIntermediateDirectories: true)
        func repo(_ name: String, _ files: [(String, String)], history: [String], github: Bool) throws -> URL {
            let folder = code.appendingPathComponent(name)
            try write(files, in: folder)
            try Scenarios.git(folder, ["init", "-q", "-b", "main"])
            try Scenarios.git(folder, ["add", "."])
            try Scenarios.git(folder, ["commit", "-q", "-m", history[0]])
            for message in history.dropFirst() { try Scenarios.git(folder, ["commit", "-q", "--allow-empty", "-m", message]) }
            if github {
                let origin = origins.appendingPathComponent("\(name).git")
                try fm.createDirectory(at: origin, withIntermediateDirectories: true)
                try Scenarios.git(origin, ["init", "--bare", "-q", "-b", "main"])
                try Scenarios.git(folder, ["remote", "add", "origin", origin.path])
                try Scenarios.git(folder, ["push", "-q", "origin", "main"])
                try Scenarios.git(folder, ["remote", "set-head", "origin", "main"])
                try Scenarios.git(folder, ["remote", "set-url", "origin", "git@github.com:acme/\(name).git"])
            }
            return folder
        }
        let storefront = try repo("storefront", storefrontFiles, history: [
            "Start the storefront", "Basket totals in pence (#198)", "Render checkout from templates (#201)",
            "Show the VAT line on the receipt (#203)", "Keep the basket badge in sync (#209)", "Bump Go to 1.23 (#215)",
        ], github: true)
        let payments = try repo("payments-api", paymentsFiles, history: [
            "Start the payments API", "Refunds through Stripe (#52)", "Webhooks for paid and refunded orders (#57)",
            "Gift card VAT (#60)",
        ], github: true)
        let ios = try repo("ios-app", iosFiles, history: [
            "Start the app", "Basket screen (#118)", "Order history (#124)", "Universal links for orders (#130)",
        ], github: true)
        // Claude Code trusts a worktree when it trusts the main checkout.
        let claudeJSON = home.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: claudeJSON), var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var projects = object["projects"] as? [String: Any] ?? [:]
            for folder in [storefront, payments, ios] {
                for path in Set([folder.path, realPath(folder.path)]) { projects[path] = ["hasTrustDialogAccepted": true] }
            }
            object["projects"] = projects
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: claudeJSON)
        }

        // The plots.
        func loam(_ args: [String], input: String? = nil) throws -> String { try rig.loam(args, extra: env, input: input) }
        let checkout = try rig.newPlot("Checkout")
        _ = try loam(["repo", "add", checkout, storefront.path])
        _ = try loam(["repo", "add", checkout, payments.path])
        _ = try loam(["set", checkout, "what", "The web checkout: the basket, payment, and the order confirmation."])
        _ = try loam(["set", checkout, "why", "Most support tickets start at checkout, and each fix here shows in conversion."])
        _ = try loam(["set", checkout, "where-it-stands", "Apple Pay and the new address form are live. Webhook retries are in "
            + "review. Next: the gift card VAT fix, then saved baskets for signed-out shoppers."])
        _ = try loam(["link", "add", checkout, "SHOP team", "https://linear.app/acme/team/SHOP/active"])
        _ = try loam(["link", "add", checkout, "Checkout spec", "https://www.notion.so/acme/Checkout-spec-0123456789abcdef0123456789abcdef",
                      "--note", "Flows, edge cases, and the copy"])
        _ = try loam(["link", "add", checkout, "Payments runbook", payments.appendingPathComponent("RUNBOOK.md").path])
        _ = try loam(["link", "add", checkout, "Stripe webhooks", "https://docs.stripe.com/webhooks"])
        _ = try loam(["rule", "add", checkout, "--name", "Prices use pence", "--command", "! grep -rn 'float64' basket"])
        _ = try loam(["rule", "add", checkout, "--name", "No card numbers in logs", "--command", "true"])
        _ = try loam(["run", "defaults", checkout, "--model", "opus", "--effort", "high"])
        let mobile = try rig.newPlot("Mobile app")
        _ = try loam(["repo", "add", mobile, ios.path])
        _ = try loam(["set", mobile, "what", "The iOS app: browse, the basket, and order history."])
        _ = try loam(["link", "add", mobile, "MOB team", "https://linear.app/acme/team/MOB/active"])

        // The recurring runs of Checkout. The chore ran once by hand, and its precheck found no work.
        _ = try loam(["recurring", "add", checkout, "--title", "Shape new bugs", "--kind", "shape", "--days", "weekdays", "--at", "07:00",
                      "--prompt", "Read the new SHOP issues labelled Bug. Draft a run for each one that has steps to reproduce."])
        let chore = try loam(["recurring", "add", checkout, "--title", "Bump Go modules", "--kind", "chore", "--days", "daily",
                              "--at", "02:00", "--repo", payments.path,
                              "--prompt", "Bump the Go modules that have updates, and fix what breaks.",
                              "--precheck", "go list -m -u all | grep -q '\\['", "--check", "Tests=go test ./...", "--json"])
        guard let choreID = ((try JSONSerialization.jsonObject(with: Data(chore.utf8)) as? [String: Any])?["recurring"]
            as? [String: Any])?["id"] as? String else { throw DriverFailure("recurring add printed no recurring run: \(chore)") }
        _ = try loam(["recurring", "add", checkout, "--title", "Weekly dependency audit", "--kind", "shape", "--days", "mon",
                      "--at", "06:30", "--repo", storefront.path,
                      "--prompt", "Run govulncheck. Draft a run for each finding that affects checkout."])
        _ = try loam(["recurring", "run", choreID])

        // The runs.
        var runs: [String: String] = [:]
        var sessions: [String: String] = [:]
        func start(_ name: String, _ plot: String, _ title: String, goal: String, checks: [String], repo: URL, worktree: String,
                   link: String? = nil, maxTries: Int = 3, base: String? = nil) throws -> URL {
            var args = ["run", "start", plot, "--title", title, "--goal", goal, "--repo", repo.path, "--worktree", worktree,
                        "--max-tries", String(maxTries), "--json"]
            if let base { args += ["--base", base] }
            for check in checks { args += ["--check", check] }
            if let link { args += ["--link", link] }
            let text = try loam(args)
            let run = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["run"] as? [String: Any]
            guard let id = run?["id"] as? String, let folder = run?["folder"] as? String else {
                throw DriverFailure("run start printed no run: \(text)")
            }
            runs[name] = id
            sessions[name] = String(format: "%08x-4b1d-4c2e-9f3a-5e6d7c8b9a0f", 0x5100 + sessions.count)
            _ = try hook(name, "SessionStart", ["source": "startup"])
            return URL(fileURLWithPath: folder)
        }
        /// One hook event, as Claude Code sends it. A Stop that the gate blocks exits 2.
        func hook(_ name: String, _ event: String, _ fields: [String: Any] = [:]) throws -> Bool {
            guard let id = runs[name] else { throw DriverFailure("no run \(name)") }
            var body = fields
            body["hook_event_name"] = event
            body["session_id"] = sessions[name] ?? ""
            let input = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            do { _ = try loam(["run", "hook", id], input: input) } catch where event == "Stop" { return false }
            return true
        }
        /// Writes the files in the worktree, commits them as the session does, and ends the turn.
        func work(_ name: String, in folder: URL, _ files: [(String, String)], _ message: String) throws {
            try write(files, in: folder)
            try Scenarios.git(folder, ["add", "."])
            try Scenarios.git(folder, ["commit", "-q", "-m", message])
            _ = try hook(name, "UserPromptSubmit")
            _ = try hook(name, "Stop")
        }
        let shop = "https://linear.app/acme/issue/"

        // Two runs that landed this week.
        let address = try start("address", checkout, "Postcode on Back", goal: "The address form keeps the postcode when you go Back.",
                                checks: ["Templates=go test ./web/..."], repo: storefront, worktree: "postcode-on-back",
                                link: shop + "SHOP-139/address-form-loses-the-postcode")
        try work("address", in: address, [("web/templates/address.html", addressForm)], "Keep the postcode on Back")
        let paypal = try start("paypal", checkout, "Hide PayPal when off", goal: "The PayPal button hides when PayPal is off for the shop.",
                               checks: ["Templates=go test ./web/..."], repo: storefront, worktree: "hide-paypal",
                               link: shop + "SHOP-144/hide-the-paypal-button")
        try work("paypal", in: paypal, [("web/templates/paypal.html", paypalButton)], "Hide the PayPal button when PayPal is off")
        let orderLinks = try start("orderLinks", mobile, "Order links", goal: "A link to an order opens the order in the app.",
                                   checks: ["Tests=make test"], repo: ios, worktree: "order-links",
                                   link: "https://github.com/acme/ios-app/issues/126")
        try work("orderLinks", in: orderLinks, [("App/Orders/OrderLink.swift", orderLinkSwift)], "Open order links in the app")

        // Three runs that wait to land, and one whose CI still runs.
        let webhookFolder = try start("webhook", checkout, "Webhook retries", goal: "Webhook delivery retries a 5xx answer with backoff, and gives up after 4 attempts.",
                                      checks: ["Webhook tests=go test ./webhook/...", "Vet=go vet ./webhook/..."], repo: payments,
                                      worktree: "webhook-retry", link: shop + "SHOP-147/retry-webhook-delivery-on-5xx")
        try work("webhook", in: webhookFolder, [("webhook/deliver.go", deliverRetry), ("webhook/deliver_test.go", deliverTest)],
                 "Retry webhook delivery on 5xx")
        let applePay = try start("applePay", checkout, "Apple Pay button", goal: "The Apple Pay button keeps its size on screens narrower than 375 points.",
                                 checks: ["Templates=go test ./web/..."], repo: storefront, worktree: "apple-pay",
                                 link: shop + "SHOP-142/apple-pay-button-misaligned")
        try work("applePay", in: applePay, [("web/static/checkout.css", checkoutCSSFixed)], "Wrap the pay buttons on small screens")
        let delivery = try start("delivery", checkout, "Delivery estimate", goal: "The basket page shows the delivery estimate for the postcode.",
                                 checks: ["Basket tests=go test ./basket/...", "Templates=go test ./web/..."], repo: storefront,
                                 worktree: "delivery-eta", link: shop + "SHOP-155/show-the-delivery-estimate")
        try work("delivery", in: delivery, [("basket/estimate.go", estimateGo)], "Show the delivery estimate on the basket page")
        let darkMode = try start("darkMode", mobile, "Dark mode total", goal: "The order total reads clearly in dark mode.",
                                 checks: ["Tests=make test"], repo: ios, worktree: "dark-total",
                                 link: "https://github.com/acme/ios-app/issues/132")
        try work("darkMode", in: darkMode, [("App/Basket/TotalView.swift", totalViewFixed)], "Use the label colour for the total")

        // A run that used its tries.
        let postcode = try start("postcode", checkout, "Postcode timeout", goal: "The postcode lookup waits long enough on a slow network.",
                                 checks: ["Lookup tests=go test ./postcode/..."], repo: storefront, worktree: "postcode",
                                 link: shop + "SHOP-158/postcode-lookup-times-out", maxTries: 2)
        try work("postcode", in: postcode, [("postcode/lookup.go", lookupGo), ("postcode/lookup_test.go", lookupTest)],
                 "Raise the postcode lookup timeout")
        _ = try hook("postcode", "UserPromptSubmit")
        _ = try hook("postcode", "Stop")

        // The tick pushes the branches whose checks passed and opens their PRs. Then CI: it passed, except on the
        // delivery estimate, where it still runs.
        _ = try loam(["run", "tick"])
        try setCI(ghState, folders: ["address": address, "paypal": paypal, "orderLinks": orderLinks, "webhook": webhookFolder, "applePay": applePay,
                                     "delivery": delivery, "darkMode": darkMode], running: delivery)
        _ = try loam(["run", "tick"])
        for name in ["address", "paypal", "orderLinks"] { _ = try loam(["run", "land", runs[name] ?? ""]) }

        // Three runs that work, the first on its second try, and one that waits for a slot.
        let vat = try start("vat", checkout, "Gift card VAT", goal: "Gift card VAT rounds half up to the penny, as HMRC asks.",
                            checks: ["VAT tests=go test ./vat/...", "Vet=go vet ./..."], repo: payments, worktree: "gift-card-vat",
                            link: shop + "SHOP-151/gift-card-vat-rounds-the-wrong-way")
        try work("vat", in: vat, [("vat/vat_test.go", vatTestMore)], "Test more gift card amounts")
        _ = try hook("vat", "UserPromptSubmit")
        _ = try start("history", mobile, "Offline order history", goal: "Order history shows the last 50 orders with no network.",
                      checks: ["Tests=make test"], repo: ios, worktree: "offline-orders", link: shop + "MOB-88/show-order-history-offline")
        _ = try hook("history", "UserPromptSubmit")
        _ = try start("refunds", checkout, "Refund request IDs", goal: "Each refund log line has the Stripe request ID.",
                      checks: ["Tests=go test ./..."], repo: payments, worktree: "refund-ids",
                      link: "https://github.com/acme/payments-api/issues/61")
        _ = try hook("refunds", "UserPromptSubmit")
        _ = try loam(["run", "limits", "--at-a-time", "3", "--max-turns", "40", "--hold-at", "80"])
        _ = try start("discount", checkout, "Discount code spaces", goal: "The discount code field trims spaces before it checks the code.",
                      checks: ["Basket tests=go test ./basket/..."], repo: storefront, worktree: "discount-code",
                      link: "https://github.com/acme/storefront/issues/214")

        // Two drafts that wait for you.
        for (name, plot, title, link, repoURL) in [
            ("savedBasket", checkout, "Saved basket", shop + "SHOP-153/save-the-basket-for-signed-out-shoppers", storefront),
            ("ipad", mobile, "iPad empty basket", shop + "MOB-91/crash-when-the-basket-is-empty-on-ipad", ios),
        ] {
            let text = try loam(["run", "shape", plot, "--title", title, "--link", link, "--repo", repoURL.path, "--json"])
            guard let id = ((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["run"] as? [String: Any])?["id"]
                as? String else { throw DriverFailure("run shape printed no run: \(text)") }
            runs[name] = id
        }

        let noteLine = (deliverRetry.split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0.contains("const maxAttempts") } ?? 0) + 1
        handedOver = true
        return ReadmeShotStage(checkout: checkout, mobile: mobile, storefront: storefront, runs: runs,
                               noteLine: noteLine, linear: linear)
    }

    /// GitHub has each PR at the head of its worktree, with one required check, ci / test. It passed, except on
    /// `running`, where it is in progress.
    private static func setCI(_ ghState: URL, folders: [String: URL], running: URL) throws {
        guard var state = try JSONSerialization.jsonObject(with: Data(contentsOf: ghState)) as? [String: Any],
              var pulls = state["pulls"] as? [[String: Any]] else { throw DriverFailure("no gh state") }
        var refs: [String] = []
        var details: [String: Any] = [:]
        for folder in folders.values {
            let branch = try Scenarios.git(folder, ["branch", "--show-current"])
            let head = try Scenarios.git(folder, ["rev-parse", "HEAD"])
            guard let index = pulls.firstIndex(where: { $0["headRefName"] as? String == branch }),
                  let number = pulls[index]["number"] as? Int else { throw DriverFailure("no PR for \(branch)") }
            refs.append(branch)
            let done = folder != running
            pulls[index].merge(["mergeable": "MERGEABLE", "mergeStateStatus": done ? "CLEAN" : "BLOCKED", "baseRefName": "main",
                                "headRefOid": head, "commits": ["totalCount": 1]]) { $1 }
            let check: [String: Any] = ["__typename": "CheckRun", "name": "test", "status": done ? "COMPLETED" : "IN_PROGRESS",
                                        "conclusion": done ? "SUCCESS" : "", "isRequired": true,
                                        "checkSuite": ["workflowRun": ["databaseId": 9000 + number, "workflow": ["name": "ci"]]]]
            details[String(number)] = [
                "baseRef": ["compare": ["behindBy": 0]], "reviewThreads": ["nodes": [Any]()],
                "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": done ? "SUCCESS" : "PENDING",
                                                                       "contexts": ["totalCount": 1, "nodes": [check]]]]]]],
            ]
        }
        state["pulls"] = pulls
        state["refs"] = refs
        state["details"] = details
        try JSONSerialization.data(withJSONObject: state).write(to: ghState)
    }

    /// Writes files in a folder. A Go file gets tabs for its indent, as gofmt gives it.
    private static func write(_ files: [(String, String)], in folder: URL) throws {
        for (path, text) in files {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var body = text
            if path.hasSuffix(".go") {
                body = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                    let spaces = line.prefix { $0 == " " }.count
                    return String(repeating: "\t", count: spaces / 4) + String(line.dropFirst(spaces - spaces % 4))
                }.joined(separator: "\n")
            }
            try body.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// The path with every symlink resolved, as Go's `filepath.EvalSymlinks` gives it.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: The staged data

    /// The open issues of the Linear teams SHOP and MOB, as Linear gives them.
    static let linearIssues = #"""
        [
         {"identifier":"SHOP-151","title":"Gift card VAT rounds the wrong way","url":"https://linear.app/acme/issue/SHOP-151/gift-card-vat-rounds-the-wrong-way",
          "priorityLabel":"Urgent","updatedAt":"2026-10-27T16:10:00.000Z","createdAt":"2026-10-26T09:00:00.000Z",
          "description":"A gift card of £10 shows £1.66 VAT on the receipt. HMRC rounds half up, so it must be £1.67.","branchName":"shop-151-gift-card-vat",
          "cycle":{"isActive":true},"assignee":{"id":"user-ada"},"state":{"name":"In Progress"},"labels":{"nodes":[]}},
         {"identifier":"SHOP-142","title":"Apple Pay button misaligned on small screens","url":"https://linear.app/acme/issue/SHOP-142/apple-pay-button-misaligned",
          "priorityLabel":"High","updatedAt":"2026-10-27T11:00:00.000Z","createdAt":"2026-10-20T10:00:00.000Z",
          "description":"On an iPhone SE the Apple Pay button squeezes to half its width and overlaps the total.","branchName":"shop-142-apple-pay-button",
          "cycle":{"isActive":true},"assignee":{"id":"user-ada"},"state":{"name":"In Review"},"labels":{"nodes":[]}},
         {"identifier":"SHOP-147","title":"Retry webhook delivery on 5xx","url":"https://linear.app/acme/issue/SHOP-147/retry-webhook-delivery-on-5xx",
          "priorityLabel":"High","updatedAt":"2026-10-27T10:00:00.000Z","createdAt":"2026-10-21T14:00:00.000Z",
          "description":"When a merchant's endpoint answers 502, the paid event is lost. Retry with backoff.","branchName":"shop-147-webhook-retries",
          "cycle":{"isActive":true},"assignee":{"id":"user-ada"},"state":{"name":"In Review"},"labels":{"nodes":[]}},
         {"identifier":"SHOP-160","title":"Rate-limit the gift card balance check","url":"https://linear.app/acme/issue/SHOP-160/rate-limit-the-gift-card-balance-check",
          "priorityLabel":"High","updatedAt":"2026-10-28T08:40:00.000Z","createdAt":"2026-10-28T08:40:00.000Z",
          "description":"Bots try card numbers on the balance page. Allow 5 checks a minute for each IP address, then show a message that asks the shopper to wait.",
          "branchName":"shop-160-balance-rate-limit","cycle":{"isActive":true},"assignee":{"id":"user-ada"},"state":{"name":"Todo"},
          "labels":{"nodes":[{"name":"Bug"}]}},
         {"identifier":"SHOP-155","title":"Show the delivery estimate on the basket page","url":"https://linear.app/acme/issue/SHOP-155/show-the-delivery-estimate",
          "priorityLabel":"Medium","updatedAt":"2026-10-26T15:00:00.000Z","createdAt":"2026-10-19T09:00:00.000Z",
          "description":"Shoppers ask when the order arrives before they pay. Show the estimate for their postcode.","branchName":"shop-155-delivery-estimate",
          "cycle":{"isActive":true},"assignee":{"id":"user-ada"},"state":{"name":"In Review"},"labels":{"nodes":[]}},
         {"identifier":"SHOP-153","title":"Save the basket for signed-out shoppers","url":"https://linear.app/acme/issue/SHOP-153/save-the-basket-for-signed-out-shoppers",
          "priorityLabel":"Medium","updatedAt":"2026-10-25T12:00:00.000Z","createdAt":"2026-10-18T09:00:00.000Z",
          "description":"A signed-out shopper loses the basket when the tab closes. Keep it for 30 days.","branchName":"shop-153-saved-basket",
          "cycle":{"isActive":true},"assignee":{"id":"user-ada"},"state":{"name":"Todo"},"labels":{"nodes":[{"name":"Feature"}]}},
         {"identifier":"SHOP-158","title":"Postcode lookup times out on slow networks","url":"https://linear.app/acme/issue/SHOP-158/postcode-lookup-times-out",
          "priorityLabel":"Medium","updatedAt":"2026-10-24T09:00:00.000Z","createdAt":"2026-10-23T09:00:00.000Z",
          "description":"On 3G the lookup gives up after 2 seconds, and the shopper must type the address.","branchName":"shop-158-postcode-timeout",
          "cycle":null,"assignee":{"id":"user-sam"},"state":{"name":"In Progress"},"labels":{"nodes":[]}},
         {"identifier":"SHOP-162","title":"Show the card brand on saved cards","url":"https://linear.app/acme/issue/SHOP-162/show-the-card-brand-on-saved-cards",
          "priorityLabel":"Low","updatedAt":"2026-10-22T09:00:00.000Z","createdAt":"2026-10-22T09:00:00.000Z",
          "description":null,"branchName":"shop-162-card-brand","cycle":null,"assignee":null,"state":{"name":"Backlog"},
          "labels":{"nodes":[{"name":"Feature"}]}},
         {"identifier":"MOB-91","title":"Crash when the basket is empty on iPad","url":"https://linear.app/acme/issue/MOB-91/crash-when-the-basket-is-empty-on-ipad",
          "priorityLabel":"Urgent","updatedAt":"2026-10-28T07:50:00.000Z","createdAt":"2026-10-27T18:00:00.000Z",
          "description":"Open the basket with no items on an iPad in split view. The app crashes.","branchName":"mob-91-ipad-empty-basket",
          "cycle":{"isActive":true},"assignee":{"id":"user-ada"},"state":{"name":"Todo"},"labels":{"nodes":[]}},
         {"identifier":"MOB-88","title":"Show order history offline","url":"https://linear.app/acme/issue/MOB-88/show-order-history-offline",
          "priorityLabel":"High","updatedAt":"2026-10-26T09:00:00.000Z","createdAt":"2026-10-12T09:00:00.000Z",
          "description":"With no network, order history is empty. Keep the last 50 orders on the device.","branchName":"mob-88-offline-history",
          "cycle":{"isActive":true},"assignee":{"id":"user-ada"},"state":{"name":"In Progress"},"labels":{"nodes":[]}},
         {"identifier":"MOB-94","title":"Haptic feedback on add to basket","url":"https://linear.app/acme/issue/MOB-94/haptic-feedback-on-add-to-basket",
          "priorityLabel":"Low","updatedAt":"2026-10-20T09:00:00.000Z","createdAt":"2026-10-20T09:00:00.000Z",
          "description":null,"branchName":"mob-94-haptics","cycle":null,"assignee":null,"state":{"name":"Backlog"},"labels":{"nodes":[]}}
        ]
        """#

    /// The open GitHub issues of each repo.
    static let githubIssues: [(String, [(number: Int, title: String, labels: [String], updated: String, body: String)])] = [
        ("storefront", [
            (214, "Discount code field accepts spaces", ["bug"], "2026-10-27T13:00:00Z",
             "A code pasted with a space at the end is refused as not valid."),
            (211, "Basket badge count lags after remove", ["bug"], "2026-10-23T09:00:00Z",
             "Remove an item, and the badge shows the old count until the page reloads."),
        ]),
        ("payments-api", [
            (61, "Log the Stripe request ID on refunds", ["chore"], "2026-10-25T10:00:00Z",
             "Support needs the request ID to trace a failed refund with Stripe."),
        ]),
        ("ios-app", [
            (132, "Dark mode: order total is hard to read", ["bug"], "2026-10-26T17:00:00Z",
             "The total uses a fixed grey that is too dark on a dark background."),
            (128, "Support Dynamic Type in the basket", ["accessibility"], "2026-10-21T09:00:00Z",
             "The basket rows clip at the largest text sizes."),
        ]),
    ]

    /// What `claude -p` answers: a Shape draft for each issue, and the ship notes of each run. The key is a phrase
    /// of the prompt: the key of the issue for a draft, a phrase of the goal for the notes.
    static let claudeAnswers: [(key: String, json: String)] = [
        ("Issue: SHOP-153", draft(
            goal: "A signed-out shopper finds the same basket after the tab closes, for up to 30 days.",
            checks: [("Basket tests", "go test ./basket/..."), ("Vet", "go vet ./...")],
            assumptions: ["The basket lives in a signed cookie, not in the database, so the store does not change.",
                          "At sign-in, the saved basket merges into the account basket. Quantities add up."],
            plan: ["Write the basket to a signed cookie on each change.", "Read the cookie when a signed-out shopper comes back.",
                   "Merge the cookie basket into the account basket at sign-in.", "Add tests for the cookie round trip and the merge."],
            size: "About 150 lines in the basket package and one handler.")),
        ("Issue: MOB-91", draft(
            goal: "The basket with no items shows its empty state on iPad, in split view too, and the app does not crash.",
            checks: [("Tests", "make test")],
            assumptions: ["The crash is the split view that asks for row 0 of an empty list."],
            plan: ["Show the empty state when the basket has no rows.", "Add a UI test for an empty basket in split view."],
            size: "About 30 lines in BasketView.")),
        ("5xx answer with backoff", notes(
            walkthrough: "Deliver now retries an event when the merchant's endpoint answers with a 5xx or the network fails. "
                + "It waits 1, 2, then 4 seconds between attempts, and gives up after 4. A 4xx answer still fails at once, because "
                + "a retry cannot fix it.",
            files: [("webhook/deliver.go", "The retry loop"), ("webhook/deliver_test.go", "Tests")],
            risk: "medium", reasons: ["A slow endpoint now holds a worker for up to 7 seconds.",
                                      "The tests replace the wait, so they do not prove the real backoff."],
            stands: "Webhook retries are ready to land. Next: the gift card VAT fix, then saved baskets.")),
        ("narrower than 375 points", notes(
            walkthrough: "The pay buttons now wrap under the total on screens narrower than 375 points, so the Apple Pay "
                + "button keeps its full size.",
            files: [("web/static/checkout.css", "The fix")], risk: "low",
            reasons: ["One CSS rule in a media query. Wider screens do not change."],
            stands: "The Apple Pay fix is ready to land.")),
        ("delivery estimate for the postcode", notes(
            walkthrough: "The basket page asks the courier API for the estimate of the postcode, and shows it under the total.",
            files: [("basket/estimate.go", "The estimate")], risk: "low",
            reasons: ["A failed call shows no estimate. Checkout still works."], stands: "The delivery estimate is in CI.")),
        ("reads clearly in dark mode", notes(
            walkthrough: "The order total uses the label colour, so it follows dark mode.",
            files: [("App/Basket/TotalView.swift", "The fix")], risk: "low", reasons: ["One colour in one view."],
            stands: "The dark mode fix is ready to land.")),
        ("keeps the postcode", notes(
            walkthrough: "The address form keeps the postcode in the form state, so Back shows it again.",
            files: [("web/templates/address.html", "The form")], risk: "low", reasons: ["One template."],
            stands: "The address form is live.")),
        ("opens the order in the app", notes(
            walkthrough: "A universal link to an order now opens the order screen, not the home screen.",
            files: [("App/Orders/OrderLink.swift", "The route")], risk: "low", reasons: ["One new route."],
            stands: "Order links open in the app.")),
        ("PayPal is off", notes(
            walkthrough: "The checkout page hides the PayPal button when PayPal is off in the shop settings.",
            files: [("web/templates/paypal.html", "The button")], risk: "low", reasons: ["One template."],
            stands: "Apple Pay and the new address form are live.")),
    ]

    private static func draft(goal: String, checks: [(String, String)], assumptions: [String], plan: [String], size: String) -> String {
        json(["type": "result", "subtype": "success", "is_error": false, "result": "", "structured_output": [
            "goal": goal, "checks": checks.map { ["name": $0.0, "command": $0.1] }, "assumptions": assumptions,
            "plan": plan, "size": size,
        ]])
    }

    private static func notes(walkthrough: String, files: [(String, String)], risk: String, reasons: [String], stands: String) -> String {
        json(["type": "result", "subtype": "success", "is_error": false, "result": "", "structured_output": [
            "walkthrough": walkthrough, "files": files.map { ["path": $0.0, "role": $0.1] },
            "risk": ["level": risk, "reasons": reasons], "where_it_stands": stands,
        ]])
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    // MARK: The repos

    static let storefrontFiles: [(String, String)] = [
        ("go.mod", "module github.com/acme/storefront\n\ngo 1.22\n"),
        ("README.md", "# storefront\n\nThe web shop: the catalogue, the basket, and checkout.\n"),
        ("basket/basket.go", """
            // Package basket holds what a shopper is about to buy.
            package basket

            // Item is one line of the basket. Prices are in pence.
            type Item struct {
                SKU      string
                Name     string
                Price    int64
                Quantity int
            }

            // Basket is the items of one shopper.
            type Basket struct {
                Items []Item
            }

            // Total is the sum of the lines, in pence.
            func (b Basket) Total() int64 {
                var total int64
                for _, it := range b.Items {
                    total += it.Price * int64(it.Quantity)
                }
                return total
            }

            // Count is the number of things in the basket, for the badge.
            func (b Basket) Count() int {
                n := 0
                for _, it := range b.Items {
                    n += it.Quantity
                }
                return n
            }

            """),
        ("basket/basket_test.go", """
            package basket

            import "testing"

            func TestTotalAndCount(t *testing.T) {
                b := Basket{Items: []Item{{SKU: "MUG-01", Price: 1200, Quantity: 2}, {SKU: "TEA-07", Price: 450, Quantity: 1}}}
                if b.Total() != 2850 || b.Count() != 3 {
                    t.Fatalf("total %d, count %d", b.Total(), b.Count())
                }
            }

            """),
        ("web/render.go", """
            // Package web renders the checkout pages.
            package web

            import (
                "embed"
                "html/template"
            )

            //go:embed templates/*.html
            var files embed.FS

            // Pages are the parsed page templates.
            var Pages = template.Must(template.ParseFS(files, "templates/*.html"))

            """),
        ("web/render_test.go", """
            package web

            import "testing"

            func TestTheCheckoutPageParses(t *testing.T) {
                if Pages.Lookup("checkout.html") == nil {
                    t.Fatal("no checkout page")
                }
            }

            """),
        ("web/templates/checkout.html", """
            <section class="checkout">
              <h1>Checkout</h1>
              <div class="total-row">
                <span class="total">{{.Total}}</span>
                <div class="pay-buttons">
                  <button class="apple-pay" aria-label="Pay with Apple Pay"></button>
                  <button class="card">Pay by card</button>
                </div>
              </div>
            </section>

            """),
        ("web/static/checkout.css", checkoutCSS),
    ]

    static let checkoutCSS = """
        .total-row {
          display: flex;
          align-items: center;
          justify-content: space-between;
        }

        .pay-buttons {
          display: flex;
          gap: 8px;
        }

        .apple-pay {
          width: 180px;
          height: 44px;
          -webkit-appearance: -apple-pay-button;
        }

        """

    static let checkoutCSSFixed = checkoutCSS + """

        /* Below 375 points, the pay buttons wrap under the total at full width. */
        @media (max-width: 374px) {
          .total-row {
            flex-direction: column;
            align-items: stretch;
          }

          .apple-pay {
            width: 100%;
          }
        }

        """

    static let addressForm = """
        <form class="address" method="post">
          <label>Postcode <input name="postcode" value="{{.Postcode}}" autocomplete="postal-code"></label>
          <button>Find address</button>
        </form>

        """

    static let paypalButton = """
        {{if .PayPalOn}}<button class="paypal">Pay with PayPal</button>{{end}}

        """

    static let estimateGo = """
        package basket

        import "time"

        // Estimate is when an order to the postcode arrives, from the courier.
        type Estimate struct {
            Postcode string
            From, To time.Time
        }

        """

    static let lookupGo = """
        // Package postcode finds the addresses of a postcode.
        package postcode

        import "time"

        // lookupTimeout is how long a lookup waits for the address API.
        const lookupTimeout = 4 * time.Second

        """

    static let lookupTest = """
        package postcode

        import (
            "testing"
            "time"
        )

        func TestLookupWaitsForASlowNetwork(t *testing.T) {
            // A 3G network in the test lab answers in 6 seconds.
            if lookupTimeout < 6*time.Second {
                t.Fatalf("lookupTimeout is %s; a slow network needs 6s", lookupTimeout)
            }
        }

        """

    static let paymentsFiles: [(String, String)] = [
        ("go.mod", "module github.com/acme/payments-api\n\ngo 1.22\n"),
        ("README.md", "# payments-api\n\nPayments, refunds, and merchant webhooks.\n"),
        ("RUNBOOK.md", "# Payments runbook\n\n## A webhook fails\n\nCheck the merchant endpoint first.\n"),
        ("webhook/deliver.go", """
            // Package webhook tells merchants about payment events.
            package webhook

            import (
                "bytes"
                "context"
                "fmt"
                "net/http"
            )

            // Deliver posts the event to the merchant's endpoint once.
            func Deliver(ctx context.Context, c *http.Client, url string, body []byte) error {
                req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
                if err != nil {
                    return err
                }
                req.Header.Set("Content-Type", "application/json")
                resp, err := c.Do(req)
                if err != nil {
                    return err
                }
                defer resp.Body.Close()
                if resp.StatusCode >= 300 {
                    return fmt.Errorf("webhook: %s answered %d", url, resp.StatusCode)
                }
                return nil
            }

            """),
        ("vat/vat.go", """
            // Package vat works out the VAT in a price.
            package vat

            // GiftCardVAT is the VAT in pence in a gift card sale of gross pence, at the
            // rate in basis points (2000 is 20%).
            func GiftCardVAT(gross, rateBP int64) int64 {
                return gross * rateBP / (10000 + rateBP)
            }

            """),
        ("vat/vat_test.go", vatTest),
    ]

    static let vatTest = """
        package vat

        import "testing"

        func TestGiftCardVATRoundsHalfUp(t *testing.T) {
            // 1000 gross at 20% holds 166.67 VAT, which HMRC rounds to 167.
            if got := GiftCardVAT(1000, 2000); got != 167 {
                t.Fatalf("GiftCardVAT(1000, 2000) = %d, want 167", got)
            }
        }

        """

    static let vatTestMore = vatTest + """

        func TestGiftCardVATOfRoundAmounts(t *testing.T) {
            for gross, want := range map[int64]int64{1200: 200, 6000: 1000} {
                if got := GiftCardVAT(gross, 2000); got != want {
                    t.Errorf("GiftCardVAT(%d, 2000) = %d, want %d", gross, got, want)
                }
            }
        }

        """

    static let deliverRetry = """
        // Package webhook tells merchants about payment events.
        package webhook

        import (
            "bytes"
            "context"
            "fmt"
            "net/http"
            "time"
        )

        // maxAttempts is how many times Deliver posts an event before it gives up.
        const maxAttempts = 4

        // sleep waits between attempts. The tests replace it.
        var sleep = func(ctx context.Context, d time.Duration) error {
            select {
            case <-ctx.Done():
                return ctx.Err()
            case <-time.After(d):
                return nil
            }
        }

        // Deliver posts the event to the merchant's endpoint. A 5xx answer or a
        // network error gets another attempt after a backoff. A 4xx answer does not.
        func Deliver(ctx context.Context, c *http.Client, url string, body []byte) error {
            var last error
            for attempt := 1; attempt <= maxAttempts; attempt++ {
                status, err := post(ctx, c, url, body)
                switch {
                case err == nil && status < 300:
                    return nil
                case err == nil && status < 500:
                    return fmt.Errorf("webhook: %s answered %d", url, status)
                case err == nil:
                    last = fmt.Errorf("webhook: %s answered %d", url, status)
                default:
                    last = err
                }
                if attempt < maxAttempts {
                    if err := sleep(ctx, backoff(attempt)); err != nil {
                        return err
                    }
                }
            }
            return fmt.Errorf("webhook: gave up after %d attempts: %w", maxAttempts, last)
        }

        // backoff is the wait after an attempt: 1s, 2s, then 4s.
        func backoff(attempt int) time.Duration { return time.Second << (attempt - 1) }

        func post(ctx context.Context, c *http.Client, url string, body []byte) (int, error) {
            req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
            if err != nil {
                return 0, err
            }
            req.Header.Set("Content-Type", "application/json")
            resp, err := c.Do(req)
            if err != nil {
                return 0, err
            }
            resp.Body.Close()
            return resp.StatusCode, nil
        }

        """

    static let deliverTest = """
        package webhook

        import (
            "context"
            "net/http"
            "net/http/httptest"
            "testing"
            "time"
        )

        func TestDeliverRetriesA5xx(t *testing.T) {
            var waits []time.Duration
            sleep = func(_ context.Context, d time.Duration) error { waits = append(waits, d); return nil }
            calls := 0
            srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
                calls++
                if calls < 3 {
                    w.WriteHeader(http.StatusBadGateway)
                }
            }))
            defer srv.Close()
            if err := Deliver(context.Background(), srv.Client(), srv.URL, []byte(`{}`)); err != nil {
                t.Fatal(err)
            }
            if calls != 3 || len(waits) != 2 || waits[1] != 2*time.Second {
                t.Fatalf("%d calls, waits %v", calls, waits)
            }
        }

        func TestDeliverDoesNotRetryA4xx(t *testing.T) {
            calls := 0
            srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
                calls++
                w.WriteHeader(http.StatusGone)
            }))
            defer srv.Close()
            if err := Deliver(context.Background(), srv.Client(), srv.URL, []byte(`{}`)); err == nil || calls != 1 {
                t.Fatalf("err %v after %d calls", err, calls)
            }
        }

        """

    static let iosFiles: [(String, String)] = [
        ("README.md", "# ios-app\n\nThe iOS app of the shop.\n"),
        ("Makefile", "test:\n\t@echo 'Test Suite All tests passed'\n"),
        ("App/Basket/TotalView.swift", totalView),
    ]

    static let totalView = """
        import SwiftUI

        struct TotalView: View {
            let total: Decimal

            var body: some View {
                Text(total, format: .currency(code: "GBP"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color(white: 0.25))
            }
        }

        """

    static let totalViewFixed = totalView.replacingOccurrences(of: "Color(white: 0.25)", with: "Color(.label)")

    static let orderLinkSwift = """
        import Foundation

        /// The order that a universal link names, such as /orders/4821.
        struct OrderLink {
            let orderID: String

            init?(url: URL) {
                let parts = url.pathComponents
                guard parts.count == 3, parts[1] == "orders" else { return nil }
                orderID = parts[2]
            }
        }

        """
}

@MainActor
extension Scenarios {
    /// The shots of the pages of runs, in the window of `readme-shots`. `shot` takes the main window, and `window`
    /// takes another window, such as the settings window.
    static func runPages(_ app: DriverApp, _ host: AppHost, _ stage: ReadmeShotStage,
                         shot: (String) async throws -> Void, window: (String, NSWindow?) async throws -> Void) async throws {
        let model = host.model
        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            await app.sleep(1)
        }
        func run(_ name: String) throws -> String {
            guard let id = stage.runs[name] else { throw DriverFailure("no run \(name)") }
            return id
        }
        await model.reloadRuns()

        // Today: the desk, the line, While you were away, and the limits.
        await appearance(.darkAqua)
        try app.click("sidebar-today")
        try await app.waitUntil("Today reads its data", timeout: 60) {
            model.page == .today && app.exists("today-limits") && model.todayData.usage?.sevenDay != nil
                && !model.todayData.awayEvents.isEmpty && model.todayData.limits?.atATime == 3
        }
        try await app.waitUntil("a chip for each run on the line", timeout: 30) {
            ["webhook", "applePay", "delivery", "vat", "discount", "history", "darkMode", "refunds"]
                .allSatisfy { stage.runs[$0].map { app.exists("today-chip-\($0)") } == true }
        }
        await app.sleep(1)
        try await shot("hero-night")
        await appearance(.aqua)
        try await shot("hero-day")
        await appearance(.darkAqua)

        // Intake of Checkout: Linear and GitHub issues, one selected, with its detail, and the bar of the checked row
        // at the sidebar width of the other shots.
        await model.showIntake(plot: stage.checkout)
        let key = stage.intakeKey
        try await app.waitUntil("the intake lists Linear and GitHub issues", timeout: 60) {
            app.exists("intake-row-\(key)") && model.intake?.items.contains { $0.key.contains("214") } == true
        }
        try app.click("intake-row-\(key)")
        try await app.waitUntil("the detail") { app.exists("intake-detail") && app.exists("intake-text") }
        try app.click("intake-check-\(key)")
        try await app.waitUntil("the bar shows") { app.exists("intake-batch-start") }
        await app.sleep(0.5)
        try await shot("intake-night")
        await appearance(.aqua)
        try await shot("intake-day")
        await appearance(.darkAqua)
        try app.click("intake-check-\(key)")
        try await app.waitUntil("the bar goes") { !app.exists("intake-batch") }

        // A Shape draft at the desk.
        let draft = try run("savedBasket")
        await model.openDesk(draft)
        try await app.waitUntil("the desk shows the draft", timeout: 30) {
            model.page == .desk && model.desk.runID == draft && app.exists("desk-shape") && app.exists("desk-plan")
        }
        await app.sleep(0.5)
        try await shot("desk-shape")

        // A run's page while it runs, on its second try.
        let vat = try run("vat")
        await model.openRun(vat)
        try await app.waitUntil("the run page", timeout: 30) {
            model.page == .run(vat) && model.runStatus?.run.id == vat && app.exists("run-page-history")
        }
        await app.sleep(0.5)
        try await shot("run-page")

        // Land at the desk, with a note on a line.
        let land = try run("webhook")
        await model.openDesk(land)
        try await app.waitUntil("the desk shows the diff", timeout: 30) {
            model.page == .desk && model.desk.runID == land && app.exists("desk-file-\(stage.noteFile)")
                && app.exists("desk-line-\(stage.noteLine)") && app.exists("desk-walkthrough") && app.exists("desk-risk")
        }
        model.addDeskNote(file: stage.noteFile, line: stage.noteLine,
                          text: "Read this from the merchant's settings. Two merchants asked for 6 attempts.")
        try await app.waitUntil("the note shows") { app.exists("desk-note-\(stage.noteLine)") }
        await app.sleep(0.5)
        try await shot("desk-land")

        // The recurring runs of Checkout.
        await model.showRecurring(plot: stage.checkout)
        try await app.waitUntil("the recurring runs", timeout: 30) {
            model.page == .recurring(stage.checkout) && model.recurring.count == 3 && model.tickStatus != nil
        }
        await app.sleep(0.5)
        try await shot("recurring")
        model.showToday()

        // Settings: the Runs tab, and the Connections tab with Linear.
        try app.pressMenuKey(",")
        func settingsWindow() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == "dev.loam.settings" && $0.isVisible }
        }
        try await app.waitUntil("the settings window") { settingsWindow() != nil }
        guard let tabs = settingsWindow()?.contentViewController as? NSTabViewController else {
            throw DriverFailure("the settings window has no tabs")
        }
        func select(_ tab: String) throws {
            guard let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == tab }) else {
                throw DriverFailure("the settings window has no \(tab) tab")
            }
            tabs.selectedTabViewItemIndex = index
        }
        try select("Runs")
        try await app.waitUntil("the limits and the usage", timeout: 30) {
            model.runsSettings.limits?.atATime == 3 && app.text(of: "settings-runs-usage")?.contains("41") == true
        }
        await app.sleep(0.5)
        try await window("settings-runs", settingsWindow())
        try select("Connections")
        try await app.waitUntil("Linear is connected", timeout: 30) {
            model.connections.linear?.connected == true && model.connections.scopeRows.count >= 2 && model.connections.updates != nil
        }
        if model.connections.updates?.walkthroughComment == false {
            try app.click("settings-update-walkthrough")
            try await app.waitUntil("the walkthrough switch") { model.connections.updates?.walkthroughComment == true }
        }
        await app.sleep(0.5)
        try await window("settings-linear", settingsWindow())
        settingsWindow()?.close()
    }
}

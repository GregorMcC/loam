import AppKit
import LoamKit
import LoamTerminal

/// Driver scenarios for ticket 98: drag to reorder tabs in the tab bar (`tab-drag`) and plots in the
/// sidebar (`plot-drag`). Each drags past two others and checks the new order, then checks that
/// Escape and a release outside cancel, that a short move is a click, and the Reduce Motion
/// insertion line. Screenshots mid-drag show the gap. They use a temp `LOAM_HOME` and a fake HOME. `plot-drag` also
/// presses a plot while `loam move` holds the last move (ticket 125).
@MainActor
extension Scenarios {
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    // MARK: Tabs

    static func tabDrag(_ app: DriverApp) async throws {
        defer { LoamMotion.reduceMotionOverride = nil }
        do { try await tabDragSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func tabDragSteps(_ app: DriverApp) async throws {
        LoamMotion.reduceMotionOverride = false
        let rig = try PanelRig(outFolder: app.outFolder)
        let plot = try rig.newPlot("Tab drag")
        // Placeholder panes: no shell sets a title, so the pill widths stay put during the run.
        let host = try await app.launchApp(client: rig.client, state: rig.stateFile)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        for _ in 0..<4 { model.openTab() }
        try await app.waitUntil("four tabs") { model.workspace.tabs(of: .plot(plot)).count == 4 }
        func ids() -> [UUID] { model.workspace.tabs(of: .plot(plot)).map(\.id) }
        func selected() -> UUID? { model.workspace.selectedTab(of: .plot(plot))?.id }
        let start = ids()
        // The last tab is selected. The drag moves the first, so the selection must not follow it.
        try check(selected() == start[3], "the last tab is not selected")
        guard let content = app.window.contentView?.superview, let bar = tabBar(in: content) else {
            throw DriverFailure("no tab bar")
        }
        content.layoutSubtreeIfNeeded()
        func frames(_ count: Int) -> [CGRect?] { (0..<count).map { bar.tabFrame(at: $0) } }
        func shown(_ count: Int) -> [CGRect?] { (0..<count).map { bar.shownTabFrame(at: $0) } }
        /// True when no tab keeps an offset and no drag runs. A cancel slides the tabs back, and the drag ends after the
        /// slide. A press before that end starts no drag (ticket 131).
        func atRest(_ count: Int = 4) -> Bool { !bar.isDragging && shown(count) == frames(count) }
        /// True when the tab at a 0-based position draws at `x`: its slide has ended.
        func slid(_ index: Int, to x: CGFloat) -> Bool { abs((bar.shownTabFrame(at: index)?.minX ?? .infinity) - x) < 0.5 }
        var laidOut: [CGRect?] = []
        try await app.waitUntil("the tab bar shows four tabs") {
            content.layoutSubtreeIfNeeded()
            defer { laidOut = frames(4) }
            return !laidOut.contains { $0 == nil } && laidOut == frames(4)
        }
        func frame(_ index: Int) throws -> CGRect {
            guard let frame = bar.tabFrame(at: index) else { throw DriverFailure("no tab \(index + 1)") }
            return frame
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { bar.convert(CGPoint(x: x, y: y), to: nil) }
        /// Moves the pointer from `from` to `to` in steps of 6 pt, as a hand does.
        func glide(from: CGPoint, to: CGPoint) async {
            let steps = max(1, Int(hypot(to.x - from.x, to.y - from.y) / 6))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                app.mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), on: bar)
                await app.sleep(0.008)
            }
        }

        // 1. Drag tab 1 past tabs 2 and 3.
        let one = try frame(0), two = try frame(1), three = try frame(2)
        let grab = point(one.midX, one.midY)
        app.mouse(.leftMouseDown, at: grab, on: bar)
        let pastTwo = point(two.midX + 6, one.midY)
        await glide(from: grab, to: pastTwo)
        try check(bar.isDragging, "the drag of tab 1 did not start")
        await app.sleep(0.07)
        app.screenshot("tab-drag-mid-slide")
        try await app.waitUntil("tab 2 slides into the slot of tab 1") { slid(1, to: one.minX) }
        let pastThree = point(three.midX + 6, one.midY)
        await glide(from: pastTwo, to: pastThree)
        // Tab 3 takes the slot after tab 2, which now sits in the slot of tab 1.
        try await app.waitUntil("tab 3 slides into the slot of tab 2") { slid(2, to: one.minX + two.width + (two.minX - one.maxX)) }
        app.screenshot("tab-drag-past-two")
        let shownOne = bar.shownTabFrame(at: 0) ?? .zero
        try check(abs(shownOne.midX - (three.midX + 6)) < 1, "the dragged tab does not follow the pointer: \(shownOne)")
        try check(ids() == start, "the order changed before the release")
        app.mouse(.leftMouseUp, at: pastThree, on: bar)
        try await app.waitUntil("the tab lands in slot 3") { ids() == [start[1], start[2], start[0], start[3]] }
        try check(selected() == start[3], "the drag changed the selected tab")
        try await app.waitUntil("the tabs are at rest after the drop") { atRest() }
        app.screenshot("tab-drag-dropped")
        // ⌘1 follows the new order.
        model.selectTab(number: 1)
        try check(selected() == start[1], "⌘1 does not follow the new order")
        model.selectTab(number: 4)
        Log.line("RESULT dragged tab 1 past two tabs, the selection stayed")

        // 2. Escape sends it back.
        let order = ids()
        var first = try frame(0)
        app.mouse(.leftMouseDown, at: point(first.midX, first.midY), on: bar)
        let right = point((try frame(1)).maxX + 4, first.midY)
        await glide(from: point(first.midX, first.midY), to: right)
        try check(bar.isDragging, "the drag of tab 1 before Escape did not start")
        try await app.waitUntil("tab 2 slides into the slot of tab 1 before Escape") { slid(1, to: first.minX) }
        app.pressThroughApp(.escape)
        try await app.waitUntil("Escape puts the tabs back") { atRest() }
        app.mouse(.leftMouseUp, at: right, on: bar)
        try check(ids() == order, "Escape changed the order")
        try check(selected() == order[3], "the release after Escape selected a tab")
        Log.line("RESULT Escape sent the tab back")

        // 3. A release outside the bar sends it back.
        first = try frame(0)
        app.mouse(.leftMouseDown, at: point(first.midX, first.midY), on: bar)
        await glide(from: point(first.midX, first.midY), to: right)
        try check(bar.isDragging, "the second drag of tab 1 did not start")
        let below = point((try frame(1)).maxX + 4, bar.bounds.height + 80)
        await glide(from: right, to: below)
        app.mouse(.leftMouseUp, at: below, on: bar)
        try await app.waitUntil("the release outside puts the tabs back") { atRest() }
        try check(ids() == order, "a release outside the bar changed the order")
        Log.line("RESULT a release outside the bar sent the tab back")

        // 4. A move under 4 pt is a click: it selects the tab.
        let second = try frame(1)
        app.mouse(.leftMouseDown, at: point(second.midX, second.midY), on: bar)
        app.mouse(.leftMouseDragged, at: point(second.midX + 2, second.midY), on: bar)
        try check(!bar.isDragging, "a move under 4 pt started a drag")
        app.mouse(.leftMouseUp, at: point(second.midX + 2, second.midY), on: bar)
        try await app.waitUntil("the click selects tab 2") { selected() == order[1] }
        try check(ids() == order, "a click moved a tab")

        // 5. Reduce Motion: nothing slides, a line marks the drop point, the release moves it at once.
        LoamMotion.reduceMotionOverride = true
        let last = try frame(3)
        app.mouse(.leftMouseDown, at: point(last.midX, last.midY), on: bar)
        let left = point((try frame(1)).midX - 6, last.midY)
        await glide(from: point(last.midX, last.midY), to: left)
        try check(bar.isDragging, "the drag of tab 4 under Reduce Motion did not start")
        await app.sleep(0.1)
        try check(shown(4) == frames(4), "a tab moved under Reduce Motion")
        app.screenshot("tab-drag-reduce-motion")
        app.mouse(.leftMouseUp, at: left, on: bar)
        try check(ids() == [order[0], order[3], order[1], order[2]], "the Reduce Motion drop did not move the tab at once: \(ids())")
        Log.line("RESULT Reduce Motion showed the line and moved the tab at once")

        // 6. Ten tabs: each pointer move and the redraw of the bar fit well inside one frame: the worst move in time of the
        // main thread on the CPU, and the median move on the clock. A busy machine can hold the thread off the CPU for a
        // frame, which only the worst move on the clock counts (ticket 125).
        LoamMotion.reduceMotionOverride = false
        for _ in 0..<6 { model.openTab() }
        try await app.waitUntil("ten tabs") { ids().count == 10 }
        laidOut = []
        try await app.waitUntil("the tab bar shows ten tabs") {
            content.layoutSubtreeIfNeeded()
            defer { laidOut = frames(10) }
            return !laidOut.contains { $0 == nil } && laidOut == frames(10)
        }
        try await app.waitUntil("the tabs are at rest after the Reduce Motion drop") { atRest(10) }
        let head = try frame(0), tail = try frame(9)
        var at = point(head.midX, head.midY)
        app.mouse(.leftMouseDown, at: at, on: bar)
        var cpu: [Double] = [], wall: [Double] = []
        while at.x < bar.convert(CGPoint(x: tail.midX, y: 0), to: nil).x {
            at.x += 6
            let begin = (cpu: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), wall: ProcessInfo.processInfo.systemUptime)
            app.mouse(.leftMouseDragged, at: at, on: bar)
            bar.layoutSubtreeIfNeeded()
            bar.display()
            cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - begin.cpu) / 1_000_000)
            wall.append((ProcessInfo.processInfo.systemUptime - begin.wall) * 1000)
            await app.sleep(0.008)
        }
        try check(bar.isDragging, "the drag across ten tabs did not start")
        app.screenshot("tab-drag-ten-tabs")
        app.pressThroughApp(.escape)
        try await app.waitUntil("Escape puts the ten tabs back") { atRest(10) }
        app.mouse(.leftMouseUp, at: at, on: bar)
        let worst = cpu.max() ?? 0, mean = cpu.reduce(0, +) / Double(max(cpu.count, 1))
        let median = wall.sorted().dropFirst(wall.count / 2).first ?? 0
        Log.line(String(format: "RESULT ten tabs: %d moves, mean %.2f ms, worst %.2f ms of CPU per move and redraw, median %.2f ms on the clock",
                        cpu.count, mean, worst, median))
        try check(worst < 8, "a move and redraw took \(worst) ms of CPU, more than one frame at 120 Hz")
        try check(median < 8, "the median move and redraw took \(median) ms, more than one frame at 120 Hz")
    }

    private static func tabBar(in view: NSView) -> (any FirstTabFraming)? {
        (view as? any FirstTabFraming) ?? view.subviews.lazy.compactMap(tabBar).first
    }

    // MARK: Plots

    static func plotDrag(_ app: DriverApp) async throws {
        defer { LoamMotion.reduceMotionOverride = nil }
        do { try await plotDragSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func plotDragSteps(_ app: DriverApp) async throws {
        LoamMotion.reduceMotionOverride = false
        let rig = try PanelRig(outFolder: app.outFolder)
        // An archived plot first in the store order, so the move position must count it.
        let old = try rig.newPlot("Old work")
        let p1 = try rig.newPlot("Loam v1 build"), p2 = try rig.newPlot("Recipe manager")
        let p3 = try rig.newPlot("Client onboarding"), p4 = try rig.newPlot("Release notes")
        let p5 = try rig.newPlot("Reading list")
        try rig.loam(["archive", old])
        // The app's `loam` holds a `move` while the file `hold` exists, so a step can press while a move is not stored.
        // The hold also ends when the app ends, so a failed run leaves no wait behind.
        let hold = rig.root.appendingPathComponent("hold-move")
        let held = rig.root.appendingPathComponent("loam-held")
        try """
            #!/bin/sh
            if [ "$1" = move ]; then
              while [ -e "$LOAM_DRIVER_HOLD" ] && kill -0 $PPID 2>/dev/null; do sleep 0.05; done
            fi
            exec "$LOAM_DRIVER_REAL_LOAM" "$@"

            """.write(to: held, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: held.path)
        let environment = rig.environment.merging(["LOAM_DRIVER_HOLD": hold.path, "LOAM_DRIVER_REAL_LOAM": rig.binary.path]) { $1 }
        let host = try await app.launchApp(client: LoamClient(binary: held, environment: environment), state: rig.stateFile)
        let model = host.model
        try await app.waitUntil("the plots load") { model.plots.count == 5 }
        // Plots 1 to 4 have panes. Plot 1 is active, so its tree is open. Plot 5 is in "No panes".
        for plot in [p4, p3, p2] {
            model.activate(plot: plot)
            model.openTab()
        }
        model.activate(plot: p1)
        model.openTab()
        model.openTab()
        try await app.waitUntil("4 plots with panes") { model.sidebar.withPanes.count == 4 }
        guard let root = app.window.contentView?.superview else { throw DriverFailure("no window content") }
        func handle(_ plot: String) throws -> NSView {
            root.layoutSubtreeIfNeeded()
            guard let view = find(root, "plot-drag-\(plot)") else { throw DriverFailure("no drag handle for \(plot)") }
            return view
        }
        try await app.waitUntil("the plot rows show") { (try? handle(p4)) != nil }
        // A drag reads the rows at the press and ends when a row comes or goes, so the tree of plot 1 must show first.
        let tree = model.workspace.tabs(of: .plot(p1)).flatMap(\.tree.paneIDs)
        try await app.waitUntil("the tree of plot 1 shows") { tree.allSatisfy { app.exists("pane-row-\($0.uuidString)") } }
        func center(_ plot: String) throws -> CGPoint {
            let view = try handle(plot)
            return view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        func storeOrder() throws -> [String] {
            let text = try rig.loam(["list", "--json"])
            let rows = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] ?? []
            return rows.compactMap { $0["id"] as? String }
        }
        func glide(_ view: NSView, from: CGPoint, to: CGPoint) async {
            let steps = max(1, Int(hypot(to.x - from.x, to.y - from.y) / 6))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                app.mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), on: view)
                await app.sleep(0.008)
            }
        }
        /// True when no row of the sidebar list keeps an offset or a dimmed look, and no row sits above the others. A
        /// cancel puts the offsets back at once and slides the rows, and the dragged rows sit above until the slide ends.
        /// A press before that end starts no drag (ticket 125).
        func rowsAtRest() -> Bool {
            guard let outline = findOutline(root) else { return false }
            return (0..<outline.numberOfRows).allSatisfy { row in
                guard let view = outline.rowView(atRow: row, makeIfNecessary: false) else { return true }
                return CATransform3DIsIdentity(view.layer?.transform ?? CATransform3DIdentity) && view.alphaValue == 1
                    && (view.layer?.zPosition ?? 0) == 0
            }
        }
        /// Waits until no plot row moves from one check to the next: the outline has ended the slides of a tree that opened
        /// or closed. A drag reads the rows at the press, so the press must come after it.
        func waitForRowsToStand(_ what: String, _ plots: [String]) async throws {
            var seen: [CGPoint]?
            try await app.waitUntil(what) {
                let now = plots.compactMap { try? center($0) }
                defer { seen = now }
                return now.count == plots.count && now == seen
            }
        }
        try await waitForRowsToStand("the plot rows stand still", [p1, p2, p3, p4, p5])
        let start = model.plots.map(\.id)
        try check(start == [p1, p2, p3, p4, p5], "the start order is \(start)")
        app.screenshot("plot-drag-start")

        // 1. Drag plot 1 (open, with its tree) down past plots 2 and 3. Window y grows upward. The
        // plot moves by its edges, so a move of one row height passes one collapsed plot.
        let grabView = try handle(p1)
        let grab = try center(p1)
        let row = try center(p2).y - center(p3).y
        let pastTwo = CGPoint(x: grab.x, y: grab.y - row)
        let pastThree = CGPoint(x: grab.x, y: grab.y - 2 * row)
        app.mouse(.leftMouseDown, at: grab, on: grabView)
        await glide(grabView, from: grab, to: pastTwo)
        await app.sleep(0.08)
        app.screenshot("plot-drag-mid-slide")
        await app.sleep(0.3)
        app.screenshot("plot-drag-past-one")
        await glide(grabView, from: pastTwo, to: pastThree)
        await app.sleep(0.35)
        app.screenshot("plot-drag-past-two")
        try check(model.plots.map(\.id) == start, "the order changed before the release")
        // `loam move` waits until the press below has run.
        FileManager.default.createFile(atPath: hold.path, contents: nil)
        app.mouse(.leftMouseUp, at: pastThree, on: grabView)
        let moved = [p2, p3, p1, p4, p5]
        try await app.waitUntil("the sidebar shows the new order") { model.plots.map(\.id) == moved }
        try await app.waitUntil("the rows are at rest") { rowsAtRest() }
        app.screenshot("plot-drag-dropped")
        // Ticket 125: before the move is stored, a plot does not drag, and the release of that press is not a click.
        try check(model.isMovingPlot, "the app did not wait for the move that loam holds")
        var view = try handle(p2)
        var from = try center(p2)
        let downOne = CGPoint(x: from.x, y: from.y - row)
        app.mouse(.leftMouseDown, at: from, on: view)
        await glide(view, from: from, to: downOne)
        try check(rowsAtRest(), "a plot dragged before the last move was stored")
        app.mouse(.leftMouseUp, at: downOne, on: view)
        try check(model.workspace.activePlotID == p1, "the release of a drag that could not start selected a plot")
        try check(model.plots.map(\.id) == moved, "a drag that could not start changed the order")
        try FileManager.default.removeItem(at: hold)
        try await app.waitUntil("loam move stored the order") { (try? storeOrder()) == moved }
        // A new drag starts only when the app has the move: `loam move` and the plot list read after it.
        try await app.waitUntil("the app has the move") { !model.isMovingPlot }
        let numbers = model.sidebar.withPanes.map { "\($0.id)=\($0.number ?? 0)" }
        try check(model.sidebar.withPanes.map(\.id) == [p2, p3, p1, p4]
                  && model.sidebar.withPanes.map(\.number) == [1, 2, 3, 4], "the ⌃ numbers do not follow: \(numbers)")
        try check(model.workspace.activePlotID == p1, "the drag changed the active plot")
        try check(app.text(of: "plot-\(p1)")?.contains("\u{2303}3") ?? true, "the row of plot 1 does not show ⌃3")
        // The archived plot kept its place first in the store order.
        let full = try rig.loam(["export"])
        try check(full.range(of: old).map { $0.lowerBound < full.range(of: p2)!.lowerBound } == true,
                  "the archived plot moved in the store order")
        Log.line("RESULT dragged plot 1 down two rows, store order and ⌃ numbers follow")
        Log.line("RESULT a press before the move was stored did not drag or select")

        // 2. Escape sends the rows back.
        view = try handle(p2)
        from = try center(p2)
        app.mouse(.leftMouseDown, at: from, on: view)
        await glide(view, from: from, to: downOne)
        try await app.waitUntil("the drag of plot 2 starts") { !rowsAtRest() }
        app.pressThroughApp(.escape)
        try await app.waitUntil("Escape puts the rows back") { rowsAtRest() }
        app.mouse(.leftMouseUp, at: downOne, on: view)
        await app.sleep(0.2)
        try check(model.plots.map(\.id) == moved, "Escape changed the order")
        try check(model.workspace.activePlotID == p1, "the release after Escape selected a plot")
        Log.line("RESULT Escape sent the plot back")

        // 3. A release outside the sidebar sends the rows back.
        view = try handle(p2)
        from = try center(p2)
        app.mouse(.leftMouseDown, at: from, on: view)
        await glide(view, from: from, to: downOne)
        try check(!rowsAtRest(), "the second drag of plot 2 did not start")
        let outside = CGPoint(x: app.window.frame.width - 60, y: downOne.y)
        await glide(view, from: downOne, to: outside)
        app.mouse(.leftMouseUp, at: outside, on: view)
        try await app.waitUntil("the release outside puts the rows back") { rowsAtRest() }
        try check(model.plots.map(\.id) == moved, "a release outside changed the order")
        Log.line("RESULT a release outside the sidebar sent the plot back")

        // 4. A move under 4 pt is a click: it selects the plot.
        view = try handle(p4)
        from = try center(p4)
        app.mouse(.leftMouseDown, at: from, on: view)
        app.mouse(.leftMouseDragged, at: CGPoint(x: from.x, y: from.y - 2), on: view)
        app.mouse(.leftMouseUp, at: CGPoint(x: from.x, y: from.y - 2), on: view)
        try await app.waitUntil("the click makes plot 4 active") { model.workspace.activePlotID == p4 }
        try check(model.plots.map(\.id) == moved, "a click moved a plot")
        // Plot 1 is active again, so its tree opens and the tree of plot 4 closes. The next drag reads the rows after that.
        let p4Tree = model.workspace.tabs(of: .plot(p4)).flatMap(\.tree.paneIDs)
        model.activate(plot: p1)
        try await app.waitUntil("the tree of plot 1 shows again") {
            tree.allSatisfy { app.exists("pane-row-\($0.uuidString)") } && !p4Tree.contains { app.exists("pane-row-\($0.uuidString)") }
        }
        try await waitForRowsToStand("the plot rows stand still again", [p1, p2, p3, p4, p5])

        // 5. Reduce Motion: drag plot 4 to the top. Nothing slides, and the release moves it at once.
        LoamMotion.reduceMotionOverride = true
        view = try handle(p4)
        from = try center(p4)
        let top = CGPoint(x: from.x, y: try center(p2).y + 6)
        app.mouse(.leftMouseDown, at: from, on: view)
        await glide(view, from: from, to: top)
        await app.sleep(0.1)
        app.screenshot("plot-drag-reduce-motion")
        app.mouse(.leftMouseUp, at: top, on: view)
        try check(model.plots.map(\.id) == [p4, p2, p3, p1, p5], "the Reduce Motion drop did not move the plot at once: \(model.plots.map(\.id))")
        try await app.waitUntil("the rows are at rest after Reduce Motion") { rowsAtRest() }
        try await app.waitUntil("loam move stored it") { (try? storeOrder()) == [p4, p2, p3, p1, p5] }
        try await app.waitUntil("the app has the move after Reduce Motion") { !model.isMovingPlot }
        Log.line("RESULT Reduce Motion showed the line and moved the plot at once")

        // 6. Fifteen plots: drag the top plot of "No panes" to its end. Each pointer move fits well inside one frame: the
        // worst move in time of the main thread on the CPU, and the median move on the clock. A busy machine can hold the
        // thread off the CPU for a frame, which only the worst move on the clock counts (ticket 125).
        LoamMotion.reduceMotionOverride = false
        var extra: [String] = []
        for index in 1...10 { extra.append(try rig.newPlot("Plot \(index + 5)")) }
        await model.reloadPlots()
        try await app.waitUntil("15 plots") { model.plots.count == 15 }
        // A taller window, so every plot row shows with no scroll.
        app.window.setFrame(NSRect(x: 80, y: 40, width: 1100, height: 1150), display: true)
        try await app.waitUntil("the last plot row shows") { (try? handle(extra[9])) != nil }
        try await waitForRowsToStand("the plot rows stand still in the taller window", [p1, p2, p3, p4, p5] + extra)
        view = try handle(p5)
        from = try center(p5)
        let end = try center(extra[9])
        app.mouse(.leftMouseDown, at: from, on: view)
        var cpu: [Double] = [], wall: [Double] = []
        var at = from
        while at.y > end.y {
            at.y -= 6
            let begin = (cpu: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), wall: ProcessInfo.processInfo.systemUptime)
            app.mouse(.leftMouseDragged, at: at, on: view)
            cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - begin.cpu) / 1_000_000)
            wall.append((ProcessInfo.processInfo.systemUptime - begin.wall) * 1000)
            await app.sleep(0.008)
        }
        await app.sleep(0.3)
        app.screenshot("plot-drag-fifteen-plots")
        app.mouse(.leftMouseUp, at: at, on: view)
        try await app.waitUntil("Reading list lands last") { model.plots.last?.id == p5 }
        try await app.waitUntil("the rows are at rest after the long drag") { rowsAtRest() }
        let worst = cpu.max() ?? 0, mean = cpu.reduce(0, +) / Double(max(cpu.count, 1))
        let median = wall.sorted().dropFirst(wall.count / 2).first ?? 0
        Log.line(String(format: "RESULT fifteen plots: %d moves, mean %.2f ms, worst %.2f ms of CPU per move, median %.2f ms on the clock",
                        cpu.count, mean, worst, median))
        try check(worst < 8, "a pointer move took \(worst) ms of CPU, more than one frame at 120 Hz")
        try check(median < 8, "the median pointer move took \(median) ms, more than one frame at 120 Hz")
    }

    private static func find(_ view: NSView, _ identifier: String) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { find($0, identifier) }.first
    }

    private static func findOutline(_ view: NSView) -> NSOutlineView? {
        (view as? NSOutlineView) ?? view.subviews.lazy.compactMap(findOutline).first
    }
}

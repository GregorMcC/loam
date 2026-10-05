import GhosttyKit
import LoamKit

extension AppCommand {
    /// The Loam command for a Ghostty action (spec 8.3), or nil for an action that Loam does not
    /// take. Ghostty's tab and split actions act on the active plot, its new window action makes
    /// a plot, and its command palette action opens the switcher on actions.
    init?(ghostty action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_NEW_TAB:
            self = .newTab
        case GHOSTTY_ACTION_NEW_WINDOW:
            self = .newPlot
        case GHOSTTY_ACTION_NEW_SPLIT:
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_DOWN, GHOSTTY_SPLIT_DIRECTION_UP: self = .newSplit(.stacked)
            default: self = .newSplit(.sideBySide)
            }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: self = .focusPane(.previous)
            case GHOSTTY_GOTO_SPLIT_NEXT: self = .focusPane(.next)
            case GHOSTTY_GOTO_SPLIT_UP: self = .focusPane(.up)
            case GHOSTTY_GOTO_SPLIT_DOWN: self = .focusPane(.down)
            case GHOSTTY_GOTO_SPLIT_LEFT: self = .focusPane(.left)
            case GHOSTTY_GOTO_SPLIT_RIGHT: self = .focusPane(.right)
            default: return nil
            }
        case GHOSTTY_ACTION_GOTO_TAB:
            switch action.action.goto_tab {
            case GHOSTTY_GOTO_TAB_PREVIOUS: self = .previousTab
            case GHOSTTY_GOTO_TAB_NEXT: self = .nextTab
            case GHOSTTY_GOTO_TAB_LAST: self = .lastTab
            default:
                let number = Int(action.action.goto_tab.rawValue)
                guard number > 0 else { return nil }
                self = .selectTab(number)
            }
        case GHOSTTY_ACTION_CLOSE_TAB:
            guard action.action.close_tab_mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS else { return nil }
            self = .closeTab
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resize = action.action.resize_split
            let direction: SplitTree.ResizeDirection
            switch resize.direction {
            case GHOSTTY_RESIZE_SPLIT_UP: direction = .up
            case GHOSTTY_RESIZE_SPLIT_DOWN: direction = .down
            case GHOSTTY_RESIZE_SPLIT_LEFT: direction = .left
            default: direction = .right
            }
            self = .resizeSplit(direction, points: Double(resize.amount))
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            self = .equalizeSplits
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
            self = .quickSwitcherActions
        case GHOSTTY_ACTION_UNDO:
            self = .undo
        case GHOSTTY_ACTION_REDO:
            self = .redo
        case GHOSTTY_ACTION_OPEN_CONFIG:
            self = .openConfig
        case GHOSTTY_ACTION_QUIT:
            self = .quit
        default:
            return nil
        }
    }
}

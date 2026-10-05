Buttons for sheets and empty states in the web bundle. The app uses native buttons. In the app, the one primary button of a row (Save, Add) is a native prominent button in `moss` with `on-moss` text, from `loamPrimaryButton()`. Outside the key window, macOS draws it as a plain bordered button.

- `loam-btn--primary`: `moss` with `on-moss` text. One per view, for the action that moves the work on: Start session, Create plot.
- `loam-btn`: the default, outlined in `edge` on `horizon-b`.
- `loam-btn--quiet`: text in `moss`, for row actions such as Undo.
- `loam-btn--danger`: outlined in `rust`. A destructive action needs a second press: the first press arms it (`is-armed`, filled `rust`) and the label says what will happen ("Delete Loam v1 build").
- Labels are verbs in sentence case. 26px tall, `radius-sm`. A press scales to 0.97 in `duration-fast`.
- `loam-kbd` shows a shortcut beside a control or in the switcher.

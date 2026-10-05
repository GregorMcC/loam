One link of a plot, in the plot panel.

- The icon shows the kind that `loam show --json` returns (see Iconography): the GitHub or Linear mark, the Claude mark for a claude.ai URL, else an SF Symbol. The icon is `ink-muted`, or `rust` when the path is gone. Its tooltip and its spoken name are the kind: Notion, Linear, GitHub, URL, Folder, File, or Vault.
- The label is `ink`. A click on the row runs `loam open`. The note follows in `ink-muted` `caption`.
- A local link whose path is gone takes `is-missing`: the label is struck through in `rust`, and opening it shows "This folder is gone. Edit the link or remove it."
- A right-click offers Copy target and, for local links, Reveal in Finder. In the app, it also offers Edit link and Remove link.
- In the app (ticket 87), the row is 32pt, with no box around the section. The icon is 16pt in `ink-muted`. The kind is at the right in `ink-faint`: Local, Vault, GitHub, Web, Notion, or Linear. Hover gives the row a neutral fill, and an `ellipsis` menu replaces the kind. The menu has the same actions as the right-click. The note sits under the label in `ink-faint`.
- In the app, opening a missing link shows a banner at the top of the panel with the path, Dismiss, and Edit link. Edit link opens an inline editor in place of the row: Label, Target, Note, Cancel, and Save.

The consumer provides the kind, icon, label, note, target and whether the path exists.

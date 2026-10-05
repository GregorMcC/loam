A one-line message at the bottom of a pane, above the terminal text.

- `loam-banner--needs`: shown while the pane's session needs you. It names what it waits on. It goes away when the session moves on, never on a timer.
- `loam-banner--ended`: the session ended and the pane stays. Return starts a new seeded session in the same plot.
- `loam-banner--error`: a Loam error the person must act on. Say what went wrong and what to do.

Banners sit inside the pane, `radius-md`, `space-2` × `space-3`. Never stack more than one per pane.

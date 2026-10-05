# Seeds hold links, not page snapshots

A seed gives a new session the plot's brief and its links. Loam never fetches or caches the content of a Notion page, a Linear issue, or any other linked page. When a session needs a page, Claude fetches it through its own connectors.

We chose this because a link is always current and no work content is copied to disk. Loam also needs no credentials of its own for Notion, Linear, or other sources. The cost is that Claude must have a working connector for each source, and a session cannot read linked pages offline.

## Considered Options

- **Cached page snapshots.** Loam fetches each page and gives Claude the text at start. A session starts faster and works offline. Rejected because copies go stale, Loam would hold its own credentials, and work content would sit on disk.
- **Links only, no brief.** Rejected because Claude would know the URLs and not why they matter.

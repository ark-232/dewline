# Changelog

What changed in each Dewline release, newest first.

## 0.1.1 (2 Nov 2026)

A new look and a calmer window, a live preview, and a panel for your own coding agent.

- The window title names the open note and its folder. The sidebar starts at your folder's name, with + for a new note, and a native toolbar replaces the old top bar.
- Open the preview to see the note rendered on the right while you edit its Markdown on the left.
- Chat with your own coding agent beside the note. Dewline talks to it over the Agent Client Protocol, and its edits arrive marked, with Keep and Revert. Dewline ships no model and needs no account.
- Links are quieter. A link on its own line shows a preview card, and hovering a link shows one; Settings turns previews off.
- Which instruction files your agents read in a folder now shows in the status bar.
- Reopening a note brings you back to the same place in it.
- Sharing a note works again: the share popover opens, and join requests show in the status bar with Approve and Deny.
- `dewline export --to pdf` writes the PDF again.
- A new app icon, and headings use the system font by default.

## 0.1.0 (2 Nov 2026)

The first public build. Dewline is a native Markdown editor for Mac: it opens the .md files you already keep, in place, and renders them as you write. Links, embeds, math, diagrams, export and live collaboration are built in, and every save changes only what you edited. No account and no telemetry.

- Open any Markdown file and edit it in place. Syntax hides until the caret reaches it; tables, task boxes, footnotes, callouts and highlighted code render in the page, and math and Mermaid diagrams are drawn natively. Wikilinks, embeds and #tags follow Obsidian's syntax.
- Saves change only the bytes you edited, and never overwrite a newer version on disk. File > Snapshots restores an earlier version of the file. Export to HTML, PDF or DOCX, and preview .md files in Finder with Quick Look.
- Open a folder or an Obsidian vault in place. A sidebar for the folder and your agent files, tabs, Quick Open (Shift-Command-O), find in files (Shift-Command-F) and one palette for files, commands and settings (Shift-Command-P).
- Edit a file live with someone by invite link, peer to peer.
- Six themes plus a pack of four, installable fonts, Vim mode, a Source view, and focus and typewriter modes.
- When git, a sync app, a script or a coding agent changes the open file, Dewline marks each change, and names the agent when its hooks report it. Keep or revert each one, or all at once; Dewline snapshots the file first.
- `dewline open file.md:12 --wait` works as `$EDITOR`, `dewline notify` lets agent hooks name their edits, and `dewline mcp` serves a folder's notes to an agent.

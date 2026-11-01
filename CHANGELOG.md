# Changelog

What changed in each Dewline release, newest first.

## 0.1.0 (1 Nov 2026)

The first public build.

- Open any Markdown file and edit it in place. Syntax hides until the caret reaches it; tables, task boxes, code, math and callouts render in the page.
- When Claude Code, Codex, git or another app changes the open file, the change lands where you can see it, marked with who wrote it. Keep or revert each one, or all at once, and Dewline snapshots the file first.
- Saves change only the bytes you edited, and never overwrite a newer version on disk.
- A sidebar for the folder, your agent files and what loads into each agent, plus one palette for files, commands and settings (Shift-Command-P).
- Six themes, installable fonts, Vim mode and a Source view.
- `dewline open file.md:12 --wait` works as `$EDITOR`, and `dewline notify` lets agent hooks name their edits.

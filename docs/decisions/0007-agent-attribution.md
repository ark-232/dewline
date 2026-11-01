# 0007: Naming agent writes

Date: 2026-10-26. Decided by evidence, as the owner authorized.

| Decision | Choice | Reopens if |
|---|---|---|
| When a change gets a name | The writer's hooks bracket it with one call id, and its declared change (Write's content, Edit's strings, Codex's patch) turns the ancestor into the bytes on disk. Anything else is Unknown. | a writer's hooks report hashes of what it wrote |
| Codex CLI | Named from M2, through `apply_patch` PreToolUse and PostToolUse hooks in the user's Codex config. Codex shell edits, `codex exec` runs and code-mode edits that skip either hook stay Unknown. | Codex drops `tool_use_id` or the patch from hook input |
| Claude Code Bash edits | Unknown, `bashEditDiff` included | the diff covers only the command's own writes and carries hashes |
| Claude Code's editor | `VISUAL="dewline open --wait"`. Ctrl+G and plan approval wait for it, and what you save there is your own write. | Claude Code stops waiting for editors it does not list |
| Cursor, Gemini CLI | Unknown in 1.0. Cursor's preToolUse and postToolUse carry `conversation_id` and `tool_use_id`, but as of 2026-10-30 its hooks docs (cursor.com/docs/agent/hooks) give `tool_input` only for Shell and name edits as the `Write` tool with no documented file path or content, so nothing can declare the bytes an edit wrote; `afterFileEdit` has the edit strings but no call id. Gemini's hooks carry no call id. | Cursor documents the Write tool's input |

**Codex.** Hooks are on by default. The hook input schema requires `tool_use_id`, the call id Codex records for the edit, and since [openai/codex#18391](https://github.com/openai/codex/pull/18391) (April 2026) `apply_patch` passes its raw patch as `tool_input.command`. The patch names each file in `*** Add File:`, `*** Update File:`, `*** Delete File:` and `*** Move to:` lines, relative to `cwd`. `dewline notify` checks for these fields at runtime rather than trusting a version number. Codex writes in place, truncating and then writing, so a watcher can read an empty or partial file. Dewline hashes at PostToolUse, and while a hooked call on a file is open, landings on that file wait, 10 s at most, as they wait for git's `index.lock`. Codex runs a hook the user adds only after the user trusts it in `/hooks`.

**Claude Code Bash.** `bashEditDiff` (2.1.269) diffs the working tree before and after each Bash call and carries no hashes. Claude Code's 2.1.293 changelog says the list "can include writes by other processes", and [claude-code#97146](https://github.com/anthropics/claude-code/issues/97146) shows a concurrent session's edits credited to the wrong command. In auto and bypassPermissions modes Claude Code tells the model to edit with sed, heredocs or short scripts ([claude-code#92271](https://github.com/anthropics/claude-code/issues/92271)), so many Claude edits there will show as Unknown. G1's label check runs in the default permission mode, and no public copy says every change carries a name.

**Ctrl+G.** Claude Code reads `$VISUAL`, then `$EDITOR`, and waits for the command to exit (a maintainer in [claude-code#18990](https://github.com/anthropics/claude-code/issues/18990)). An editor missing from its list of GUI editors is treated as a terminal editor, with the conversation hidden until the command exits ([claude-code#20045](https://github.com/anthropics/claude-code/issues/20045)). `--wait` gives it that exit.

The declared-change test keeps a second writer inside the bracket from taking the agent's name. Hashes before and after the call alone would credit the agent with both writes.

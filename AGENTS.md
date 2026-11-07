# Repository instructions

## Language

- Write all maintained project documentation in English.
- Write all code comments in English, including PowerShell comment-based help.
- When editing existing documentation or comments, keep the resulting content
  in English.
- Preserve verbatim historical source material, such as `docs/context.md`, in
  its original language. Such archives are reference material, not maintained
  specifications.
- These rules apply to repository content. Use the user's language in chat
  unless they request otherwise.

## Documentation formatting

- Keep each Markdown prose paragraph on one source line. Do not hard-wrap documentation at 80 columns or another fixed width.

## Project context

- Maintain `docs/build-log.md` as a short numbered sequence of concrete build actions. Include the command actually run or a link to the executed script and its invocation; compact command blocks are allowed. Mark each action Done, Blocked, Next, or Pending. Make the current stopping point and immediate next action obvious. Omit conversation history, documentation edits, routine checks, environment diagnostics, and verbose explanations. Keep hashes and image metadata in the lock files. Never put secrets or full machine inventories in the log.

- Read `README.md` for the project purpose and principles.
- Read `docs/requirements.md` for accepted decisions and unresolved requirements.
- Read `docs/stage-01.md` for the scope and acceptance criteria of Stage 1.
- Verify technical claims from `docs/context.md` before using them; the
  historical conversation is not an authoritative specification.

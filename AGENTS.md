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

- Keep temporary scripts for local operational tasks under `.local/ops/`; do not add them to the maintained repository scripts.

- Keep selected applications, components, policies, resource limits, and other configuration values in configuration and lock files. Markdown explains their purpose and usage and links to those files; do not duplicate selection lists, numeric settings, catalog counts, or report statistics.

- Maintain `docs/build-plan.md` as a short numbered sequence of reproducible build instructions. Describe each step by its goal and include the required commands or script invocations. Do not record execution status, statistics, run results, or development history. Keep selected values and input metadata in configuration and lock files, and execution results in generated reports. Never put secrets or full machine inventories in the plan.

- Read `README.md` for the project purpose and principles.
- Read `docs/requirements.md` for accepted decisions and unresolved requirements.
- Read `docs/stage-01.md` for the scope and acceptance criteria of Stage 1.
- Verify technical claims from `docs/context.md` before using them; the
  historical conversation is not an authoritative specification.

# TODOs

This is the delivery plan derived from [the intent pyramid](PYRAMID-OF-INTENTS.md).
Checked entries are evaluated implementation evidence, not aspirational claims.

## Intent evaluation

| Intent | Status | Evidence |
| --- | --- | --- |
| Explicit incremental build graph | Done | `BuildContext`, `Target`, `add_target!`, `depends!`, `phony!`, `build!`, cycle checks, and timestamp freshness. |
| Safe, transparent commands | Done | `command`, `appendargs`, `run!`, `capture!`, `chain`, and dry-run/verbose context options. |
| Local concurrent process workflow | Done | `start!`, `waitall!`, and bounded `runparallel!`. |
| Focused filesystem workflow | Done | `mkdirp`, `writefile!`, `copyfile!`, `move!`, `remove!`, `filetype`, and deterministic `files`. |
| Self-hosted build support | Done | `rebuild_self!` checks freshness and validates the artifact. |
| Automated behavior validation | Done | The suite covers public APIs, normal paths, error paths, dry runs, graph behavior, command failures, filesystem behavior, macros, and rebuild/clean behavior. |
| Supported-platform confidence | Done | CI covers Linux, macOS, and Windows on Julia 1.10 and latest stable; tests use Julia child processes rather than shell utilities. |
| Reliable output contract | Done | Non-phony, non-virtual targets must create their output; `virtual=true` makes output-less actions explicit. |

## Next work, in priority order

### P0 — Release confidence

- [x] Add GitHub Actions CI for Julia 1.10 and the latest stable Julia on Linux,
  macOS, and Windows. Run `Pkg.test()` as the required check.
  - Done when every pull request runs the matrix and reports test results.
- [x] Make the process tests platform-native. Replace POSIX-only `sh`, `printf`,
  and `touch` assumptions with Julia-based helper processes or robust
  platform-specific test helpers.
  - Done when the same test suite passes unmodified on Windows.
- [x] Add a test command and contributor instructions to the README.
  - Done when a fresh clone can run `julia --project=. -e 'using Pkg; Pkg.test()'`.

### P1 — Core contract clarity

- [x] Decide and document the output contract for non-phony targets: either
  verify that a stale target's recipe creates its named output, or add an
  explicit `virtual=true`/action-target option for targets without outputs.
  - Done when a missing declared output cannot silently make a build appear
    successful.
- [x] Add a `BuildError` type carrying the target name, dependency/command when
  applicable, and original exception as its cause.
  - Done when graph, recipe, and process failures identify the failing target
    without parsing error strings.
- [ ] Specify timestamp edge cases: equal mtimes, directory dependencies,
  symlinks, and coarse filesystem clocks.
  - Done when the policy is documented and each case has a deterministic test.

### P2 — Usability without framework creep

- [ ] Add a complete `examples/build.jl` that compiles a tiny program, exposes
  `all`, `test`, and `clean` phony targets, and demonstrates dry-run mode.
  - Done when it is exercised by an integration test.
- [ ] Add generated API documentation for every exported symbol and link it from
  the README.
  - Done when all exports have a concise reference and at least one runnable
  example covers the common graph workflow.
- [ ] Add structured build events (target started/skipped/finished and command
  started/finished) through an optional callback on `BuildContext`.
  - Done when callers can render progress without scraping stdout and callback
  failures are handled predictably.

## Guardrails for future TODOs

Do not add a DSL parser, implicit source discovery, remote execution, persistent
caching, watch mode, or package-management behavior here unless
`PYRAMID-OF-INTENTS.md` is deliberately changed first. These are currently
outside Build.jl's boundary.

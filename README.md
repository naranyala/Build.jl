# Build.jl

`Build.jl` is a small, dependency-free build graph library for Julia. It takes
the directness of [nob.h](https://github.com/tsoding/nob.h) and expresses it as
explicit Julia targets, functions, and Julia's shell-free `Cmd` values.

```julia
using Build

b = BuildContext()

@target b "hello.txt" begin
    write(joinpath(ctx.workdir, target.name), "hello\\n")
end

@phony b "all" begin
    # Put aggregate actions here.
end
depends!(b, "all", "hello.txt")
build!(b, "all")
```

Targets are rebuilt when their file output is missing or any file dependency is
newer. A dependency may be another target or an existing source file. Missing
source dependencies are errors. Mark actions such as `test`, `all`, or
`install` with `phony!`; they run on every request.

Every non-phony target must create its named output when it runs. For an
output-less action that is not a conventional phony target, declare it
explicitly with `virtual=true`; virtual targets run whenever requested:

```julia
add_target!(b, "generate-metadata"; virtual=true, recipe=(ctx, _) ->
    println("generated metadata"))
```

## Commands

A recipe can return a `Cmd` (or a vector of `Cmd`s). Build.jl executes returned
commands in `ctx.workdir`, prints them when `verbose=true`, and skips them when
`dry_run=true`:

```julia
add_target!(b, "program"; deps=["main.c"], recipe=(_, _) ->
    command("cc", "main.c", "-o", "program"))

build!(BuildContext(workdir=pwd(), dry_run=true), "program")
```

Dry runs traverse the same target graph and print the commands that would run,
but do not require a file target's output to exist afterward. This makes them
safe for a fresh checkout as well as an already-built tree.

Use `run!(ctx, command(...))` inside a recipe when a command must run between
other Julia operations. It follows the same working-directory, verbosity, and
dry-run policy.

`appendargs(command("cc", "main.c"), "-O2", "-o", "program")` is the
Julia analogue of `NOB_CMD_APPEND`: it builds a command as data and never
requires shell quoting. `chain(command("producer"), command("consumer"))`
builds a pipeline. `runall!` runs a sequence, while `capture!` returns a
command's standard output.

`start!` starts a command asynchronously and `waitall!` waits for its process
handles. `runparallel!(ctx, commands; max_procs=nprocs())` provides bounded
parallel execution, analogous to nob.h's asynchronous process list.

## Utilities

`needs_rebuild(output, inputs; workdir=pwd())` exposes the timestamp check for
ad-hoc work. `mkdirp(path)`, `copyfile!(source, destination)`, and
`move!`, `writefile!`, and `remove!(path; recursive=false)` cover common file
operations without invoking a shell. `files(path; recursive=false)` provides a
deterministic directory scan and `filetype(path)` identifies paths safely.

For self-hosted build scripts, `rebuild_self!(artifact, sources...;
rebuild=...)` performs nob.h-style freshness checking and invokes the supplied
rebuild closure only when needed. It verifies that the closure created the
expected artifact. `clean!(b)` removes registered file outputs; it never
removes directories or phony targets.

## Development

Build.jl supports Julia 1.10 and newer. Run the complete test suite from the
repository root:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The CI matrix runs this command on Linux, macOS, and Windows. Tests launch Julia
child processes directly, so they do not require a shell or external build
tools.

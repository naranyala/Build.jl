# Pyramid of Intents

This document defines what Build.jl is for, what it promises, and—just as
importantly—what it deliberately does not become. Higher levels constrain every
lower-level decision.

## 1. North star

Build.jl is a small, understandable Julia library for expressing and executing
local build steps. A developer should be able to read one Julia build script
and know which files are inputs, which outputs are produced, and which commands
will run.

## 2. Product principles

- **Julia first.** Build scripts are ordinary Julia code. The API complements
  `Cmd`, functions, and the standard library rather than inventing a language.
- **Explicit over magical.** Dependencies, target names, working directories,
  and side effects are visible in source. There is no implicit globbing or
  hidden rule search.
- **Safe by default.** Command arguments are data, not shell text. Destructive
  file operations have narrow, named targets.
- **Small enough to trust.** Keep the dependency footprint at zero and prefer a
  few composable primitives over a large build-framework abstraction.
- **Honest execution.** Dry runs, verbosity, failure propagation, and freshness
  rules must match what the build actually does.

## 3. Core product commitments

### Build graph

Build.jl provides named targets, file and target dependencies, phony actions,
cycle detection, and timestamp-based incremental rebuilding. A missing external
input is an error; a missing target output is stale.

### Process orchestration

Build.jl constructs commands without shell interpolation, runs them in an
explicit working directory, supports captured output and pipelines, and offers
sequential, asynchronous, and bounded-parallel execution. Process failures are
observable errors.

### Filesystem workflow

Build.jl provides the focused filesystem operations commonly needed by a build
script: inspect, list, create, write, copy, move, and remove. Operations return
useful values and avoid broad implicit deletion.

### Self-hosting support

Build scripts can check whether their generated artifact is stale and invoke a
caller-supplied rebuild action. Build.jl verifies that the promised artifact was
created.

### Library quality

Every public behavior has documentation and automated tests. The package is
dependency-free and supports Julia 1.10 or newer.

## 4. Explicit boundaries and non-goals

Build.jl is not:

- a replacement for Julia's package manager, artifact system, or test runner;
- a Make/Ninja-compatible parser, build-file format, or rule-inference engine;
- a remote/distributed build executor, cache server, sandbox, or CI service;
- a general task scheduler with persistent state, watch mode, or daemon;
- a package that silently discovers source files or deletes directory trees as
  part of normal builds.

Those features may be integrated by a caller using ordinary Julia code, but
they are outside this package unless this pyramid is intentionally revised.

## Decision rule

A proposed feature belongs in Build.jl only when it directly strengthens a core
commitment, preserves the principles above, and can be exposed as a small,
testable Julia API. Otherwise it should live in a build script or a separate
package.

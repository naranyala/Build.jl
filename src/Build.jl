module Build

export BuildContext, Target, add_target!, depends!, target, phony!, build!, clean!,
       BuildError,
       isoutofdate, needs_rebuild, rebuild_self!, command, appendargs, run!, runall!, capture!,
       start!, waitall!, runparallel!, chain, nprocs, mkdirp, copyfile!, move!, remove!,
       writefile!, filetype, files,
       @target, @phony

"""A node in a build graph.

`name` is usually an output path. A target whose name is registered with
[`phony!`](@ref) always runs when requested.
"""
mutable struct Target
    name::String
    dependencies::Vector{String}
    recipe::Function
    virtual::Bool
end

"""An error annotated with the target and build operation that failed."""
struct BuildError <: Exception
    target::String
    operation::Symbol
    cause
end

function Base.showerror(io::IO, error::BuildError)
    print(io, "build target '", error.target, "' failed during ", error.operation, ": ")
    showerror(io, error.cause)
end

"""A collection of build targets and execution options.

Set `dry_run=true` to print returned commands without executing them. Recipes
still run, so direct Julia filesystem operations must inspect `ctx.dry_run`
themselves. Recipes may return `Cmd` values (or vectors of them); returned
commands are executed by the context, so command dry runs work consistently.
"""
mutable struct BuildContext
    targets::Dict{String,Target}
    phony::Set{String}
    dry_run::Bool
    verbose::Bool
    workdir::String
end

function BuildContext(; dry_run::Bool=false, verbose::Bool=true,
                      workdir::AbstractString=pwd())
    BuildContext(Dict{String,Target}(), Set{String}(), dry_run, verbose,
                 abspath(String(workdir)))
end

_key(name) = String(name)
_dependencies(deps) = deps isa AbstractString ? [String(deps)] : _key.(collect(deps))

"""Add or replace a named target.

The recipe receives the `BuildContext` and its `Target`. It can create files
directly, or return a `Cmd` (or a vector of `Cmd`s) for Build.jl to run.
Other return values from direct Julia operations are ignored.
"""
function add_target!(ctx::BuildContext, name;
                     deps=String[], recipe::Function=(_, _) -> nothing,
                     virtual::Bool=false)
    key = _key(name)
    ctx.targets[key] = Target(key, _dependencies(deps), recipe, virtual)
    return ctx.targets[key]
end

"""Return the target named `name`, or throw a useful error."""
function target(ctx::BuildContext, name)
    key = _key(name)
    get(ctx.targets, key) do
        throw(ArgumentError("unknown target: $key"))
    end
end

"""Append dependencies to an existing target."""
function depends!(ctx::BuildContext, name, dependencies...)
    append!(target(ctx, name).dependencies, _key.(dependencies))
    return target(ctx, name)
end

"""Mark target names as actions rather than file outputs."""
function phony!(ctx::BuildContext, names...)
    union!(ctx.phony, _key.(names))
    return ctx
end

_path(ctx, name) = isabspath(name) ? name : joinpath(ctx.workdir, name)
_exists(ctx, name) = isfile(_path(ctx, name)) || isdir(_path(ctx, name))

"""Return a `Cmd` from program and argument values without invoking a shell."""
command(program, arguments...) = Cmd(String[string(program), string.(arguments)...])

"""Return `cmd` with additional arguments, without involving a shell."""
appendargs(cmd::Cmd, arguments...) = Cmd(String[String.(cmd.exec)..., string.(arguments)...])

"""Connect commands with pipes, returning a command that `run!` can execute."""
function chain(commands::Base.AbstractCmd...)
    isempty(commands) && throw(ArgumentError("chain requires at least one command"))
    return pipeline(commands...)
end

"""Return the number of logical CPU threads available to Julia."""
nprocs() = Sys.CPU_THREADS

"""Create `path`, including missing parent directories, and return the path."""
function mkdirp(path::AbstractString)
    mkpath(path)
    return path
end

"""Copy `source` to `destination`, creating the destination parent directory."""
function copyfile!(source::AbstractString, destination::AbstractString; force::Bool=true)
    parent = dirname(destination)
    parent == "." || mkdirp(parent)
    cp(source, destination; force)
    return destination
end

"""Move `source` to `destination`, creating the destination parent directory."""
function move!(source::AbstractString, destination::AbstractString; force::Bool=true)
    parent = dirname(destination)
    parent == "." || mkdirp(parent)
    mv(source, destination; force)
    return destination
end

"""Remove a file, symlink, or directory if it exists, and return `path`."""
function remove!(path::AbstractString; recursive::Bool=false)
    (ispath(path) || islink(path)) || return path
    rm(path; force=true, recursive)
    return path
end

"""Write `contents` to `path`, creating missing parent directories."""
function writefile!(path::AbstractString, contents)
    parent = dirname(path)
    parent == "." || mkdirp(parent)
    write(path, contents)
    return path
end

"""Return `:file`, `:directory`, `:link`, `:other`, or `:missing` for `path`."""
function filetype(path::AbstractString)
    islink(path) && return :link
    isfile(path) && return :file
    isdir(path) && return :directory
    ispath(path) && return :other
    return :missing
end

"""List entries below `directory` in deterministic order.

By default the returned paths are relative and include files only. Set
`recursive=true`, `absolute=true`, or `include_dirs=true` as needed.
"""
function files(directory::AbstractString; recursive::Bool=false,
               absolute::Bool=false, include_dirs::Bool=false)
    root = abspath(directory)
    isdir(root) || throw(ArgumentError("not a directory: $directory"))
    found = String[]
    if recursive
        for (dir, dirs, names) in walkdir(root)
            include_dirs && append!(found, joinpath.(dir, dirs))
            append!(found, joinpath.(dir, names))
        end
    else
        for name in readdir(root)
            path = joinpath(root, name)
            (include_dirs || !isdir(path)) && push!(found, path)
        end
    end
    sort!(found)
    return absolute ? found : relpath.(found, root)
end

"""Return whether `output` is absent or older than any `inputs`.

Paths are interpreted relative to `workdir`. A missing input returns `true`;
build graph traversal reports an unregistered missing input as an error.
"""
function needs_rebuild(output, inputs::AbstractVector; workdir::AbstractString=pwd())
    root = abspath(String(workdir))
    resolve(path) = isabspath(path) ? path : joinpath(root, path)
    output_path = resolve(String(output))
    ispath(output_path) || return true
    output_time = stat(output_path).mtime
    for input in inputs
        input_path = resolve(String(input))
        !ispath(input_path) && return true
        stat(input_path).mtime > output_time && return true
    end
    return false
end

needs_rebuild(output, inputs...; kwargs...) = needs_rebuild(output, collect(inputs); kwargs...)

"""Run `rebuild` when `artifact` is missing or older than `sources`.

This is the Julia equivalent of nob.h's rebuild-yourself check: callers choose
how to rebuild (for example, by invoking Julia or a compiler). The function
verifies that the rebuild produced the requested artifact and returns whether
a rebuild occurred.
"""
function rebuild_self!(artifact, sources...; workdir::AbstractString=pwd(), rebuild::Function)
    needs_rebuild(artifact, sources...; workdir) || return false
    rebuild()
    root = abspath(String(workdir))
    path = isabspath(String(artifact)) ? String(artifact) : joinpath(root, String(artifact))
    ispath(path) || throw(ArgumentError("rebuild did not create artifact: $artifact"))
    return true
end

"""Whether a target should be rebuilt based on timestamps and phony status."""
function isoutofdate(ctx::BuildContext, t::Target)
    (t.name in ctx.phony || t.virtual) && return true
    for dep in t.dependencies
        dep in ctx.phony && return true
        !haskey(ctx.targets, dep) && !_exists(ctx, dep) &&
            throw(ArgumentError("missing dependency '$dep' required by '$(t.name)'"))
    end
    return needs_rebuild(t.name, t.dependencies; workdir=ctx.workdir)
end

"""Run a command using a build context's working directory and dry-run policy."""
function run!(ctx::BuildContext, command::Base.AbstractCmd)
    ctx.verbose && println(command)
    ctx.dry_run && return nothing
    return cd(ctx.workdir) do
        Base.run(command)
    end
end

"""Start a command without waiting for it to finish.

The returned `Process` can be passed to [`waitall!`](@ref). Dry runs return
`nothing` and never start a process.
"""
function start!(ctx::BuildContext, command::Base.AbstractCmd)
    ctx.verbose && println(command)
    ctx.dry_run && return nothing
    return cd(ctx.workdir) do
        Base.run(command; wait=false)
    end
end

"""Wait for every process, rethrowing the first process failure after draining all."""
function waitall!(processes)
    failure = nothing
    for process in processes
        process === nothing && continue
        try
            wait(process)
            success(process) || throw(ProcessFailedException(process))
        catch error
            failure === nothing && (failure = error)
        end
    end
    failure === nothing || throw(failure)
    return processes
end

"""Run commands concurrently, starting at most `max_procs` at a time.

This is the Julia counterpart to nob.h's asynchronous process list. Commands
are started in input order; each batch completes before the next one starts.
"""
function runparallel!(ctx::BuildContext, commands::AbstractVector{<:Base.AbstractCmd};
                      max_procs::Integer=nprocs())
    max_procs > 0 || throw(ArgumentError("max_procs must be positive"))
    for first in 1:max_procs:length(commands)
        last = min(first + max_procs - 1, length(commands))
        waitall!(start!.(Ref(ctx), commands[first:last]))
    end
    return ctx
end

runparallel!(ctx::BuildContext, commands::Base.AbstractCmd...; kwargs...) =
    runparallel!(ctx, collect(commands); kwargs...)

"""Run every command in order using a context's dry-run and verbosity policy."""
function runall!(ctx::BuildContext, commands::Base.AbstractCmd...)
    foreach(command -> run!(ctx, command), commands)
    return ctx
end

"""Run a command and return its standard output as a string.

When `stderr=true`, standard error is preserved instead of being suppressed.
Dry runs return an empty string.
"""
function capture!(ctx::BuildContext, command::Base.AbstractCmd; stderr::Bool=false)
    ctx.verbose && println(command)
    ctx.dry_run && return ""
    return cd(ctx.workdir) do
        read(pipeline(command, stderr=stderr ? Base.stderr : devnull), String)
    end
end

function _run_recipe!(ctx::BuildContext, t::Target)
    result = cd(ctx.workdir) do
        t.recipe(ctx, t)
    end
    commands = if result isa Base.AbstractCmd
        (result,)
    elseif result isa AbstractVector
        result
    else
        () # Direct Julia operations such as `write` return ordinary values.
    end
    for command in commands
        command isa Base.AbstractCmd || throw(ArgumentError("recipe for $(t.name) returned $(typeof(command)); expected command, vector of commands, or nothing"))
        run!(ctx, command)
    end
end

function _build!(ctx::BuildContext, name::String, visiting::Set{String}, built::Set{String})
    name in built && return
    name in visiting && throw(ArgumentError("cyclic build dependency involving: $name"))
    push!(visiting, name)
    t = try
        target(ctx, name)
    catch error
        throw(BuildError(name, :target, error))
    end
    for dep in t.dependencies
        haskey(ctx.targets, dep) && _build!(ctx, dep, visiting, built)
    end
    delete!(visiting, name)
    stale = try
        isoutofdate(ctx, t)
    catch error
        throw(BuildError(name, :dependency, error))
    end
    if stale
        ctx.verbose && println("BUILD ", t.name)
        try
            _run_recipe!(ctx, t)
        catch error
            error isa BuildError && rethrow()
            throw(BuildError(name, :recipe, error))
        end
        # A dry run intentionally performs no writes, so a missing output is
        # expected. Real builds still enforce the output contract.
        if !ctx.dry_run && !(t.name in ctx.phony || t.virtual) && !_exists(ctx, t.name)
            throw(BuildError(name, :output,
                             ArgumentError("recipe did not create output '$(t.name)'")))
        end
    elseif ctx.verbose
        println("UP TO DATE ", t.name)
    end
    push!(built, name)
end

"""Build `names` and all registered target dependencies.

Cycles and unknown targets are errors. With no names, all registered targets
are considered in insertion-independent dependency order.
"""
function build!(ctx::BuildContext, names...)
    requested = isempty(names) ? collect(keys(ctx.targets)) : _key.(names)
    built = Set{String}()
    for name in requested
        _build!(ctx, name, Set{String}(), built)
    end
    return ctx
end

"""Remove file targets. Phony targets and directories are left untouched."""
function clean!(ctx::BuildContext, names...)
    requested = isempty(names) ? collect(keys(ctx.targets)) : _key.(names)
    for name in requested
        name in ctx.phony && continue
        path = _path(ctx, name)
        isfile(path) || continue
        ctx.verbose && println("REMOVE ", name)
        ctx.dry_run || rm(path)
    end
    return ctx
end

"""Convenient declaration form: `@target ctx "output" deps=["input"] begin ... end`."""
macro target(ctx, name, args...)
    body = args[end]
    keywords = if length(args) == 1
        Any[]
    elseif args[1] isa Expr && args[1].head === :parameters
        args[1].args
    elseif args[1] isa Expr && args[1].head === :(=)
        [Expr(:kw, args[1].args...)]
    else
        throw(ArgumentError("@target options must be keyword arguments"))
    end
    recipe = Expr(:kw, :recipe, :((ctx, target) -> begin $body end))
    return esc(Expr(:call, :add_target!, Expr(:parameters, keywords..., recipe), ctx, name))
end

"""Declare a phony target: `@phony ctx "test" begin ... end`."""
macro phony(ctx, name, body)
    return esc(quote
        add_target!($ctx, $name; recipe = (ctx, target) -> begin $body end)
        phony!($ctx, $name)
    end)
end

end # module

using Test
using Build

"""A portable child process for process tests; it never relies on a shell."""
julia_eval(code) = `$(Base.julia_cmd()) --startup-file=no --history-file=no -e $code`

@testset "Build.jl" begin
    @testset "context and target declarations" begin
        ctx = BuildContext(verbose=false)
        @test ctx.workdir == abspath(pwd())
        @test !ctx.dry_run && !ctx.verbose && isempty(ctx.targets) && isempty(ctx.phony)
        first = add_target!(ctx, :first; deps="input.txt")
        @test first isa Target
        @test first.name == "first" && first.dependencies == ["input.txt"]
        @test target(ctx, :first) === first
        @test_throws ArgumentError target(ctx, "unknown")
        @test depends!(ctx, "first", :other, "last") === first
        @test first.dependencies == ["input.txt", "other", "last"]
        @test phony!(ctx, :first, "all") === ctx
        @test ctx.phony == Set(["first", "all"])
        replacement = add_target!(ctx, "first")
        @test target(ctx, "first") === replacement && isempty(replacement.dependencies)
        custom = BuildContext(workdir=".", verbose=false)
        @test custom.workdir == abspath(".")
    end

    @testset "file freshness" begin
        mktempdir() do dir
            write(joinpath(dir, "input"), "in")
            @test needs_rebuild("output", "input"; workdir=dir)
            write(joinpath(dir, "output"), "out")
            @test !needs_rebuild("output", String[]; workdir=dir)
            @test !needs_rebuild("output", "input"; workdir=dir)
            @test needs_rebuild("output", "missing"; workdir=dir)
            @test !needs_rebuild(joinpath(dir, "output"), joinpath(dir, "input"))
            sleep(0.02); touch(joinpath(dir, "input"))
            @test needs_rebuild("output", ["input"]; workdir=dir)
            ctx = BuildContext(workdir=dir, verbose=false)
            add_target!(ctx, "output"; deps="input")
            @test isoutofdate(ctx, target(ctx, "output"))
            write(joinpath(dir, "output"), "out")
            @test !isoutofdate(ctx, target(ctx, "output"))
            phony!(ctx, "output"); @test isoutofdate(ctx, target(ctx, "output"))
            ctx = BuildContext(workdir=dir, verbose=false)
            add_target!(ctx, "parent"; deps="missing")
            @test_throws ArgumentError isoutofdate(ctx, target(ctx, "parent"))
            add_target!(ctx, "generated"; virtual=true, recipe=(_, _) -> nothing)
            add_target!(ctx, "parent"; deps="generated")
            write(joinpath(dir, "parent"), "parent")
            @test isoutofdate(ctx, target(ctx, "parent"))
        end
    end

    @testset "build graph and recipes" begin
        mktempdir() do dir
            ctx = BuildContext(workdir=dir, verbose=false); calls = String[]
            add_target!(ctx, "a"; recipe=(ctx, t) -> begin push!(calls, t.name); write(joinpath(ctx.workdir, t.name), "a") end)
            add_target!(ctx, "b"; deps="a", recipe=(ctx, t) -> begin push!(calls, t.name); write(joinpath(ctx.workdir, t.name), read(joinpath(ctx.workdir, "a"))) end)
            @test build!(ctx, "b") === ctx
            @test calls == ["a", "b"] && read(joinpath(dir, "b"), String) == "a"
            empty!(calls); build!(ctx, "b"); @test isempty(calls)
            phony!(ctx, "a"); build!(ctx, "b"); @test calls == ["a", "b"]
            add_target!(ctx, "command-output"; recipe=(_, _) -> julia_eval("write(\"command-output\", \"command\")"))
            build!(ctx, "command-output"); @test read(joinpath(dir, "command-output"), String) == "command"
            add_target!(ctx, "commands-output"; recipe=(_, _) -> [julia_eval("write(\"one\", \"one\")"), julia_eval("write(\"commands-output\", \"two\")")])
            build!(ctx, "commands-output")
            @test read(joinpath(dir, "one"), String) == "one" && read(joinpath(dir, "commands-output"), String) == "two"
            add_target!(ctx, "pipeline-output"; recipe=(_, _) -> chain(julia_eval("print(\"pipeline\")"), julia_eval("write(\"pipeline-output\", read(stdin, String))")))
            build!(ctx, "pipeline-output")
            @test read(joinpath(dir, "pipeline-output"), String) == "pipeline"
            add_target!(ctx, "all"; recipe=(_, _) -> nothing); phony!(ctx, "all"); depends!(ctx, "all", "a", "b")
            @test build!(ctx) === ctx
            @test_throws BuildError build!(ctx, "unknown")
            add_target!(ctx, "direct-value"; virtual=true, recipe=(_, _) -> 42); @test build!(ctx, "direct-value") === ctx
            add_target!(ctx, "bad-vector"; recipe=(_, _) -> Any[julia_eval("exit()"), 42]); @test_throws BuildError build!(ctx, "bad-vector")
            add_target!(ctx, "missing-output"; recipe=(_, _) -> nothing)
            output_error = try build!(ctx, "missing-output"); nothing catch error; error end
            @test output_error isa BuildError && output_error.target == "missing-output" && output_error.operation == :output
        end
        ctx = BuildContext(verbose=false); add_target!(ctx, "left"; deps="right"); add_target!(ctx, "right"; deps="left")
        @test_throws BuildError build!(ctx, "left")
    end

    @testset "macros" begin
        mktempdir() do dir
            ctx = BuildContext(workdir=dir, verbose=false)
            @target ctx "macro-source" begin write(joinpath(ctx.workdir, target.name), "source") end
            @target ctx "macro-output" deps=["macro-source"] begin write(joinpath(ctx.workdir, target.name), read(joinpath(ctx.workdir, "macro-source"))) end
            @phony ctx "all" begin end
            depends!(ctx, "all", "macro-output"); build!(ctx, "all")
            @test read(joinpath(dir, "macro-output"), String) == "source"
        end
    end

    @testset "process helpers" begin
        @test command("echo", 1, :two).exec == ["echo", "1", "two"]
        @test appendargs(command("echo", "one"), 2, :three).exec == ["echo", "one", "2", "three"]
        @test nprocs() >= 1
        @test chain(command("printf", "hello"), command("wc", "-c")) isa Base.AbstractCmd
        @test_throws ArgumentError chain()
        mktempdir() do dir
            live = BuildContext(workdir=dir, verbose=false)
            @test run!(live, julia_eval("write(\"live\", \"live\")")) isa Base.Process
            @test read(joinpath(dir, "live"), String) == "live"
            @test runall!(live, julia_eval("write(\"first\", \"one\")"), julia_eval("write(\"second\", \"two\")")) === live
            @test read(joinpath(dir, "first"), String) == "one" && read(joinpath(dir, "second"), String) == "two"
            @test runall!(live, chain(julia_eval("print(\"chained\")"), julia_eval("write(\"chained\", read(stdin, String))"))) === live
            @test read(joinpath(dir, "chained"), String) == "chained"
            @test capture!(live, julia_eval("print(\"captured\")")) == "captured"
            @test capture!(live, julia_eval("println(stderr, \"ignored\"); print(\"visible\")")) == "visible"
            @test capture!(live, chain(julia_eval("print(\"piped\")"), julia_eval("print(read(stdin, String))"))) == "piped"
            process = start!(live, julia_eval("write(\"async\", \"async\")"))
            @test process isa Base.Process && waitall!([process]) == [process]
            @test read(joinpath(dir, "async"), String) == "async"
            @test runparallel!(live, [julia_eval("write(\"parallel-one\", \"one\")"), julia_eval("write(\"parallel-two\", \"two\")")]; max_procs=1) === live
            @test read(joinpath(dir, "parallel-one"), String) == "one"
            @test read(joinpath(dir, "parallel-two"), String) == "two"
            @test_throws ArgumentError runparallel!(live, Cmd[]; max_procs=0)
            failed = start!(live, julia_eval("exit(5)"))
            @test_throws ProcessFailedException waitall!([failed])
            @test_throws ProcessFailedException runparallel!(live, [julia_eval("write(\"kept\", \"kept\")"), julia_eval("exit(6)")]; max_procs=1)
            @test read(joinpath(dir, "kept"), String) == "kept"
            @test_throws ProcessFailedException run!(live, julia_eval("exit(3)"))
            @test_throws ProcessFailedException capture!(live, julia_eval("exit(4)"))
            dry = BuildContext(workdir=dir, dry_run=true, verbose=false)
            add_target!(dry, "dry-output"; recipe=(_, _) -> julia_eval("write(\"dry-output\", \"dry\")"))
            @test build!(dry, "dry-output") === dry
            @test run!(dry, julia_eval("write(\"dry\", \"dry\")")) === nothing
            @test runall!(dry, julia_eval("write(\"dry-one\", \"dry-one\")"), julia_eval("write(\"dry-two\", \"dry-two\")")) === dry
            @test capture!(dry, julia_eval("print(\"hidden\")")) == ""
            @test start!(dry, julia_eval("write(\"dry-async\", \"dry-async\")")) === nothing
            @test waitall!([nothing]) == [nothing]
            @test runparallel!(dry, julia_eval("write(\"dry-parallel\", \"dry-parallel\")")) === dry
            @test !ispath(joinpath(dir, "dry-output")) && !ispath(joinpath(dir, "dry")) && !ispath(joinpath(dir, "dry-one"))
        end
        mktempdir() do dir
            write(joinpath(dir, "root-file"), "root")
            mkdir(joinpath(dir, "root-directory"))
            @test files(dir) == ["root-file"]
            @test files(dir; include_dirs=true) == ["root-directory", "root-file"]
            @test files(dir; absolute=true) == [joinpath(dir, "root-file")]
            @test_throws Base.IOError remove!(dir)
        end
    end

    @testset "filesystem helpers" begin
        mktempdir() do dir
            source = joinpath(dir, "source"); write(source, "contents")
            nested = joinpath(dir, "nested", "written")
            @test mkdirp(joinpath(dir, "empty", "child")) == joinpath(dir, "empty", "child") && isdir(joinpath(dir, "empty", "child"))
            @test writefile!(nested, "written") == nested && read(nested, String) == "written"
            copied = joinpath(dir, "copies", "copy"); @test copyfile!(source, copied) == copied && read(copied, String) == "contents"
            @test_throws ArgumentError copyfile!(source, copied; force=false)
            moved = joinpath(dir, "moves", "moved"); @test move!(copied, moved) == moved && !ispath(copied) && read(moved, String) == "contents"
            @test_throws ArgumentError move!(source, moved; force=false)
            @test remove!(joinpath(dir, "absent")) == joinpath(dir, "absent")
            @test remove!(moved) == moved && !ispath(moved)
            @test remove!(joinpath(dir, "nested"); recursive=true) == joinpath(dir, "nested") && !ispath(joinpath(dir, "nested"))
            link = joinpath(dir, "source-link"); symlink(source, link)
            @test filetype(source) == :file && filetype(link) == :link && filetype(dir) == :directory && filetype(joinpath(dir, "absent")) == :missing
            writefile!(joinpath(dir, "tree", "deep", "leaf"), "leaf")
            @test files(joinpath(dir, "tree")) == String[]
            @test files(joinpath(dir, "tree"); include_dirs=true) == ["deep"]
            @test files(joinpath(dir, "tree"); recursive=true) == [joinpath("deep", "leaf")]
            @test files(joinpath(dir, "tree"); recursive=true, include_dirs=true) == ["deep", joinpath("deep", "leaf")]
            @test files(joinpath(dir, "tree"); recursive=true, absolute=true) == [joinpath(dir, "tree", "deep", "leaf")]
            @test_throws ArgumentError files(joinpath(dir, "absent"))
            @test remove!(link) == link && !ispath(link)
        end
    end

    @testset "rebuild and clean" begin
        mktempdir() do dir
            source, artifact = joinpath(dir, "source"), joinpath(dir, "artifact"); write(source, "source"); calls = Ref(0)
            rebuild = () -> begin calls[] += 1; write(artifact, "artifact") end
            @test rebuild_self!(artifact, source; rebuild)
            @test calls[] == 1 && !rebuild_self!(artifact, source; rebuild)
            sleep(0.02); touch(source); @test rebuild_self!(artifact, source; rebuild) && calls[] == 2
            @test_throws ArgumentError rebuild_self!(joinpath(dir, "missing"), source; rebuild=() -> nothing)
            ctx = BuildContext(workdir=dir, verbose=false); add_target!(ctx, "artifact"); add_target!(ctx, "missing"); add_target!(ctx, "directory")
            mkdir(joinpath(dir, "directory")); phony!(ctx, "missing")
            @test clean!(ctx) === ctx && !isfile(artifact) && isdir(joinpath(dir, "directory"))
            write(joinpath(dir, "phony-file"), "keep")
            add_target!(ctx, "phony-file"); phony!(ctx, "phony-file")
            @test clean!(ctx, "phony-file") === ctx && isfile(joinpath(dir, "phony-file"))
            write(artifact, "artifact"); dry = BuildContext(workdir=dir, dry_run=true, verbose=false); add_target!(dry, "artifact")
            @test clean!(dry, "artifact") === dry && isfile(artifact)
        end
    end
end

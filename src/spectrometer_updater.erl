%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_updater).

-moduledoc """
Scans AtomVM source trees to auto-generate the supported functions database
with platform and version information.

This module parses multiple sources within an AtomVM checkout to discover
which OTP functions are supported:

- **gperf files** (`bifs.gperf`, `nifs.gperf`) — BIF and NIF registration
tables, available on all platforms.
- **Platform NIFs** (`src/platforms/*/platform_nifs.c`) — platform-specific
NIFs.
- **Erlang library sources** (`libs/*/src/*.erl`) — `-export` directives with
platform scoping based on library location.
- **Test files** (`tests/erlang_tests/*.erl`, `tests/libs/*/*.erl`) — test
files that call OTP functions.

### Platform Scoping Rules

- gperf files: `all` platforms
- Core libs (alisp, estdlib, etest, exavmlib, jit, gleam_avm): `all` platforms
- eavmlib (general): `all` platforms
- eavmlib/\\*_hal.erl: esp32, stm32, rp2 only
- avm_esp32, esp32boot, esp32devmode: esp32 only
- avm_network: esp32, rp2, generic_unix (all but `network` module - which is also incorrectly
reported as supported on generic_unix, see TODO.md)
- avm_rp2: rp2 only
- avm_stm32: stm32 only
- avm_emscripten: emscripten only
- avm_unix: generic_unix only
""".

-export([
    update/1
]).

-include_lib("kernel/include/file.hrl").

-type scan_opts() :: #{tests => boolean()}.
-type platforms() :: all | [atom()].
-type since() :: binary() | {unreleased, binary()}.
-type entry() :: {platforms(), since()}.

-define(ALL_PLATFORMS, [emscripten, esp32, generic_unix, rp2, stm32]).

-doc """
Update the supported functions database by scanning an AtomVM repository.

This is the main entry point for refreshing the database of supported OTP
functions. It scans an AtomVM source tree, extracts function information,
and writes a machine-readable data file.

### Options

The `Opts` map accepts the following keys:

- `atomvm_dir` — Path to a local AtomVM repository. If provided, the existing
  checkout is used instead of cloning a fresh copy. The directory is not deleted
  after scanning.
- `branch` — Git branch to use when cloning (default: `"main"`). Ignored if
  `atomvm_dir` is provided.
- `cache_dir` — Directory path for cached data. Sets the `spectrometer`
  application environment.
- `force` — `true` to overwrite an existing output file. Without this flag,
  the function errors if the output file already exists.
- `output` — Path for the output data file (default: user database path from
  `spectrometer_utils:user_db_file/0`).
- `tag` — Git tag to check out when cloning (e.g., `"v0.7.0"`). Tags take
  precedence over `branch`.
- `tests` — `false` to skip scanning test files for external function calls
  (default: `true`).

### Returns

- `ok` on success
- `{error, Reason}` if the output file exists (without `force`), the output
  cannot be written, or the repository cannot be cloned

### Examples

```erlang
%% Update from main branch (clones temp repo)
ok = spectrometer_updater:update(#{branch => "main"}).

%% Update from local checkout with force
ok = spectrometer_updater:update(#{atomvm_dir => "/path/to/atomvm", force => true}).

%% Update specific tag without scanning tests
ok = spectrometer_updater:update(#{tag => "v0.7.0", tests => false}).
```
""".
-spec update(Opts :: map()) -> ok | {error, term()}.
update(Opts) ->
    case Opts of
        #{cache_dir := CacheDir} ->
            application:set_env(spectrometer, cache_dir, CacheDir);
        #{} ->
            ok
    end,
    OutputFile =
        case Opts of
            #{output := File} ->
                File;
            #{} ->
                spectrometer_utils:user_db_file()
        end,
    Force = maps:get(force, Opts, false),

    case filelib:is_file(OutputFile) andalso not Force of
        true ->
            io:format("Output file already exists: ~s\n", [OutputFile]),
            io:format("Use --force to overwrite.\n"),
            {error, {file_exists, OutputFile}};
        _ ->
            case update_datafile(Opts, OutputFile) of
                ok ->
                    ok;
                {error, Reason} ->
                    io:format(
                        standard_error, "Error: unable to update data, ~p\n", [
                            Reason
                        ]
                    ),
                    {error, Reason}
            end
    end.

-spec build_db_from_list([{atom(), term()}]) -> map().
build_db_from_list(Data) ->
    lists:foldl(
        fun({Mod, Funs}, Acc) ->
            lists:foldl(
                fun({F, A, Platforms, Since0}, A2) ->
                    maps:put({Mod, F, A}, {Platforms, Since0}, A2)
                end,
                Acc,
                Funs
            )
        end,
        #{},
        Data
    ).

-doc """
Update the supported functions database by scanning an AtomVM repository using the provided options.
""".
-spec update_datafile(map(), string()) -> ok | {error, Reason :: term()}.
update_datafile(Opts, OutputFile) ->
    Tag = maps:get(tag, Opts, undefined),
    Branch = maps:get(branch, Opts, undefined),
    Since = derive_since(Tag, Branch),

    ExistingDB =
        case file:consult(OutputFile) of
            {ok, [Data]} when is_list(Data) ->
                io:format("Loading existing data set from ~s\n", [OutputFile]),
                build_db_from_list(Data);
            {error, enoent} ->
                % If no user cache exists, try to load from bundled data for initial values
                Datafile = spectrometer_utils:bundled_data_path(),
                case file:consult(Datafile) of
                    {ok, [Data]} when is_list(Data) ->
                        io:format(
                            "Loading bundled data set from ~s\n", [Datafile]
                        ),
                        build_db_from_list(Data);
                    {ok, _} ->
                        io:format(
                            "Ignoring invalid data set in ~s, starting with empty data\n",
                            [OutputFile]
                        ),
                        #{};
                    {error, enoent} ->
                        io:format(
                            "No existing data found, starting with empty data set\n"
                        ),
                        #{};
                    {error, Reason} ->
                        {error, Reason}
                end;
            {error, Reason} ->
                {error, Reason}
        end,

    case ExistingDB of
        {error, Err} ->
            {error, Err};
        _ ->
            RepoDir =
                case maps:find(atomvm_dir, Opts) of
                    {ok, Dir} ->
                        io:format("Using local AtomVM repo: ~s\n", [Dir]),
                        Dir;
                    error ->
                        ClonedDir =
                            spectrometer_utils:clone_temp_repo(
                                maps:get(branch, Opts, "main"),
                                maps:get(tag, Opts, undefined)
                            ),
                        case ClonedDir of
                            {error, _} -> ClonedDir;
                            _ -> ClonedDir
                        end
                end,
            case RepoDir of
                {error, Err3} ->
                    {error, Err3};
                _ ->
                    ScanOpts = #{tests => maps:get(tests, Opts, true)},
                    NewAcc = scan_atomvm_repo(RepoDir, ScanOpts, Since),

                    MergedDB = maps:fold(
                        fun(Key, NewEntry, Acc) ->
                            case maps:find(Key, Acc) of
                                {ok, {ExistingPlatforms, ExistingSince}} ->
                                    {MergedPlatforms, MergedSince} = merge_entry(
                                        {ExistingPlatforms, ExistingSince},
                                        NewEntry
                                    ),
                                    maps:put(
                                        Key, {MergedPlatforms, MergedSince}, Acc
                                    );
                                error ->
                                    maps:put(Key, NewEntry, Acc)
                            end
                        end,
                        ExistingDB,
                        NewAcc
                    ),

                    case maps:find(atomvm_dir, Opts) of
                        {ok, _} ->
                            ok;
                        error ->
                            TmpDir = RepoDir,
                            _ = spectrometer_utils:purge_dir(TmpDir),
                            ok
                    end,

                    case write_db_file(OutputFile, MergedDB) of
                        ok ->
                            spectrometer_atomvm:reload_db(),
                            spectrometer_atomvm:load_db(),
                            io:format("Done.\n"),
                            ok;
                        {error, Err4} ->
                            io:format("Error writing database file ~p: ~p\n", [
                                OutputFile, Err4
                            ]),
                            {error, Err4}
                    end
            end
    end.

-doc """
Scan an AtomVM repo and return supported functions with platform information.

Parses gperf files, platform NIFs, Erlang library exports, and (optionally)
test files to discover supported functions. Returns a map from
`{Module, Function, Arity}` to `{Platforms, Since}` entries.

#### Arguments

- `RepoDir` — Path to the AtomVM repository root
- `Opts` — Options map; `#{tests => false}` skips test file scanning
- `Since` — Version tag (e.g. `<<"v0.7.0">>`) or branch info
""".
-spec scan_atomvm_repo(string(), scan_opts(), since()) ->
    #{{atom(), atom(), arity()} => entry()}.
scan_atomvm_repo(RepoDir, Opts, Since) ->
    io:format("Scanning AtomVM repo at ~s (since: ~p)\n", [RepoDir, Since]),
    LibDir = filename:join(RepoDir, "src/libAtomVM"),
    PlatformsDir = filename:join(RepoDir, "src/platforms"),
    LibsDir = filename:join(RepoDir, "libs"),
    TestsDir = filename:join(RepoDir, "tests"),

    Acc0 = #{},
    Acc1 =
        case filelib:is_regular(filename:join(LibDir, "bifs.gperf")) of
            true ->
                io:format("  Parsing bifs.gperf...\n"),
                parse_bifs_gperf(
                    filename:join(LibDir, "bifs.gperf"), Acc0, all, Since
                );
            false ->
                io:format("  Skipping bifs.gperf (not found)\n"),
                Acc0
        end,
    Acc2 =
        case filelib:is_regular(filename:join(LibDir, "nifs.gperf")) of
            true ->
                io:format("  Parsing nifs.gperf...\n"),
                parse_nifs_gperf(
                    filename:join(LibDir, "nifs.gperf"), Acc1, all, Since
                );
            false ->
                io:format("  Skipping nifs.gperf (not found)\n"),
                Acc1
        end,
    io:format("  Scanning platform NIFs...\n"),
    Acc3 = scan_platform_nifs(PlatformsDir, Acc2, Since),
    io:format("  Scanning Erlang library sources...\n"),
    Acc4 = scan_erlang_libs(LibsDir, Acc3, Since),
    case maps:get(tests, Opts, true) of
        true ->
            io:format("  Scanning test files for external calls...\n"),
            Acc5 = scan_test_files(TestsDir, Acc4, Since),
            finalize(Acc5);
        false ->
            io:format("  Skipping test file scan (disabled)\n"),
            finalize(Acc4)
    end.

-doc false.
%% Finalize scan and log results.
finalize(Acc) ->
    io:format(
        "  Found ~p unique module:function/arity entries\n",
        [maps:size(Acc)]
    ),
    Acc.

-doc """
Write a human-readable database file with platform and version information.

Formats the accumulated scan results into a machine-generated `.data` file
containing `{Module, [{Function, Arity, Platforms, Since}]}` tuples sorted
by module name.
""".
-spec write_db_file(string(), #{{atom(), atom(), arity()} => entry()}) ->
    ok | {error, Reason :: term()}.
write_db_file(Path, Acc) ->
    ByMod = maps:fold(
        fun({M, F, A}, {Platforms, Since}, MAcc) ->
            maps:update_with(
                M,
                fun(L) -> [{F, A, Platforms, Since} | L] end,
                [{F, A, Platforms, Since}],
                MAcc
            )
        end,
        #{},
        Acc
    ),
    SortedMods = lists:sort(
        maps:to_list(
            maps:map(fun(_K, L) -> lists:usort(L) end, ByMod)
        )
    ),
    Header = [
        "%% Supported AtomVM functions - machine generated, edit with extreme caution.\n",
        "%% Format: [{module, [{function, arity, platforms, since}]}]\n",
        "%% Platforms: 'all' or list of platform atoms [esp32, stm32, rp2, emscripten, generic_unix]\n",
        "%% Since: binary version string like <<\"v0.5.0\">> or {unreleased, <<\"0.7.x\">>}\n",
        "\n",
        "[\n"
    ],
    Content = lists:join(
        ",\n",
        [
            io_lib:format("    {~w, ~w}", [M, FunList])
         || {M, FunList} <- SortedMods
        ]
    ),
    EndLines = ["\n].\n"],
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Path, Header ++ Content ++ EndLines) of
                ok ->
                    io:format(
                        "Wrote ~p functions across ~p modules to ~s\n",
                        [maps:size(Acc), length(SortedMods), Path]
                    );
                {error, Reason} ->
                    io:format("Error writing file ~s: ~p\n", [Path, Reason]),
                    {error, Reason}
            end;
        {error, Reason} ->
            io:format("Error ensuring directory ~s: ~p\n", [Path, Reason]),
            {error, Reason}
    end.

-doc """
Derive the `Since` value from tag and branch options.

Tags always take precedence over branches. Prerelease suffixes
(`-alpha.#`, `-beta.#`, `-rc.#`) are stripped from tags.
""".
-spec derive_since(string() | undefined, string() | undefined) -> since().
derive_since(Tag, _Branch) when is_list(Tag), Tag =/= [] ->
    normalize_tag(Tag);
derive_since(_Tag, Branch) when is_list(Branch), Branch =/= [] ->
    branch_to_since(Branch);
derive_since(undefined, undefined) ->
    {unreleased, <<"main">>}.

-doc false.
%% Normalize a tag string to a binary version string.
%% Strips -alpha.#, -beta.#, -rc.# suffixes.
-spec normalize_tag(string()) -> binary().
normalize_tag(Tag) ->
    Base = re:replace(Tag, "-(alpha|beta|rc)\\.\\d+$", "", [{return, list}]),
    list_to_binary(Base).

-doc false.
%% Convert a branch name to a Since value.
-spec branch_to_since(string()) -> {unreleased, binary()}.
branch_to_since("release-" ++ Version) ->
    {unreleased, list_to_binary(Version ++ ".x")};
branch_to_since("main") ->
    {unreleased, <<"main">>};
branch_to_since(Branch) ->
    {unreleased, list_to_binary(Branch)}.

-doc false.
%% Assign a sort key to a branch name for age comparison.
%% main is newest (tier 3), release branches are tier 2 (ordered by version),
%% unknown branches are tier 1.
-spec branch_sort_key(binary()) -> {1 | 2 | 3, term()}.
branch_sort_key(<<"main">>) ->
    {3, <<>>};
branch_sort_key(<<"release-", Version/binary>>) ->
    {2, parse_release_version(Version)};
branch_sort_key(Branch) ->
    case binary:split(Branch, <<".">>, [global]) of
        [Major, Minor, <<"x">>] ->
            case is_digit_binary(Major) andalso is_digit_binary(Minor) of
                true ->
                    {2, {binary_to_integer(Major), binary_to_integer(Minor)}};
                false ->
                    {1, Branch}
            end;
        _ ->
            {1, Branch}
    end.

%% Parse a release version string like "0.7" into {0, 7}.
parse_release_version(Version) ->
    Parts = binary:split(Version, <<".">>, [global]),
    case Parts of
        [Major, Minor | _] ->
            {binary_to_integer(Major), binary_to_integer(Minor)};
        [Major] ->
            {binary_to_integer(Major), 0};
        _ ->
            {0, 0}
    end.

%% Check if a binary contains only digit characters.
is_digit_binary(Bin) when is_binary(Bin) ->
    case Bin of
        <<>> ->
            false;
        _ ->
            lists:all(
                fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bin)
            )
    end.

%% Parse a semantic version string like "v0.7.0" or "0.7.0-alpha.1"
%% Returns {ok, {Major, Minor, Patch}} | {error, Reason}
-spec parse_semver(binary() | string()) ->
    {ok, {integer(), integer(), integer()}}
    | {error, term()}.
parse_semver(Version) when is_binary(Version) ->
    parse_semver(binary_to_list(Version));
parse_semver("v" ++ Rest) ->
    parse_semver(Rest);
parse_semver(VersionStr) when is_list(VersionStr) ->
    case string:split(VersionStr, "-") of
        [Base, _Pre] ->
            parse_semver_base(Base);
        [Base] ->
            parse_semver_base(Base)
    end.

parse_semver_base(Base) ->
    case string:split(Base, ".", all) of
        [Major, Minor, Patch] ->
            try
                Maj = list_to_integer(Major),
                Min = list_to_integer(Minor),
                Pat = list_to_integer(Patch),
                {ok, {Maj, Min, Pat}}
            catch
                _:badarg -> {error, non_integer_version};
                _:Reason -> {error, Reason}
            end;
        [Major, Minor] ->
            try
                Maj = list_to_integer(Major),
                Min = list_to_integer(Minor),
                {ok, {Maj, Min, 0}}
            catch
                _:badarg -> {error, non_integer_version};
                _:Reason -> {error, Reason}
            end;
        [Major] ->
            try
                Maj = list_to_integer(Major),
                {ok, {Maj, 0, 0}}
            catch
                _:badarg -> {error, non_integer_version};
                _:Reason -> {error, Reason}
            end;
        _ ->
            {error, invalid_version_format}
    end.

%% Compare two semantic version binaries.
%% Returns older if First < Second, newer if First > Second, same if equal.
-spec compare_semver(binary(), binary()) -> older | newer | same.
compare_semver(First, Second) ->
    case {parse_semver(First), parse_semver(Second)} of
        {{ok, V1}, {ok, V2}} ->
            compare_semver_versions(V1, V2);
        _ ->
            %% Fallback to binary comparison if parsing fails
            if
                First < Second -> older;
                First > Second -> newer;
                true -> same
            end
    end.

compare_semver_versions({M1, Mi1, P1}, {M2, Mi2, P2}) ->
    if
        M1 > M2 -> newer;
        M1 < M2 -> older;
        Mi1 > Mi2 -> newer;
        Mi1 < Mi2 -> older;
        P1 > P2 -> newer;
        P1 < P2 -> older;
        true -> same
    end.

-doc false.
%% Compare two Since values. Returns true if First is older than Second.
-spec is_older_since(since(), since()) -> boolean().
is_older_since(First, Second) when is_binary(First), is_binary(Second) ->
    case compare_semver(First, Second) of
        older -> true;
        _ -> false
    end;
is_older_since(Tag, {unreleased, _Branch}) when is_binary(Tag) ->
    true;
is_older_since({unreleased, _Branch}, Tag) when is_binary(Tag) ->
    false;
is_older_since({unreleased, Branch1}, {unreleased, Branch2}) ->
    branch_sort_key(Branch1) < branch_sort_key(Branch2).

-doc """
Merge two entries following the tag > branch, earliest-wins rules.

Returns `{MergedPlatforms, MergedSince}` — platforms are combined and
the older `Since` value is kept.
""".
-spec merge_entry(entry(), entry()) -> entry().
merge_entry({OldPlatforms, OldSince}, {NewPlatforms, NewSince}) ->
    MergedPlatforms = merge_platforms_all(OldPlatforms, NewPlatforms),
    MergedSince =
        case is_older_since(OldSince, NewSince) of
            true ->
                OldSince;
            false ->
                case is_older_since(NewSince, OldSince) of
                    true -> NewSince;
                    false -> OldSince
                end
        end,
    {MergedPlatforms, MergedSince}.

-doc false.
%% Merge platforms from two entries.
merge_platforms_all(all, _) ->
    all;
merge_platforms_all(_, all) ->
    all;
merge_platforms_all(OldList, NewList) when is_list(OldList), is_list(NewList) ->
    Merged = lists:umerge(lists:sort(OldList), lists:sort(NewList)),
    case Merged of
        ?ALL_PLATFORMS -> all;
        _ -> Merged
    end.

scan_platform_nifs(PlatformsDir, Acc, Since) ->
    case filelib:is_dir(PlatformsDir) of
        false ->
            io:format("    Platforms dir not found: ~s\n", [PlatformsDir]),
            Acc;
        true ->
            Platforms = discover_platforms(PlatformsDir),
            io:format("    Discovered platforms: ~p\n", [Platforms]),
            lists:foldl(
                fun({PlatName, NifsFile}, A) ->
                    io:format("    Parsing ~s platform_nifs.c...\n", [PlatName]),
                    parse_platform_nifs(NifsFile, PlatName, A, Since)
                end,
                Acc,
                Platforms
            )
    end.

discover_platforms(PlatformsDir) ->
    case file:list_dir(PlatformsDir) of
        {ok, Entries} ->
            lists:filtermap(
                fun(Entry) ->
                    PlatDir = filename:join(PlatformsDir, Entry),
                    case filelib:is_dir(PlatDir) of
                        true ->
                            Candidates = [
                                filename:join(PlatDir, "platform_nifs.c"),
                                filename:join([
                                    PlatDir, "lib", "platform_nifs.c"
                                ]),
                                filename:join([
                                    PlatDir, "src", "lib", "platform_nifs.c"
                                ]),
                                filename:join([
                                    PlatDir,
                                    "components",
                                    "avm_sys",
                                    "platform_nifs.c"
                                ])
                            ],
                            case find_platform_nifs_file(Candidates) of
                                {ok, Path} ->
                                    Normalized = spectrometer_utils:normalize_platform_name(
                                        Entry
                                    ),
                                    {true, {Normalized, Path}};
                                false ->
                                    false
                            end;
                        false ->
                            false
                    end
                end,
                Entries
            );
        {error, _} ->
            []
    end.

find_platform_nifs_file([Path | Rest]) ->
    case filelib:is_file(Path) of
        true -> {ok, Path};
        false -> find_platform_nifs_file(Rest)
    end;
find_platform_nifs_file([]) ->
    false.

%% Generic file scanner that extracts function entries using a regex and
%% accumulates them with platform/version metadata.
%% Pattern should capture groups that the KeyFun can transform into a key.
%% EntryFun receives captured groups and returns the value to store.
-doc false.
-spec parse_file_entries(
    string(),
    iodata(),
    fun(([string()]) -> term()),
    platforms(),
    since(),
    map()
) -> map().
parse_file_entries(File, Pattern, KeyFun, Platforms, Since, Acc) ->
    {ok, Bin} = file:read_file(File),
    Lines = string:split(binary_to_list(Bin), "\n", all),
    lists:foldl(
        fun(Line, A) ->
            case re:run(Line, Pattern, [{capture, all_but_first, list}]) of
                {match, Groups} ->
                    Key = KeyFun(Groups),
                    maps:put(Key, {Platforms, Since}, A);
                nomatch ->
                    A
            end
        end,
        Acc,
        Lines
    ).

%% Generic file scanner for parsing with global regex (finds all matches at once)
%% and merging into accumulator with custom merger function.
-doc false.
-spec parse_file_global(
    string(),
    iodata(),
    fun(([string()], map()) -> map()),
    map()
) -> map().
parse_file_global(File, Pattern, MergeFun, Acc) ->
    {ok, Bin} = file:read_file(File),
    Content = binary_to_list(Bin),
    case re:run(Content, Pattern, [{capture, all_but_first, list}, global]) of
        {match, Matches} ->
            lists:foldl(MergeFun, Acc, Matches);
        nomatch ->
            Acc
    end.

parse_platform_nifs(File, Platform, Acc, Since) ->
    MergeFun = fun([ModStr, FunStr, ArityStr], A) ->
        Arity = list_to_integer(ArityStr),
        Key = {
            spectrometer_utils:atom_from_string(ModStr),
            spectrometer_utils:atom_from_string(FunStr),
            Arity
        },
        maps:update_with(
            Key,
            fun({ExistingPlatforms, ExistingSince}) ->
                {
                    merge_platforms(ExistingPlatforms, Platform),
                    merge_since(ExistingSince, Since)
                }
            end,
            {[Platform], Since},
            A
        )
    end,
    parse_file_global(
        File,
        "strcmp\\s*\\(\\s*\"([a-z_][a-z0-9_]*):([A-Za-z_][A-Za-z0-9_]*)/(\\d+)\"",
        MergeFun,
        Acc
    ).

%% Merge Since values following the tag > branch, earliest-wins rules.
merge_since(Old, New) when is_binary(Old), is_binary(New) ->
    %% Both are tags - keep the older (semantically smaller) one
    case compare_semver(Old, New) of
        older -> Old;
        _ -> New
    end;
merge_since({unreleased, _OldBranch}, New) when is_binary(New) ->
    %% Tag replaces unreleased branch
    New;
merge_since(Old, {unreleased, _NewBranch}) when is_binary(Old) ->
    %% Existing tag is kept (tag wins over branch)
    Old;
merge_since({unreleased, OldBranch}, {unreleased, NewBranch}) ->
    %% Both are unreleased - keep the older (smaller sort key) one
    case branch_sort_key(OldBranch) < branch_sort_key(NewBranch) of
        true -> {unreleased, OldBranch};
        false -> {unreleased, NewBranch}
    end;
merge_since(Old, _New) ->
    %% Fallback - keep existing
    Old.

merge_platforms(all, _NewPlatform) ->
    all;
merge_platforms(Existing, NewPlatform) when is_list(Existing) ->
    case lists:member(NewPlatform, Existing) of
        true ->
            Existing;
        false ->
            Platforms = lists:sort([NewPlatform | Existing]),
            case Platforms of
                ?ALL_PLATFORMS -> all;
                _ -> Platforms
            end
    end;
merge_platforms(Existing, NewPlatform) ->
    Platforms = lists:sort([NewPlatform | Existing]),
    case Platforms of
        ?ALL_PLATFORMS -> all;
        _ -> Platforms
    end.

parse_bifs_gperf(File, Acc, Platforms, Since) ->
    KeyFun = fun([Fun, ArityStr]) ->
        Arity = list_to_integer(ArityStr),
        {erlang, spectrometer_utils:atom_from_string(Fun), Arity}
    end,
    parse_file_entries(
        File,
        "^\\s*erlang:([A-Za-z0-9_+'/-]+|[^/,\\s]+)/(\\d+)",
        KeyFun,
        Platforms,
        Since,
        Acc
    ).

parse_nifs_gperf(File, Acc, Platforms, Since) ->
    KeyFun = fun([Mod, Fun, ArityStr]) ->
        Arity = list_to_integer(ArityStr),
        {
            spectrometer_utils:atom_from_string(Mod),
            spectrometer_utils:atom_from_string(Fun),
            Arity
        }
    end,
    parse_file_entries(
        File,
        "\\s*?\"?([a-z_][a-z0-9_]*):([A-Za-z_][A-Za-z0-9_]*)/(\\d+)\"?",
        KeyFun,
        Platforms,
        Since,
        Acc
    ).

scan_erlang_libs(LibsDir, Acc, Since) ->
    case filelib:is_dir(LibsDir) of
        false ->
            io:format("    libs dir not found: ~s\n", [LibsDir]),
            Acc;
        true ->
            Acc1 = scan_lib_group(
                LibsDir, all_platform_libs(), all, Acc, Since
            ),
            Acc2 = scan_lib_group(
                LibsDir, hal_platform_libs(), [esp32, stm32, rp2], Acc1, Since
            ),
            Acc3 = scan_lib_group(
                LibsDir, esp32_only_libs(), [esp32], Acc2, Since
            ),
            Acc4 = scan_lib_group(
                LibsDir, network_libs(), [generic_unix, esp32, rp2], Acc3, Since
            ),
            Acc5 = scan_lib_group(LibsDir, rp2_only_libs(), [rp2], Acc4, Since),
            Acc6 = scan_lib_group(
                LibsDir, stm32_only_libs(), [stm32], Acc5, Since
            ),
            Acc7 = scan_lib_group(
                LibsDir, emscripten_only_libs(), [emscripten], Acc6, Since
            ),
            scan_lib_group(
                LibsDir, generic_unix_only_libs(), [generic_unix], Acc7, Since
            )
    end.

all_platform_libs() ->
    ["alisp", "estdlib", "etest", "jit", "gleam_avm", "eavmlib"].

hal_platform_libs() ->
    %% These are _hal.erl files within eavmlib

    %% Handled specially in scan_lib_group
    [].

esp32_only_libs() ->
    ["avm_esp32", "esp32boot", "esp32devmode"].

network_libs() ->
    ["avm_network"].

rp2_only_libs() ->
    ["avm_rp2"].

stm32_only_libs() ->
    ["avm_stm32"].

emscripten_only_libs() ->
    ["avm_emscripten"].

generic_unix_only_libs() ->
    ["avm_unix"].

scan_lib_group(_LibsDir, [], _Platforms, Acc, _Since) ->
    Acc;
scan_lib_group(LibsDir, LibNames, Platforms, Acc, Since) ->
    lists:foldl(
        fun(LibName, A) ->
            LibSrcDir = filename:join([LibsDir, LibName, "src"]),
            case filelib:is_dir(LibSrcDir) of
                true ->
                    ErlFiles = find_erl_files(LibSrcDir),
                    io:format(
                        "    Scanning ~s (~p files, platforms: ~p)\n",
                        [LibName, length(ErlFiles), Platforms]
                    ),
                    lists:foldl(
                        fun(F, A2) ->
                            parse_exports(
                                F, Platforms, Since, A2
                            )
                        end,
                        A,
                        ErlFiles
                    );
                false ->
                    A
            end
        end,
        Acc,
        LibNames
    ).

parse_exports(File, Platforms, Since, Acc) ->
    {ok, Bin} = file:read_file(File),
    Lines = string:split(binary_to_list(Bin), "\n", all),
    ModName = find_module_name(Lines),
    case ModName of
        undefined ->
            Acc;
        Mod ->
            Exports = find_exports(Lines),
            BaseName = filename:basename(File, ".erl"),
            %% Check if this is a _hal.erl file
            BaseLen = string:length(BaseName),
            ActualPlatforms =
                case
                    (BaseLen >= 4) andalso
                        string:equal(
                            string:slice(BaseName, BaseLen - 4), "_hal"
                        )
                of
                    true ->
                        %% HAL files are only for esp32, stm32, rp2
                        case Platforms of
                            all -> [esp32, stm32, rp2];
                            _ -> Platforms
                        end;
                    false ->
                        Platforms
                end,
            lists:foldl(
                fun({F, A}, A2) ->
                    maps:put({Mod, F, A}, {ActualPlatforms, Since}, A2)
                end,
                Acc,
                Exports
            )
    end.

find_module_name(Lines) ->
    find_first_match(
        "-module\\s*\\(\\s*([a-z_][a-z0-9_]*)\\s*\\)\\s*\\.", Lines
    ).

find_first_match(Regex, Lines) ->
    find_first_match(Regex, Lines, undefined).

find_first_match(_Regex, [], Default) ->
    Default;
find_first_match(Regex, [Line | Rest], Default) ->
    case re:run(Line, Regex, [{capture, all_but_first, list}]) of
        {match, [Name]} -> spectrometer_utils:atom_from_string(Name);
        _ -> find_first_match(Regex, Rest, Default)
    end.

find_exports(Lines) ->
    %% -export can span multiple lines. We need to collect all [ ... ] contents.
    %% Strategy: join all lines, find all -export( ... ) blocks, parse atoms/arities.
    Joined = lists:join(" ", Lines),
    case
        re:run(Joined, "-export\\s*\\(([^)]+)\\)", [
            global, {capture, all_but_first, list}
        ])
    of
        {match, Matches} ->
            lists:flatmap(
                fun([Content]) ->
                    parse_export_list(Content)
                end,
                Matches
            );
        nomatch ->
            []
    end.

parse_export_list(Content) ->
    Trimmed = string:trim(Content),
    %% Remove surrounding brackets if present
    Inner =
        case Trimmed of
            [$[ | Rest] ->
                case lists:last(Rest) of
                    $] ->
                        lists:sublist(Rest, 1, length(Rest) - 1);
                    _ ->
                        Trimmed
                end;
            _ ->
                Trimmed
        end,
    Tokens = string:split(Inner, ",", all),
    lists:filtermap(
        fun(Token) ->
            case
                re:run(
                    string:trim(Token), "^([a-z_][a-z0-9_]*)\\s*/\\s*(\\d+)$", [
                        {capture, all_but_first, list}
                    ]
                )
            of
                {match, [Fun, ArityStr]} ->
                    {true, {
                        spectrometer_utils:atom_from_string(Fun),
                        list_to_integer(ArityStr)
                    }};
                _ ->
                    false
            end
        end,
        Tokens
    ).

scan_test_files(TestsDir, Acc, Since) ->
    case filelib:is_dir(TestsDir) of
        false ->
            io:format("    tests dir not found: ~s\n", [TestsDir]),
            Acc;
        true ->
            ErlTestsDir = filename:join(TestsDir, "erlang_tests"),
            Acc1 = scan_calls_dir(ErlTestsDir, "erlang_tests", Acc, Since),
            EstdlibTestsDir = filename:join([TestsDir, "libs", "estdlib"]),
            Acc2 = scan_calls_dir(
                EstdlibTestsDir, "tests/libs/estdlib", Acc1, Since
            ),
            EavmlibTestsDir = filename:join([TestsDir, "libs", "eavmlib"]),
            scan_calls_dir(
                EavmlibTestsDir, "tests/libs/eavmlib", Acc2, Since
            )
    end.

scan_calls_dir(Dir, Label, Acc, Since) ->
    case filelib:is_dir(Dir) of
        true ->
            Files = find_erl_files(Dir),
            io:format("    Found ~p .erl files in ~s\n", [length(Files), Label]),
            scan_calls(Files, Acc, Since);
        false ->
            Acc
    end.

scan_calls(Files, Acc, Since) ->
    OTPMods = spectrometer_otp:modules_list(),
    OTPAtoms = [spectrometer_utils:atom_from_string(Mod) || Mod <- OTPMods],
    OTPSet = sets:from_list(OTPAtoms),
    lists:foldl(
        fun(File, A) ->
            case spectrometer_scanner:parse_calls(File) of
                {ok, ModName, Calls} ->
                    % Filter to OTP calls and exclude self-calls
                    Filtered = maps:filter(
                        fun({Mod, _Fun, _Arity}, _Count) ->
                            sets:is_element(Mod, OTPSet) andalso Mod =/= ModName
                        end,
                        Calls
                    ),
                    % Convert to accumulator format with all platforms
                    maps:fold(
                        fun({Mod, Fun, Arity}, _Count, Acc2) ->
                            Key = {Mod, Fun, Arity},
                            case maps:is_key(Key, Acc2) of
                                true ->
                                    case maps:get(Key, Acc2) of
                                        {all, _} -> Acc2;
                                        _ -> maps:put(Key, {all, Since}, Acc2)
                                    end;
                                false ->
                                    maps:put(Key, {all, Since}, Acc2)
                            end
                        end,
                        A,
                        Filtered
                    );
                {error, _} ->
                    A
            end
        end,
        Acc,
        Files
    ).

find_erl_files(Dir) ->
    find_erl_files(Dir, []).

find_erl_files(Dir, Acc) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foldl(
                fun(Entry, A) ->
                    Path = filename:join(Dir, Entry),
                    case file:read_link_info(Path) of
                        {ok, #file_info{type = directory}} ->
                            case Entry of
                                %% skip _build, .git etc
                                "_" ++ _ -> A;
                                "." ++ _ -> A;
                                _ -> find_erl_files(Path, A)
                            end;
                        {ok, #file_info{type = regular}} ->
                            case filename:extension(Entry) of
                                ".erl" -> [Path | A];
                                _ -> A
                            end;
                        _ ->
                            A
                    end
                end,
                Acc,
                Entries
            );
        {error, _} ->
            Acc
    end.

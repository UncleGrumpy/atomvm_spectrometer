%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_updater).

-include("function.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

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
- avm_network: esp32, rp2, generic_unix (except `network` and `network_fsm` which are esp32, rp2 only)
- avm_rp2: rp2 only
- avm_stm32: stm32 only
- avm_emscripten: emscripten only
- avm_unix: generic_unix only
""".

-export([update/1]).

-type scan_opts() :: #{tests => boolean()}.
-type platforms() :: all | [atom()].
-type since() :: binary() | {unreleased, binary()}.
-type removed() :: version_tuple() | undefined.
-type entry() :: {platforms(), since_map(), removed()}.
-type since_map() :: #{atom() | all => since()}.

%% Helper: create a since_map from a platforms list and a single since value
-spec make_since_map(platforms(), since()) -> since_map().
make_since_map(all, Since) ->
    #{all => Since};
make_since_map(Platforms, Since) when is_list(Platforms) ->
    maps:from_list([{P, Since} || P <- Platforms]).

%% Helper: merge two since-maps, keeping the older since for each platform
-spec merge_since_maps(since_map(), since_map()) -> since_map().
merge_since_maps(SM1, SM2) ->
    Merged = maps:fold(
        fun(Platform, Since2, Acc) ->
            case maps:find(Platform, Acc) of
                {ok, Since1} ->
                    case is_older_since(Since1, Since2) of
                        true -> Acc;
                        false -> maps:put(Platform, Since2, Acc)
                    end;
                error ->
                    maps:put(Platform, Since2, Acc)
            end
        end,
        SM1,
        SM2
    ),
    normalize_since_map(Merged).
-spec normalize_since_map(map()) -> map().

%% Normalize a since_map: 'all' must never coexist with specific platform
%% entries. When both are present, the specific platforms are more
%% authoritative — drop 'all'. 'all' should only survive when it is the
%% sole key (meaning the function is genuinely supported on every platform
%% in ALL_PLATFORMS with the same version).
normalize_since_map(SinceMap) ->
    case maps:is_key(all, SinceMap) andalso map_size(SinceMap) > 1 of
        true ->
            maps:remove(all, SinceMap);
        false ->
            SinceMap
    end.

%% Helper: restrict a since_map to only the specified platforms
-spec restrict_since_map(since_map(), [atom()]) -> since_map().
restrict_since_map(SinceMap, Platforms) ->
    lists:foldl(
        fun(P, Acc) ->
            case maps:find(P, SinceMap) of
                {ok, V} ->
                    maps:put(P, V, Acc);
                error ->
                    maps:put(
                        P,
                        maps:get(all, SinceMap, {unreleased, <<"unknown">>}),
                        Acc
                    )
            end
        end,
        #{},
        Platforms
    ).

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
            ?LOG_ERROR("Output file already exists: ~s", [OutputFile]),
            ?LOG_ERROR("Use --force to overwrite."),
            {error, {file_exists, OutputFile}};
        _ ->
            case update_datafile(Opts, OutputFile) of
                ok ->
                    ok;
                {error, Reason} ->
                    ?LOG_ERROR(
                        standard_error, "Error: unable to update data, ~p", [
                            Reason
                        ]
                    ),
                    {error, Reason}
            end
    end.

-spec build_db_from_list([{atom() | binary(), term()}]) -> map().
build_db_from_list(Data) ->
    lists:foldl(
        fun({Mod, Funs}, Acc) ->
            ModBin = ensure_key_binary(Mod),
            %% Skip 'unknown' module entries — they are always bogus artifacts
            case ModBin =:= <<"unknown">> of
                true ->
                    Acc;
                false ->
                    lists:foldl(
                        fun({F, A, Arg3, Arg4}, A2) ->
                            FBin = ensure_key_binary(F),
                            %% Detect format: if element 3 is a map, it's new format {F, A, SinceMap, Removed}
                            %% Otherwise it's old format {F, A, Platforms, Since}
                            {Plat, SM, Removed} =
                                case Arg3 of
                                    _ when is_map(Arg3) ->
                                        %% New format: derive platforms from since_map keys,
                                        %% use the map directly as since_map, and get Removed
                                        case maps:keys(Arg3) of
                                            [all] ->
                                                {all, Arg3,
                                                    ensure_compat_version(Arg4)};
                                            Keys ->
                                                {Keys, Arg3,
                                                    ensure_compat_version(Arg4)}
                                        end;
                                    all ->
                                        {all, make_since_map(all, Arg4),
                                            ensure_compat_version(undefined)};
                                    _ when is_list(Arg3) ->
                                        {Arg3, make_since_map(Arg3, Arg4),
                                            ensure_compat_version(undefined)}
                                end,
                            maps:put({ModBin, FBin, A}, {Plat, SM, Removed}, A2)
                        end,
                        Acc,
                        Funs
                    )
            end
        end,
        #{},
        Data
    ).

-spec ensure_key_binary(binary() | atom()) -> binary().
ensure_key_binary(Bin) when is_binary(Bin) ->
    Bin;
ensure_key_binary(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8).

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
                ?LOG_DEBUG("Loading existing data set from ~s", [OutputFile]),
                build_db_from_list(Data);
            {error, enoent} ->
                % If no user cache exists, try to load from bundled data for initial values
                Datafile = spectrometer_utils:bundled_data_path(),
                case file:consult(Datafile) of
                    {ok, [Data]} when is_list(Data) ->
                        ?LOG_DEBUG(
                            "Loading bundled data from ~s", [Datafile]
                        ),
                        build_db_from_list(Data);
                    {ok, _} ->
                        ?LOG_WARNING(
                            "Ignoring invalid data set in ~s, starting with empty data",
                            [OutputFile]
                        ),
                        #{};
                    {error, enoent} ->
                        ?LOG_DEBUG(
                            "No existing data found, starting with empty data"
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
                        ?LOG_DEBUG("Using local AtomVM repo: ~s", [Dir]),
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
                                {ok,
                                    {ExistingPlatforms, ExistingSM,
                                        _ExistingRemoved}} ->
                                    {MergedPlatforms, MergedSM} = merge_entry(
                                        {ExistingPlatforms, ExistingSM},
                                        NewEntry
                                    ),
                                    % Function exists in new scan, so NOT removed
                                    maps:put(
                                        Key,
                                        {MergedPlatforms, MergedSM, undefined},
                                        Acc
                                    );
                                error ->
                                    {EP, ESM} = NewEntry,
                                    maps:put(
                                        Key,
                                        {EP, ESM, undefined},
                                        Acc
                                    )
                            end
                        end,
                        ExistingDB,
                        NewAcc
                    ),

                    %% Detect removals: functions in existing DB but not found in new scan
                    DBWithRemovals = detect_removals(MergedDB, NewAcc, Since),

                    %% Constrain known modules to their actual platforms
                    %% (e.g., network_fsm was only ever on esp32)
                    DBWithConstrainedPlatforms = intersect_known_module_platforms(
                        DBWithRemovals
                    ),

                    case maps:find(atomvm_dir, Opts) of
                        {ok, _} ->
                            ok;
                        error ->
                            TmpDir = RepoDir,
                            _ = spectrometer_utils:purge_dir(TmpDir),
                            ok
                    end,

                    case
                        write_db_file(OutputFile, DBWithConstrainedPlatforms)
                    of
                        ok ->
                            spectrometer_atomvm:flush_db_cache(),
                            _ = spectrometer_atomvm:load_db(),
                            ?LOG_INFO("Updated supported functions data."),
                            ok;
                        {error, Err4} ->
                            ?LOG_ERROR("Error writing database file ~p: ~p", [
                                OutputFile, Err4
                            ]),
                            {error, Err4}
                    end
            end
    end.

-doc """
Scan an AtomVM repo and return supported functions with platform information.

Parses gperf files, platform NIFs, Erlang and Elixir library exports, and
(optionally) test files to discover supported functions. Returns a map from
`{Module, Function, Arity}` to `{Platforms, Since}` entries.

#### Arguments

- `RepoDir` — Path to the AtomVM repository root
- `Opts` — Options map; `#{tests => false}` skips test file scanning
- `Since` — Version tag (e.g. `<<"v0.7.0">>`) or branch info
""".
-spec scan_atomvm_repo(string(), scan_opts(), since()) ->
    #{{binary(), binary(), arity()} => entry()}.
scan_atomvm_repo(RepoDir, Opts, Since) ->
    ?LOG_INFO("Scanning AtomVM repo at ~s (since: ~p)", [RepoDir, Since]),
    LibDir = filename:join(RepoDir, "src/libAtomVM"),
    PlatformsDir = filename:join(RepoDir, "src/platforms"),
    LibsDir = filename:join(RepoDir, "libs"),
    TestsDir = filename:join(RepoDir, "tests"),

    Acc0 = #{},
    Acc1 =
        case filelib:is_regular(filename:join(LibDir, "bifs.gperf")) of
            true ->
                ?LOG_DEBUG("Parsing bifs.gperf"),
                parse_bifs_gperf(
                    filename:join(LibDir, "bifs.gperf"), Acc0, all, Since
                );
            false ->
                ?LOG_DEBUG("Skipping bifs.gperf (not found)"),
                Acc0
        end,
    Acc2 =
        case filelib:is_regular(filename:join(LibDir, "nifs.gperf")) of
            true ->
                ?LOG_DEBUG("Parsing nifs.gperf"),
                parse_nifs_gperf(
                    filename:join(LibDir, "nifs.gperf"), Acc1, all, Since
                );
            false ->
                ?LOG_DEBUG("Skipping nifs.gperf (not found)"),
                Acc1
        end,
    ?LOG_DEBUG("Scanning platform NIFs"),
    Acc3 = scan_platform_nifs(PlatformsDir, Acc2, Since),
    ?LOG_DEBUG("Scanning port drivers"),
    Acc3b = scan_port_drivers(PlatformsDir, Acc3, Since),
    ?LOG_DEBUG("Scanning platform Erlang sources"),
    Acc3c = scan_platform_erlang_sources(PlatformsDir, Acc3b, Since),
    ?LOG_DEBUG("Scanning Erlang library sources"),
    Acc4 = scan_erlang_libs(LibsDir, Acc3c, Since),
    % Scan Elixir libraries (exavmlib) for def exports
    Acc5 = scan_elixir_libs(LibsDir, Acc4, Since),
    ?LOG_DEBUG("Intersecting platforms with port driver availability"),
    Acc5b = intersect_port_driver_platforms(Acc5, PlatformsDir, Since),
    case maps:get(tests, Opts, true) of
        true ->
            ?LOG_DEBUG("  Scanning test files for external calls"),
            Acc6 = scan_test_files(TestsDir, Acc5b, Since),
            finalize(Acc6);
        false ->
            ?LOG_DEBUG("Skipping test file scan (disabled)"),
            finalize(Acc5b)
    end.
-spec finalize(map()) -> map().

-doc false.
%% Finalize scan and log results.
finalize(Acc) ->
    ?LOG_INFO(
        "Found ~p unique module:function/arity entries",
        [maps:size(Acc)]
    ),
    Acc.

-doc """
Write a human-readable database file with platform and version information.

Formats the accumulated scan results into a machine-generated `.data` file
containing `{Module, [{Function, Arity, SinceMap, Removed}]}` tuples sorted
by module name.

SinceMap is `#{Platform => Version}` mapping each platform to its
introduction version.
""".
-spec write_db_file(string(), #{{binary(), binary(), arity()} => entry()}) ->
    ok | {error, Reason :: term()}.
write_db_file(Path, Acc) ->
    ByMod = maps:fold(
        fun({M, F, A}, {_Platforms, SinceMap, Removed}, MAcc) ->
            maps:update_with(
                M,
                fun(L) -> [{F, A, SinceMap, Removed} | L] end,
                [{F, A, SinceMap, Removed}],
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
        "%% Format: [{Module, [{Function, Arity, SinceMap, Removed}]}]\n",
        "%% SinceMap: #{Platform => Version} mapping each platform to its since version\n",
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
                    ?LOG_INFO(
                        "Wrote ~p functions across ~p modules to ~s",
                        [maps:size(Acc), length(SortedMods), Path]
                    );
                {error, Reason} ->
                    ?LOG_ERROR("writing file ~s: ~p", [Path, Reason]),
                    {error, Reason}
            end;
        {error, Reason} ->
            ?LOG_ERROR("ensuring directory ~s: ~p", [Path, Reason]),
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
    {2, parse_release_branch_version(Version)};
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
-spec parse_release_branch_version(binary()) ->
    {non_neg_integer(), non_neg_integer()}.

%% Parse a release branch version string like "0.7" into {0, 7}.
parse_release_branch_version(Version) ->
    Parts = binary:split(Version, <<".">>, [global]),
    case Parts of
        [Major, Minor | _] ->
            case is_digit_binary(Major) andalso is_digit_binary(Minor) of
                true ->
                    {binary_to_integer(Major), binary_to_integer(Minor)};
                false ->
                    {0, 0}
            end;
        [Major] ->
            case is_digit_binary(Major) of
                true ->
                    {binary_to_integer(Major), 0};
                false ->
                    {0, 0}
            end;
        _ ->
            {0, 0}
    end.
-spec is_digit_binary(binary()) -> boolean().

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
-spec parse_semver_base(string()) ->
    {ok, {integer(), integer(), integer()}} | {error, term()}.

parse_semver_base(Base) ->
    case string:split(Base, ".", all) of
        [Major, Minor, Patch] ->
            try
                Maj = list_to_integer(Major),
                Min = list_to_integer(Minor),
                Pch = list_to_integer(Patch),
                {ok, {Maj, Min, Pch}}
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
-spec compare_semver_versions({integer(), integer(), integer()}, {
    integer(), integer(), integer()
}) -> older | newer | same.

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

%% Ensure backward compatibility for version values (old binary → version tuple)
%% Used when reading/writing the database to normalize version representations.
-spec ensure_compat_version(since() | version_tuple() | undefined) ->
    version_tuple() | undefined.
ensure_compat_version(undefined) ->
    undefined;
ensure_compat_version({unreleased, Branch}) when is_binary(Branch) ->
    case binary:split(Branch, <<".">>, [global]) of
        [Maj, <<"x">>] ->
            try
                {release, binary_to_integer(Maj), 0}
            catch
                _:_ -> {release, 0, 0}
            end;
        [Maj, Min, <<"x">>] ->
            try
                {release, binary_to_integer(Maj), binary_to_integer(Min)}
            catch
                _:_ -> {release, 0, 0}
            end;
        _ ->
            {release, 0, 0}
    end;
ensure_compat_version(V) when is_tuple(V) ->
    V;
ensure_compat_version(V) when is_binary(V) ->
    case V of
        <<"v", Rest/binary>> ->
            try
                Parts = binary:split(Rest, <<".">>, [global]),
                case Parts of
                    [Maj, Min, Pat] ->
                        {
                            binary_to_integer(Maj),
                            binary_to_integer(Min),
                            binary_to_integer(Pat)
                        };
                    _ ->
                        V
                end
            catch
                _:_ -> V
            end;
        _ ->
            V
    end.

-doc """
Merge two entries following the tag > branch, earliest-wins rules.

Both arguments are {Platforms, SinceMap} 2-tuples, returning a merged 2-tuple.
The Removed field is handled separately during the merge fold and detect_removals.
""".
-spec merge_entry({platforms(), since_map()}, {platforms(), since_map()}) ->
    {platforms(), since_map()}.
merge_entry({OldPlatforms, OldSM}, {NewPlatforms, NewSM}) ->
    MergedPlatforms = merge_platforms_all(OldPlatforms, NewPlatforms),
    MergedSM = merge_since_maps(OldSM, NewSM),
    %% Restrict since_map to only the merged platforms. This prunes stale
    %% platform entries from old since_maps when the platform list has been
    %% narrowed (e.g., [esp32,stm32] + [esp32] → [esp32] should drop stm32
    %% from the since_map too, not just from the platforms list).
    RestrictedSM =
        case MergedPlatforms of
            all -> MergedSM;
            _ -> maps:with(MergedPlatforms, MergedSM)
        end,
    {MergedPlatforms, RestrictedSM}.
-spec merge_platforms_all(platforms(), platforms()) -> platforms().

-doc false.
%% Merge platforms from two entries.
%% 'all' merged with 'all' stays 'all'.
merge_platforms_all(all, all) ->
    all;
%% 'all' merged with a specific list uses the specific platforms (more accurate).
%% If the specific list equals ALL_PLATFORMS, keep 'all' for efficiency.
merge_platforms_all(all, NewList) when is_list(NewList) ->
    case lists:sort(NewList) of
        ?ALL_PLATFORMS -> all;
        Sorted -> Sorted
    end;
merge_platforms_all(OldList, all) when is_list(OldList) ->
    %% Preserve the more restrictive (constrained) platform list.
    %% If OldList was narrowed to specific platforms by port driver
    %% intersection, don't overwrite with 'all' from a later scan.
    OldList;
%% Two specific lists: use the more restrictive (smaller) platform set.
%% A newer scan finding a function in a specific library (e.g. avm_network)
%% supersedes an older scan that found it in a generic library (e.g. eavmlib).
%% The newer scan is more authoritative about actual platform support.
%% An empty list means "not found" and is treated as a no-op (keeps the other list).
merge_platforms_all(OldList, []) when is_list(OldList) ->
    case lists:sort(OldList) of
        ?ALL_PLATFORMS -> all;
        Sorted -> Sorted
    end;
merge_platforms_all([], NewList) when is_list(NewList) ->
    case lists:sort(NewList) of
        ?ALL_PLATFORMS -> all;
        Sorted -> Sorted
    end;
merge_platforms_all(OldList, NewList) when is_list(OldList), is_list(NewList) ->
    OldSorted = lists:sort(OldList),
    NewSorted = lists:sort(NewList),
    %% Compute the union across both scans.  Cross-version platform accumulation
    %% should never LOSE platforms: an older scan may have found fewer platforms
    %% simply because the platform didn't exist yet (e.g. rp2 pre-v0.7.0).
    %% Individual function narrowing (e.g. deep_sleep_hold to [esp32]) is
    %% handled by scan_platform_nifs finding the NIF only in esp32 C source.
    Merged = lists:umerge(OldSorted, NewSorted),
    case Merged of
        ?ALL_PLATFORMS -> all;
        _ -> Merged
    end.
-spec scan_platform_nifs(string(), map(), since()) -> map().

scan_platform_nifs(PlatformsDir, Acc, Since) ->
    case filelib:is_dir(PlatformsDir) of
        false ->
            ?LOG_WARNING("Platforms dir not found: ~s", [PlatformsDir]),
            Acc;
        true ->
            case file:list_dir(PlatformsDir) of
                {ok, Entries} ->
                    lists:foldl(
                        fun(Entry, A) ->
                            PlatDir = filename:join(PlatformsDir, Entry),
                            case filelib:is_dir(PlatDir) of
                                true ->
                                    case
                                        spectrometer_utils:normalize_platform_name(
                                            Entry
                                        )
                                    of
                                        Plat when is_atom(Plat) ->
                                            CFiles = find_c_files(PlatDir),
                                            ?LOG_DEBUG(
                                                "Scanning ~s C source (~p files)",
                                                [Plat, length(CFiles)]
                                            ),
                                            lists:foldl(
                                                fun(CF, A2) ->
                                                    parse_platform_nifs(
                                                        CF, Plat, A2, Since
                                                    )
                                                end,
                                                A,
                                                CFiles
                                            );
                                        _ ->
                                            A
                                    end;
                                false ->
                                    A
                            end
                        end,
                        Acc,
                        Entries
                    );
                {error, _} ->
                    Acc
            end
    end.

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
                    maps:put(
                        Key, {Platforms, make_since_map(Platforms, Since)}, A
                    );
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
-spec parse_platform_nifs(string(), atom(), map(), since()) -> map().

parse_platform_nifs(File, Platform, Acc, Since) ->
    MergeFun = fun([ModStr, FunStr, ArityStr], A) ->
        Arity = list_to_integer(ArityStr),
        Key = {
            spectrometer_utils:ensure_binary(ModStr),
            spectrometer_utils:ensure_binary(FunStr),
            Arity
        },
        maps:update_with(
            Key,
            fun({ExistingPlatforms, ExistingSM}) ->
                {
                    merge_platforms(ExistingPlatforms, Platform),
                    merge_since_maps(
                        ExistingSM, make_since_map([Platform], Since)
                    )
                }
            end,
            {[Platform], make_since_map([Platform], Since)},
            A
        )
    end,
    parse_file_global(
        File,
        "strcmp\\s*\\(\\s*\"([A-Za-z_][A-Za-z0-9_.]*):([A-Za-z_][A-Za-z0-9_]*)/(\\d+)\"",
        MergeFun,
        Acc
    ).

-doc "Merge platforms from two entries, handling 'all' replacement semantics.".
-spec merge_platforms(platforms(), atom()) -> platforms().
merge_platforms(all, NewPlatform) ->
    % Single platform replaces 'all'
    [NewPlatform];
merge_platforms(Existing, all) when is_list(Existing) ->
    %% Preserve specific platforms when merged with 'all' (port driver
    %% constraints are more authoritative than generic library attribution).
    Existing;
merge_platforms(Existing, NewPlatform) when is_list(Existing) ->
    % Existing logic for accumulating specific platforms
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
    % Fallback for other cases (e.g., atom merging)
    Platforms = lists:sort([NewPlatform | Existing]),
    case Platforms of
        ?ALL_PLATFORMS -> all;
        _ -> Platforms
    end.
-spec parse_bifs_gperf(string(), map(), platforms(), since()) -> map().

parse_bifs_gperf(File, Acc, Platforms, Since) ->
    KeyFun = fun([Fun, ArityStr]) ->
        Arity = list_to_integer(ArityStr),
        {<<"erlang">>, spectrometer_utils:ensure_binary(Fun), Arity}
    end,
    parse_file_entries(
        File,
        %% Match erlang:Function/Arity where Function may contain operator
        %% characters (+, -, *, /, =, <, >, !, etc.). Greedy match for
        %% the function name, then backtrack to find the last "/" before digits.
        "^\\s*erlang:([^,\\s]+)/(\\d+)",
        KeyFun,
        Platforms,
        Since,
        Acc
    ).
-spec parse_nifs_gperf(string(), map(), platforms(), since()) -> map().

parse_nifs_gperf(File, Acc, Platforms, Since) ->
    KeyFun = fun([Mod, Fun, ArityStr]) ->
        Arity = list_to_integer(ArityStr),
        {
            spectrometer_utils:ensure_binary(Mod),
            spectrometer_utils:ensure_binary(Fun),
            Arity
        }
    end,
    parse_file_entries(
        File,
        %% Match Module:Function/Arity. Function may be a standard name
        %% (letter/underscore start) or an operator (++ -- ! =/ =/= etc.).
        %% The optional leading quote handles entries like "erlang:error/1".
        %% Module must start with lowercase letter.
        "\\s*?\"?([a-z_][a-z0-9_]*):([A-Za-z_][A-Za-z0-9_]*|[+!@<>=./-]+)/(\\d+)\"?",
        KeyFun,
        Platforms,
        Since,
        Acc
    ).
-spec scan_erlang_libs(string(), map(), since()) -> map().

scan_erlang_libs(LibsDir, Acc, Since) ->
    case filelib:is_dir(LibsDir) of
        false ->
            ?LOG_WARNING("libs dir not found: ~s", [LibsDir]),
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
-spec all_platform_libs() -> [string()].

all_platform_libs() ->
    ["alisp", "estdlib", "etest", "jit", "gleam_avm", "eavmlib"].
-spec hal_platform_libs() -> [term()].

hal_platform_libs() ->
    %% These are _hal.erl files within eavmlib

    %% Handled specially in scan_lib_group
    [].
-spec esp32_only_libs() -> [string()].

esp32_only_libs() ->
    ["avm_esp32", "esp32boot", "esp32devmode"].

-doc "Library definitions with per-module platform restrictions.".
-spec network_libs() ->
    [{binary() | string(), binary() | string() | undefined, [atom()]}].
network_libs() ->
    [
        % Modules with restricted platform support (esp32 and rp2 only)
        {"avm_network", <<"network">>, [esp32, rp2]},
        % network_fsm was only ever on esp32 - deprecated before rp2 had network support
        {"avm_network", <<"network_fsm">>, [esp32]},
        % Other avm_network modules support generic_unix as well
        {"avm_network", <<"ahttp_client">>, [generic_unix, esp32, rp2]},
        {"avm_network", <<"epmd">>, [generic_unix, esp32, rp2]},
        {"avm_network", <<"http_server">>, [generic_unix, esp32, rp2]},
        {"avm_network", <<"mdns">>, [generic_unix, esp32, rp2]}
    ].
-spec rp2_only_libs() -> [string()].

rp2_only_libs() ->
    ["avm_rp2"].
-spec stm32_only_libs() -> [string()].

stm32_only_libs() ->
    ["avm_stm32"].
-spec emscripten_only_libs() -> [string()].

emscripten_only_libs() ->
    ["avm_emscripten"].
-spec generic_unix_only_libs() -> [string()].

generic_unix_only_libs() ->
    ["avm_unix"].

-doc "Scan a library group, supporting both uniform platform strings and per-module tuples.".
-spec scan_lib_group(
    string(),
    [binary() | string() | tuple()],
    platforms() | undefined,
    map(),
    since()
) -> map().
scan_lib_group(_LibsDir, [], _Platforms, Acc, _Since) ->
    Acc;
scan_lib_group(
    LibsDir,
    [{LibName, ModuleName, ModulePlatforms} | Rest],
    _DefaultPlatforms,
    Acc,
    Since
) when is_binary(ModuleName) ->
    % Tuple format: LibName is binary/string, ModuleName is binary, ModulePlatforms is list
    LibSrcDir = filename:join([LibsDir, LibName, "src"]),
    AccNew =
        case filelib:is_dir(LibSrcDir) of
            true ->
                ErlFiles = find_erl_files(LibSrcDir),
                ModuleBin = ensure_key_binary(ModuleName),
                % Filter to only the specific module file
                FilteredFiles = lists:filter(
                    fun(File) ->
                        BaseName = filename:basename(File, ".erl"),
                        list_to_binary(BaseName) =:= ModuleBin
                    end,
                    ErlFiles
                ),
                ?LOG_DEBUG(
                    "Scanning ~s:~s (~p files, platforms: ~p)",
                    [
                        LibName,
                        ModuleName,
                        length(FilteredFiles),
                        ModulePlatforms
                    ]
                ),
                lists:foldl(
                    fun(F, A2) ->
                        parse_exports(F, ModulePlatforms, Since, A2)
                    end,
                    Acc,
                    FilteredFiles
                );
            false ->
                Acc
        end,
    scan_lib_group(LibsDir, Rest, _DefaultPlatforms, AccNew, Since);
scan_lib_group(LibsDir, [LibName | Rest], Platforms, Acc, Since) ->
    % String format: uniform platforms for all modules in a library
    LibSrcDir = filename:join([LibsDir, LibName, "src"]),
    AccNew =
        case filelib:is_dir(LibSrcDir) of
            true ->
                ErlFiles = find_erl_files(LibSrcDir),
                ?LOG_DEBUG(
                    "Scanning ~s (~p files, platforms: ~p)",
                    [LibName, length(ErlFiles), Platforms]
                ),
                lists:foldl(
                    fun(F, A2) ->
                        parse_exports(F, Platforms, Since, A2)
                    end,
                    Acc,
                    ErlFiles
                );
            false ->
                Acc
        end,
    scan_lib_group(LibsDir, Rest, Platforms, AccNew, Since).
-spec parse_exports(string(), platforms(), since(), map()) -> map().

parse_exports(File, Platforms, Since, Acc) ->
    case is_test_module(File) of
        true ->
            Acc;
        false ->
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
                            Key = {Mod, F, A},
                            NewSM = make_since_map(ActualPlatforms, Since),
                            maps:update_with(
                                Key,
                                fun({ExistingPlatforms, ExistingSM}) ->
                                    {
                                        merge_platforms_all(
                                            ExistingPlatforms, ActualPlatforms
                                        ),
                                        merge_since_maps(ExistingSM, NewSM)
                                    }
                                end,
                                {ActualPlatforms, NewSM},
                                A2
                            )
                        end,
                        Acc,
                        Exports
                    )
            end
        % end of case ModName, end of case is_test_module
    end.
-spec is_test_module(string()) -> boolean().

%% Skip test modules to avoid false positives in supported functions.
is_test_module(File) ->
    Base = filename:basename(File, ".erl"),
    case Base of
        "test_" ++ _ -> true;
        "Test_" ++ _ -> true;
        _ -> false
    end.
-spec find_module_name([string()]) -> binary() | undefined.

find_module_name(Lines) ->
    find_first_match(
        "-module\\s*\\(\\s*([a-z_][a-z0-9_]*)\\s*\\)\\s*\\.", Lines
    ).
-spec find_first_match(string(), [string()]) -> binary() | undefined.

find_first_match(Regex, Lines) ->
    find_first_match(Regex, Lines, undefined).

find_first_match(_Regex, [], Default) ->
    Default;
find_first_match(Regex, [Line | Rest], Default) ->
    case re:run(Line, Regex, [{capture, all_but_first, list}]) of
        {match, [Name]} -> spectrometer_utils:ensure_binary(Name);
        _ -> find_first_match(Regex, Rest, Default)
    end.
-spec find_exports([string()]) -> [{binary(), non_neg_integer()}].

find_exports(Lines) ->
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
-spec parse_export_list(string()) -> [{binary(), non_neg_integer()}].

parse_export_list(Content) ->
    Trimmed = string:trim(Content),
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
                        spectrometer_utils:ensure_binary(Fun),
                        list_to_integer(ArityStr)
                    }};
                _ ->
                    false
            end
        end,
        Tokens
    ).
-spec scan_test_files(string(), map(), since()) -> map().

scan_test_files(TestsDir, Acc, Since) ->
    case filelib:is_dir(TestsDir) of
        false ->
            ?LOG_WARNING("tests dir not found: ~s", [TestsDir]),
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
-spec scan_calls_dir(string(), string(), map(), since()) -> map().

scan_calls_dir(Dir, Label, Acc, Since) ->
    case filelib:is_dir(Dir) of
        true ->
            Files = find_erl_files(Dir),
            ?LOG_DEBUG("Found ~p .erl files in ~s", [length(Files), Label]),
            scan_calls(Files, Acc, Since);
        false ->
            Acc
    end.
-spec scan_calls([string()], map(), since()) -> map().

scan_calls(Files, Acc, Since) ->
    OTPMods = spectrometer_otp:modules_list(),
    OTPBins =
        [spectrometer_utils:ensure_binary(Mod) || Mod <- OTPMods],
    OTPSet = sets:from_list(OTPBins),
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
                                        {all, _} ->
                                            Acc2;
                                        _ ->
                                            maps:put(
                                                Key,
                                                {all,
                                                    make_since_map(all, Since)},
                                                Acc2
                                            )
                                    end;
                                false ->
                                    maps:put(
                                        Key,
                                        {all, make_since_map(all, Since)},
                                        Acc2
                                    )
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
-spec scan_port_drivers(string(), map(), since()) -> map().

%% Scan platform directories for C port driver files and register driver
%% modules in the accumulator with per-platform since versions.
%% Drivers registered via REGISTER_PORT_DRIVER macros and *driver.c naming.
scan_port_drivers(PlatformsDir, Acc, Since) ->
    case filelib:is_dir(PlatformsDir) of
        false ->
            Acc;
        true ->
            case file:list_dir(PlatformsDir) of
                {ok, Entries} ->
                    lists:foldl(
                        fun(Entry, A) ->
                            PlatDir = filename:join(PlatformsDir, Entry),
                            case filelib:is_dir(PlatDir) of
                                true ->
                                    Plat = spectrometer_utils:normalize_platform_name(
                                        Entry
                                    ),
                                    CFiles = find_c_files(PlatDir),
                                    lists:foldl(
                                        fun(CF, A2) ->
                                            scan_port_driver_file(
                                                CF, Plat, Since, A2
                                            )
                                        end,
                                        A,
                                        CFiles
                                    );
                                false ->
                                    A
                            end
                        end,
                        Acc,
                        Entries
                    );
                {error, _} ->
                    Acc
            end
    end.
-spec scan_port_driver_file(string(), atom(), since(), map()) -> map().

%% Scan a single C file for REGISTER_PORT_DRIVER macros and register
%% the driver module with the given platform and since version.
scan_port_driver_file(File, Platform, Since, Acc) ->
    {ok, Bin} = file:read_file(File),
    Content = binary_to_list(Bin),
    DriverNames = extract_drivers_from_registry_macros(Content),
    DriverNames2 = extract_driver_modules_from_files(File, DriverNames),
    lists:foldl(
        fun(DriverName, A) ->
            ModBin = spectrometer_utils:ensure_binary(DriverName),
            Key = {ModBin, <<"init">>, 1},
            SM = make_since_map([Platform], Since),
            maps:update_with(
                Key,
                fun({ExistingPlatforms, ExistingSM}) ->
                    {
                        merge_platforms(ExistingPlatforms, Platform),
                        merge_since_maps(ExistingSM, SM)
                    }
                end,
                {[Platform], SM},
                A
            )
        end,
        Acc,
        DriverNames2
    ).
-spec extract_drivers_from_registry_macros(string()) -> [string()].

%% Extract driver module names from REGISTER_PORT_DRIVER and
%% REGISTER_NIF_COLLECTION macros in C source.
extract_drivers_from_registry_macros(Content) ->
    PortDrivers =
        case
            re:run(
                Content,
                "REGISTER_PORT_DRIVER\\s*\\(\\s*([a-z_][a-z0-9_]*)",
                [{capture, all_but_first, list}, global]
            )
        of
            {match, Matches} -> [DriverName || [DriverName] <- Matches];
            nomatch -> []
        end,
    NifCollections =
        case
            re:run(
                Content,
                "REGISTER_NIF_COLLECTION\\s*\\(\\s*([a-z_][a-z0-9_]*)",
                [{capture, all_but_first, list}, global]
            )
        of
            {match, Matches2} -> [DriverName || [DriverName] <- Matches2];
            nomatch -> []
        end,
    PortDrivers ++ NifCollections.
-spec extract_driver_modules_from_files(string(), [string()]) -> [string()].

%% Extract driver module names from *_driver.c and *driver.c file naming convention.
%% Used for v0.5.0 era drivers that don't use REGISTER_PORT_DRIVER macros.
extract_driver_modules_from_files(File, Acc) ->
    FileName = filename:basename(File),
    case filename:extension(FileName) of
        ".c" ->
            Base = filename:basename(FileName, ".c"),
            %% Use re:run with capture offset to find match position
            case re:run(Base, "_driver") of
                {match, [{Start, _Len}]} ->
                    [string:slice(Base, 0, Start) | Acc];
                nomatch ->
                    case re:run(Base, "driver") of
                        {match, [{Start2, _Len2}]} ->
                            [string:slice(Base, 0, Start2) | Acc];
                        nomatch ->
                            Acc
                    end
            end;
        _ ->
            Acc
    end.
-spec find_c_files(string()) -> [string()].

%% Find all .c files in a directory recursively.
find_c_files(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foldl(
                fun(Entry, Acc) ->
                    Path = filename:join(Dir, Entry),
                    case filelib:is_regular(Path) of
                        true ->
                            case filename:extension(Entry) of
                                ".c" -> [Path | Acc];
                                _ -> Acc
                            end;
                        false ->
                            case Entry of
                                %% skip hidden dirs and _build
                                "." ++ _ -> Acc;
                                "_" ++ _ -> Acc;
                                _ -> find_c_files(Path) ++ Acc
                            end
                    end
                end,
                [],
                Entries
            );
        {error, _} ->
            []
    end.
-spec scan_platform_erlang_sources(string(), map(), since()) -> map().

%% Scan platform directories for Erlang library sources (.erl files)
%% and attribute them to their specific platform.
scan_platform_erlang_sources(PlatformsDir, Acc, Since) ->
    case filelib:is_dir(PlatformsDir) of
        false ->
            Acc;
        true ->
            case file:list_dir(PlatformsDir) of
                {ok, Entries} ->
                    lists:foldl(
                        fun(Entry, A) ->
                            PlatDir = filename:join(PlatformsDir, Entry),
                            case filelib:is_dir(PlatDir) of
                                true ->
                                    case
                                        spectrometer_utils:normalize_platform_name(
                                            Entry
                                        )
                                    of
                                        Plat when is_atom(Plat) ->
                                            ErlFiles = find_erl_files(PlatDir),
                                            lists:foldl(
                                                fun(EF, A2) ->
                                                    parse_exports(
                                                        EF, [Plat], Since, A2
                                                    )
                                                end,
                                                A,
                                                ErlFiles
                                            );
                                        _ ->
                                            A
                                    end;
                                false ->
                                    A
                            end
                        end,
                        Acc,
                        Entries
                    );
                {error, _} ->
                    Acc
            end
    end.
-spec intersect_port_driver_platforms(map(), string(), since()) -> map().

%% Intersect platforms with port driver availability.
%% For modules that have C port driver registrations, constrain their
%% functions to only platforms where the driver exists.
%% This is called as a post-processing step after all scanning is done
%% within a single scan_atomvm_repo call.
intersect_port_driver_platforms(DB, _PlatformsDir, _Since) ->
    DriverModules = collect_driver_platforms(DB),
    constrain_function_platforms(DB, DriverModules).
-spec collect_driver_platforms(map()) -> #{binary() => [atom()]}.

%% Collect a map of Module => [Platform] from port driver init/1 entries.
%% These entries were created by scan_port_drivers and have specific platform lists.
collect_driver_platforms(DB) ->
    maps:fold(
        fun
            ({Mod, <<"init">>, 1}, {Platforms, _}, Acc) when
                is_list(Platforms)
            ->
                Sorted = lists:sort(Platforms),
                maps:update_with(
                    Mod,
                    fun(Existing) -> lists:umerge(Existing, Sorted) end,
                    Sorted,
                    Acc
                );
            (_, _, Acc) ->
                Acc
        end,
        #{},
        DB
    ).
-spec constrain_function_platforms(map(), #{binary() => [atom()]}) -> map().

%% Constrain function platforms using collected port driver platform info.
%% For each module that has port driver info, constrain all all-platform
%% entries to only the driver-supported platforms.
%% Handles both Erlang module names (e.g., <<"gpio">>) and Elixir module
%% names (e.g., <<"Elixir.GPIO">>) by normalizing Elixir names to their
%% Erlang driver equivalents.
constrain_function_platforms(DB, DriverModules) ->
    maps:map(
        fun
            ({Mod, _Fun, _Arity}, {all, SinceMap}) ->
                DriverMod = elixir_to_erlang_mod(Mod),
                case maps:find(DriverMod, DriverModules) of
                    {ok, Platforms} ->
                        {Platforms, restrict_since_map(SinceMap, Platforms)};
                    error ->
                        {all, SinceMap}
                end;
            (_Key, Entry) ->
                Entry
        end,
        DB
    ).
-spec elixir_to_erlang_mod(binary()) -> binary().

%% Normalize Elixir module names (<<"Elixir.GPIO">>) to Erlang driver
%% names (<<"gpio">>). Erlang names pass through unchanged.
elixir_to_erlang_mod(<<"Elixir.", Rest/binary>>) ->
    string:lowercase(Rest);
elixir_to_erlang_mod(Mod) ->
    Mod.
-spec intersect_known_module_platforms(map()) -> map().

%% Constrain known modules to their actual platform support.
%% Some modules were moved to avm_network but originally existed in eavmlib
%% with 'all' platforms - these need to be constrained based on historical
%% knowledge of which platforms they actually supported.
intersect_known_module_platforms(DB) ->
    KnownModulePlatforms = #{<<"network_fsm">> => [esp32]},
    maps:map(
        fun
            ({Mod, _Fun, _Arity}, {Platforms, SinceMap, Removed}) ->
                case maps:find(Mod, KnownModulePlatforms) of
                    {ok, ConstrainedPlatforms} when is_list(Platforms) ->
                        % Platforms already specific, but check if it should be constrained
                        % SinceMap might have wrong platforms - constrain to known list
                        AllVersion = maps:get(all, SinceMap, undefined),
                        case AllVersion of
                            undefined ->
                                % No 'all' key - keep specific platforms that match our constraint
                                ConstrainedSM = maps:with(
                                    ConstrainedPlatforms, SinceMap
                                ),
                                {ConstrainedPlatforms, ConstrainedSM, Removed};
                            _ ->
                                % Has 'all' key - use it for all constrained platforms
                                ConstrainedSM = maps:from_list(
                                    [
                                        {P, AllVersion}
                                     || P <- ConstrainedPlatforms
                                    ]
                                ),
                                {ConstrainedPlatforms, ConstrainedSM, Removed}
                        end;
                    {ok, ConstrainedPlatforms} when Platforms =:= all ->
                        % All platforms but module should be constrained
                        AllVersion = maps:get(all, SinceMap),
                        ConstrainedSM = maps:from_list(
                            [{P, AllVersion} || P <- ConstrainedPlatforms]
                        ),
                        {ConstrainedPlatforms, ConstrainedSM, Removed};
                    error ->
                        % No constraint, keep entry as-is
                        {Platforms, SinceMap, Removed}
                end;
            (_, OtherEntry) ->
                OtherEntry
        end,
        DB
    ).
-spec find_erl_files(string()) -> [string()].

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
-spec scan_elixir_libs(string(), map(), since()) -> map().

%% Scan Elixir library source files (.ex) for def exports
%% Exavmlib modules are supported on all platforms
scan_elixir_libs(LibsDir, Acc, Since) ->
    ExavmlibDir = filename:join(LibsDir, "exavmlib"),
    scan_exavmlib_dir(ExavmlibDir, Acc, all, Since).
-spec scan_exavmlib_dir(string(), map(), atom() | [atom()], since()) -> map().

scan_exavmlib_dir(ExavmlibDir, Acc, Platforms, Since) ->
    case filelib:is_dir(ExavmlibDir) of
        true ->
            ExFiles = find_ex_files(ExavmlibDir),
            ?LOG_DEBUG("Scanning exavmlib (~p .ex files)", [length(ExFiles)]),
            lists:foldl(
                fun(F, A) ->
                    parse_elixir_file(F, A, Platforms, Since)
                end,
                Acc,
                ExFiles
            );
        false ->
            ?LOG_WARNING("Skipping exavmlib (not found)"),
            Acc
    end.
-spec find_ex_files(string()) -> [string()].

%% Find all .ex files recursively in a directory
find_ex_files(Dir) ->
    find_ex_files(Dir, []).

find_ex_files(Dir, Acc) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foldl(
                fun(Name, A) ->
                    Path = filename:join(Dir, Name),
                    case file:read_link_info(Path) of
                        {ok, #file_info{type = directory}} ->
                            case Name of
                                "_" ++ _ -> A;
                                "." ++ _ -> A;
                                _ -> find_ex_files(Path, A)
                            end;
                        {ok, #file_info{type = regular}} ->
                            case filename:extension(Name) of
                                ".ex" -> [Path | A];
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
-spec parse_elixir_file(string(), map(), atom() | [atom()], since()) -> map().

%% Parse a single .ex file which may contain multiple defmodule blocks.
parse_elixir_file(File, Acc, Platforms, Since) ->
    case file:read_file(File) of
        {ok, Bin} ->
            Content = binary_to_list(Bin),
            Lines = string:split(Content, "\n", all),
            % Find all exports with their module context
            Exports = find_elixir_exports(Lines),
            lists:foldl(
                fun({Mod, Fun, Arity}, A) ->
                    Key = {Mod, Fun, Arity},
                    NewSM = make_since_map(Platforms, Since),
                    maps:update_with(
                        Key,
                        fun({ExistingPlatforms, ExistingSM}) ->
                            {
                                merge_platforms(ExistingPlatforms, Platforms),
                                merge_since_maps(ExistingSM, NewSM)
                            }
                        end,
                        {Platforms, NewSM},
                        A
                    )
                end,
                Acc,
                Exports
            );
        {error, _} ->
            Acc
    end.
-spec get_indent(string()) -> non_neg_integer().

%% Get leading indentation length (number of leading spaces) from a line
get_indent(Line) ->
    get_indent(Line, 0).

get_indent([$\s | Rest], Count) ->
    get_indent(Rest, Count + 1);
get_indent(_, Count) ->
    Count.
-spec find_elixir_exports([string()]) ->
    [{binary(), binary(), non_neg_integer()}].

%% Find all def exports with their module context.
%% Scans for defmodule/defimpl to track the active module, then associates
%% each def with its enclosing module. Returns [{ModuleNameAtom, FunName, Arity}].
%% ModuleStack entries are {ModAtom, ModIndent} tuples.
find_elixir_exports(Lines) ->
    find_elixir_exports(Lines, [], undefined, []).

find_elixir_exports([], _ModuleStack, _CurrentModule, Acc) ->
    lists:reverse(Acc);
find_elixir_exports(
    [Line | Rest], ModuleStack, CurrentModule, Acc
) ->
    case find_elixir_module_def(Line) of
        {defmodule, ModName} ->
            % Entering a new defmodule block - track its indentation
            ModBin = spectrometer_utils:ensure_binary(
                "Elixir." ++ ModName
            ),
            Indent = get_indent(Line),
            find_elixir_exports(
                Rest, [{ModBin, Indent} | ModuleStack], ModBin, Acc
            );
        {defimpl, ProtocolName} ->
            % Entering a defimpl block (also counts as a module context)
            % Without explicit for, just use the protocol name
            ModBin = spectrometer_utils:ensure_binary(
                "Elixir." ++ ProtocolName
            ),
            Indent = get_indent(Line),
            find_elixir_exports(
                Rest, [{ModBin, Indent} | ModuleStack], ModBin, Acc
            );
        {defimpl, ProtocolName, TargetName} ->
            % Entering a defimpl Protocol, for: Target block
            ModBin = spectrometer_utils:ensure_binary(
                "Elixir." ++ ProtocolName ++ "." ++ TargetName
            ),
            Indent = get_indent(Line),
            find_elixir_exports(
                Rest, [{ModBin, Indent} | ModuleStack], ModBin, Acc
            );
        {end_block} ->
            % Pop module scope if end line indentation matches top module's indentation
            EndIndent = get_indent(Line),
            case ModuleStack of
                [{_ModAtIndent, ModIndent} | RestStack] when
                    EndIndent =< ModIndent
                ->
                    % This end closes the module/impl block - pop the stack
                    NewCurrent =
                        case RestStack of
                            [] -> undefined;
                            [{NewHead, _} | _] -> NewHead
                        end,
                    find_elixir_exports(
                        Rest, RestStack, NewCurrent, Acc
                    );
                _ ->
                    % No module at this indent or no module on stack - stay unchanged
                    find_elixir_exports(
                        Rest, ModuleStack, CurrentModule, Acc
                    )
            end;
        error ->
            % Check for regular def inside a module
            case find_elixir_def(Line) of
                {ok, FunName, Args} ->
                    Arity = count_arity(Args),
                    FunBin = spectrometer_utils:ensure_binary(
                        FunName
                    ),
                    Export =
                        case CurrentModule of
                            undefined ->
                                % Fallback: use filename-based module (shouldn't happen normally)
                                {unknown, FunBin, Arity};
                            ModBin ->
                                {ModBin, FunBin, Arity}
                        end,
                    find_elixir_exports(
                        Rest, ModuleStack, CurrentModule, [Export | Acc]
                    );
                skip ->
                    find_elixir_exports(
                        Rest, ModuleStack, CurrentModule, Acc
                    )
            end
    end.
-spec find_elixir_module_def(string()) ->
    {defmodule, string()}
    | {defimpl, string()}
    | {defimpl, string(), string()}
    | {end_block}
    | error.

%% Detect module boundary lines: defmodule, defimpl, end
find_elixir_module_def(Line) ->
    % Check for end keyword (closing a module/impl block)
    case re:run(Line, "^\\s*end\\s*$", [{capture, none}]) of
        match ->
            {end_block};
        nomatch ->
            % Check for defmodule Name do (require "do" after module name)
            case
                re:run(
                    Line,
                    "^\\s*defmodule\\s+([A-Z][A-Za-z0-9_.]*)\\s+do\\b",
                    [
                        {capture, all_but_first, list}
                    ]
                )
            of
                {match, [ModName]} ->
                    {defmodule, ModName};
                nomatch ->
                    % Check for defprotocol Name do (treat like defmodule)
                    case
                        re:run(
                            Line,
                            "^\\s*defprotocol\\s+([A-Z][A-Za-z0-9_.]*)\\s+do\\b",
                            [{capture, all_but_first, list}]
                        )
                    of
                        {match, [ProtoName]} ->
                            {defmodule, ProtoName};
                        nomatch ->
                            % Check for defimpl Protocol, for: Module do
                            case
                                re:run(
                                    Line,
                                    "^\\s*defimpl\\s+([A-Z][A-Za-z0-9_.]*),\\s*for:\\s*([A-Z][A-Za-z0-9_.]*)\\s+do\\b",
                                    [{capture, all_but_first, list}]
                                )
                            of
                                {match, [ProtocolName, TargetName]} ->
                                    {defimpl, ProtocolName, TargetName};
                                nomatch ->
                                    % Fallback: just protocol name without explicit for (require "do")
                                    case
                                        re:run(
                                            Line,
                                            "^\\s*defimpl\\s+([A-Z][A-Za-z0-9_.]*)\\s+do\\b",
                                            [{capture, all_but_first, list}]
                                        )
                                    of
                                        {match, [ImplName]} ->
                                            {defimpl, ImplName};
                                        nomatch ->
                                            error
                                    end
                            end
                    end
            end
    end.
-spec find_elixir_def(string()) -> {ok, string(), list()} | skip.

%% Match "def " or "defimpl " at beginning of line, then function name
%% with parentheses. This ensures we don't match defp or comments/strings.
find_elixir_def(Line) ->
    % Check for defp first - if found, this is a private function
    case string:find(Line, "defp ") of
        nomatch ->
            find_elixir_def_impl(Line);
        _ ->
            skip
    end.
-spec find_elixir_def_impl(string()) -> {ok, string(), list()} | skip.

find_elixir_def_impl(Line) ->
    % Use re:run to check for "def " at start of line
    case re:run(Line, "^\\s*def\\s+", [{capture, none}]) of
        match ->
            extract_function_from_line(Line);
        nomatch ->
            skip
    end.
-spec extract_function_from_line(string()) -> {ok, string(), list()} | skip.

extract_function_from_line(Line) ->
    % Pattern: def function_name(args) or def function_name do
    % We've already filtered out defp, so just match "def" followed by function name
    % Function names can end with ? or ! (Elixir style).
    % We need to match either:
    %   1. "def name(args)" with optional whitespace around args
    %   2. "def name do" for zero-arity functions
    Parenthesized =
        re:run(
            Line,
            "def\\s+([a-z_][a-z0-9_]*[?!]?)\\s*\\(([^)]*)\\)",
            [{capture, all_but_first, list}]
        ),
    ZeroArity =
        re:run(Line, "def\\s+([a-z_][a-z0-9_]*[?!]?)\\s+do\\b", [
            {capture, all_but_first, list}
        ]),
    case Parenthesized of
        {match, [FunName, Args]} ->
            {ok, FunName, Args};
        _ ->
            case ZeroArity of
                {match, [FunName]} ->
                    {ok, FunName, ""};
                _ ->
                    skip
            end
    end.
-spec count_arity(list()) -> non_neg_integer().

%% Count arity by counting top-level commas + 1 (minimum 0)
count_arity("") ->
    0;
count_arity(Args) ->
    CleanArgs = re:replace(Args, "\\s+", "", [global, {return, list}]),
    case CleanArgs of
        "" -> 0;
        _ -> count_top_level_commas(CleanArgs) + 1
    end.
-spec count_top_level_commas(list()) -> non_neg_integer().

%% Count commas at nesting depth 0 only
%% Track depth for (), [], and {}
count_top_level_commas(Str) ->
    count_top_level_commas(Str, 0, 0).

count_top_level_commas([Char | Rest], Depth, Count) ->
    case Char of
        $( -> count_top_level_commas(Rest, Depth + 1, Count);
        $[ -> count_top_level_commas(Rest, Depth + 1, Count);
        ${ -> count_top_level_commas(Rest, Depth + 1, Count);
        $) -> count_top_level_commas(Rest, Depth - 1, Count);
        $] -> count_top_level_commas(Rest, Depth - 1, Count);
        $} -> count_top_level_commas(Rest, Depth - 1, Count);
        $, when Depth == 0 -> count_top_level_commas(Rest, Depth, Count + 1);
        _ -> count_top_level_commas(Rest, Depth, Count)
    end;
count_top_level_commas([], _Depth, Count) ->
    Count.

%% Detect removals: functions present in existing DB but not found in new scan.
%% Marks them with the Since version as the removal version.
%% Only marks functions as removed if their since version is older than the scan version.
-spec detect_removals(
    #{{binary(), binary(), arity()} => entry()},
    #{{binary(), binary(), arity()} => entry()},
    since()
) -> #{{binary(), binary(), arity()} => entry()}.
detect_removals(ExistingDB, NewAcc, Since) ->
    ExistingKeys = maps:keys(ExistingDB),
    NewKeys = maps:keys(NewAcc),
    RemovedKeys = ExistingKeys -- NewKeys,
    lists:foldl(
        fun(Key, Acc) ->
            case maps:find(Key, ExistingDB) of
                {ok, {Platforms, SinceMap, _OldRemoved}} ->
                    % Check if any since version is older than the scan version
                    % (function existed before this scan, so its removal is meaningful)
                    case has_older_since(SinceMap, Since) of
                        true ->
                            % Function existed before this scan, mark as removed
                            RemovedVersion = ensure_compat_version(Since),
                            maps:put(
                                Key, {Platforms, SinceMap, RemovedVersion}, Acc
                            );
                        false ->
                            % Function was introduced after or at this scan version
                            Acc
                    end;
                error ->
                    Acc
            end
        end,
        ExistingDB,
        RemovedKeys
    ).

%% Check if any since version in the map is older than the scan version.
-spec has_older_since(since_map(), since()) -> boolean().
has_older_since(SinceMap, ScanSince) ->
    lists:any(
        fun(SinceVal) ->
            % Handle both since() binaries/tuples and version tuples
            NormalizedSince = normalize_since(SinceVal),
            is_older_since(NormalizedSince, ScanSince)
        end,
        maps:values(SinceMap)
    ).
-spec normalize_since(since()) -> since().

%% Normalize since values - convert version tuples to binary strings for comparison.
normalize_since({X, Y, Z}) when is_integer(X), is_integer(Y), is_integer(Z) ->
    <<"v", (integer_to_binary(X))/binary, ".", (integer_to_binary(Y))/binary,
        ".", (integer_to_binary(Z))/binary>>;
normalize_since(Other) ->
    Other.

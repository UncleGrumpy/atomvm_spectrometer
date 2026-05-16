%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% Filter command from GitHub Gist: @pguyot/beam_stats.escript#beam_stats_filter.escript
%% Copyright 2026 Paul Guyot <pguyot@kallisys.net>
%% https://gist.github.com/pguyot/da327972f1ecdb7041c97addd4e76bb5#file-beam_stats_filter-escript
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-FileCopyrightText: 2026 Paul Guyot <pguyot@kallisys.net>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_analyzer).

-include("ecosystem.hrl").

-moduledoc """
This modules provides filter and analysis functions.

This module serves as the abstraction layer between CLI commands and the raw
scanner. It accepts a target (GitHub URL, Hex package or local directory),
orchestrates cloning and downloading, and delegates to the scanner and 
reporter.
""".

-export([
    audit/1,
    examine/1,
    filter/1
]).

-type scan_target() ::
    {github_url, string()}
    | {github_clone, string()}
    | {hex, string()}
    | {hex, string(), string()}
    | {local_dir, string()}.

-type stats_map() :: #{{atom(), atom(), arity()} => non_neg_integer()}.

-type csv_row() :: {
    string(), string(), non_neg_integer(), non_neg_integer(), non_neg_integer()
}.

-doc """
Audit a target for use with AtomVM using the provided options.

Options are a map that may include:
- `target` (required if `multi_file` not provided): A single target to scan,
see below for supported formats.
- `multi_file` (required if `target` not provided): A file path containing
multiple targets to scan, one per line. Lines starting with `#` are treated as
comments and ignored. Each line should be either a GitHub URL, a local
directory path, or a Hex package name prefixed with `hex:`.
- `cache_dir`: Optional directory path for caching downloads and clones.
Defaults to a standard user cache directory if not provided.
- `output`: Optional file path to write a CSV report of the scan results. If
not provided, results are only printed to the console.
- `min_count`: Optional minimum call count to include in the report.
Defaults to 1.
- `top`: Optional number of top results to display in the console report.
Defaults to 50.

Supported target types:

- `{github_url, Url}` — A GitHub repo URL; examples: owner/repo, github.com/owner/repo,
https://github.com/owner/repo, or https://github.com/owner/repo.git etc...
- `{github_clone, CloneUrl}` — A git clone URL; example: github.com/owner/repo.git
- `{hex, PackageName}` — Latest version from Hex.pm
- `{hex, PackageName, Version}` — Specific version from Hex.pm
- `{local_dir, Dir}` — A local directory path

Creates temporary directories for clones/downloads and cleans them up
after scanning.
""".
-spec audit(Opts :: map()) -> ok | {error, Reason :: term()}.
audit(Opts) ->
    analyze(Opts, true).

-doc """
Examine the modules and functions provided by an application or library.

Options are a map that may include:
- `target` (required if `multi_file` not provided): A single target to scan,
see below for supported formats.
- `multi_file` (required if `target` not provided): A file path containing
multiple targets to scan, one per line. Lines starting with `#` are treated as
comments and ignored. Each line should be either a GitHub URL, a local
directory path, or a Hex package name prefixed with `hex:`.
- `cache_dir`: Optional directory path for caching downloads and clones.
Defaults to a standard user cache directory if not provided.
- `output`: Optional file path to write a CSV report of the scan results. If
not provided, results are only printed to the console.
- `min_count`: Optional minimum call count to include in the report.
Defaults to 1.
- `top`: Optional number of top results to display in the console report.
Defaults to 50.

Supported target types:

- `{github_url, Url}` — A GitHub repo URL; examples: owner/repo, github.com/owner/repo,
https://github.com/owner/repo, or https://github.com/owner/repo.git etc...
- `{github_clone, CloneUrl}` — A git clone URL; example: github.com/owner/repo.git
- `{hex, PackageName}` — Latest version from Hex.pm
- `{hex, PackageName, Version}` — Specific version from Hex.pm
- `{local_dir, Dir}` — A local directory path

Creates temporary directories for clones/downloads and cleans them up
after scanning.
""".
-spec examine(Opts :: map()) -> ok | {error, Reason :: term()}.
examine(Opts) ->
    analyze(Opts, false).

-spec analyze(Opts :: map(), AvmAudit :: boolean()) ->
    ok | {error, Reason :: term()}.
analyze(Opts, AvmAudit) ->
    try
        case spectrometer_utils:start_applications() of
            {error, {already_started, _}} ->
                ok;
            {error, Reason0} ->
                io:format(
                    "Failed to start required applications: ~p\n",
                    [Reason0]
                ),
                error(Reason0);
            ok ->
                ok
        end,
        case Opts of
            #{cache_dir := CacheDir} ->
                application:set_env(spectrometer, cache_dir, CacheDir);
            #{} ->
                ok
        end,

        Stats =
            case maps:find(multi_file, Opts) of
                {ok, File} ->
                    scan_multi(File);
                error ->
                    #{target := Target} = Opts,
                    scan_target(Target)
            end,

        io:format("\nAnalyzing ~p unique function calls...\n", [
            maps:size(Stats)
        ]),

        Report = spectrometer_reporter:generate_report(
            Stats, maps:get(min_count, Opts, 1)
        ),

        Top =
            case maps:get(top, Opts, 50) of
                N when is_integer(N), N > 0 -> N;
                _ -> 50
            end,
        spectrometer_reporter:print_summary(Report, Top, AvmAudit),

        case Opts of
            #{output := OutputFile} when is_list(OutputFile) ->
                case spectrometer_reporter:write_csv(OutputFile, Report) of
                    ok ->
                        ok;
                    {error, Reason1} ->
                        io:format(
                            "Failed to write CSV report to ~s: ~p\n",
                            [OutputFile, Reason1]
                        ),
                        error(Reason1)
                end;
            #{} ->
                ok
        end
    catch
        error:Reason -> {error, Reason}
    end.

-spec scan_target(scan_target()) -> stats_map().
scan_target({local_dir, Dir}) ->
    io:format("  Scanning local directory: ~s\n", [Dir]),
    spectrometer_scanner:scan_directory(Dir);
scan_target({github_clone, CloneUrl}) ->
    TmpDir = spectrometer_utils:make_temp_dir("gh_"),
    try
        io:format("  Cloning ~s...\n", [CloneUrl]),
        Url = spectrometer_utils:normalize_github_url(CloneUrl),
        case spectrometer_http:download_github_repo(Url, TmpDir) of
            ok ->
                io:format("  Scanning...\n"),
                spectrometer_scanner:scan_directory(TmpDir);
            {error, Reason} ->
                io:format("  Clone failed: ~p\n", [Reason]),
                #{}
        end
    after
        spectrometer_utils:purge_dir(TmpDir)
    end;
scan_target({github_url, Url}) ->
    CloneUrl = spectrometer_utils:normalize_github_url(Url),
    scan_target({github_clone, CloneUrl});
scan_target({hex, PackageName}) ->
    scan_target({hex, PackageName, "latest"});
scan_target({hex, PackageName, "latest"}) ->
    %% Fetch package info from Hex to get latest version
    Url = lists:flatten(
        io_lib:format("https://hex.pm/api/packages/~s", [PackageName])
    ),
    case spectrometer_http:fetch(Url) of
        {ok, Body} ->
            try
                case json:decode(Body) of
                    #{<<"releases">> := [#{<<"version">> := V} | _]} when
                        is_binary(V)
                    ->
                        scan_target({hex, PackageName, binary_to_list(V)});
                    _ ->
                        io:format("  Failed to get version info for ~s\n", [
                            PackageName
                        ]),
                        #{}
                end
            catch
                _:_ ->
                    #{}
            end;
        {error, Reason} ->
            io:format("  Failed to fetch ~s from Hex: ~p\n", [
                PackageName, Reason
            ]),
            #{}
    end;
scan_target({hex, PackageName, Version}) ->
    io:format("  Downloading ~s-~s from Hex...\n", [PackageName, Version]),
    case spectrometer_http:download_hex_tarball(PackageName, Version) of
        {ok, TmpDir} ->
            try
                io:format("  Scanning...\n"),
                spectrometer_scanner:scan_directory(TmpDir)
            after
                spectrometer_utils:purge_dir(TmpDir)
            end;
        {error, Reason} ->
            io:format("  Failed to download ~s-~s: ~p\n", [
                PackageName, Version, Reason
            ]),
            #{}
    end.

-spec scan_multi(string()) ->
    #{{atom(), atom(), arity()} => non_neg_integer()}.
scan_multi(File) ->
    case file:read_file(File) of
        {ok, Bin} ->
            Lines = string:split(binary_to_list(Bin), "\n", all),
            Targets = parse_target_lines(Lines),
            io:format("Scanning ~p targets from ~s...\n\n", [
                length(Targets), File
            ]),
            {_, FinalAcc} = lists:foldl(
                fun(Target, {Count, Acc}) ->
                    NewCount = Count + 1,
                    io:format("[~p/~p]\n", [NewCount, length(Targets)]),
                    Stats0 = scan_target(Target),
                    NewAcc = merge_stats(Stats0, Acc),
                    {NewCount, NewAcc}
                end,
                {0, #{}},
                Targets
            ),
            FinalAcc;
        {error, Reason} ->
            erlang:error({could_not_read_multi_target_file, Reason})
    end.

-doc false.
% Parse multi-target file lines into scan targets.
% Lines starting with `#` are treated as comments and blank lines are
% skipped. Lines prefixed with `hex:` become Hex targets; GitHub URLs and
% local directory paths are auto-detected.
-spec parse_target_lines([unicode:chardata()]) -> [scan_target()].
parse_target_lines(Lines) ->
    lists:filtermap(
        fun(Line) ->
            case string:trim(Line) of
                "" ->
                    false;
                "#" ++ _ ->
                    false;
                "hex:" ++ Pkg ->
                    {true, {hex, Pkg}};
                Url ->
                    case string:find(Url, "github.com") of
                        nomatch ->
                            case filelib:is_dir(Url) of
                                true ->
                                    {true, {local_dir, Url}};
                                false ->
                                    case is_valid_url(Url) of
                                        true -> {true, {github_url, Url}};
                                        false -> false
                                    end
                            end;
                        _ ->
                            {true, {github_url, Url}}
                    end
            end
        end,
        Lines
    ).

-doc """
Combine multiple scan results into a single statistics map.

Adds call counts from `New` into `Acc`, summing counts for keys that
exist in both maps. Useful for merging results from multiple targets
scanned in a multi-target file or ecosystem scan.

#### Example

```erlang
1> merge_stats(
1>   #{{lists,map,2} => 5},
1>   #{{lists,map,2} => 3, {io,format,2} => 10}).
#{{io,format,2} => 10, {lists,map,2} => 8}
```
""".
-spec merge_stats(stats_map(), stats_map()) -> stats_map().
merge_stats(New, Acc) ->
    maps:fold(
        fun(Key, Count, A) ->
            maps:update_with(Key, fun(V) -> V + Count end, Count, A)
        end,
        Acc,
        New
    ).

-spec load_ecosystem_state() ->
    #{{atom(), atom(), arity()} => {non_neg_integer(), non_neg_integer()}}.
load_ecosystem_state() ->
    CacheDir = spectrometer_utils:user_cache_path(),
    StateFile = filename:join(CacheDir, ?ECOSYSTEM_STATE),
    case file:read_file(StateFile) of
        {ok, Bin} ->
            try
                case binary_to_term(Bin) of
                    {spectrometer_v1, _, Stats, _} when is_map(Stats) ->
                        io:format("Loaded ecosystem state from ~s\n", [
                            StateFile
                        ]),
                        Stats;
                    _ ->
                        io:format(
                            standard_error,
                            "Warning: Invalid ecosystem state file: ~s, starting with empty data set.\n",
                            [
                                StateFile
                            ]
                        ),
                        #{}
                end
            catch
                _:_:_ ->
                    io:format(
                        standard_error,
                        "Warning: Unable to load data from ~s, starting with empty data set.\n",
                        [StateFile]
                    ),
                    #{}
            end;
        {error, enoent} ->
            #{};
        {error, Reason} ->
            io:format(standard_error, "Error: Could not read ~s: ~p\n", [
                StateFile, Reason
            ]),
            #{}
    end.

-doc """
Execute the filter command to analyze ecosystem scan results.

This function loads data from either a CSV file or the saved ecosystem state,
filters the results based on repository count and optional AtomVM support status,
and prints a formatted report.
""".
-spec filter(atomvm_spectrometer:opts_map()) -> ok | {error, term()}.
filter(Opts) ->
    MinRepos = maps:get(min_repos, Opts, 1),
    AvmFilter = maps:get(avm, Opts, false),
    case Opts of
        #{cache_dir := CacheDir} ->
            application:set_env(spectrometer, cache_dir, CacheDir),
            spectrometer_atomvm:reload_db();
        #{} ->
            ok
    end,

    case load_filter_data(Opts) of
        {error, _} = Error ->
            Error;
        Rows ->
            case filter_by_repositories(Rows, MinRepos) of
                [] ->
                    io:format(
                        standard_error,
                        "Error: No OTP functions found with >= ~p repos. Try lowering --min-repos?\n",
                        [MinRepos]
                    ),
                    ok;
                FilteredByRepos ->
                    Filtered =
                        case AvmFilter of
                            true -> filter_by_avm_support(FilteredByRepos);
                            false -> FilteredByRepos
                        end,

                    case Filtered of
                        [] ->
                            io:format(
                                standard_error,
                                "No functions match the specified criteria.\n",
                                []
                            ),
                            ok;
                        _ ->
                            print_filtered_results(
                                Filtered, MinRepos, AvmFilter
                            )
                    end
            end
    end.

-doc """
Load filter data from either a CSV file or the ecosystem state.
""".
-spec load_filter_data(atomvm_spectrometer:opts_map()) ->
    [csv_row()] | {error, string()}.
load_filter_data(Opts) ->
    case maps:find(csv_file, Opts) of
        {ok, CsvFile} ->
            case file:read_file(CsvFile) of
                {ok, Bin} ->
                    [_Header | DataLines] = string:split(
                        binary_to_list(Bin), "\n", all
                    ),
                    parse_csv_rows(DataLines);
                {error, Reason} ->
                    {error,
                        "Could not read CSV file: " ++
                            file:format_error(Reason)}
            end;
        error ->
            case load_ecosystem_state() of
                Stats when map_size(Stats) > 0 ->
                    maps:fold(
                        fun({Mod, Fun, Arity}, {Calls, RepoCount}, Acc) ->
                            [
                                {
                                    atom_to_list(Mod),
                                    atom_to_list(Fun),
                                    Arity,
                                    Calls,
                                    RepoCount
                                }
                                | Acc
                            ]
                        end,
                        [],
                        Stats
                    );
                _ ->
                    {error,
                        "No ecosystem state file found. Run 'ecosystem' command first."}
            end
    end.

-doc """
Filter rows by minimum repository count and OTP module status.
""".
-spec filter_by_repositories([csv_row()], non_neg_integer()) -> [csv_row()].
filter_by_repositories(Rows, MinRepos) ->
    lists:filter(
        fun({Mod, _Fun, _Arity, _Calls, RepoCount}) ->
            RepoCount >= MinRepos andalso spectrometer_otp:is_otp_module(Mod)
        end,
        Rows
    ).

-doc """
Filter rows by AtomVM support status, only report unsupported functions.
""".
-spec filter_by_avm_support([csv_row()]) -> [csv_row()].
filter_by_avm_support(Rows) ->
    lists:filter(
        fun({ModStr, FunStr, Arity, _Calls, _RepoCount}) ->
            % First try to create atoms using list_to_existing_atom for validation
            {Mod, Fun} = {
                spectrometer_utils:atom_from_string(ModStr),
                spectrometer_utils:atom_from_string(FunStr)
            },
            false =:= spectrometer_atomvm:is_supported({Mod, Fun, Arity})
        end,
        Rows
    ).

%% @private
%% Check if a string looks like a valid URL or repo path.
is_valid_url(Url) ->
    case
        string:find(Url, "http://") =:= nomatch andalso
            string:find(Url, "https://") =:= nomatch andalso
            string:find(Url, "git@") =:= nomatch andalso
            string:find(Url, "/") =:= nomatch
    of
        true ->
            %% No protocol, no ssh, no slash — could be a hex pkg or garbage
            false;
        false ->
            true
    end.

-doc """
Print the filtered results organized by module.
""".
-spec print_filtered_results([csv_row()], non_neg_integer(), boolean()) -> ok.
print_filtered_results(Filtered, MinRepos, AvmFilter) ->
    ByModule = lists:foldl(
        fun({Mod, Fun, Arity, Calls, RC}, Acc) ->
            maps:update_with(
                Mod,
                fun(L) -> [{Fun, Arity, Calls, RC} | L] end,
                [{Fun, Arity, Calls, RC}],
                Acc
            )
        end,
        #{},
        Filtered
    ),

    Modules = lists:sort(maps:to_list(ByModule)),
    TotalFuns = lists:sum([length(Funs) || {_, Funs} <- Modules]),

    case AvmFilter of
        true ->
            io:format(
                "OTP functions not supported by AtomVM (>= ~p repos): ~p functions across ~p modules\n\n",
                [MinRepos, TotalFuns, length(Modules)]
            );
        false ->
            io:format(
                "OTP functions used by >= ~p repos: ~p functions across ~p modules\n\n",
                [MinRepos, TotalFuns, length(Modules)]
            )
    end,

    lists:foreach(
        fun({Mod, Funs}) ->
            Sorted = lists:sort(
                fun({_, _, _, RC1}, {_, _, _, RC2}) -> RC1 > RC2 end, Funs
            ),
            io:format("~ts (~p functions):\n", [Mod, length(Sorted)]),
            lists:foreach(
                fun({Fun, Arity, Calls, RC}) ->
                    io:format("  ~ts/~p  (~p calls in ~p repos)\n", [
                        Fun, Arity, Calls, RC
                    ])
                end,
                Sorted
            ),
            io:format("\n")
        end,
        Modules
    ).

-doc """
Parse CSV data lines into row tuples.

Supports 4-column (`module,function,arity,calls`) and 5-column
(`module,function,arity,calls,repo_count`) formats.
""".
-spec parse_csv_rows([string()]) -> [csv_row()].
parse_csv_rows(Lines) ->
    parse_csv_rows(Lines, []).

-spec parse_csv_rows([string()], Acc :: list()) -> [csv_row()].
parse_csv_rows([], Acc) ->
    lists:reverse(Acc);
parse_csv_rows([Line | Lines], Acc) ->
    case string:trim(Line) of
        "" ->
            parse_csv_rows(Lines, Acc);
        Trimmed ->
            case string:split(Trimmed, ",", all) of
                [ModStr, FunStr, ArityStr, CallsStr, RCStr] ->
                    case
                        {
                            string:to_integer(string:trim(ArityStr)),
                            string:to_integer(string:trim(CallsStr)),
                            string:to_integer(string:trim(RCStr))
                        }
                    of
                        {{Arity, []}, {Calls, []}, {RC, []}} ->
                            parse_csv_rows(Lines, [
                                {ModStr, FunStr, Arity, Calls, RC} | Acc
                            ]);
                        _ ->
                            parse_csv_rows(Lines, Acc)
                    end;
                [ModStr, FunStr, ArityStr, CallsStr] ->
                    case
                        {
                            string:to_integer(string:trim(ArityStr)),
                            string:to_integer(string:trim(CallsStr))
                        }
                    of
                        {{Arity, []}, {Calls, []}} ->
                            parse_csv_rows(Lines, [
                                {ModStr, FunStr, Arity, Calls, 1} | Acc
                            ]);
                        _ ->
                            parse_csv_rows(Lines, Acc)
                    end;
                _ ->
                    parse_csv_rows(Lines, Acc)
            end
    end.

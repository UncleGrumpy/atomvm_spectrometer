%%
%% Copyright 2026 Paul Guyot <pguyot@kallisys.net>
%% GitHub Gist @pguyot/beam_stats.escript
%% https://gist.github.com/pguyot/da327972f1ecdb7041c97addd4e76bb5
%%
%% Adapted for atomvm_spectrometer
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%%
%% SPDX-FileCopyrightText: 2026 Paul Guyot <pguyot@kallisys.net>
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_ecosystem).

-include("ecosystem.hrl").

-export([run/1]).

-define(SAVE_INTERVAL, 10).

-type work_item() :: {github | hex, map()}.
-type coordinator_state() :: #{
    work => [work_item()],
    scanned => sets:set(map()),
    stats => #{
        {atom(), atom(), arity()} => {non_neg_integer(), non_neg_integer()}
    },
    total_processed => non_neg_integer(),
    total_work => non_neg_integer(),
    since_save => non_neg_integer(),
    active_workers => non_neg_integer(),
    worker_monitors => #{reference() => pid()},
    parent => pid()
}.

-doc false.
-spec run(atomvm_spectrometer:opts_map()) -> ok | {error, term()}.
run(Opts) ->
    try
        case spectrometer_utils:start_applications() of
            {error, already_started} ->
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

        {Scanned, Stats, TotalProcessed} =
            case maps:get(resume, Opts) of
                true -> load_state();
                false -> {sets:new([{version, 2}]), #{}, 0}
            end,

        Limit = maps:get(limit, Opts),
        Stars = maps:get(stars, Opts, infinity),
        GithubRepos =
            case maps:get(github, Opts) of
                true -> spectrometer_http:fetch_github_repos({Limit, Stars});
                false -> []
            end,
        HexLeft =
            case Limit of
                infinity -> infinity;
                _ -> max(0, Limit - length(GithubRepos))
            end,
        HexPackages =
            case maps:get(hex, Opts) of
                true -> spectrometer_http:fetch_hex_packages(HexLeft);
                false -> []
            end,

        {Repos, Packages} = deduplicate(GithubRepos, HexPackages),

        io:format(
            "Work items: ~p GitHub repos, ~p Hex packages\n",
            [length(Repos), length(Packages)]
        ),

        Work0 = [{github, R} || R <- Repos] ++ [{hex, P} || P <- Packages],
        Work = lists:filter(
            fun({Type, Item}) ->
                Key = work_key(Type, Item),
                not sets:is_element(Key, Scanned)
            end,
            Work0
        ),

        io:format(
            "Items to scan: ~p (skipping ~p already scanned)\n",
            [length(Work), length(Work0) - length(Work)]
        ),

        case run_coordinator(Work, Scanned, Stats, TotalProcessed, Opts) of
            {ok, _FinalStats} -> ok;
            {error, Err} -> {error, Err}
        end
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, Stack}}
    end.

-doc """
Remove duplicate work items between GitHub and Hex sources.

Returns `{GithubRepos, FilteredHexPackages}` where Hex packages whose
GitHub URL matches an already-included GitHub repo are removed.
""".
-spec deduplicate([map()], [map()]) -> {[map()], [map()]}.
deduplicate(GithubRepos, HexPackages) ->
    GithubUrls = sets:from_list(
        [
            spectrometer_utils:normalize_github_url(maps:get(html_url, R))
         || R <- GithubRepos
        ],
        [
            {version, 2}
        ]
    ),
    FilteredHex = lists:filter(
        fun(P) ->
            case maps:get(github_url, P) of
                "" ->
                    true;
                Url ->
                    Normalized = spectrometer_utils:normalize_github_url(
                        Url
                    ),
                    not sets:is_element(Normalized, GithubUrls)
            end
        end,
        HexPackages
    ),
    {GithubRepos, FilteredHex}.

-doc """
Generate a unique string key for a work item.
""".
-spec work_key(github | hex, map()) -> string().
work_key(github, #{full_name := Name}) -> "github:" ++ Name;
work_key(hex, #{name := Name}) -> "hex:" ++ Name.

-spec run_coordinator(
    [work_item()],
    sets:set(map()),
    #{{atom(), atom(), arity()} => {non_neg_integer(), non_neg_integer()}},
    non_neg_integer(),
    atomvm_spectrometer:opts_map()
) ->
    {ok, #{{atom(), atom(), arity()} => {non_neg_integer(), non_neg_integer()}}}
    | {error, term()}.
run_coordinator(Work, Scanned, Stats, TotalProcessed, Opts) ->
    NumWorkers = maps:get(workers, Opts),
    case NumWorkers < 1 of
        true ->
            {error, {invalid_workers, NumWorkers}};
        false ->
            do_run_coordinator(
                Work, Scanned, Stats, TotalProcessed, Opts, NumWorkers
            )
    end.

do_run_coordinator(Work, Scanned, Stats, TotalProcessed, _Opts, NumWorkers) ->
    TotalWork = length(Work) + TotalProcessed,
    Self = self(),
    {CoordPid, CoordRef} = spawn_monitor(fun() ->
        coordinator_loop_initial(#{
            work => Work,
            scanned => Scanned,
            stats => Stats,
            total_processed => TotalProcessed,
            total_work => TotalWork,
            since_save => 0,
            active_workers => NumWorkers,
            worker_monitors => #{},
            parent => Self
        })
    end),
    receive
        {coordinator_done, FinalStats} -> {ok, FinalStats};
        {error, Reason} -> {error, Reason};
        {'DOWN', CoordRef, process, CoordPid, Reason} -> {error, Reason}
    end.

-spec coordinator_loop_initial(coordinator_state()) -> no_return().
coordinator_loop_initial(State) ->
    #{active_workers := NumWorkers} = State,
    WorkerMonitors = spawn_workers(self(), NumWorkers),
    coordinator_loop(State#{worker_monitors => WorkerMonitors}).

-spec spawn_workers(pid(), non_neg_integer()) -> #{reference() => pid()}.
spawn_workers(_CoordPid, 0) ->
    #{};
spawn_workers(CoordPid, N) when N > 0 ->
    {WorkerPid, MonitorRef} = spawn_monitor(fun() -> worker_loop(CoordPid) end),
    Rest = spawn_workers(CoordPid, N - 1),
    Rest#{MonitorRef => WorkerPid}.

-spec coordinator_loop(coordinator_state()) -> no_return().
coordinator_loop(State) ->
    receive
        {get_work, WorkerPid} ->
            case maps:get(work, State) of
                [] ->
                    WorkerPid ! no_more_work,
                    coordinator_loop(State);
                [Item | Rest] ->
                    WorkerPid ! {work, Item},
                    coordinator_loop(State#{work => Rest})
            end;
        {result, Key, RepoStats} ->
            #{
                scanned := Scanned,
                stats := Stats,
                total_processed := TP,
                total_work := TW,
                since_save := SS,
                parent := Parent
            } = State,
            NewScanned = sets:add_element(Key, Scanned),
            NewStats = merge_repo_stats(RepoStats, Stats),
            NewTP = TP + 1,
            NewSS = SS + 1,
            io:format(
                "\r  Progress: ~p/~p (~.1f%)    ",
                [NewTP, TW, NewTP / max(1, TW) * 100]
            ),
            case NewSS >= ?SAVE_INTERVAL of
                true ->
                    case save_state(NewScanned, NewStats, NewTP) of
                        ok ->
                            coordinator_loop(State#{
                                scanned => NewScanned,
                                stats => NewStats,
                                total_processed => NewTP,
                                since_save => 0
                            });
                        {error, Reason} ->
                            io:format(
                                "\n  Warning: Failed to save state: ~p\n",
                                [Reason]
                            ),
                            Parent ! {error, {save_state, Reason}}
                    end;
                false ->
                    coordinator_loop(State#{
                        scanned => NewScanned,
                        stats => NewStats,
                        total_processed => NewTP,
                        since_save => NewSS
                    })
            end;
        {worker_done, _WorkerPid} ->
            handle_worker_exit(State, undefined);
        {'DOWN', MonitorRef, process, WorkerPid, Reason} ->
            case maps:get(worker_monitors, State, #{}) of
                #{MonitorRef := _} ->
                    handle_worker_exit(State, {MonitorRef, WorkerPid, Reason});
                #{} ->
                    % Unknown monitor ref - just clean up
                    NewMonitors = maps:remove(
                        MonitorRef, maps:get(worker_monitors, State, #{})
                    ),
                    coordinator_loop(State#{worker_monitors => NewMonitors})
            end
    end.

handle_worker_exit(State, ExitInfo) ->
    #{
        active_workers := AW,
        stats := Stats,
        scanned := Scanned,
        total_processed := TP,
        parent := Parent,
        worker_monitors := Monitors
    } = State,
    NewAW = AW - 1,
    NewMonitors =
        case ExitInfo of
            undefined ->
                Monitors;
            {MonitorRef, _WorkerPid, _Reason} ->
                maps:remove(MonitorRef, Monitors)
        end,
    case NewAW of
        0 ->
            io:format("\n"),
            case save_state(Scanned, Stats, TP) of
                ok ->
                    Parent ! {coordinator_done, Stats};
                {error, Reason} ->
                    Parent ! {error, {save_state, Reason}}
            end;
        _ ->
            coordinator_loop(State#{
                active_workers => NewAW,
                worker_monitors => NewMonitors
            })
    end.

-spec worker_loop(pid()) -> no_return().
worker_loop(CoordPid) ->
    CoordPid ! {get_work, self()},
    receive
        {work, {github, Item}} ->
            Key = work_key(github, Item),
            RepoStats =
                try
                    process_github_repo(Item)
                catch
                    _:Reason ->
                        io:format("\n  Error processing ~s: ~p\n", [Key, Reason]),
                        #{}
                end,
            CoordPid ! {result, Key, RepoStats},
            worker_loop(CoordPid);
        {work, {hex, Item}} ->
            Key = work_key(hex, Item),
            RepoStats =
                try
                    process_hex_package(Item)
                catch
                    _:Reason ->
                        io:format("\n  Error processing ~s: ~p\n", [Key, Reason]),
                        #{}
                end,
            CoordPid ! {result, Key, RepoStats},
            worker_loop(CoordPid);
        no_more_work ->
            CoordPid ! {worker_done, self()},
            ok
    end.

-spec process_github_repo(map()) ->
    #{{atom(), atom(), arity()} => non_neg_integer()}.
process_github_repo(Repo) ->
    CloneUrl = maps:get(clone_url, Repo),
    TmpDir = spectrometer_utils:make_temp_dir("gh_"),
    try
        case
            spectrometer_utils:run_git_command(
                [
                    "clone", "--depth", "1", "--quiet", CloneUrl, TmpDir
                ],
                [{"GIT_TERMINAL_PROMPT", "0"}]
            )
        of
            {ok, _} ->
                case filelib:is_dir(TmpDir) of
                    true -> spectrometer_scanner:scan_directory(TmpDir);
                    false -> #{}
                end;
            {error, _} ->
                #{}
        end
    after
        _ = spectrometer_utils:purge_dir(TmpDir)
    end.

-spec process_hex_package(map()) ->
    #{{atom(), atom(), arity()} => non_neg_integer()}.
process_hex_package(Package) ->
    Name = maps:get(name, Package),
    Version = maps:get(version, Package),
    case spectrometer_http:download_hex_tarball(Name, Version) of
        {ok, TmpDir} ->
            try
                spectrometer_scanner:scan_directory(TmpDir)
            after
                spectrometer_utils:purge_dir(TmpDir)
            end;
        {error, _Reason} ->
            #{}
    end.

-doc """
Merge a single repo's scan statistics into the global ecosystem accumulator.

Each entry in `GlobalStats` tracks `{TotalCalls, RepoCount}`.
""".
-spec merge_repo_stats(
    #{{atom(), atom(), arity()} => non_neg_integer()},
    #{{atom(), atom(), arity()} => {non_neg_integer(), non_neg_integer()}}
) ->
    #{{atom(), atom(), arity()} => {non_neg_integer(), non_neg_integer()}}.
merge_repo_stats(RepoStats, GlobalStats) ->
    maps:fold(
        fun(Key, CallCount, Acc) ->
            maps:update_with(
                Key,
                fun({TC, RC}) -> {TC + CallCount, RC + 1} end,
                {CallCount, 1},
                Acc
            )
        end,
        GlobalStats,
        RepoStats
    ).

-spec save_state(
    sets:set(map()),
    #{{atom(), atom(), arity()} => {non_neg_integer(), non_neg_integer()}},
    non_neg_integer()
) -> ok | {error, term()}.
save_state(Scanned, Stats, TotalProcessed) ->
    State = {spectrometer_v1, Scanned, Stats, TotalProcessed},
    CacheDir =
        case application:get_env(spectrometer, cache_dir) of
            undefined -> spectrometer_utils:user_cache_path();
            {ok, CacheDir1} -> CacheDir1
        end,
    TmpFile = filename:join(CacheDir, ?ECOSYSTEM_STATE ++ ".tmp"),
    case filelib:ensure_path(CacheDir) of
        ok ->
            case
                file:write_file(TmpFile, term_to_binary(State, [compressed]))
            of
                ok ->
                    EcoState = filename:join(CacheDir, ?ECOSYSTEM_STATE),
                    case file:rename(TmpFile, EcoState) of
                        ok -> ok;
                        {error, Reason} -> {error, {rename, Reason}}
                    end;
                {error, Reason} ->
                    {error, {write, Reason}}
            end;
        {error, Reason} ->
            {error, {ensure_path, Reason}}
    end.

-spec load_state() ->
    {
        sets:set(map()),
        #{{atom(), atom(), arity()} => {non_neg_integer(), non_neg_integer()}},
        non_neg_integer()
    }.
load_state() ->
    case
        file:read_file(
            filename:join(
                spectrometer_utils:user_cache_path(), ?ECOSYSTEM_STATE
            )
        )
    of
        {ok, Bin} ->
            try
                case binary_to_term(Bin) of
                    {spectrometer_v1, Scanned, Stats, TotalProcessed} ->
                        io:format(
                            "Resumed state: ~p items already scanned\n", [
                                TotalProcessed
                            ]
                        ),
                        {Scanned, Stats, TotalProcessed};
                    _ ->
                        io:format(
                            "Warning: Invalid state file, starting fresh\n"
                        ),
                        {sets:new([{version, 2}]), #{}, 0}
                end
            catch
                _:_ ->
                    io:format(
                        "Warning: Could not decode state file, starting fresh\n"
                    ),
                    {sets:new([{version, 2}]), #{}, 0}
            end;
        {error, enoent} ->
            io:format("No state file found, starting fresh\n"),
            {sets:new([{version, 2}]), #{}, 0};
        {error, Reason} ->
            io:format(
                "Warning: Could not read state file (~p), starting fresh\n",
                [Reason]
            ),
            {sets:new([{version, 2}]), #{}, 0}
    end.

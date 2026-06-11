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

-include_lib("kernel/include/logger.hrl").
-include("ecosystem.hrl").

-export([run/1]).

-type work_item() :: {github | hex, map()}.

-doc """
Run the ecosystem scan using distributed worker nodes.
""".
-spec run(atomvm_spectrometer:opts_map()) -> ok | {error, term()}.
run(Opts) ->
    try
        {Scanned, Stats, PackageMap, TotalProcessed} =
            case maps:get(resume, Opts) of
                true -> load_state();
                false -> {#{}, #{}, #{}, 0}
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

        ?LOG_INFO(
            "Work items: ~p GitHub repos, ~p Hex packages",
            [length(Repos1), length(Packages1)]
        ),

        Work0 = [{github, R} || R <- Repos] ++ [{hex, P} || P <- Packages],
        Work = filter_scanned(Work0, Scanned),

        ?LOG_NOTICE(
            "Items to scan: ~p (skipping ~p already scanned)",
            [length(Work), length(Work0) - length(Work)]
        ),

        run_scan(Work, Scanned, Stats, PackageMap, TotalProcessed, Opts)
    catch
        error:R1:_ ->
            {error, R1};
        Class:R2:_ ->
            {error, {Class, R2}}
    end.

-doc false.
configure_cache_dir(Opts) ->
    case maps:get(cache_dir, Opts, undefined) of
        undefined -> ok;
        CacheDir -> application:set_env(spectrometer, cache_dir, CacheDir)
    end.

-doc "Dispatch to distributed or local scan based on mode".
run_scan(Work, Scanned, Stats, PackageMap, TotalProcessed, Opts) ->
    run_distributed_scan(
        Work, Scanned, Stats, PackageMap, TotalProcessed, Opts
    ).

-doc false.
fetch_initial_sources(
    Limit, Stars, GithubEnabled, HexEnabled, GithubStartPage, HexStartPage
) ->
    {GithubRepos, GithubFetched} =
        case GithubEnabled of
            true ->
                GithubRepos0 = spectrometer_http:fetch_github_repos(
                    {Limit, Stars}, GithubStartPage
                ),
                {GithubRepos0, true};
            false ->
                {[], true}
        end,
    {HexPackages, HexFetched} =
        case HexEnabled of
            true ->
                HexPackages0 = spectrometer_http:fetch_hex_packages(
                    remaining_limit(Limit, length(GithubRepos)), HexStartPage
                ),
                {HexPackages0, true};
            false ->
                {[], true}
        end,
    {GithubRepos, HexPackages, GithubFetched, HexFetched}.

-doc false.
resume_start_page(_Scanned, _Source, false) ->
    1;
resume_start_page(Scanned, Source, true) ->
    scanned_source_count(Scanned, Source) div ?ECOSYSTEM_PAGE_SIZE + 1.

scanned_source_count(Scanned, Source) ->
    Prefix = source_scanned_prefix(Source),
    maps:fold(
        fun(Key, _PackageID, Acc) ->
            case binary:match(Key, Prefix) of
                nomatch -> Acc;
                {0, _} -> Acc + 1
            end
        end,
        0,
        Scanned
    ).

-doc false.
source_scanned_prefix(github) ->
    <<"github:">>;
source_scanned_prefix(hex) ->
    <<"hex:">>.

-doc false.
remaining_limit(infinity, _GithubCount) ->
    infinity;
remaining_limit(Limit, GithubCount) ->
    max(0, Limit - GithubCount).

-doc "Distributed scan using remote worker nodes".
-spec run_distributed_scan(
    [work_item()],
    #{binary() => non_neg_integer()},
    #{_ => _},
    #{non_neg_integer() => binary()},
    non_neg_integer(),
    atomvm_spectrometer:opts_map()
) -> ok | {error, term()}.
run_distributed_scan(Work, Scanned, Stats, PackageMap, TotalProcessed, Opts) ->
    Cookie = generate_cookie(),
    %% TODO: Fix this to use find executable and open_port spawn_executable and check for errors.
    _ = os:cmd("epmd -daemon"),
    %% Start as a distributed node so worker BEAM nodes can connect
    NodeName = list_to_atom(
        "spec_controller_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    case net_kernel:start([NodeName, shortnames]) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, NetReason} ->
            ?LOG_WARNING("Warning: Failed to start net_kernel: ~p", [NetReason]),
            ?LOG_WARNING("Worker nodes may not be able to connect.")
    end,
    %% Set cookie AFTER net_kernel:start so we have a real node name
    erlang:set_cookie(node(), Cookie),

    case spectrometer_ecosystem_sup:start_link() of
        {ok, _SupPid} ->
            ok;
        {error, {already_started, _SupPid}} ->
            ok
    end,

    %% Coordinator is already started by the supervisor, just use it
    CoordinatorPid = whereis(spectrometer_ecosystem_coordinator),
    spectrometer_ecosystem_coordinator:start_work(
        Work, Scanned, Stats, PackageMap, TotalProcessed, Opts, self()
    ),

    NumWorkers = maps:get(workers, Opts, 4),
    lists:foreach(
        fun(_) ->
            spectrometer_ecosystem_worker_sup:start_worker(
                #{cookie => Cookie}
            )
        end,
        lists:seq(1, NumWorkers)
    ),

    CoordinatorPid = whereis(spectrometer_ecosystem_coordinator),
    Ref = erlang:monitor(process, CoordinatorPid),
    receive
        {coordinator_done, _FinalStats} ->
            erlang:demonitor(Ref, [flush]),
            ok;
        {error, Reason} ->
            erlang:demonitor(Ref, [flush]),
            error(Reason);
        {'DOWN', Ref, process, CoordinatorPid, Reason} ->
            error({coordinator_died, Reason})
    after 3600000 ->
        erlang:demonitor(Ref, [flush]),
        error(coordinator_timeout)
    end.

-doc "Remove duplicate work items between GitHub and Hex sources".
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

-doc "Filter out already-scanned work items".
-spec filter_scanned([work_item()], #{binary() => non_neg_integer()}) ->
    [work_item()].
filter_scanned(WorkItems, Scanned) ->
    lists:filter(
        fun({Type, Item}) ->
            Key = work_key(Type, Item),
            not maps:is_key(Key, Scanned)
        end,
        WorkItems
    ).

-doc false.
-spec fetch_more(
    [map()],
    [map()],
    #{binary() => non_neg_integer()},
    integer() | infinity,
    integer() | infinity,
    boolean(),
    boolean(),
    boolean(),
    boolean()
) ->
    {[map()], [map()]}.
fetch_more(
    Repos,
    Packages,
    _Scanned,
    _Limit,
    _Stars,
    _GithubEnabled,
    _HexEnabled,
    _GithubFetched,
    _HexFetched
) ->
    {Repos, Packages}.

-doc "Generate a unique string key for a work item".
-spec work_key(github | hex, map()) -> binary().
work_key(github, #{full_name := Name}) ->
    list_to_binary("github:" ++ Name);
work_key(hex, #{name := Name}) ->
    list_to_binary("hex:" ++ Name).

-doc """
Returns the canonical package name for a work item.

For GitHub items, this is `basename(full_name)` (e.g. `<<">>` from
`<<">>`). For Hex items, this is the package name as-is.
The canonical name is used as the key in `PackageNames` / `PackageMap`.
""".
-spec canonical_package_name(github | hex, map()) -> binary().
canonical_package_name(github, #{full_name := FullName}) ->
    list_to_binary(filename:basename(FullName));
canonical_package_name(hex, #{name := Name}) ->
    spectrometer_utils:ensure_binary(Name).

-doc """
Returns the canonical package key for a work item.

This is the value used as key in `PackageNames` / `PackageMap`.
Delegates to `canonical_package_name/2`.
""".
-spec package_key(github | hex, map()) -> binary().
package_key(Type, Item) ->
    canonical_package_name(Type, Item).

-doc "Generate a random cookie for this ecosystem run".
-spec generate_cookie() -> atom().
generate_cookie() ->
    Cookie = list_to_atom(
        "spec_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    application:set_env(spectrometer, ecosystem_cookie, Cookie),
    Cookie.

-type eco_stats_value() :: #{
    calls => non_neg_integer(),
    repo_count => non_neg_integer(),
    callers => ordsets:ordset(non_neg_integer())
}.
-type mod_name() :: binary().
-type fun_name() :: binary().
-type eco_stats() :: #{{mod_name(), fun_name(), arity()} => eco_stats_value()}.
-type eco_scanned() :: #{binary() => non_neg_integer()}.
-type eco_package_map() :: #{non_neg_integer() => binary()}.

%% @doc Load ecosystem state from disk (v3 format).
%% Returns {ScannedMap, Stats, PackageMap, TotalProcessed}.
%% On invalid or old format, starts fresh.
-spec load_state() ->
    {eco_scanned(), eco_stats(), eco_package_map(), non_neg_integer()}.
load_state() ->
    CacheDir = spectrometer_utils:user_cache_path(),
    StateFile = filename:join(CacheDir, ?ECOSYSTEM_STATE),
    case file:read_file(StateFile) of
        {ok, Bin} ->
            try
                case binary_to_term(Bin) of
                    {spectrometer_v1, Scanned, Stats, PackageMap,
                        TotalProcessed} when
                        is_map(Scanned),
                        is_map(Stats),
                        is_map(PackageMap)
                    ->
                        case package_map_valid(PackageMap) of
                            true ->
                                ?LOG_INFO(
                                    "Resumed state: ~p items already scanned",
                                    [TotalProcessed]
                                ),
                                {Scanned, Stats, PackageMap, TotalProcessed};
                            false ->
                                ?LOG_WARNING(
                                    "Warning: Incompatible state file (old format), "
                                    "renaming and starting fresh"
                                ),
                                _ = backup_state_file(),
                                {#{}, #{}, #{}, 0}
                        end;
                    _ ->
                        ?LOG_WARNING(
                            "Warning: Invalid state file, renaming and starting fresh"
                        ),
                        {#{}, #{}, #{}, 0}
                end
            catch
                _:_ ->
                    ?LOG_WARNING(
                        "Warning: Could not decode state file, starting fresh"
                    ),
                    {#{}, #{}, #{}, 0}
            end;
        {error, enoent} ->
            ?LOG_INFO("No state file found, starting fresh"),
            {#{}, #{}, #{}, 0};
        {error, Reason} ->
            ?LOG_WARNING(
                "Warning: Could not read state file (~p), starting fresh",
                [Reason]
            ),
            {#{}, #{}, #{}, 0}
    end.

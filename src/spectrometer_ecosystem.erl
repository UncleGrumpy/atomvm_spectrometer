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

-define(ECOSYSTEM_PAGE_SIZE, 100).

-export([
    load_state/0,
    run/1
]).
-type work_item() :: {github | hex, map()}.

-doc """
Run the ecosystem scan using distributed worker nodes.
""".
-spec run(atomvm_spectrometer:opts_map()) -> ok | {error, term()}.
run(Opts) ->
    try
        configure_cache_dir(Opts),
        {Scanned, Stats, PackageMap, TotalProcessed, PagesConsumed} =
            case maps:get(resume, Opts) of
                true -> load_state();
                false -> {#{}, #{}, #{}, 0, #{}}
            end,

        GithubEnabled = maps:get(github, Opts),
        HexEnabled = maps:get(hex, Opts),
        Resume = maps:get(resume, Opts),
        Limit = maps:get(limit, Opts),
        Stars = maps:get(stars, Opts, infinity),
        Slow = maps:get(slow, Opts, false),

        scan_loop(
            Limit,
            Stars,
            GithubEnabled,
            HexEnabled,
            Resume,
            Slow,
            Scanned,
            Stats,
            PackageMap,
            TotalProcessed,
            PagesConsumed,
            Opts
        )
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

-spec work_key(github | hex, map()) -> binary().
work_key(github, #{full_name := Name}) ->
    list_to_binary("github:" ++ Name);
work_key(hex, #{name := Name}) ->
    list_to_binary("hex:" ++ Name).

-doc """
Filter out already-scanned items from a list of raw maps.
""".
-spec filter_items_scanned(
    [map()], #{binary() => non_neg_integer()}, github | hex
) ->
    [map()].
filter_items_scanned(Items, Scanned, Type) ->
    lists:filter(
        fun(Item) ->
            Key = work_key(Type, Item),
            not maps:is_key(Key, Scanned)
        end,
        Items
    ).

-doc false.
resume_start_page(_PagesConsumed, _Source, false, _Slow) ->
    1;
resume_start_page(PagesConsumed, Source, true, Slow) ->
    case Slow of
        true -> 1;
        false -> maps:get(Source, PagesConsumed, 1)
    end.

-doc """
Dispatch to distributed scan.
""".
-spec run_scan(
    Work, Scanned, Stats, PackageMap, TotalProcessed, Opts, PagesConsumed
) ->
    ok | {error, term()}
when
    Work :: [work_item()],
    Scanned :: #{binary() => non_neg_integer()},
    Stats :: #{_ => _},
    PackageMap :: #{non_neg_integer() => binary()},
    TotalProcessed :: non_neg_integer(),
    Opts :: atomvm_spectrometer:opts_map(),
    PagesConsumed :: #{github => pos_integer(), hex => pos_integer()}.
run_scan(Work, Scanned, Stats, PackageMap, TotalProcessed, Opts, PagesConsumed) ->
    run_distributed_scan(
        Work, Scanned, Stats, PackageMap, TotalProcessed, Opts, PagesConsumed
    ).

-doc """
Distributed scan using remote worker nodes.
""".
-spec run_distributed_scan(
    [work_item()],
    #{binary() => non_neg_integer()},
    #{_ => _},
    #{non_neg_integer() => binary()},
    non_neg_integer(),
    atomvm_spectrometer:opts_map(),
    #{github => pos_integer(), hex => pos_integer()}
) -> ok | {error, term()}.
run_distributed_scan(
    Work, Scanned, Stats, PackageMap, TotalProcessed, Opts, PagesConsumed
) ->
    Cookie = generate_cookie(),
    %% TODO: `os:cmd` in UNSAFE! Fix this to use find executable and open_port spawn_executable and check for errors.
    _ = os:cmd("epmd -daemon"),
    %% Start as a distributed node so worker BEAM nodes can connect
    case net_kernel:start([spec_controller, shortnames]) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, NetReason} ->
            ?LOG_ERROR(
                "Failed to start net_kernel: ~p. Worker nodes may not be able to connect.",
                [NetReason]
            )
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
        Work,
        Scanned,
        Stats,
        PackageMap,
        TotalProcessed,
        PagesConsumed,
        Opts,
        self()
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
            {error, Reason};
        {'DOWN', Ref, process, CoordinatorPid, Reason} ->
            {error, {coordinator_died, Reason}}
    after 3600000 ->
        erlang:demonitor(Ref, [flush]),
        {error, coordinator_timeout}
    end.

-doc """
Remove duplicate work items between GitHub and Hex sources.
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
Main scan loop. For infinity limit, does a single pass.
For finite limit, runs rounds until `Limit` new items are added.

""".
-spec scan_loop(
    Limit :: pos_integer() | infinity,
    Stars :: pos_integer() | infinity,
    GithubEnabled :: boolean(),
    HexEnabled :: boolean(),
    Resume :: boolean(),
    Slow :: boolean(),
    Scanned :: #{binary() => non_neg_integer()},
    Stats :: #{_ => _},
    PackageMap :: #{non_neg_integer() => binary()},
    TotalProcessed :: non_neg_integer(),
    PagesConsumed :: #{github => pos_integer(), hex => pos_integer()},
    Opts :: atomvm_spectrometer:opts_map()
) -> ok | {error, term()}.
scan_loop(
    infinity,
    Stars,
    _GithubEnabled,
    _HexEnabled,
    Resume,
    Slow,
    Scanned,
    Stats,
    PackageMap,
    TotalProcessed,
    PagesConsumed,
    Opts
) ->
    % Infinity mode: single pass, same as current behavior
    GithubStartPage = resume_start_page(PagesConsumed, github, Resume, Slow),
    HexStartPage = resume_start_page(PagesConsumed, hex, Resume, Slow),
    {Repos, NextGithubPage} = fetch_github_new(
        infinity, Stars, GithubStartPage, Scanned
    ),
    {Packages, NextHexPage} = fetch_hex_new(
        infinity, HexStartPage, Scanned
    ),
    {Repos1, Packages1} = deduplicate(Repos, Packages),
    Work0 = [{github, R} || R <- Repos1] ++ [{hex, P} || P <- Packages1],
    ?LOG_INFO(
        "Work items: ~p GitHub repos, ~p Hex packages",
        [length(Repos1), length(Packages1)]
    ),
    ?LOG_NOTICE("Items to scan: ~p", [length(Work0)]),
    UpdatedPagesConsumed = PagesConsumed#{
        github => NextGithubPage - 1,
        hex => NextHexPage - 1
    },
    run_scan(
        Work0,
        Scanned,
        Stats,
        PackageMap,
        TotalProcessed,
        Opts,
        UpdatedPagesConsumed
    );
scan_loop(
    Limit,
    Stars,
    GithubEnabled,
    HexEnabled,
    Resume,
    Slow,
    _Scanned,
    _Stats,
    _PackageMap,
    _TotalProcessed,
    PagesConsumed,
    Opts
) ->
    GithubStartPage = resume_start_page(PagesConsumed, github, Resume, Slow),
    HexStartPage = resume_start_page(PagesConsumed, hex, Resume, Slow),
    scan_loop_round(
        Limit,
        Stars,
        GithubEnabled,
        HexEnabled,
        Opts,
        GithubStartPage,
        HexStartPage,
        0,
        PagesConsumed
    ).
-doc """
Performs a scan for the given parameters.

Returns `ok` if the limit was reached, or `{error, Reason}`
One round of the scan loop reloads state from disk, fetches candidates,
runs the scan, then checks if more rounds are needed.

""".
-spec scan_loop_round(
    Limit :: pos_integer(),
    Stars :: pos_integer() | infinity,
    GithubEnabled :: boolean(),
    HexEnabled :: boolean(),
    Opts :: atomvm_spectrometer:opts_map(),
    GithubPage :: pos_integer(),
    HexPage :: pos_integer(),
    TotalAdded :: non_neg_integer(),
    PagesConsumed :: #{github => pos_integer(), hex => pos_integer()}
) -> ok | {error, term()}.
%% @private Deduplicate GitHub repos by canonical package name.
-spec deduplicate_forks([map()]) -> [map()].
deduplicate_forks(Repos) ->
    deduplicate_forks(Repos, #{}, []).

deduplicate_forks([], _Seen, Acc) ->
    lists:reverse(Acc);
deduplicate_forks([Repo | Rest], Seen, Acc) ->
    FullName = maps:get(full_name, Repo, <<>>),
    Canonical = spectrometer_utils:ensure_binary(filename:basename(FullName)),
    case maps:is_key(Canonical, Seen) of
        true ->
            deduplicate_forks(Rest, Seen, Acc);
        false ->
            deduplicate_forks(Rest, maps:put(Canonical, true, Seen), [
                Repo | Acc
            ])
    end.

scan_loop_round(
    Limit,
    _Stars,
    _GithubEnabled,
    _HexEnabled,
    _Opts,
    _GithubPage,
    _HexPage,
    TotalAdded,
    _PagesConsumed
) when
    TotalAdded >= Limit
->
    ok;
scan_loop_round(
    Limit,
    Stars,
    GithubEnabled,
    HexEnabled,
    Opts,
    GithubPage,
    HexPage,
    TotalAdded,
    _PagesConsumed
) ->
    Remaining = Limit - TotalAdded,

    % Reload state from disk. The coordinator saves state on completion
    % (in complete/1 and terminate/2), so after the previous round's
    % run_scan returned, the state file reflects all items scanned so far.
    % This gives us an up-to-date Scanned map so that fetch_github_new
    % and fetch_hex_new correctly skip items from previous rounds.
    {Scanned, Stats, PackageMap, TotalProcessed, PagesConsumed1} = load_state(),

    % Step 1: Fetch new GitHub repos
    {Repos1, NextGithubPage} =
        case GithubEnabled of
            true ->
                fetch_github_new(Remaining, Stars, GithubPage, Scanned);
            false ->
                {[], GithubPage}
        end,

    % Step 2: Fetch new Hex packages (remaining budget after GitHub)
    GithubNewCount = length(Repos1),
    HexRemaining = max(0, Remaining - GithubNewCount),
    {Packages1, NextHexPage} =
        case HexEnabled of
            true ->
                fetch_hex_new(HexRemaining, HexPage, Scanned);
            false ->
                {[], HexPage}
        end,

    % Step 3: Deduplicate between the two sources
    {Repos2, Packages2} = deduplicate(Repos1, Packages1),

    % Step 4: Compensate for dedup losses (GitHub first, then Hex fallback)
    {Repos3, Packages3, NextGithubPage2, NextHexPage2} = compensate_dedup_losses(
        Repos2,
        Packages2,
        GithubNewCount,
        GithubEnabled,
        HexEnabled,
        Stars,
        NextGithubPage,
        GithubNewCount,
        NextHexPage,
        Scanned
    ),

    % Step 4b: Deduplicate GitHub forks by canonical name
    Repos4 = deduplicate_forks(Repos3),

    % Step 4c: Compensate for fork dedup losses
    RemovedByForkDedup = length(Repos3) - length(Repos4),
    {Repos5, Packages4, NextGithubPage3, NextHexPage3} =
        case RemovedByForkDedup > 0 of
            true ->
                compensate_fork_losses(
                    Repos4,
                    Packages3,
                    RemovedByForkDedup,
                    GithubEnabled,
                    HexEnabled,
                    Stars,
                    NextGithubPage2,
                    NextHexPage2,
                    Scanned
                );
            false ->
                {Repos4, Packages3, NextGithubPage2, NextHexPage2}
        end,
    % Step 5: Build work items
    Work0 = [{github, R} || R <- Repos5] ++ [{hex, P} || P <- Packages4],

    NewCount = length(Work0),
    ?LOG_INFO(
        "Work items: ~p GitHub repos, ~p Hex packages",
        [length(Repos5), length(Packages4)]
    ),
    ?LOG_NOTICE("Items to scan: ~p", [NewCount]),

    UpdatedPagesConsumed = PagesConsumed1#{
        github => NextGithubPage3 - 1,
        hex => NextHexPage3 - 1
    },

    case NewCount of
        0 ->
            % Nothing new to scan — API exhausted
            % But if this is the very first round (no items processed yet),
            % it's likely an error (API failure, no results, etc.)
            case TotalProcessed =:= 0 andalso TotalAdded =:= 0 of
                true ->
                    ?LOG_WARNING(
                        "First scan round returned 0 items - possible API failure or no results"
                    ),
                    {error, no_candidates_found};
                false ->
                    ok
            end;
        _ ->
            % Run the scan. resume=true so the coordinator loads existing
            % state via start_work (which receives the reloaded Scanned map).
            ScanOpts = Opts#{resume => true},
            case
                run_scan(
                    Work0,
                    Scanned,
                    Stats,
                    PackageMap,
                    TotalProcessed,
                    ScanOpts,
                    UpdatedPagesConsumed
                )
            of
                ok ->
                    % Step 6: Verify limit was met
                    NewTotalAdded = TotalAdded + NewCount,
                    case NewTotalAdded >= Limit of
                        true ->
                            ok;
                        false ->
                            ?LOG_INFO(
                                "Added ~p of ~p requested, "
                                "fetching more...",
                                [NewTotalAdded, Limit]
                            ),
                            scan_loop_round(
                                Limit,
                                Stars,
                                GithubEnabled,
                                HexEnabled,
                                Opts,
                                NextGithubPage2,
                                NextHexPage2,
                                NewTotalAdded,
                                UpdatedPagesConsumed
                            )
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-doc """
Fetch up to `Limit` new (not-yet-scanned) GitHub repos starting from
`StartPage`. Continues to subsequent pages as needed.
Returns the list of new repos and the next page number.
""".
-spec fetch_github_new(
    Limit :: pos_integer() | infinity,
    Stars :: pos_integer() | infinity,
    StartPage :: pos_integer(),
    Scanned :: #{binary() => non_neg_integer()}
) -> {[map()], pos_integer()}.
fetch_github_new(infinity, Stars, StartPage, Scanned) ->
    Repos = spectrometer_http:fetch_github_repos({infinity, Stars}, StartPage),
    NewRepos = filter_items_scanned(Repos, Scanned, github),
    {NewRepos, StartPage + 1};
fetch_github_new(Limit, Stars, StartPage, Scanned) ->
    ?LOG_INFO("Gathering scan candidates from GitHub"),
    fetch_github_new(Limit, Stars, StartPage, Scanned, []).

fetch_github_new(0, _Stars, Page, _Scanned, Acc) ->
    {lists:reverse(Acc), Page};
fetch_github_new(Limit, Stars, Page, Scanned, Acc) ->
    Repos = spectrometer_http:fetch_github_repos({Limit, Stars}, Page),
    NewRepos = filter_items_scanned(Repos, Scanned, github),
    Acc1 = Acc ++ NewRepos,
    case length(Acc1) >= Limit of
        true ->
            {lists:sublist(lists:reverse(Acc1), Limit), Page + 1};
        false ->
            case length(Repos) < ?ECOSYSTEM_PAGE_SIZE of
                true ->
                    % Last page from API
                    {lists:reverse(Acc1), Page + 1};
                false ->
                    fetch_github_new(
                        Limit - length(NewRepos),
                        Stars,
                        Page + 1,
                        Scanned,
                        Acc1
                    )
            end
    end.

-doc """
Fetch up to `Limit` new (not-yet-scanned) Hex packages starting from
`StartPage`. Continues to subsequent pages as needed.
Returns the list of new packages and the next page number.
""".
-spec fetch_hex_new(
    Limit :: pos_integer() | infinity,
    StartPage :: pos_integer(),
    Scanned :: #{binary() => non_neg_integer()}
) -> {[map()], pos_integer()}.
fetch_hex_new(infinity, StartPage, Scanned) ->
    Packages = spectrometer_http:fetch_hex_packages(infinity, StartPage),
    NewPackages = filter_items_scanned(Packages, Scanned, hex),
    {NewPackages, StartPage + 1};
fetch_hex_new(Limit, StartPage, Scanned) ->
    ?LOG_INFO("Gathering scan candidates from hex.pm"),
    fetch_hex_new(Limit, StartPage, Scanned, []).

fetch_hex_new(0, Page, _Scanned, Acc) ->
    {lists:reverse(Acc), Page};
fetch_hex_new(Limit, Page, Scanned, Acc) ->
    Packages = spectrometer_http:fetch_hex_packages(Limit, Page),
    NewPackages = filter_items_scanned(Packages, Scanned, hex),
    Acc1 = Acc ++ NewPackages,
    case length(Acc1) >= Limit of
        true ->
            {lists:sublist(lists:reverse(Acc1), Limit), Page + 1};
        false ->
            case length(Packages) < ?HEX_PER_PAGE of
                true ->
                    {lists:reverse(Acc1), Page + 1};
                false ->
                    fetch_hex_new(
                        Limit - length(NewPackages),
                        Page + 1,
                        Scanned,
                        Acc1
                    )
            end
    end.

-doc "\n"
"Given deduplicated Repos and Packages, fetch more items to compensate for any\n"
"that were removed by deduplicate/2. Tries GitHub first (if enabled and under\n"
"the API cap), then falls back to Hex (if enabled). OriginalCount is the\n"
"running total of GitHub repos fetched so far; Repos must grow to match it.\n"
"Repeats until matched or all sources are exhausted.\n".
-spec compensate_dedup_losses(
    Repos :: [map()],
    Packages :: [map()],
    OriginalCount :: non_neg_integer(),
    GithubEnabled :: boolean(),
    HexEnabled :: boolean(),
    Stars :: pos_integer() | infinity,
    GithubNextPage :: pos_integer(),
    GithubFetched :: non_neg_integer(),
    HexNextPage :: pos_integer(),
    Scanned :: #{binary() => non_neg_integer()}
) -> {[map()], [map()], pos_integer(), pos_integer()}.
compensate_dedup_losses(
    Repos,
    Packages,
    OriginalCount,
    GithubEnabled,
    HexEnabled,
    Stars,
    GithubNextPage,
    GithubFetched,
    HexNextPage,
    Scanned
) ->
    Lost = OriginalCount - length(Repos),
    case Lost =< 0 of
        true ->
            {Repos, Packages, GithubNextPage, HexNextPage};
        false ->
            case GithubEnabled andalso GithubFetched < ?GITHUB_MAX_PER_QUERY of
                true ->
                    % Try GitHub first
                    {MoreRepos, GithubNextPage1} = fetch_github_new(
                        Lost, Stars, GithubNextPage, Scanned
                    ),
                    case MoreRepos of
                        [] ->
                            % GitHub exhausted, try Hex if enabled
                            compensate_via_hex(
                                Repos,
                                Packages,
                                OriginalCount,
                                HexEnabled,
                                GithubNextPage1,
                                GithubFetched,
                                HexNextPage,
                                Scanned,
                                Stars
                            );
                        _ ->
                            NewGithubFetched =
                                GithubFetched + length(MoreRepos),
                            {AllRepos, Packages1} = deduplicate(
                                Repos ++ MoreRepos, Packages
                            ),
                            compensate_dedup_losses(
                                AllRepos,
                                Packages1,
                                OriginalCount + length(MoreRepos),
                                GithubEnabled,
                                HexEnabled,
                                Stars,
                                GithubNextPage1,
                                NewGithubFetched,
                                HexNextPage,
                                Scanned
                            )
                    end;
                false ->
                    % GitHub disabled or capped, try Hex if enabled
                    compensate_via_hex(
                        Repos,
                        Packages,
                        OriginalCount,
                        HexEnabled,
                        GithubNextPage,
                        GithubFetched,
                        HexNextPage,
                        Scanned,
                        Stars
                    )
            end
    end.

-doc """
Fetch additional Hex packages to compensate for dedup losses.
""".
-spec compensate_via_hex(
    [map()],
    [map()],
    non_neg_integer(),
    boolean(),
    pos_integer(),
    non_neg_integer(),
    pos_integer(),
    #{binary() => non_neg_integer()},
    pos_integer() | infinity
) -> {[map()], [map()], pos_integer(), pos_integer()}.
compensate_via_hex(
    Repos,
    Packages,
    _OriginalCount,
    false,
    GithubNextPage,
    _GithubFetched,
    HexNextPage,
    _Scanned,
    _Stars
) ->
    % Hex disabled, nothing to compensate with
    {Repos, Packages, GithubNextPage, HexNextPage};
compensate_via_hex(
    Repos,
    Packages,
    OriginalCount,
    true,
    GithubNextPage,
    GithubFetched,
    HexNextPage,
    Scanned,
    Stars
) ->
    Lost = OriginalCount - length(Repos),
    case Lost =< 0 of
        true ->
            {Repos, Packages, GithubNextPage, HexNextPage};
        false ->
            {MorePackages, HexNextPage1} = fetch_hex_new(
                Lost, HexNextPage, Scanned
            ),
            case MorePackages of
                [] ->
                    % Hex exhausted too
                    {Repos, Packages, GithubNextPage, HexNextPage1};
                _ ->
                    {AllRepos, AllPackages} = deduplicate(
                        Repos, Packages ++ MorePackages
                    ),
                    compensate_dedup_losses(
                        AllRepos,
                        AllPackages,
                        OriginalCount,
                        % Both sources now exhausted for next round
                        false,
                        false,
                        Stars,
                        GithubNextPage,
                        GithubFetched,
                        HexNextPage1,
                        Scanned
                    )
            end
    end.

-doc "\n"
"Given deduplicated Repos and Packages, fetch more items to compensate for\n"
"fork duplicates removed by deduplicate_forks/1. Tries GitHub first (if enabled),\n"
"then falls back to Hex (if enabled).\n".
-spec compensate_fork_losses(
    [map()],
    [map()],
    pos_integer(),
    boolean(),
    boolean(),
    pos_integer() | infinity,
    pos_integer(),
    pos_integer(),
    #{binary() => non_neg_integer()}
) -> {[map()], [map()], pos_integer(), pos_integer()}.
compensate_fork_losses(
    Repos,
    Packages,
    Lost,
    GithubEnabled,
    HexEnabled,
    Stars,
    GithubPage,
    HexPage,
    Scanned
) ->
    case GithubEnabled of
        true ->
            {MoreRepos, GithubPage1} = fetch_github_new(
                Lost, Stars, GithubPage, Scanned
            ),
            case MoreRepos of
                [] ->
                    compensate_via_hex(
                        Repos,
                        Packages,
                        Lost,
                        HexEnabled,
                        GithubPage1,
                        0,
                        HexPage,
                        Scanned,
                        Stars
                    );
                _ ->
                    {AllRepos, Packages1} = deduplicate(
                        Repos ++ MoreRepos, Packages
                    ),
                    StillNeeded = Lost - (length(AllRepos) - length(Repos)),
                    case StillNeeded > 0 of
                        true ->
                            compensate_fork_losses(
                                AllRepos,
                                Packages1,
                                StillNeeded,
                                GithubEnabled,
                                HexEnabled,
                                Stars,
                                GithubPage1,
                                HexPage,
                                Scanned
                            );
                        false ->
                            {AllRepos, Packages1, GithubPage1, HexPage}
                    end
            end;
        false ->
            compensate_via_hex(
                Repos,
                Packages,
                Lost,
                HexEnabled,
                GithubPage,
                0,
                HexPage,
                Scanned,
                Stars
            )
    end.

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

-doc """
Check if a package map uses the new canonical format.

Returns `true` if no package name contains `/` (old-style `<<">>`).
Returns `false` if any entry uses the old format, indicating the state file
must be backed up and the scan started fresh.
""".
-spec package_map_valid(eco_package_map()) -> boolean().
package_map_valid(PackageMap) ->
    not lists:any(
        fun({_, Name}) -> binary:match(Name, <<"/">>) =/= nomatch end,
        maps:to_list(PackageMap)
    ).

-doc """
Rename the current state file with a date suffix.

Renames `beam_ecosystem.bin` to `beam_ecosystem.YYYY-MM-DD.bin` in the
user cache directory. Used when an incompatible state file is detected.
""".
-spec backup_state_file() -> ok | {error, term()}.
backup_state_file() ->
    CacheDir = spectrometer_utils:user_cache_path(),
    StateFile = filename:join(CacheDir, ?ECOSYSTEM_STATE),
    {{Y, M, D}, _} = calendar:local_time(),
    DateSuffix = io_lib:format(".~4..0B-~2..0B-~2..0B.bin", [Y, M, D]),
    Renamed = StateFile ++ DateSuffix,
    file:rename(StateFile, Renamed).

-doc """
Load ecosystem state from disk.

Returns `{ScannedMap, Stats, PackageMap, TotalProcessed, PagesConsumed}`.
If the file is missing or unreadable, starts fresh with empty state.

If the file decodes but contains an incompatible package map format
(old-style names containing `/`), the file is renamed with a date suffix
(e.g. `beam_ecosystem.2026-06-17.bin`) and the scan starts fresh.
""".
-spec load_state() ->
    {eco_scanned(), eco_stats(), eco_package_map(), non_neg_integer(), #{
        github => pos_integer(), hex => pos_integer()
    }}.
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
                                {Scanned, Stats, PackageMap, TotalProcessed,
                                    #{}};
                            false ->
                                ?LOG_WARNING(
                                    "Incompatible state file (old format), "
                                    "renaming and starting fresh"
                                ),
                                _ = backup_state_file(),
                                {#{}, #{}, #{}, 0, #{}}
                        end;
                    {spectrometer_v0_r2, Scanned, Stats, PackageMap,
                        TotalProcessed,
                        PagesConsumed} when
                        is_map(Scanned),
                        is_map(Stats),
                        is_map(PackageMap),
                        is_map(PagesConsumed)
                    ->
                        ?LOG_INFO(
                            "Resumed state: ~p items already scanned",
                            [TotalProcessed]
                        ),
                        {Scanned, Stats, PackageMap, TotalProcessed,
                            PagesConsumed};
                    _ ->
                        ?LOG_ERROR(
                            "Invalid state file, renaming and starting fresh"
                        ),
                        _ = backup_state_file(),
                        {#{}, #{}, #{}, 0, #{}}
                end
            catch
                _:_ ->
                    _ = backup_state_file(),
                    ?LOG_ERROR(
                        "Could not decode state file, renaming and starting fresh"
                    ),
                    {#{}, #{}, #{}, 0, #{}}
            end;
        {error, enoent} ->
            ?LOG_INFO("No state file found, starting fresh"),
            {#{}, #{}, #{}, 0, #{}};
        {error, Reason} ->
            _ = backup_state_file(),
            ?LOG_ERROR(
                "Could not read state file (~p), renaming and starting fresh",
                [Reason]
            ),
            {#{}, #{}, #{}, 0, #{}}
    end.

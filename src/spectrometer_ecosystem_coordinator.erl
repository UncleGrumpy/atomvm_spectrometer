%%
%% Copyright 2026 Paul Guyot <pguyot@kallisys.net>
%% GitHub Gist @pguyot/beam_stats.escript
%% https://gist.github.com/pguyot/da327972f1ecdb7041c97addd4e76bb5
%%
%% gen_server and worker node implementation for atomvm_spectrometer:
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Paul Guyot <pguyot@kallisys.net>
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_ecosystem_coordinator).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-ignore_xref(start_link/0).

-export([
    start_link/0,
    start_work/8,
    worker_down/1
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include("ecosystem.hrl").

-define(SAVE_INTERVAL, 10).

-record(coord_state, {
    work :: [{github | hex, map()}],
    scanned :: #{binary() => non_neg_integer()},
    stats :: #{
        {binary(), binary(), arity()} => #{
            calls => non_neg_integer(),
            repo_count => non_neg_integer(),
            callers => ordsets:ordset(non_neg_integer())
        }
    },
    package_map :: #{non_neg_integer() => binary()},
    package_names :: #{binary() => non_neg_integer()},
    next_package_id :: non_neg_integer(),
    total_processed :: non_neg_integer(),
    total_work :: non_neg_integer(),
    unique_work :: non_neg_integer(),
    since_save :: non_neg_integer(),
    pending_work :: #{reference() => {node(), binary(), {github | hex, map()}}},
    ready_workers :: sets:set(node()),
    parent :: pid(),
    pages_consumed :: #{github => pos_integer(), hex => pos_integer()}
}).

%% @doc Start the coordinator gen_server.
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Initialize work in the coordinator. Called once after start_link.
""".
-spec start_work(
    [{github | hex, map()}],
    #{binary() => non_neg_integer()},
    #{
        {binary(), binary(), arity()} => #{
            calls => non_neg_integer(),
            repo_count => non_neg_integer(),
            callers => ordsets:ordset(non_neg_integer())
        }
    },
    #{non_neg_integer() => binary()},
    non_neg_integer(),
    #{github => pos_integer(), hex => pos_integer()},
    atomvm_spectrometer:opts_map(),
    pid()
) -> ok.
start_work(
    Work,
    Scanned,
    Stats,
    PackageMap,
    TotalProcessed,
    PagesConsumed,
    _Opts,
    Parent
) ->
    gen_server:cast(
        ?MODULE,
        {start_work, Work, Scanned, Stats, PackageMap, TotalProcessed,
            PagesConsumed, Parent}
    ).

%% @doc Notify the coordinator that a worker node went down.
-spec worker_down(node()) -> ok.
worker_down(Node) ->
    gen_server:cast(?MODULE, {worker_down, Node}).

%% gen_server callbacks

init([]) ->
    {ok, #coord_state{
        work = [],
        scanned = #{},
        stats = #{},
        package_map = #{},
        package_names = #{},
        next_package_id = 1,
        total_processed = 0,
        total_work = 0,
        unique_work = 0,
        since_save = 0,
        pending_work = #{},
        ready_workers = sets:new([{version, 2}]),
        parent = self(),
        pages_consumed = #{}
    }}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(
    {start_work, Work, Scanned, Stats, PackageMap, TotalProcessed,
        PagesConsumed, Parent},
    State
) ->
    TotalWork = length(Work) + TotalProcessed,
    UniqueWork = length(Work) + State#coord_state.unique_work,
    PackageNames = maps:from_list(
        [{Name, ID} || {ID, Name} <- maps:to_list(PackageMap)]
    ),
    NewState = State#coord_state{
        work = Work,
        scanned = Scanned,
        stats = Stats,
        package_map = PackageMap,
        package_names = PackageNames,
        next_package_id = maps:size(PackageMap) + 1,
        total_processed = TotalProcessed,
        total_work = TotalWork,
        unique_work = UniqueWork,
        since_save = 0,
        pending_work = #{},
        parent = Parent,
        pages_consumed = PagesConsumed
    },
    %% Dispatch work to any workers that have already signaled ready
    {Action, NewState1} = dispatch_ready(NewState),
    case Action of
        continue -> {noreply, NewState1};
        stop -> {stop, normal, NewState1}
    end;
handle_cast(
    {worker_ready, WorkerNode},
    State = #coord_state{ready_workers = Ready}
) ->
    ?LOG_INFO("Worker ~p ready, adding to pool", [WorkerNode]),
    NewReady = sets:add_element(WorkerNode, Ready),
    NewState = State#coord_state{ready_workers = NewReady},
    %% If we have work, dispatch immediately
    {Action, NewState1} = dispatch_ready(NewState),
    case Action of
        continue -> {noreply, NewState1};
        stop -> {stop, normal, NewState1}
    end;
handle_cast(
    {worker_down, Node},
    State = #coord_state{
        pending_work = Pending, work = Work
    }
) ->
    %% Find all work items assigned to this node and re-queue them
    {RequeuedItems, NewPending} = maps:fold(
        fun(Ref, {WorkerNode, PackageKey, Item}, {AccItems, AccPending}) ->
            case WorkerNode =:= Node of
                true ->
                    ?LOG_WARNING("Worker ~p crashed, re-queuing ~p", [
                        Node, PackageKey
                    ]),
                    {[Item | AccItems], AccPending};
                false ->
                    {AccItems,
                        maps:put(
                            Ref, {WorkerNode, PackageKey, Item}, AccPending
                        )}
            end
        end,
        {[], #{}},
        Pending
    ),
    {noreply, State#coord_state{
        work = RequeuedItems ++ Work,
        pending_work = NewPending
    }};
handle_cast(
    {worker_result, Ref, WorkerNode, RepoStats},
    State = #coord_state{
        pending_work = Pending,
        work = Work,
        ready_workers = ReadyWorkers
    }
) ->
    %% Find the matching reference for this worker's result
    case maps:find(Ref, Pending) of
        error ->
            ?LOG_WARNING(
                "Spurious result from ~p with ref ~p (no pending work)", [
                    WorkerNode, Ref
                ]
            ),
            {noreply, State};
        {ok, {WorkerNode, WorkKey, Item}} ->
            NewPending = maps:remove(Ref, Pending),
            {Action, NewState} = handle_worker_result(
                WorkerNode,
                Item,
                WorkKey,
                RepoStats,
                Work,
                NewPending,
                ReadyWorkers,
                State
            ),
            case Action of
                continue ->
                    {Action1, NewState1} = dispatch_ready(NewState),
                    case Action1 of
                        continue -> {noreply, NewState1};
                        stop -> {stop, normal, NewState1}
                    end;
                stop ->
                    {stop, normal, NewState}
            end
    end;
handle_cast(
    {worker_threshold_reached, WorkerNode},
    State = #coord_state{ready_workers = ReadyWorkers}
) ->
    ?LOG_INFO("Worker ~p hit atom threshold, spawning replacement", [WorkerNode]),
    %% Remove this worker from ready set
    NewReady = sets:del_element(WorkerNode, ReadyWorkers),
    NewState = State#coord_state{ready_workers = NewReady},
    %% Spawn replacement
    spawn_replacement(),
    {Action, NewState1} = dispatch_ready(NewState),
    case Action of
        continue -> {noreply, NewState1};
        stop -> {stop, normal, NewState1}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodedown, Node}, State) ->
    #coord_state{pending_work = Pending, work = Work} = State,
    %% Find all work items assigned to this node and re-queue them
    {RequeuedItems, NewPending} = maps:fold(
        fun(Ref, {WorkerNode, PackageKey, Item}, {AccItems, AccPending}) ->
            case WorkerNode =:= Node of
                true ->
                    ?LOG_WARNING("Worker ~p nodedown, re-queuing ~p", [
                        Node, PackageKey
                    ]),
                    {[Item | AccItems], AccPending};
                false ->
                    {AccItems,
                        maps:put(
                            Ref, {WorkerNode, PackageKey, Item}, AccPending
                        )}
            end
        end,
        {[], #{}},
        Pending
    ),
    {noreply, State#coord_state{
        work = RequeuedItems ++ Work,
        pending_work = NewPending
    }};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #coord_state{
    stats = Stats,
    scanned = Scanned,
    package_map = PackageMap,
    total_processed = TP,
    pages_consumed = PagesConsumed
}) ->
    case save_state(Scanned, Stats, PackageMap, TP, PagesConsumed) of
        ok -> ok;
        {error, R} -> ?LOG_ERROR("Failed to save state on terminate: ~p", [R])
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions

-doc """
Dispatch work to ready workers, skipping duplicates and already-scanned items.

Each work item is classified before dispatch:
- Already scanned items are skipped.
- Duplicate canonical package names are recorded without worker dispatch.
- New unique items are sent to available workers via gen_server:cast.
""".
-spec dispatch_ready(#coord_state{}) -> {continue | stop, #coord_state{}}.
dispatch_ready(State) ->
    State1 = dispatch_ready_workers(State),
    case
        State1#coord_state.work =:= [] andalso
            State1#coord_state.pending_work =:= #{}
    of
        true ->
            complete(State1);
        false ->
            {continue, State1}
    end.

-spec dispatch_ready_workers(#coord_state{}) -> #coord_state{}.
dispatch_ready_workers(State = #coord_state{work = []}) ->
    State;
dispatch_ready_workers(
    State = #coord_state{ready_workers = Ready, pending_work = Pending}
) ->
    case sets:size(Ready) of
        0 ->
            State;
        _ ->
            %% Only dispatch to workers that don't already have pending work
            dispatch_to_available(State, sets:to_list(Ready), Pending)
    end.

-spec complete(#coord_state{}) -> {stop, #coord_state{}}.
complete(
    State = #coord_state{
        stats = Stats,
        scanned = Scanned,
        package_map = PackageMap,
        total_processed = TP,
        pages_consumed = PagesConsumed,
        parent = Parent
    }
) ->
    io:format("~n"),
    case save_state(Scanned, Stats, PackageMap, TP, PagesConsumed) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Failed to save final state: ~p", [Reason])
    end,
    Parent ! {coordinator_done, Stats},
    {stop, State}.

%% Dispatch work to available workers (those without pending work)
dispatch_to_available(State = #coord_state{work = []}, _ReadyNodes, _Pending) ->
    State;
dispatch_to_available(State, [], _Pending) ->
    State;
dispatch_to_available(
    State = #coord_state{work = [Item | Rest]},
    [WorkerNode | RestNodes],
    Pending
) ->
    %% Check if this worker already has pending work
    case
        lists:any(
            fun({_, {WN, _, _}}) -> WN =:= WorkerNode end, maps:to_list(Pending)
        )
    of
        true ->
            %% Worker already has pending work, skip to next
            dispatch_to_available(State, RestNodes, Pending);
        false ->
            %% Classify the work item
            WorkKey = work_key(Item),
            PackageKey = package_key(Item),
            case maps:is_key(WorkKey, State#coord_state.scanned) of
                true ->
                    %% Already scanned, skip this item
                    dispatch_to_available(
                        State#coord_state{work = Rest}, RestNodes, Pending
                    );
                false ->
                    case
                        find_package_id(
                            PackageKey, State#coord_state.package_names
                        )
                    of
                        {ok, ExistingID} ->
                            %% Duplicate canonical package - record without dispatching
                            {Action, NewState} = record_duplicate_package(
                                WorkKey,
                                ExistingID,
                                Rest,
                                Rest,
                                Pending,
                                State#coord_state.ready_workers,
                                State
                            ),
                            case Action of
                                stop ->
                                    NewState;
                                continue ->
                                    dispatch_to_available(
                                        NewState, RestNodes, Pending
                                    )
                            end;
                        error ->
                            %% New unique item - dispatch to worker
                            Ref = make_ref(),
                            ?LOG_DEBUG(
                                "Dispatching ~p to worker ~p (ref=~p)", [
                                    WorkKey, WorkerNode, Ref
                                ]
                            ),
                            gen_server:cast(
                                {spectrometer_ecosystem_worker_node,
                                    WorkerNode},
                                {work, Ref, Item}
                            ),
                            NewPending = maps:put(
                                Ref, {WorkerNode, WorkKey, Item}, Pending
                            ),
                            NewState = State#coord_state{
                                work = Rest,
                                pending_work = NewPending
                            },
                            %% Continue with remaining workers and remaining work
                            dispatch_to_available(
                                NewState, RestNodes, NewPending
                            )
                    end
            end
    end.

spawn_replacement() ->
    Cookie = get_cookie(),
    case spectrometer_ecosystem_worker_sup:start_worker(#{cookie => Cookie}) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Failed to spawn replacement worker: ~p", [Reason])
    end.

-doc """
Process a worker result, updating scanned map, stats, and package registry.

Uses separate keys for `Scanned` (source-prefixed work key) and `PackageMap`
(canonical package name). If the canonical package name already exists, the
work is recorded under the existing ID without modifying stats.
""".
-spec handle_worker_result(
    node(),
    {github | hex, map()},
    binary(),
    #{{binary(), binary(), arity()} => non_neg_integer()},
    [{github | hex, map()}],
    #{reference() => {node(), binary(), {github | hex, map()}}},
    sets:set(node()),
    #coord_state{}
) -> {continue | stop, #coord_state{}}.
handle_worker_result(
    _WorkerNode,
    Item,
    WorkKey,
    RepoStats,
    Work,
    NewPending,
    _ReadyWorkers,
    State
) ->
    #coord_state{
        package_names = PackageNames,
        package_map = PackageMap,
        next_package_id = NextID,
        scanned = Scanned,
        stats = Stats,
        total_processed = TP,
        since_save = SS,
        unique_work = UW,
        parent = Parent,
        pages_consumed = PagesConsumed
    } = State,
    PackageKey = package_key(Item),
    {PackageID, NewPN, NewPM, NewNextID, NewUW} =
        case maps:find(PackageKey, PackageNames) of
            {ok, ExistingID} ->
                {ExistingID, PackageNames, PackageMap, NextID, UW};
            error ->
                ID = NextID,
                PN2 = maps:put(PackageKey, ID, PackageNames),
                PM2 = maps:put(ID, PackageKey, PackageMap),
                {ID, PN2, PM2, ID + 1, UW + 1}
        end,
    NewScanned = maps:put(WorkKey, PackageID, Scanned),
    NewStats = merge_repo_stats_with_callers(RepoStats, PackageID, Stats),
    NewTP = TP + 1,
    NewSS = SS + 1,
    io:format(
        "\r\tProgress: ~p/~p unique (~.1f%)",
        [NewTP, NewUW, NewTP / max(1, NewUW) * 100]
    ),
    NewState = State#coord_state{
        work = Work,
        scanned = NewScanned,
        stats = NewStats,
        package_map = NewPM,
        package_names = NewPN,
        next_package_id = NewNextID,
        pending_work = NewPending,
        total_processed = NewTP,
        unique_work = NewUW,
        since_save = NewSS,
        pages_consumed = State#coord_state.pages_consumed
    },
    %% Check for completion
    case Work =:= [] andalso NewPending =:= #{} of
        true ->
            io:format("~n"),
            %% Save state before stopping
            case
                save_state(NewScanned, NewStats, NewPM, NewTP, PagesConsumed)
            of
                ok ->
                    ok;
                {error, Reason} ->
                    ?LOG_ERROR("Failed to save final state: ~p", [Reason])
            end,
            Parent ! {coordinator_done, NewStats},
            {stop, NewState};
        false ->
            %% Save state at intervals
            case NewSS >= ?SAVE_INTERVAL of
                true ->
                    PagesConsumed = NewState#coord_state.pages_consumed,
                    case
                        save_state(
                            NewScanned, NewStats, NewPM, NewTP, PagesConsumed
                        )
                    of
                        ok ->
                            {continue, NewState#coord_state{since_save = 0}};
                        {error, Reason} ->
                            ?LOG_WARNING(
                                "Failed to update saved state: ~p", [
                                    Reason
                                ]
                            ),
                            Parent ! {error, {save_state, Reason}},
                            {continue, NewState#coord_state{since_save = 0}}
                    end;
                false ->
                    {continue, NewState#coord_state{since_save = NewSS}}
            end
    end.

-doc """
Look up the package ID for a canonical package name.

Searches `PackageNames` (the inverse of `PackageMap`) for the given
canonical key. Returns `{ok, PackageID}` if found, `error` if the
canonical name has not been registered yet.
""".
-spec find_package_id(binary(), #{binary() => non_neg_integer()}) ->
    {ok, non_neg_integer()} | error.
find_package_id(PackageKey, PackageNames) ->
    maps:find(PackageKey, PackageNames).

-doc """
Record a duplicate work item as scanned without dispatching to a worker.

When a work item's canonical package name already exists in `PackageNames`,
the item is recorded in `Scanned` with the existing `PackageID` and no
download or scan is triggered. Stats are not modified -- the original
package already owns the ID.

Returns `{continue, NewState}` if more work remains, or `{stop, NewState}`
if all work is complete.
""".
-spec record_duplicate_package(
    binary(),
    non_neg_integer(),
    [{github, map()} | {hex, map()}],
    [{github, map()} | {hex, map()}],
    #{reference() => {node(), binary(), {github | hex, map()}}},
    sets:set(node()),
    #coord_state{}
) -> {continue | stop, #coord_state{}}.
record_duplicate_package(
    WorkKey,
    PackageID,
    Work,
    Rest,
    NewPending,
    _ReadyWorkers,
    State
) ->
    #coord_state{
        scanned = Scanned,
        stats = Stats,
        total_processed = TP,
        since_save = SS,
        unique_work = UW,
        parent = Parent
    } = State,
    NewScanned = maps:put(WorkKey, PackageID, Scanned),
    NewTP = TP + 1,
    NewSS = SS + 1,
    ?LOG_DEBUG(
        "Progress: ~p/~p unique (~.1f%) [duplicate]",
        [NewTP, UW, NewTP / max(1, UW) * 100]
    ),
    NewState = State#coord_state{
        work = Rest,
        scanned = NewScanned,
        stats = Stats,
        total_processed = NewTP,
        since_save = NewSS,
        pages_consumed = State#coord_state.pages_consumed
    },
    case Work =:= [] andalso NewPending =:= #{} of
        true ->
            Parent ! {coordinator_done, Stats},
            {stop, NewState};
        false ->
            {continue, NewState}
    end.

-spec work_key({github | hex, map()}) -> binary().
work_key({github, #{full_name := Name}}) ->
    list_to_binary("github:" ++ Name);
work_key({hex, #{name := Name}}) ->
    list_to_binary("hex:" ++ Name).

-spec package_key({github | hex, map()}) -> binary().
package_key({github, #{full_name := FullName}}) ->
    list_to_binary(filename:basename(FullName));
package_key({hex, #{name := Name}}) ->
    spectrometer_utils:ensure_binary(Name).

-spec merge_repo_stats_with_callers(
    #{{binary(), binary(), arity()} => non_neg_integer()},
    non_neg_integer(),
    #{
        {binary(), binary(), arity()} => #{
            calls => non_neg_integer(),
            repo_count => non_neg_integer(),
            callers => ordsets:ordset(non_neg_integer())
        }
    }
) ->
    #{
        {binary(), binary(), arity()} => #{
            calls => non_neg_integer(),
            repo_count => non_neg_integer(),
            callers => ordsets:ordset(non_neg_integer())
        }
    }.
merge_repo_stats_with_callers(RepoStats, PackageID, GlobalStats) ->
    maps:fold(
        fun({Mod, Fun, Arity}, CallCount, Acc) ->
            NewEntry = #{
                calls => CallCount,
                repo_count => 1,
                callers => ordsets:from_list([PackageID])
            },
            maps:update_with(
                {Mod, Fun, Arity},
                fun(Existing) ->
                    #{
                        calls := TC,
                        repo_count := RC,
                        callers := Cs
                    } = Existing,
                    Existing#{
                        calls => TC + CallCount,
                        repo_count => RC + 1,
                        callers => ordsets:add_element(PackageID, Cs)
                    }
                end,
                NewEntry,
                Acc
            )
        end,
        GlobalStats,
        RepoStats
    ).

-spec save_state(
    #{binary() => non_neg_integer()},
    #{
        {binary(), binary(), arity()} => #{
            calls => non_neg_integer(),
            repo_count => non_neg_integer(),
            callers => ordsets:ordset(non_neg_integer())
        }
    },
    #{non_neg_integer() => binary()},
    non_neg_integer(),
    #{github => pos_integer(), hex => pos_integer()}
) -> ok | {error, term()}.
save_state(Scanned, Stats, PackageMap, TotalProcessed, PagesConsumed) ->
    State =
        {spectrometer_v0_r2, Scanned, Stats, PackageMap, TotalProcessed,
            PagesConsumed},
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

-spec get_cookie() -> atom().
get_cookie() ->
    case application:get_env(spectrometer, ecosystem_cookie) of
        {ok, Cookie} when is_atom(Cookie) -> Cookie;
        _ ->
            Cookie = list_to_atom(
                "spec_" ++ integer_to_list(erlang:unique_integer([positive]))
            ),
            application:set_env(spectrometer, ecosystem_cookie, Cookie),
            Cookie
    end.

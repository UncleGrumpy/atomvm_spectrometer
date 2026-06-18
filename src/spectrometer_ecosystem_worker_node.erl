%%
%% Copyright 2026 Paul Guyot <pguyot@kallisys.net>
%% GitHub Gist @pguyot/beam_stats.escript
%% https://gist.github.com/pguyot/da327972f1ecdb7041c97addd4e76bb5
%%
%% worker node implementation for atomvm_spectrometer:
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Paul Guyot <pguyot@kallisys.net>
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_ecosystem_worker_node).

-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-ignore_xref(start/1).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(ATOM_THRESHOLD, 0.85).

-record(state, {
    controller :: node()
}).

-doc """
Entry point for worker nodes.

Called via `-eval` from the controller. Starts a gen_server, registers it, and
notifies the controller.
""".
-spec start(string()) -> no_return().
start(ControllerNodeStr) ->
    ControllerNode = list_to_atom(ControllerNodeStr),
    case net_kernel:monitor_nodes(true) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Failed to establish node monitors: ~p", [Reason]),
            halt(2)
    end,
    %% Start gen_server locally registered so coordinator can call us
    {ok, _Pid} = gen_server:start_link(
        {local, ?MODULE},
        ?MODULE,
        [ControllerNode],
        []
    ),
    %% Block forever — the gen_server handles everything
    receive
        {nodedown, ControllerNode} ->
            ?LOG_WARNING("Controller ~p went down, halting", [ControllerNode]),
            halt(2)
    end.

init([ControllerNode]) ->
    %% PATH should be inherited from parent via open_port env
    _PathEnv = os:getenv("PATH", "/bin:/usr/bin:/usr/local/bin"),
    %% Test if git is findable
    case os:find_executable("git") of
        false -> ok;
        _GitPath -> ok
    end,
    %% Test if common git paths exist
    lists:foreach(
        fun(P) ->
            case filelib:is_file(P) of
                true -> ok;
                false -> ok
            end
        end,
        [
            "/usr/bin/git",
            "/usr/local/bin/git",
            "/opt/homebrew/bin/git",
            "/bin/git"
        ]
    ),
    %% Start required applications for HTTP and SSL
    case application:ensure_all_started(inets) of
        {error, {already_started, _}} ->
            ok;
        {error, InetsErr} ->
            ?LOG_ERROR("Failed to start inets: ~p", [InetsErr]),
            ok;
        _ ->
            ok
    end,
    case application:ensure_all_started(ssl) of
        {error, {already_started, _}} ->
            ok;
        {error, SslErr} ->
            ?LOG_ERROR("Failed to start ssl: ~p", [SslErr]),
            ok;
        _ ->
            ok
    end,
    %% Notify controller that we are ready (with retry)
    notify_controller(ControllerNode, 3),
    {ok, #state{controller = ControllerNode}}.

notify_controller(ControllerNode, Retries) ->
    Key = {notify_retry, ControllerNode},
    put(Key, #{retries => Retries, attempts => 0}),
    notify_controller_loop(ControllerNode, Key).

notify_controller_loop(ControllerNode, Key) ->
    case get(Key) of
        #{retries := Retries, attempts := Attempts} ->
            case Attempts >= Retries of
                true ->
                    ?LOG_ERROR(
                        "Failed to notify controller after ~p retries", [
                            Retries
                        ]
                    ),
                    ok;
                false ->
                    try
                        gen_server:cast(
                            {spectrometer_ecosystem_coordinator,
                                ControllerNode},
                            {worker_ready, node()}
                        ),
                        ok
                    catch
                        _:_ ->
                            timer:sleep(1000),
                            put(Key, #{
                                retries => Retries, attempts => Attempts + 1
                            }),
                            notify_controller_loop(ControllerNode, Key)
                    end
            end;
        _ ->
            ok
    end.

handle_call({work, Ref, {Type, Item}}, _From, State) ->
    RepoStats = process_item(Type, Item),
    case check_atom_table() of
        ok ->
            {reply, {ok, Ref, RepoStats}, State};
        {threshold_reached, Pct} ->
            ?LOG_WARNING("Atom table at ~.1f%, draining", [Pct * 100]),
            {reply, {threshold_reached, Ref, RepoStats}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(
    {work, Ref, {Type, Item}}, State = #state{controller = ControllerNode}
) ->
    ?LOG_DEBUG("Worker ~p received work: ~p (ref=~p)", [
        node(), {Type, Item}, Ref
    ]),
    try
        RepoStats = process_item(Type, Item),
        case check_atom_table() of
            ok ->
                ?LOG_DEBUG("Worker ~p sending result for ref=~p", [node(), Ref]),
                gen_server:cast(
                    {spectrometer_ecosystem_coordinator, ControllerNode},
                    {worker_result, Ref, node(), RepoStats}
                );
            {threshold_reached, Pct} ->
                ?LOG_WARNING("Atom table at ~.1f%, draining", [Pct * 100]),
                gen_server:cast(
                    {spectrometer_ecosystem_coordinator, ControllerNode},
                    {worker_result, Ref, node(), RepoStats}
                ),
                gen_server:cast(
                    {spectrometer_ecosystem_coordinator, ControllerNode},
                    {worker_threshold_reached, node()}
                )
        end
    catch
        Error:Reason ->
            case {Error, Reason} of
                {error, undef} ->
                    ?LOG_ERROR(
                        "Worker ~p error processing work: undef error - ~p:~p",
                        [node(), Error, Reason]
                    ),
                    ok;
                {throw, {error, undef}} ->
                    ?LOG_ERROR("Worker ~p error processing work: throw undef"),
                    ok;
                _ ->
                    ?LOG_ERROR("Worker ~p error processing work: ~p:~p", [
                        node(), Error, Reason
                    ])
            end,
            gen_server:cast(
                {spectrometer_ecosystem_coordinator, ControllerNode},
                {worker_result, Ref, node(), #{}}
            )
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodedown, ControllerNode}, State) ->
    ?LOG_WARNING("Controller ~p went down, halting", [ControllerNode]),
    {stop, {nodedown, ControllerNode}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% Internal functions

-spec process_item(github | hex, map()) ->
    #{{binary(), binary(), arity()} => non_neg_integer()}.
process_item(github, Item) ->
    process_github_repo_binary(Item);
process_item(hex, Item) ->
    process_hex_package_binary(Item).

-spec make_worker_temp_dir(string()) -> string().
make_worker_temp_dir(Prefix) ->
    NodePart = safe_node_name(node()),
    spectrometer_utils:make_temp_dir(Prefix ++ NodePart ++ "_").

-spec safe_node_name(node()) -> string().
safe_node_name(Node) ->
    [safe_filename_char(Char) || Char <- atom_to_list(Node)].

-spec safe_filename_char(char()) -> char().
safe_filename_char(Char) when
    Char >= $a,
    Char =< $z;
    Char >= $A,
    Char =< $Z;
    Char >= $0,
    Char =< $9;
    Char =:= $_;
    Char =:= $.;
    Char =:= $-
->
    Char;
safe_filename_char(_Char) ->
    $_.

%% Skip erlang/OTP and atomvm/AtomVM to avoid skewing results.
process_github_repo_binary(#{full_name := "erlang/OTP"}) ->
    #{};
process_github_repo_binary(#{full_name := "atomvm/AtomVM"}) ->
    #{};
process_github_repo_binary(Repo) ->
    CloneUrl = maps:get(clone_url, Repo),
    ?LOG_DEBUG("Worker ~p cloning ~p", [node(), CloneUrl]),
    TmpDir = make_worker_temp_dir("gh_"),
    try
        case spectrometer_http:download_github_repo(CloneUrl, TmpDir) of
            ok ->
                ?LOG_DEBUG("Worker ~p clone ok, checking dir ~p", [
                    node(), TmpDir
                ]),
                case filelib:is_dir(TmpDir) of
                    true ->
                        ?LOG_DEBUG("Worker ~p scanning directory", [node()]),
                        IncludeDirs = find_include_dirs(TmpDir),
                        ?LOG_DEBUG("Worker ~p include dirs: ~p", [
                            node(), IncludeDirs
                        ]),
                        ?LOG_DEBUG("Worker ~p: calling scan_directory", [node()]),
                        ScannerPath = code:which(spectrometer_scanner),
                        ?LOG_DEBUG(
                            "Worker ~p: spectrometer_scanner path: ~p", [
                                node(), ScannerPath
                            ]
                        ),
                        if
                            ScannerPath == non_existing ->
                                ?LOG_DEBUG(
                                    "Worker ~p: spectrometer_scanner NOT FOUND in code path",
                                    [node()]
                                ),
                                #{};
                            true ->
                                ?LOG_DEBUG(
                                    "Worker ~p: spectrometer_scanner found at ~p",
                                    [node(), ScannerPath]
                                ),
                                try
                                    Stats = spectrometer_scanner:scan_directory(
                                        TmpDir, IncludeDirs
                                    ),
                                    ?LOG_DEBUG(
                                        "Worker ~p scan done, stats: ~p", [
                                            node(), maps:size(Stats)
                                        ]
                                    ),
                                    ensure_binary_keys(Stats)
                                catch
                                    Class:Reason ->
                                        ?LOG_ERROR(
                                            "Worker ~p scan_directory CRASHED: ~p:~p",
                                            [node(), Class, Reason]
                                        ),
                                        #{}
                                end
                        end;
                    false ->
                        ?LOG_WARNING("Worker ~p: not a dir after clone: ~p", [
                            node(), TmpDir
                        ]),
                        #{}
                end;
            {error, Reason} ->
                ?LOG_ERROR("Worker ~p download failed: ~p", [node(), Reason]),
                #{{<<"error">>, <<"download_failed">>, 0} => 1}
        end
    after
        _ = spectrometer_utils:purge_dir(TmpDir)
    end.

-spec ensure_binary_keys(#{{binary(), binary(), arity()} => non_neg_integer()}) ->
    #{{binary(), binary(), arity()} => non_neg_integer()}.
ensure_binary_keys(Stats) ->
    maps:fold(
        fun({M, F, A}, Count, Acc) ->
            MBin = to_binary(M),
            FBin = to_binary(F),
            maps:put({MBin, FBin, A}, Count, Acc)
        end,
        #{},
        Stats
    ).

-spec to_binary(binary() | atom() | string()) -> binary().
to_binary(B) when is_binary(B) -> B;
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(S) when is_list(S) -> list_to_binary(S).

-spec check_atom_table() -> ok | {threshold_reached, float()}.
check_atom_table() ->
    AtomCount = erlang:system_info(atom_count),
    AtomLimit = erlang:system_info(atom_limit),
    Pct = AtomCount / AtomLimit,
    case Pct >= ?ATOM_THRESHOLD of
        true -> {threshold_reached, Pct};
        false -> ok
    end.

-spec process_hex_package_binary(map()) ->
    #{{binary(), binary(), arity()} => non_neg_integer()}.
process_hex_package_binary(Package) ->
    ?LOG_DEBUG("Worker ~p: process_hex_package_binary called", [node()]),
    Name = maps:get(name, Package),
    Version = maps:get(version, Package),
    Result = spectrometer_http:download_hex_tarball(Name, Version),
    ?LOG_DEBUG("Worker ~p: download result: ~p", [node(), Result]),
    case Result of
        {ok, TmpDir} ->
            ?LOG_DEBUG("Worker ~p: calling find_include_dirs", [node()]),
            IncludeDirs = find_include_dirs(TmpDir),
            ?LOG_DEBUG("Worker ~p: find_include_dirs returned: ~p", [
                node(), IncludeDirs
            ]),
            ?LOG_DEBUG("Worker ~p: calling find_erl_files", [node()]),
            ErlFiles = spectrometer_scanner:find_erl_files(TmpDir),
            ?LOG_DEBUG("Worker ~p: find_erl_files returned: ~p", [
                node(), ErlFiles
            ]),
            ?LOG_DEBUG("Worker ~p: calling scan_directory", [node()]),
            try
                Stats = spectrometer_scanner:scan_directory(
                    TmpDir, IncludeDirs
                ),
                ?LOG_DEBUG(
                    "Worker ~p: scan_directory returned stats size: ~p", [
                        node(), maps:size(Stats)
                    ]
                ),
                ensure_binary_keys(Stats)
            after
                spectrometer_utils:purge_dir(TmpDir)
            end;
        {error, _} ->
            #{}
    end.

-spec find_include_dirs(string()) -> [string()].
find_include_dirs(Dir) ->
    find_include_dirs(Dir, []).

find_include_dirs(Dir, Acc) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foldl(
                fun(Entry, A) ->
                    Path = filename:join(Dir, Entry),
                    case file:read_link_info(Path) of
                        {ok, #file_info{type = directory}} ->
                            case Entry of
                                "include" -> [Path | A];
                                "_build" -> A;
                                "deps" -> A;
                                ".rebar3" -> A;
                                ".git" -> A;
                                _ -> find_include_dirs(Path, A)
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

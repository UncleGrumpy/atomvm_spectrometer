%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_ecosystem_worker).

-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-ignore_xref(start_link/1).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(worker_state, {
    node :: node(),
    port :: port(),
    cookie :: atom(),
    next_worker_id :: pos_integer()
}).

%% @doc Start a worker manager that spawns and monitors a remote BEAM node.
-spec start_link(#{cookie => atom()}) -> gen_server:start_ret().
start_link(#{cookie := Cookie}) ->
    gen_server:start_link(?MODULE, [Cookie], []).

init([Cookie]) ->
    process_flag(trap_exit, true),
    case start_node(Cookie, 1) of
        {ok, Node, Port, NextWorkerId} ->
            ok = net_kernel:monitor_nodes(true),
            {ok, #worker_state{
                node = Node,
                port = Port,
                cookie = Cookie,
                next_worker_id = NextWorkerId
            }};
        {error, Reason, _NextWorkerId} ->
            {stop, {start_node_failed, Reason}}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodedown, Node}, State = #worker_state{node = Node}) ->
    ?LOG_WARNING("Worker node ~p went down", [Node]),
    spectrometer_ecosystem_coordinator:worker_down(Node),
    {stop, {nodedown, Node}, State};
handle_info({Port, {data, Data}}, State = #worker_state{port = Port}) ->
    case Data of
        Binary when is_binary(Binary) ->
            ?LOG_DEBUG("Worker port ~p: ~s", [Port, binary_to_list(Binary)]);
        Term ->
            ?LOG_DEBUG("Worker port ~p: ~p", [Port, Term])
    end,
    {noreply, State};
handle_info({Port, {exit_status, Status}}, State = #worker_state{port = Port}) ->
    ?LOG_DEBUG("Worker port ~p exited with status: ~p", [Port, Status]),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #worker_state{port = Port}) ->
    safe_port_close(Port),
    ok.

%% Internal functions

-spec start_node(atom(), pos_integer()) ->
    {ok, node(), port(), pos_integer()} | {error, term(), pos_integer()}.
start_node(Cookie, NextWorkerId) ->
    WorkerId = ensure_worker_name_counter(),
    NodeName = "spec_worker_" ++ integer_to_list(WorkerId),
    ErlPath = os:find_executable("erl"),
    case ErlPath of
        false ->
            {error, erl_not_found, NextWorkerId};
        _ ->
            CodePaths = get_code_paths(),
            PaArgs = lists:append([["-pa", Path] || Path <- CodePaths]),
            ControllerNode = atom_to_list(node()),
            ?LOG_DEBUG("Worker code paths: ~p", [CodePaths]),
            %% Get PATH from controller's environment to pass to worker node
            PathEnv = os:getenv("PATH", "/bin:/usr/bin:/usr/local/bin"),
            %% Pass PATH via open_port env
            GitEnv = [{"GIT_TERMINAL_PROMPT", "0"}, {"PATH", PathEnv}],
            EvalStr =
                "spectrometer_ecosystem_worker_node:start(\"" ++
                    ControllerNode ++ "\")",
            Args = [
                "-noshell",
                "-setcookie",
                atom_to_list(Cookie),
                "-sname",
                NodeName,
                "+S",
                "1",
                "-eval",
                EvalStr
            ],
            FullArgs = PaArgs ++ Args,
            Port = open_port(
                {spawn_executable, ErlPath},
                [
                    {args, FullArgs},
                    exit_status,
                    stderr_to_stdout,
                    {line, 256},
                    {env, GitEnv}
                ]
            ),
            Node = list_to_atom(NodeName ++ "@" ++ hostname()),
            case wait_for_node(Node, 30000) of
                ok ->
                    {ok, Node, Port, NextWorkerId};
                {error, timeout} ->
                    safe_port_close(Port),
                    {error, timeout, NextWorkerId}
            end
    end.

-spec ensure_worker_name_counter() -> pos_integer().
ensure_worker_name_counter() ->
    case ets:info(worker_name_counter) of
        undefined ->
            _ =
                try
                    ets:new(worker_name_counter, [
                        named_table,
                        public,
                        {read_concurrency, true}
                    ])
                catch
                    error:badarg -> ok
                end,
            ets:update_counter(worker_name_counter, next_id, 1, {next_id, 0});
        _ ->
            ets:update_counter(worker_name_counter, next_id, 1)
    end.

-spec safe_port_close(port()) -> ok.
safe_port_close(Port) ->
    try
        port_close(Port),
        ok
    catch
        error:badarg -> ok;
        _:_ -> ok
    end.

%% @doc Compute code paths for worker nodes.
%% Use -pa from start_node so these paths win over the inherited "." entry.
%% This avoids stale beams in the project root shadowing the compiled app.
-spec get_code_paths() -> [string()].
get_code_paths() ->
    SpectrometerPaths = spectrometer_ebin_paths(),
    OtpPaths = lists:filtermap(
        fun get_app_ebin/1,
        [
            compiler,
            syntax_tools,
            ssl,
            inets,
            crypto,
            public_key,
            asn1,
            kernel,
            stdlib
        ]
    ),
    CwdPaths = cwd_project_ebin_paths(),
    uniq(SpectrometerPaths ++ OtpPaths ++ CwdPaths).

-spec spectrometer_ebin_paths() -> [string()].
spectrometer_ebin_paths() ->
    uniq(
        existing_dirs([
            code_lib_ebin(spectrometer),
            ebin_from_beam(code:which(?MODULE)),
            cwd_project_ebin(spectrometer)
        ])
    ).

-spec cwd_project_ebin_paths() -> [string()].
cwd_project_ebin_paths() ->
    case file:get_cwd() of
        {ok, _Cwd} ->
            existing_dirs([
                cwd_project_ebin(App)
             || App <- [
                    spectrometer,
                    compiler,
                    syntax_tools,
                    ssl,
                    inets,
                    crypto,
                    public_key,
                    asn1,
                    kernel,
                    stdlib
                ]
            ]);
        _ ->
            []
    end.

-spec cwd_project_ebin(atom()) -> string() | false.
cwd_project_ebin(App) ->
    case file:get_cwd() of
        {ok, Cwd} ->
            Path = filename:join([
                Cwd,
                "_build/default/lib",
                atom_to_list(App),
                "ebin"
            ]),
            case filelib:is_dir(Path) of
                true -> filename:absname(Path);
                false -> false
            end;
        _ ->
            false
    end.

-spec code_lib_ebin(atom()) -> string() | false.
code_lib_ebin(App) ->
    try
        Dir = code:lib_dir(App),
        case is_list(Dir) of
            true ->
                EbinPath = filename:join(Dir, "ebin"),
                case filelib:is_dir(EbinPath) of
                    true -> filename:absname(EbinPath);
                    false -> false
                end;
            _ ->
                false
        end
    catch
        _:_ -> false
    end.

-spec ebin_from_beam(string() | non_existing) -> string() | false.
ebin_from_beam(BeamPath) when is_list(BeamPath) ->
    Ebin = filename:dirname(BeamPath),
    case filename:basename(Ebin) of
        "ebin" -> filename:absname(Ebin);
        _ -> false
    end;
ebin_from_beam(_NonExisting) ->
    false.

-spec existing_dirs([string() | false]) -> [string()].
existing_dirs(Paths) ->
    lists:filtermap(
        fun(Path) ->
            case filelib:is_dir(Path) of
                true -> {true, filename:absname(Path)};
                false -> false
            end
        end,
        Paths
    ).

-spec uniq([T]) -> [T] when T :: term().
uniq(Items) ->
    uniq(Items, []).

uniq([], Acc) ->
    lists:reverse(Acc);
uniq([Item | Rest], Acc) ->
    case lists:member(Item, Acc) of
        true -> uniq(Rest, Acc);
        false -> uniq(Rest, [Item | Acc])
    end.

-spec get_app_ebin(atom()) -> {true, string()} | false.
get_app_ebin(App) ->
    case code_lib_ebin(App) of
        false -> false;
        Dir -> {true, Dir}
    end.

-spec wait_for_node(node(), non_neg_integer()) -> ok | {error, timeout}.
wait_for_node(Node, Timeout) ->
    Start = erlang:monotonic_time(millisecond),
    wait_for_node(Node, Timeout, Start).

wait_for_node(Node, Timeout, Start) ->
    case net_adm:ping(Node) of
        pong ->
            ok;
        pang ->
            Elapsed = erlang:monotonic_time(millisecond) - Start,
            case Elapsed < Timeout of
                true ->
                    wait_for_node(Node, Timeout, Start);
                false ->
                    {error, timeout}
            end
    end.

-spec hostname() -> string().
hostname() ->
    case inet:gethostname() of
        {ok, Name} -> Name
    end.

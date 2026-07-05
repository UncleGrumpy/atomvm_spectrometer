%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_ecosystem_worker_sup).

-behaviour(supervisor).

-ignore_xref(start_link/0).

-export([start_link/0, start_worker/1]).
-export([init/1]).

%% @doc Start the worker node supervisor.
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a new worker node with the given arguments.
-spec start_worker(#{cookie => atom()}) -> supervisor:startchild_ret().
start_worker(Args) ->
    supervisor:start_child(?MODULE, [Args]).

init([]) ->
    ensure_worker_name_counter(),
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpec = #{
        id => spectrometer_ecosystem_worker,
        start => {spectrometer_ecosystem_worker, start_link, []},
        restart => transient,
        shutdown => 10000,
        type => worker,
        modules => [spectrometer_ecosystem_worker]
    },
    {ok, {SupFlags, [ChildSpec]}}.

-spec ensure_worker_name_counter() -> ok.
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
            ets:insert(worker_name_counter, {next_id, 0}),
            ok;
        _ ->
            ok
    end.

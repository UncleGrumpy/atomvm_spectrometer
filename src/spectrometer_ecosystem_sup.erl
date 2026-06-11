%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_ecosystem_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

%% @doc Start the ecosystem supervision tree.
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 5,
        period => 60
    },
    Children = [
        #{
            id => spectrometer_ecosystem_coordinator,
            start => {spectrometer_ecosystem_coordinator, start_link, []},
            restart => transient,
            shutdown => 5000,
            type => worker,
            modules => [spectrometer_ecosystem_coordinator]
        },
        #{
            id => worker_node_sup,
            start => {spectrometer_ecosystem_worker_sup, start_link, []},
            restart => transient,
            shutdown => 5000,
            type => supervisor,
            modules => [spectrometer_ecosystem_worker_sup]
        }
    ],
    {ok, {SupFlags, Children}}.

%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer).

-moduledoc """
Main entry point for the atomvm_spectrometer escript.

This module is the primary user-facing interface that orchestrates all CLI
commands. It handles argument parsing, command dispatch, and coordination
of scan, ecosystem, supported, filter, update, and query operations.
""".

-export([main/1]).

-ifdef(TEST).
-spec main([string()]) -> ok | {error, {halt, non_neg_integer()}}.
-else.
-spec main([string()]) -> no_return().
-endif.
main(Args) ->
    atomvm_spectrometer:main(Args).

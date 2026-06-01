%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-ifndef(FUNCTION_HRL).
-define(FUNCTION_HRL, true).

-type version_tuple() ::
    {Major :: non_neg_integer(), Minor :: non_neg_integer(), Patch :: non_neg_integer()}
    | {release, Major :: non_neg_integer(), Minor :: non_neg_integer()}
    | {main, Major :: non_neg_integer(), Minor :: non_neg_integer()}.

-type platform() :: esp32 | emscripten | generic_unix | rp2 | stm32.

-type platform_versions() :: #{platform() | all => version_tuple()}.

-record(function, {
    name :: binary(),
    arity :: non_neg_integer() | all,
    since_map :: platform_versions(),
    removed :: version_tuple() | undefined
}).

-endif.

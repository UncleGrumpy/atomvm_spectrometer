%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
%%

-module(spectrometer_elixir_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% parse_query_string/1 tests - 8 formats for Elixir.GPIO:digital_read/1
%% =============================================================================

parse_query_8_formats_test() ->
    FormatsWithArity = [
        {"Elixir.GPIO.digital_read/1",
            {ok, <<"Elixir.GPIO">>, <<"digital_read">>, 1}},
        {"GPIO.digital_read/1", {ok, <<"Elixir.GPIO">>, <<"digital_read">>, 1}},
        {"Elixir.GPIO:digital_read/1", {ok, <<"GPIO">>, <<"digital_read">>, 1}},
        {"GPIO:digital_read/1", {ok, <<"GPIO">>, <<"digital_read">>, 1}}
    ],
    FormatsNoArity = [
        {"Elixir.GPIO.digital_read",
            {ok, <<"Elixir.GPIO">>, <<"digital_read">>}},
        {"GPIO.digital_read", {ok, <<"Elixir.GPIO">>, <<"digital_read">>}},
        {"Elixir.GPIO:digital_read", {ok, <<"GPIO">>, <<"digital_read">>}},
        {"GPIO:digital_read", {ok, <<"GPIO">>, <<"digital_read">>}}
    ],
    lists:foreach(
        fun({Format, Expected}) ->
            Result = spectrometer_atomvm:parse_query_string(Format),
            ?assertEqual(Expected, Result)
        end,
        FormatsWithArity ++ FormatsNoArity
    ).

%% =============================================================================
%% normalize_module tests
%% =============================================================================

normalize_gpio_test() ->
    ?assertEqual(
        <<"GPIO">>,
        spectrometer_utils:normalize_module_name("GPIO")
    ).

normalize_elixir_gpio_test() ->
    ?assertEqual(
        <<"Elixir.GPIO">>,
        spectrometer_utils:normalize_module_name("Elixir.GPIO")
    ).

normalize_lists_test() ->
    ?assertEqual(
        <<"lists">>,
        spectrometer_utils:normalize_module_name("lists")
    ).

normalize_with_flag_test() ->
    ?assertEqual(
        <<"Elixir.GPIO">>,
        spectrometer_utils:normalize_module_name("GPIO", true)
    ),
    ?assertEqual(
        <<"GPIO">>,
        spectrometer_utils:normalize_module_name("GPIO", false)
    ).

%% =============================================================================
%% is_elixir_module_name tests
%% =============================================================================

is_elixir_module_name_elxir_prefix_test() ->
    ?assertEqual(true, spectrometer_utils:is_elixir_module_name("Elixir.GPIO")),
    ?assertEqual(
        true, spectrometer_utils:is_elixir_module_name("Elixir.MyModule")
    ).

is_elixir_module_name_lowercase_test() ->
    ?assertEqual(false, spectrometer_utils:is_elixir_module_name("lists")),
    ?assertEqual(false, spectrometer_utils:is_elixir_module_name("maps")),
    % Uppercase without Elixir prefix is no longer considered Elixir
    ?assertEqual(false, spectrometer_utils:is_elixir_module_name("GPIO")),
    ?assertEqual(false, spectrometer_utils:is_elixir_module_name("MyModule")).

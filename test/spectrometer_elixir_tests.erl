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
        {"Elixir.GPIO.digital_read/1", {ok, 'Elixir.GPIO', digital_read, 1}},
        {"GPIO.digital_read/1", {ok, 'Elixir.GPIO', digital_read, 1}},
        {"Elixir.GPIO:digital_read/1", {ok, 'Elixir.GPIO', digital_read, 1}},
        {"GPIO:digital_read/1", {ok, 'Elixir.GPIO', digital_read, 1}}
    ],
    FormatsNoArity = [
        {"Elixir.GPIO.digital_read", {ok, 'Elixir.GPIO', digital_read}},
        {"GPIO.digital_read", {ok, 'Elixir.GPIO', digital_read}},
        {"Elixir.GPIO:digital_read", {ok, 'Elixir.GPIO', digital_read}},
        {"GPIO:digital_read", {ok, 'Elixir.GPIO', digital_read}}
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
        'GPIO',
        spectrometer_utils:normalize_module_name("GPIO")
    ).

normalize_elixir_gpio_test() ->
    ?assertEqual(
        'Elixir.GPIO',
        spectrometer_utils:normalize_module_name("Elixir.GPIO")
    ).

normalize_lists_test() ->
    ?assertEqual(
        lists,
        spectrometer_utils:normalize_module_name("lists")
    ).

normalize_with_flag_test() ->
    ?assertEqual(
        'Elixir.GPIO',
        spectrometer_utils:normalize_module_name("GPIO", true)
    ),
    ?assertEqual(
        'GPIO',
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

%% =============================================================================
%% is_elixir_module_name/1 - atom input
%% =============================================================================

is_elixir_module_name_atom_with_prefix_test() ->
    ?assertEqual(true, spectrometer_utils:is_elixir_module_name('Elixir.GPIO')),
    ?assertEqual(
        true, spectrometer_utils:is_elixir_module_name('Elixir.List')
    ).

is_elixir_module_name_atom_without_prefix_test() ->
    % Erlang module atoms
    ?assertEqual(false, spectrometer_utils:is_elixir_module_name(lists)),
    ?assertEqual(false, spectrometer_utils:is_elixir_module_name(gen_server)),
    % Capitalized atom without Elixir. prefix
    ?assertEqual(false, spectrometer_utils:is_elixir_module_name('GPIO')).

%% =============================================================================
%% parse_query_string/1 - additional edge cases
%% =============================================================================

parse_query_string_erlang_module_test() ->
    % Erlang modules should not get Elixir prefix
    ?assertEqual(
        {ok, lists, map, 2},
        spectrometer_atomvm:parse_query_string("lists:map/2")
    ),
    ?assertEqual(
        {ok, lists, map},
        spectrometer_atomvm:parse_query_string("lists:map")
    ).

parse_query_string_invalid_formats_test() ->
    % No separator at all
    {error, Msg1} = spectrometer_atomvm:parse_query_string("foobar"),
    ?assert(string:str(Msg1, "Invalid format") > 0),
    % Invalid arity
    {error, Msg2} = spectrometer_atomvm:parse_query_string("lists:map/abc"),
    ?assert(string:str(Msg2, "Invalid arity") > 0).

parse_query_string_zero_arity_elixir_test() ->
    % Zero arity with Elixir module
    ?assertEqual(
        {ok, 'Elixir.MapSet', new, 0},
        spectrometer_atomvm:parse_query_string("Elixir.MapSet.new/0")
    ),
    ?assertEqual(
        {ok, 'Elixir.MapSet', new, 0},
        spectrometer_atomvm:parse_query_string("MapSet.new/0")
    ).

%% =============================================================================
%% normalize_module_name edge cases
%% =============================================================================

normalize_lowercase_erlang_with_true_flag_test() ->
    % Lowercase Erlang modules should NOT get Elixir prefix even with true flag
    ?assertEqual(
        lists,
        spectrometer_utils:normalize_module_name("lists", true)
    ),
    ?assertEqual(
        gen_server,
        spectrometer_utils:normalize_module_name("gen_server", true)
    ).

normalize_elixir_prefix_already_present_test() ->
    % When Elixir. prefix is already present, it should not be doubled
    ?assertEqual(
        'Elixir.GPIO',
        spectrometer_utils:normalize_module_name("Elixir.GPIO", true)
    ),
    ?assertEqual(
        'Elixir.GPIO',
        spectrometer_utils:normalize_module_name("Elixir.GPIO", false)
    ).

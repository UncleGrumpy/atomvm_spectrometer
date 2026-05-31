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

parse_query_string_mapset_test() ->
    ?assertEqual(
        {ok, 'Elixir.MapSet', new, 0},
        spectrometer_atomvm:parse_query_string("Elixir.MapSet:new/0")
    ).









































































%% =============================================================================
%% filter_modules_by_type/2 tests (new function in this PR)
%% =============================================================================

filter_modules_by_type_erlang_only_test() ->
    Mods = [lists, maps, 'Elixir.GPIO', 'Elixir.Enum', erlang, gen_server],
    Result = spectrometer_atomvm:filter_modules_by_type(Mods, erlang_only),
    ?assertEqual([lists, maps, erlang, gen_server], Result),
    % All Elixir modules are removed
    ?assertNot(lists:member('Elixir.GPIO', Result)),
    ?assertNot(lists:member('Elixir.Enum', Result)).

filter_modules_by_type_elixir_only_test() ->
    Mods = [lists, maps, 'Elixir.GPIO', 'Elixir.Enum', erlang, 'Elixir.List'],
    Result = spectrometer_atomvm:filter_modules_by_type(Mods, elixir_only),
    ?assertEqual(['Elixir.GPIO', 'Elixir.Enum', 'Elixir.List'], Result),
    % All Erlang modules are removed
    ?assertNot(lists:member(lists, Result)),
    ?assertNot(lists:member(erlang, Result)).

filter_modules_by_type_undefined_test() ->
    Mods = [lists, 'Elixir.GPIO', erlang],
    % undefined filter returns all modules unchanged
    ?assertEqual(Mods, spectrometer_atomvm:filter_modules_by_type(Mods, undefined)).

filter_modules_by_type_empty_list_test() ->
    % Empty list stays empty regardless of filter
    ?assertEqual([], spectrometer_atomvm:filter_modules_by_type([], erlang_only)),
    ?assertEqual([], spectrometer_atomvm:filter_modules_by_type([], elixir_only)),
    ?assertEqual([], spectrometer_atomvm:filter_modules_by_type([], undefined)).

filter_modules_by_type_all_elixir_with_erlang_filter_test() ->
    % All Elixir modules filtered by erlang_only gives empty list
    Mods = ['Elixir.GPIO', 'Elixir.Enum', 'Elixir.List'],
    ?assertEqual([], spectrometer_atomvm:filter_modules_by_type(Mods, erlang_only)).

filter_modules_by_type_all_erlang_with_elixir_filter_test() ->
    % All Erlang modules filtered by elixir_only gives empty list
    Mods = [lists, maps, erlang, gen_server],
    ?assertEqual([], spectrometer_atomvm:filter_modules_by_type(Mods, elixir_only)).

%% =============================================================================
%% format_since/1 tests (function exists in this PR's scope)
%% =============================================================================

format_since_version_binary_test() ->
    % Binary version string is returned as a string
    ?assertEqual("v0.5.0", spectrometer_atomvm:format_since(<<"v0.5.0">>)),
    ?assertEqual("v0.7.0", spectrometer_atomvm:format_since(<<"v0.7.0">>)).

format_since_unreleased_test() ->
    % Unreleased tuple formats as "unreleased BRANCH"
    ?assertEqual(
        "unreleased main",
        spectrometer_atomvm:format_since({unreleased, <<"main">>})
    ),
    ?assertEqual(
        "unreleased 0.7.x",
        spectrometer_atomvm:format_since({unreleased, <<"0.7.x">>})
    ).

format_since_unknown_test() ->
    % Special case: <<"unknown">> returns the string "unknown"
    ?assertEqual("unknown", spectrometer_atomvm:format_since(<<"unknown">>)).

format_since_other_binary_test() ->
    % Any other binary is returned as string
    ?assertEqual(
        "some_branch",
        spectrometer_atomvm:format_since(<<"some_branch">>)
    ).

%% =============================================================================
%% Regression test: supported_modules includes Elixir modules from bundled data
%% =============================================================================

supported_modules_includes_elixir_test() ->
    % The bundled data (updated in this PR) contains Elixir modules
    % Verify that supported_modules/0 returns a mix of Elixir and Erlang modules
    Mods = spectrometer_atomvm:supported_modules(),
    ElixirMods = spectrometer_atomvm:filter_modules_by_type(Mods, elixir_only),
    ErlangMods = spectrometer_atomvm:filter_modules_by_type(Mods, erlang_only),
    % After this PR, we should have at least some Elixir modules
    ?assert(is_list(ElixirMods)),
    ?assert(is_list(ErlangMods)),
    % Total count should match
    ?assertEqual(length(Mods), length(ElixirMods) + length(ErlangMods)).
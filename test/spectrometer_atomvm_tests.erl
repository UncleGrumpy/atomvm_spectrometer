%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_atomvm_tests).
-include_lib("eunit/include/eunit.hrl").
-include("function.hrl").

supported_modules_test_() ->
    [
        {"returns list of binaries",
            ?_assert(begin
                Mods = spectrometer_atomvm:supported_modules(),
                is_list(Mods) andalso lists:all(fun is_binary/1, Mods)
            end)},

        {"contains expected Elixir modules",
            ?_assert(begin
                Mods = spectrometer_atomvm:supported_modules(),
                lists:member(<<"Elixir.Access">>, Mods) andalso
                    lists:member(<<"Elixir.AVMPort">>, Mods)
            end)},

        {"returns non-empty list",
            ?_assert(begin
                Mods = spectrometer_atomvm:supported_modules(),
                length(Mods) > 0
            end)}
    ].

supported_functions_test_() ->
    [
        {"returns list of record pairs",
            ?_assert(begin
                Funs = spectrometer_atomvm:get_supported_functions(),
                is_list(Funs) andalso
                    lists:all(
                        fun({M, Rec}) ->
                            is_binary(M) andalso is_record(Rec, function)
                        end,
                        Funs
                    )
            end)},

        {"functions have valid fields",
            ?_assert(begin
                Funs = spectrometer_atomvm:get_supported_functions(),
                lists:all(
                    fun({_M, #function{name = N, arity = A, since_map = SM}}) ->
                        is_binary(N) andalso (is_integer(A) andalso A >= 0) andalso
                            is_map(SM) andalso maps:size(SM) > 0
                    end,
                    Funs
                )
            end)},

        {"contains expected functions",
            ?_assert(begin
                Funs = spectrometer_atomvm:get_supported_functions(),
                lists:any(
                    fun({M, #function{name = N, arity = A}}) ->
                        M =:= <<"Elixir.Enum">> andalso N =:= <<"map">> andalso
                            A =:= 2
                    end,
                    Funs
                )
            end)}
    ].

is_supported_test_() ->
    [
        {"returns true for supported function",
            ?_assert(
                spectrometer_atomvm:is_supported(
                    {<<"Elixir.AVMPort">>, <<"call">>, 2}
                )
            )},

        {"returns false for unsupported function",
            ?_assertNot(
                spectrometer_atomvm:is_supported(
                    {<<"nonexistent_module">>, <<"foo">>, 0}
                )
            )},

        {"handles specific arity match",
            ?_assert(
                spectrometer_atomvm:is_supported(
                    {<<"Elixir.Enum">>, <<"map">>, 2}
                )
            )},

        {"handles unknown module",
            ?_assertNot(
                spectrometer_atomvm:is_supported(
                    {<<"unknown_module">>, <<"test">>, 1}
                )
            )},

        {"handles unknown function",
            ?_assert(begin
                Mods = spectrometer_atomvm:supported_modules(),
                case Mods of
                    [Mod | _] ->
                        not spectrometer_atomvm:is_supported(
                            {Mod, <<"nonexistent_function_12345">>, 0}
                        );
                    [] ->
                        true
                end
            end)},

        {"handles Elixir modules",
            ?_assert(
                spectrometer_atomvm:is_supported(
                    {<<"Elixir.AVMPort">>, <<"call">>, 2}
                )
            )}
    ].

is_supported_with_platforms_test_() ->
    [
        {"returns true for functions on all platforms",
            ?_assertEqual(
                true,
                spectrometer_atomvm:is_supported(
                    {<<"Elixir.Enum">>, <<"map">>, 2}
                )
            )},

        {"returns false for unsupported functions",
            ?_assertEqual(
                false,
                spectrometer_atomvm:is_supported(
                    {<<"nonexistent">>, <<"foo">>, 0}
                )
            )}
    ].

support_info_test_() ->
    [
        {"returns triple for known functions",
            ?_assertMatch(
                {true, _, _},
                spectrometer_atomvm:support_info(
                    {<<"Elixir.AVMPort">>, <<"call">>, 2}
                )
            )},

        {"since_map is non-empty map",
            ?_assert(begin
                {true, SinceMap, _} = spectrometer_atomvm:support_info(
                    {<<"Elixir.AVMPort">>, <<"call">>, 2}
                ),
                is_map(SinceMap) andalso maps:size(SinceMap) > 0
            end)},

        {"returns false for unsupported functions",
            ?_assertEqual(
                false,
                spectrometer_atomvm:support_info(
                    {<<"nonexistent">>, <<"foo">>, 0}
                )
            )},

        {"removed is version_tuple or undefined",
            ?_assert(begin
                Result = spectrometer_atomvm:support_info(
                    {<<"Elixir.Enum">>, <<"map">>, 2}
                ),
                case Result of
                    {true, _, undefined} -> true;
                    {true, _, {release, _, _}} -> true;
                    {true, _, {main, _, _}} -> true;
                    {true, _, {_, _, _}} -> true;
                    false -> false
                end
            end)}
    ].

get_unsupported_test_() ->
    [
        {"filters out supported functions",
            ?_assert(begin
                Stats = #{
                    {<<"Elixir.AVMPort">>, <<"call">>, 2} => 10,
                    {<<"nonexistent_module">>, <<"foo">>, 0} => 5
                },
                Unsupported = spectrometer_atomvm:get_unsupported(Stats),
                Keys = [K || {K, _} <- Unsupported],
                not lists:member({<<"Elixir.AVMPort">>, <<"call">>, 2}, Keys) andalso
                    lists:member({<<"nonexistent_module">>, <<"foo">>, 0}, Keys)
            end)},

        {"returns only unsupported functions",
            ?_assert(begin
                Stats = #{
                    {<<"nonexistent1">>, <<"foo">>, 0} => 5,
                    {<<"nonexistent2">>, <<"bar">>, 1} => 3
                },
                Unsupported = spectrometer_atomvm:get_unsupported(Stats),
                length(Unsupported) =:= 2
            end)},

        {"sorts by call count descending",
            ?_assertEqual(
                [
                    {{<<"nonexistent1">>, <<"foo">>, 0}, 10},
                    {{<<"nonexistent2">>, <<"bar">>, 1}, 5}
                ],
                spectrometer_atomvm:get_unsupported(
                    #{
                        {<<"nonexistent1">>, <<"foo">>, 0} => 10,
                        {<<"nonexistent2">>, <<"bar">>, 1} => 5
                    }
                )
            )},

        {"returns empty list when all are supported",
            ?_assertEqual(
                [],
                spectrometer_atomvm:get_unsupported(
                    #{{<<"Elixir.Enum">>, <<"map">>, 2} => 10}
                )
            )}
    ].

db_loading_test_() ->
    [
        {"load_db returns a map", fun() ->
            ?assert(is_map(spectrometer_atomvm:load_db()))
        end},

        {"reload_db clears cache", fun() ->
            DB1 = spectrometer_atomvm:load_db(),
            ok = spectrometer_atomvm:reload_db(),
            CacheDir = spectrometer_utils:user_cache_path(),
            AltDir = spectrometer_utils:make_temp_dir("alt_cache_"),
            ok = filelib:ensure_path(AltDir),
            AltDbFile = filename:join(AltDir, "supported_functions.data"),
            AltDB = [
                {<<"test_mod">>, [
                    {<<"test_fun">>, 0, #{all => {0, 5, 0}}, undefined}
                ]}
            ],
            ok = file:write_file(AltDbFile, io_lib:format("~p.\n", [AltDB])),
            try
                application:set_env(spectrometer, cache_dir, AltDir),
                ok = spectrometer_atomvm:reload_db(),
                DB2 = spectrometer_atomvm:load_db(),
                ?assert(DB1 =/= DB2)
            after
                application:set_env(spectrometer, cache_dir, CacheDir),
                spectrometer_atomvm:reload_db()
            end
        end}
    ].

consult_db_invalid_test_() ->
    {"returns empty map for invalid DB file", fun() ->
        Dir = spectrometer_utils:make_temp_dir("consult_db_test_"),
        File = filename:join(
            Dir,
            "invalid_db_" ++ integer_to_list(erlang:unique_integer([positive])) ++
                ".data"
        ),
        ok = file:write_file(File, io_lib:format("~s\n", [not_a_list])),
        try
            DB = spectrometer_atomvm:consult_db(File),
            ?assertEqual(#{}, DB)
        after
            spectrometer_utils:purge_dir(Dir)
        end
    end}.

consult_db_nonexistent_test_() ->
    {"returns empty map for nonexistent file", fun() ->
        DB = spectrometer_atomvm:consult_db("/nonexistent/path/to/db.data"),
        ?assertEqual(#{}, DB)
    end}.

function_record_test_() ->
    [
        {"since_map values are version tuples",
            ?_assert(begin
                Funs = spectrometer_atomvm:get_supported_functions(),
                lists:all(
                    fun({_M, #function{since_map = SM}}) ->
                        maps:fold(
                            fun(_K, V, Acc) ->
                                case V of
                                    {M, Mi, P} when
                                        is_integer(M),
                                        is_integer(Mi),
                                        is_integer(P)
                                    ->
                                        Acc;
                                    {release, M, Mi} when
                                        is_integer(M), is_integer(Mi)
                                    ->
                                        Acc;
                                    {main, M, Mi} when
                                        is_integer(M), is_integer(Mi)
                                    ->
                                        Acc;
                                    _ ->
                                        false
                                end
                            end,
                            true,
                            SM
                        )
                    end,
                    Funs
                )
            end)},

        {"removed field is version_tuple or undefined",
            ?_assert(begin
                Funs = lists:map(
                    fun({_, Rec}) -> Rec end,
                    spectrometer_atomvm:get_supported_functions()
                ),
                lists:all(
                    fun
                        (#function{removed = undefined}) ->
                            true;
                        (#function{removed = {R1, R2, R3}}) when
                            is_integer(R1), is_integer(R2), is_integer(R3)
                        ->
                            true;
                        (#function{removed = {release, R1, R2}}) when
                            is_integer(R1), is_integer(R2)
                        ->
                            true;
                        (#function{removed = {main, R1, R2}}) when
                            is_integer(R1), is_integer(R2)
                        ->
                            true;
                        (_) ->
                            false
                    end,
                    Funs
                )
            end)}
    ].

get_first_funs() ->
    spectrometer_atomvm:reload_db(),
    [{_, Funs} | _] = [
        {M, F}
     || {M, F} <- maps:to_list(spectrometer_atomvm:load_db()), F =/= []
    ],
    Funs.

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

%% =============================================================================
%% supported_modules/0 tests
%% =============================================================================

supported_modules_test_() ->
    [
        {"returns list of atoms",
            ?_assert(begin
                Mods = spectrometer_atomvm:supported_modules(),
                is_list(Mods) andalso lists:all(fun is_atom/1, Mods)
            end)},

        {"contains expected OTP modules",
            ?_assert(begin
                Mods = spectrometer_atomvm:supported_modules(),
                lists:member(lists, Mods) andalso
                    lists:member(maps, Mods) andalso
                    lists:member(erlang, Mods) andalso
                    lists:member(io, Mods)
            end)},

        {"returns non-empty list",
            ?_assert(begin
                Mods = spectrometer_atomvm:supported_modules(),
                length(Mods) > 0
            end)}
    ].

%% =============================================================================
%% supported_functions/0 tests
%% =============================================================================

supported_functions_test_() ->
    [
        {"returns list of 5-tuples",
            ?_assert(begin
                Funs = spectrometer_atomvm:get_supported_functions(),
                is_list(Funs) andalso
                    lists:all(
                        fun({M, F, A, _P, _S}) ->
                            is_atom(M) andalso is_atom(F) andalso is_integer(A)
                        end,
                        Funs
                    )
            end)},

        {"contains expected functions",
            ?_assert(begin
                Funs = spectrometer_atomvm:get_supported_functions(),
                lists:any(
                    fun
                        ({lists, map, 2, _, _}) -> true;
                        (_) -> false
                    end,
                    Funs
                ) andalso
                    lists:any(
                        fun
                            ({maps, get, 2, _, _}) -> true;
                            (_) -> false
                        end,
                        Funs
                    )
            end)},

        {"all entries have valid atoms and integer arities",
            ?_assert(begin
                Funs = spectrometer_atomvm:get_supported_functions(),
                lists:all(
                    fun({M, F, A, _P, _S}) ->
                        is_atom(M) andalso is_atom(F) andalso is_integer(A) andalso
                            A >= 0
                    end,
                    Funs
                )
            end)}
    ].

%% =============================================================================
%% is_supported/1 tests
%% =============================================================================

is_supported_test_() ->
    [
        {"returns true for supported function",
            ?_assert(spectrometer_atomvm:is_supported({lists, map, 2}))},

        {"returns false for unsupported function",
            ?_assertNot(
                spectrometer_atomvm:is_supported(
                    {nonexistent_module, foo, 0}
                )
            )},

        {"handles specific arity match",
            ?_assert(spectrometer_atomvm:is_supported({io, format, 2}))},

        {"handles unknown module",
            ?_assertNot(
                spectrometer_atomvm:is_supported({unknown_module, test, 1})
            )},

        {"handles unknown function",
            ?_assert(begin
                Mods = spectrometer_atomvm:supported_modules(),
                case Mods of
                    [Mod | _] ->
                        not spectrometer_atomvm:is_supported(
                            {Mod, nonexistent_function_12345, 0}
                        );
                    [] ->
                        true
                end
            end)},

        {"handles erlang BIFs",
            ?_assert(
                spectrometer_atomvm:is_supported({erlang, atom_to_list, 1})
            )},

        {"handles erlang operators",
            ?_assert(spectrometer_atomvm:is_supported({erlang, '+', 2}))}
    ].

%% =============================================================================
%% is_supported/1 platform-specific tests
%% =============================================================================

is_supported_with_platforms_test_() ->
    [
        {"returns {true, all, Since} for functions on all platforms",
            ?_assertEqual(
                true,
                spectrometer_atomvm:is_supported({lists, map, 2})
            )},

        {"returns false for unsupported functions",
            ?_assertEqual(
                false,
                spectrometer_atomvm:is_supported({nonexistent, foo, 0})
            )}
    ].

%% =============================================================================
%% support_info/1 tests
%% =============================================================================

support_info_test_() ->
    [
        {"returns {true, all, Since} for functions on all platforms",
            ?_assertMatch(
                {true, all, _},
                spectrometer_atomvm:support_info({lists, map, 2})
            )},

        {"returns false for unsupported functions",
            ?_assertEqual(
                false,
                spectrometer_atomvm:support_info({nonexistent, foo, 0})
            )},

        {"returns since info for known functions",
            ?_assert(begin
                %% Current data file has version info
                Result = spectrometer_atomvm:support_info({lists, map, 2}),
                match_all_platforms_since(Result)
            end)}
    ].

%% Helper to check if result has valid since info
match_all_platforms_since({true, all, Since}) when
    is_binary(Since) orelse is_tuple(Since)
->
    true;
match_all_platforms_since(_) ->
    false.

%% =============================================================================
%% supported_functions_with_platforms/0 tests
%% =============================================================================

supported_functions_with_platforms_test_() ->
    [
        {"returns list with platform and since information",
            ?_assert(begin
                Funs = spectrometer_atomvm:get_supported_functions(),
                is_list(Funs) andalso
                    lists:all(
                        fun({M, F, A, P, S}) ->
                            is_atom(M) andalso is_atom(F) andalso
                                is_integer(A) andalso
                                (P =:= all orelse is_list(P)) andalso
                                (is_binary(S) orelse
                                    (is_tuple(S) andalso
                                        element(1, S) =:= unreleased))
                        end,
                        Funs
                    )
            end)},

        {"has valid since info for known functions",
            ?_assert(begin
                Funs = spectrometer_atomvm:get_supported_functions(),
                %% Find lists:map/2 and check it has valid since info
                case
                    lists:keyfind(
                        {lists, map, 2},
                        1,
                        [{{M, F, A}, {P, S}} || {M, F, A, P, S} <- Funs]
                    )
                of
                    {_, {all, Since}} when is_binary(Since) -> true;
                    _ -> false
                end
            end)}
    ].

%% =============================================================================
%% get_unsupported/1 tests
%% =============================================================================

get_unsupported_test_() ->
    [
        {"filters out supported functions from stats",
            ?_assert(begin
                Stats = #{
                    {lists, map, 2} => 10,
                    {nonexistent_module, foo, 0} => 5
                },
                Unsupported = spectrometer_atomvm:get_unsupported(Stats),
                Keys = [K || {K, _} <- Unsupported],
                not lists:member({lists, map, 2}, Keys) andalso
                    lists:member({nonexistent_module, foo, 0}, Keys)
            end)},

        {"returns only unsupported functions",
            ?_assert(begin
                Stats = #{
                    {nonexistent1, foo, 0} => 5,
                    {nonexistent2, bar, 1} => 3
                },
                Unsupported = spectrometer_atomvm:get_unsupported(Stats),
                length(Unsupported) =:= 2
            end)},

        {"sorts by call count descending",
            ?_assertEqual(
                [
                    {{nonexistent1, foo, 0}, 10},
                    {{nonexistent2, bar, 1}, 5}
                ],
                spectrometer_atomvm:get_unsupported(#{
                    {nonexistent2, bar, 1} => 5,
                    {nonexistent1, foo, 0} => 10
                })
            )},

        {"returns empty list when all are supported",
            ?_assertEqual(
                [],
                spectrometer_atomvm:get_unsupported(#{
                    {lists, map, 2} => 10
                })
            )},

        {"returns all when none are supported",
            ?_assertEqual(
                [
                    {{nonexistent1, foo, 0}, 5},
                    {{nonexistent2, bar, 1}, 3}
                ],
                lists:sort(
                    fun({_, C1}, {_, C2}) -> C1 > C2 end,
                    spectrometer_atomvm:get_unsupported(#{
                        {nonexistent1, foo, 0} => 5,
                        {nonexistent2, bar, 1} => 3
                    })
                )
            )}
    ].

%% =============================================================================
%% Database loading tests
%% =============================================================================

db_loading_test_() ->
    [
        {"load_db/0 returns a map", fun() ->
            ?assert(is_map(spectrometer_atomvm:load_db()))
        end},

        {"reload_db/0 clears cache", fun() ->
            DB1 = spectrometer_atomvm:load_db(),
            ok = spectrometer_atomvm:reload_db(),
            %% Write a different DB to the cache location to verify reload picks it up
            CacheDir = spectrometer_utils:user_cache_path(),
            AltDir = spectrometer_utils:make_temp_dir("alt_cache_"),
            ok = filelib:ensure_path(AltDir),
            AltDbFile = filename:join(AltDir, "supported_functions.data"),
            %% Write a minimal DB with a known entry
            AltDB = [
                {test_mod, [{test_fun, 0, all, {unreleased, <<"test">>}}]}
            ],
            ok = file:write_file(AltDbFile, io_lib:format("~p.\n", [AltDB])),
            try
                %% Point cache to the alt dir and reload
                application:set_env(spectrometer, cache_dir, AltDir),
                ok = spectrometer_atomvm:reload_db(),
                DB2 = spectrometer_atomvm:load_db(),
                ?assert(DB1 =/= DB2)
            after
                %% Restore original cache dir
                application:set_env(spectrometer, cache_dir, CacheDir),
                spectrometer_atomvm:reload_db()
            end
        end},

        {"bundled_data_path/0 returns a string", fun() ->
            Path = spectrometer_utils:bundled_data_path(),
            ?assert(is_list(Path))
        end},

        {"user_cache_path/0 returns platform-appropriate path", fun() ->
            Path = spectrometer_utils:user_cache_path(),
            ?assert(
                is_list(Path) andalso
                    %% Should contain our app name
                    string:str(Path, "spectrometer") > 0
            )
        end}
    ].

%% =============================================================================
%% consult_db/1 error path tests
%% =============================================================================

consult_db_invalid_test_() ->
    {"returns empty map for invalid DB file", fun() ->
        Dir = spectrometer_utils:make_temp_dir("consult_db_test_"),
        File = filename:join(
            Dir,
            "invalid_db_" ++ integer_to_list(erlang:unique_integer([positive])) ++
                ".data"
        ),
        %% Write a non-list term as text so file:consult can parse it
        ok = file:write_file(File, io_lib:format("~s\n", [not_a_list])),
        try
            %% Should return empty map and print warning
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

%% =============================================================================
%% is_supported/1 with different arities
%% =============================================================================

is_supported_arity_mismatch_test_() ->
    {"correctly distinguishes supported and unsupported arities", fun() ->
        %% Tests that is_supported/1 returns correct boolean for known arities.
        %% Note: The DB currently uses separate entries per arity (not list arities).
        Result1 = spectrometer_atomvm:is_supported({erlang, send, 1}),
        Result2 = spectrometer_atomvm:is_supported({erlang, send, 2}),
        %% send/1 is NOT supported by AtomVM (only send/2)
        ?assertEqual(false, Result1),
        %% send/2 is supported
        ?assertEqual(true, Result2)
    end}.

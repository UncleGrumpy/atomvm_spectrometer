%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
%%

-module(spectrometer_updater_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% derive_since/2 tests
%% =============================================================================

derive_since_tag_test_() ->
    {"tag strips prerelease suffixes", fun() ->
        ?assertEqual(
            <<"v0.5.0">>,
            spectrometer_updater:derive_since("v0.5.0-alpha.1", "main")
        ),
        ?assertEqual(
            <<"v0.6.0">>,
            spectrometer_updater:derive_since("v0.6.0-rc.2", "release-0.7")
        ),
        ?assertEqual(
            <<"v0.5.0">>,
            spectrometer_updater:derive_since("v0.5.0", undefined)
        ),
        ?assertEqual(
            <<"v1.0.0">>,
            spectrometer_updater:derive_since("v1.0.0-beta.3", "main")
        )
    end}.

derive_since_branch_test_() ->
    {"branch converts to since", fun() ->
        ?assertEqual(
            {unreleased, <<"main">>},
            spectrometer_updater:derive_since(undefined, "main")
        ),
        ?assertEqual(
            {unreleased, <<"0.7.x">>},
            spectrometer_updater:derive_since(undefined, "release-0.7")
        ),
        ?assertEqual(
            {unreleased, <<"feature-x">>},
            spectrometer_updater:derive_since(undefined, "feature-x")
        )
    end}.

derive_since_undefined_test_() ->
    {"undefined/undefined returns default", fun() ->
        ?assertEqual(
            {unreleased, <<"main">>},
            spectrometer_updater:derive_since(undefined, undefined)
        )
    end}.

%% =============================================================================
%% is_older_since/2 tests
%% =============================================================================

is_older_since_binary_test_() ->
    {"compares two binary tags", fun() ->
        ?assert(
            spectrometer_updater:is_older_since(<<"v0.4.0">>, <<"v0.5.0">>)
        ),
        ?assert(
            spectrometer_updater:is_older_since(<<"v0.8.2">>, <<"v1.0.1">>)
        ),
        ?assert(
            spectrometer_updater:is_older_since(<<"v0.2.9">>, <<"v0.2.11">>)
        ),
        ?assertNot(
            spectrometer_updater:is_older_since(<<"v0.5.1">>, <<"v0.5.0">>)
        ),
        ?assertNot(
            spectrometer_updater:is_older_since(<<"v0.5.0">>, <<"v0.4.0">>)
        )
    end}.

is_older_since_tag_vs_unreleased_test_() ->
    {"tag is always older than unreleased", fun() ->
        ?assert(
            spectrometer_updater:is_older_since(
                <<"v0.5.0">>, {unreleased, <<"main">>}
            )
        ),
        ?assertNot(
            spectrometer_updater:is_older_since(
                {unreleased, <<"main">>}, <<"v0.5.0">>
            )
        )
    end}.

is_older_since_both_unreleased_test_() ->
    {"main is newer than versioned branches", fun() ->
        ?assertNot(
            spectrometer_updater:is_older_since(
                {unreleased, <<"main">>}, {unreleased, <<"0.7.x">>}
            )
        ),
        ?assert(
            spectrometer_updater:is_older_since(
                {unreleased, <<"0.7.x">>}, {unreleased, <<"main">>}
            )
        ),
        ?assertNot(
            spectrometer_updater:is_older_since(
                {unreleased, <<"0.7.x">>}, {unreleased, <<"0.6.x">>}
            )
        )
    end}.

%% =============================================================================
%% merge_entry/2 and merge_platforms_all/2 tests
%% =============================================================================

merge_entry_both_all_test_() ->
    {"merges two all-platform entries", fun() ->
        E1 = {all, <<"v0.4.0">>},
        E2 = {all, <<"v0.5.0">>},
        {Plats, Since} = spectrometer_updater:merge_entry(E1, E2),
        ?assertEqual(all, Plats),
        ?assertEqual(<<"v0.4.0">>, Since)
    end}.

merge_entry_list_platforms_test_() ->
    {"merges platform lists", fun() ->
        E1 = {[esp32], <<"v0.4.0">>},
        E2 = {[rp2], <<"v0.5.0">>},
        {Plats, Since} = spectrometer_updater:merge_entry(E1, E2),
        ?assertEqual([esp32, rp2], Plats),
        ?assertEqual(<<"v0.4.0">>, Since)
    end}.

merge_entry_all_with_list_test_() ->
    {"all merged with list stays all", fun() ->
        E1 = {all, <<"v0.4.0">>},
        E2 = {[esp32], <<"v0.5.0">>},
        {Plats, Since} = spectrometer_updater:merge_entry(E1, E2),
        ?assertEqual(all, Plats),
        ?assertEqual(<<"v0.4.0">>, Since)
    end}.

%% =============================================================================
%% merge_since/2 tests
%% =============================================================================

merge_since_two_tags_test_() ->
    {"two tags: older wins", fun() ->
        ?assertEqual(
            <<"v0.4.0">>,
            spectrometer_updater:merge_since(<<"v0.4.0">>, <<"v0.5.0">>)
        ),
        ?assertEqual(
            <<"v0.4.0">>,
            spectrometer_updater:merge_since(<<"v0.5.0">>, <<"v0.4.0">>)
        )
    end}.

merge_since_tag_vs_unreleased_test_() ->
    {"tag vs unreleased: tag wins", fun() ->
        ?assertEqual(
            <<"v0.5.0">>,
            spectrometer_updater:merge_since(
                <<"v0.5.0">>, {unreleased, <<"main">>}
            )
        ),
        ?assertEqual(
            <<"v0.5.0">>,
            spectrometer_updater:merge_since(
                {unreleased, <<"main">>}, <<"v0.5.0">>
            )
        )
    end}.

merge_since_both_unreleased_test_() ->
    {"two unreleased: lexicographically first wins", fun() ->
        ?assertEqual(
            {unreleased, <<"0.6.x">>},
            spectrometer_updater:merge_since(
                {unreleased, <<"0.6.x">>}, {unreleased, <<"0.7.x">>}
            )
        ),
        ?assertEqual(
            {unreleased, <<"0.6.x">>},
            spectrometer_updater:merge_since(
                {unreleased, <<"0.7.x">>}, {unreleased, <<"0.6.x">>}
            )
        ),
        ?assertEqual(
            {unreleased, <<"0.7.x">>},
            spectrometer_updater:merge_since(
                {unreleased, <<"0.7.x">>}, {unreleased, <<"main">>}
            )
        ),
        ?assertEqual(
            {unreleased, <<"0.7.x">>},
            spectrometer_updater:merge_since(
                {unreleased, <<"main">>}, {unreleased, <<"0.7.x">>}
            )
        )
    end}.

merge_since_fallback_test_() ->
    {"fallback keeps existing", fun() ->
        ?assertEqual(
            all, spectrometer_updater:merge_since(all, something_else)
        )
    end}.

%% =============================================================================
%% normalize_platform_name/1 tests
%% =============================================================================

normalize_platform_name_variants_test_() ->
    {"normalizes all platform name variants", fun() ->
        ?assertEqual(
            rp2, spectrometer_utils:normalize_platform_name("rp2")
        ),
        ?assertEqual(
            rp2, spectrometer_utils:normalize_platform_name("RP2")
        ),
        ?assertEqual(
            rp2, spectrometer_utils:normalize_platform_name("rp2040")
        ),
        ?assertEqual(
            rp2, spectrometer_utils:normalize_platform_name("RP2040")
        ),
        ?assertEqual(
            esp32, spectrometer_utils:normalize_platform_name("esp32")
        ),
        ?assertEqual(
            esp32, spectrometer_utils:normalize_platform_name("ESP32")
        ),
        ?assertEqual(
            stm32, spectrometer_utils:normalize_platform_name("stm32")
        ),
        ?assertEqual(
            stm32, spectrometer_utils:normalize_platform_name("STM32")
        ),
        ?assertEqual(
            emscripten,
            spectrometer_utils:normalize_platform_name("emscripten")
        ),
        ?assertEqual(
            emscripten,
            spectrometer_utils:normalize_platform_name("Emscripten")
        ),
        ?assertEqual(
            generic_unix,
            spectrometer_utils:normalize_platform_name("generic_unix")
        ),
        ?assertEqual(
            generic_unix,
            spectrometer_utils:normalize_platform_name("GenericUnix")
        ),
        ?assertEqual(
            {error, badarg},
            spectrometer_utils:normalize_platform_name("custom_plat")
        )
    end}.

%% =============================================================================
%% write_db_file/2 tests
%% =============================================================================

write_db_file_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("updater_test_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Acc = #{
                        {lists, map, 2} => {all, {unreleased, <<"main">>}},
                        {io, format, 2} => {all, {unreleased, <<"main">>}}
                    },
                    Path = filename:join(Dir, "test.data"),
                    ok = spectrometer_updater:write_db_file(Path, Acc),
                    ?assert(filelib:is_file(Path)),
                    %% Verify it can be read back
                    {ok, [Data]} = file:consult(Path),
                    ?assert(is_list(Data))
                end)
            end,
            fun(Dir) ->
                ?_test(begin
                    Acc = #{
                        {lists, map, 2} => {all, {unreleased, <<"main">>}},
                        {esp32_module, func, 1} => {
                            [esp32], {unreleased, <<"main">>}
                        }
                    },
                    Path = filename:join(Dir, "test_platforms.data"),
                    ok = spectrometer_updater:write_db_file(Path, Acc),
                    {ok, [Data]} = file:consult(Path),
                    %% Check structure: {module, [{func, arity, platforms, since}]}
                    ?assert(is_list(Data)),
                    %% Each entry should be {Module, [{Func, Arity, Platforms, Since}]}
                    lists:foreach(
                        fun({Mod, Funs}) ->
                            ?assert(is_atom(Mod)),
                            ?assert(is_list(Funs)),
                            lists:foreach(
                                fun({F, A, P, _S}) ->
                                    ?assert(is_atom(F)),
                                    ?assert(is_integer(A)),
                                    ?assert(P =:= all orelse is_list(P))
                                end,
                                Funs
                            )
                        end,
                        Data
                    )
                end)
            end,
            fun(Dir) ->
                ?_test(begin
                    Acc = #{
                        {module1, func1, 1} => {all, {unreleased, <<"main">>}},
                        {module2, func2, 2} => {
                            [esp32, rp2], {unreleased, <<"main">>}
                        }
                    },
                    Path = filename:join(Dir, "roundtrip.data"),
                    ok = spectrometer_updater:write_db_file(Path, Acc),
                    %% Read back and verify
                    {ok, [Data]} = file:consult(Path),
                    FlatList = [
                        {M, F, A, P}
                     || {M, Funs} <- Data, {F, A, P, _S} <- Funs
                    ],
                    ?assert(length(FlatList) =:= 2)
                end)
            end
        ]}
    }.

%% =============================================================================
%% Integration tests with fake AtomVM repo structure
%% =============================================================================

scan_repo_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("updater_repo_test_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(_RepoDir) ->
                ?_test(begin
                    % Create fresh repo for each test case
                    RepoDir = spectrometer_utils:make_temp_dir(
                        "updater_repo_test_gperf_"
                    ),
                    ok = filelib:ensure_path(RepoDir),
                    try
                        % Create minimal structure with just gperf files
                        LibDir = filename:join(RepoDir, "src/libAtomVM"),
                        ok = filelib:ensure_path(LibDir),

                        % Create bifs.gperf
                        BifsContent =
                            "/* Some comment */\n" ++
                                "extern int some_c_function();\n" ++
                                "\n" ++
                                "%%\n" ++
                                "erlang:abs/1, bif_erlang_abs_1, true\n" ++
                                "\n",
                        ok = file:write_file(
                            filename:join(LibDir, "bifs.gperf"), BifsContent
                        ),

                        % Create nifs.gperf
                        NifsContent =
                            "/* Some comment */\n" ++
                                "\n" ++
                                "%%\n" ++
                                "binary:at/2, &binary_at_nif\n" ++
                                "\n",
                        ok = file:write_file(
                            filename:join(LibDir, "nifs.gperf"), NifsContent
                        ),

                        Acc = spectrometer_updater:scan_atomvm_repo(
                            RepoDir, #{tests => false}, {unreleased, <<"main">>}
                        ),
                        ?assert(is_map(Acc)),
                        ?assert(maps:is_key({erlang, abs, 1}, Acc)),
                        ?assert(maps:is_key({binary, at, 2}, Acc)),
                        ?assertEqual(
                            {all, {unreleased, <<"main">>}},
                            maps:get({erlang, abs, 1}, Acc)
                        ),
                        ?assertEqual(
                            {all, {unreleased, <<"main">>}},
                            maps:get({binary, at, 2}, Acc)
                        )
                    after
                        spectrometer_utils:purge_dir(RepoDir)
                    end
                end)
            end,
            fun(_RepoDir) ->
                ?_test(begin
                    RepoDir = spectrometer_utils:make_temp_dir(
                        "updater_repo_test_libs_"
                    ),
                    ok = filelib:ensure_path(RepoDir),
                    try
                        % Create libs structure
                        LibSrcDir = filename:join(RepoDir, "libs/estdlib/src"),
                        ok = filelib:ensure_path(LibSrcDir),

                        LibSource =
                            "-module(my_lists).\n" ++
                                "-export([map/2, filter/2]).\n" ++
                                "\n" ++
                                "map(F, []) -> [];\n" ++
                                "map(F, [H|T]) -> [F(H) | map(F, T)].\n" ++
                                "\n" ++
                                "filter(P, []) -> [];\n" ++
                                "filter(P, [H|T]) ->\n" ++
                                "    case P(H) of\n" ++
                                "        true -> [H | filter(P, T)];\n" ++
                                "        false -> filter(P, T)\n" ++
                                "    end.\n",
                        ok = file:write_file(
                            filename:join(LibSrcDir, "my_lists.erl"), LibSource
                        ),

                        Acc = spectrometer_updater:scan_atomvm_repo(
                            RepoDir, #{tests => false}, {unreleased, <<"main">>}
                        ),
                        % The scanner should find my_lists:map/2 and my_lists:filter/2
                        ?assert(is_map(Acc)),
                        ?assert(
                            maps:size(Acc) > 0,
                            "Expected scanner to find entries from estdlib"
                        ),
                        ?assert(
                            maps:is_key({my_lists, map, 2}, Acc),
                            "Expected to find my_lists:map/2 in scan results"
                        ),
                        ?assert(
                            maps:is_key({my_lists, filter, 2}, Acc),
                            "Expected to find my_lists:filter/2 in scan results"
                        )
                    after
                        spectrometer_utils:purge_dir(RepoDir)
                    end
                end)
            end,
            fun(_RepoDir) ->
                ?_test(begin
                    RepoDir = spectrometer_utils:make_temp_dir(
                        "updater_repo_test_empty_"
                    ),
                    ok = filelib:ensure_path(RepoDir),
                    try
                        % Create minimal structure
                        LibDir = filename:join(RepoDir, "src/libAtomVM"),
                        ok = filelib:ensure_path(LibDir),

                        % Create empty gperf files
                        ok = file:write_file(
                            filename:join(LibDir, "bifs.gperf"), "{}\n"
                        ),
                        ok = file:write_file(
                            filename:join(LibDir, "nifs.gperf"), "{}\n"
                        ),

                        % Create tests directory (should be ignored)
                        TestsDir = filename:join(RepoDir, "tests/erlang_tests"),
                        ok = filelib:ensure_path(TestsDir),

                        Acc = spectrometer_updater:scan_atomvm_repo(
                            RepoDir, #{tests => false}, {unreleased, <<"main">>}
                        ),
                        ?assert(is_map(Acc))
                    after
                        spectrometer_utils:purge_dir(RepoDir)
                    end
                end)
            end,
            fun(_RepoDir) ->
                ?_test(begin
                    RepoDir = spectrometer_utils:make_temp_dir(
                        "updater_repo_test_clean_"
                    ),
                    ok = filelib:ensure_path(RepoDir),
                    try
                        % Empty repo
                        Acc = spectrometer_updater:scan_atomvm_repo(
                            RepoDir, #{tests => false}, {unreleased, <<"main">>}
                        ),
                        ?assert(is_map(Acc)),
                        ?assertEqual(0, maps:size(Acc))
                    after
                        spectrometer_utils:purge_dir(RepoDir)
                    end
                end)
            end
        ]}
    }.

%% =============================================================================
%% scan_calls via AST tests
%% =============================================================================

scan_via_ast_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("ast_scan_test_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    TestFile = filename:join(Dir, "test_mod.erl"),
                    Content = <<
                        "-module(test_mod).\n"
                        "-export([test/0]).\n"
                        "test() ->\n"
                        "    lists:map(fun(X) -> X * 2 end, [1,2,3]),\n"
                        "    io:format(\"hello\"),\n"
                        "    ok.\n"
                    >>,
                    ok = file:write_file(TestFile, Content),
                    {ok, test_mod, Calls} = spectrometer_scanner:parse_calls(
                        TestFile
                    ),
                    ?assertEqual(test_mod, test_mod),
                    ?assert(is_map(Calls)),
                    % lists:map/2 should be found
                    ?assert(maps:is_key({lists, map, 2}, Calls)),
                    % io:format/1 should be found
                    ?assert(maps:is_key({io, format, 1}, Calls))
                end)
            end,
            fun(Dir) ->
                ?_test(begin
                    TestFile = filename:join(Dir, "test_mod.erl"),
                    Content = <<
                        "-module(test_mod).\n"
                        "-export([test/0]).\n"
                        "test() ->\n"
                        "    test_mod:internal(),\n"
                        "    ok.\n"
                        "\n"
                        "internal() ->\n"
                        "    lists:map(fun(X) -> X end, [1]).\n"
                    >>,
                    ok = file:write_file(TestFile, Content),
                    {ok, test_mod, Calls} = spectrometer_scanner:parse_calls(
                        TestFile
                    ),
                    ?assert(is_map(Calls)),
                    % Self-call test_mod:internal/0 should NOT be in calls
                    ?assertNot(maps:is_key({test_mod, internal, 0}, Calls)),
                    % lists:map/2 should be found
                    ?assert(maps:is_key({lists, map, 2}, Calls))
                end)
            end
        ]}
    }.

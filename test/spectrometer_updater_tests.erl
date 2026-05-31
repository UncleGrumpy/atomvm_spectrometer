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

%% =============================================================================
%% normalize_tag/1 tests
%% =============================================================================

normalize_tag_strips_prerelease_test_() ->
    {"strips prerelease suffixes from tags", fun() ->
        ?assertEqual(
            <<"v0.5.0">>,
            spectrometer_updater:normalize_tag("v0.5.0-alpha.1")
        ),
        ?assertEqual(
            <<"v0.6.0">>,
            spectrometer_updater:normalize_tag("v0.6.0-rc.2")
        ),
        ?assertEqual(
            <<"v1.0.0">>,
            spectrometer_updater:normalize_tag("v1.0.0-beta.3")
        ),
        ?assertEqual(
            <<"v0.5.0">>,
            spectrometer_updater:normalize_tag("v0.5.0")
        )
    end}.

%% =============================================================================
%% branch_sort_key/1 tests
%% =============================================================================

branch_sort_key_main_test_() ->
    {"main branch is newest (tier 3)", fun() ->
        ?assertEqual(
            {3, <<>>}, spectrometer_updater:branch_sort_key(<<"main">>)
        )
    end}.

branch_sort_key_release_test_() ->
    {"release branches are tier 2", fun() ->
        ?assertEqual(
            {2, {0, 7}},
            spectrometer_updater:branch_sort_key(<<"release-0.7">>)
        ),
        ?assertEqual(
            {2, {1, 2}},
            spectrometer_updater:branch_sort_key(<<"release-1.2">>)
        )
    end}.

branch_sort_key_versioned_test_() ->
    {"versioned branches like 0.7.x are tier 2", fun() ->
        ?assertEqual(
            {2, {0, 7}},
            spectrometer_updater:branch_sort_key(<<"0.7.x">>)
        ),
        ?assertEqual(
            {2, {1, 0}},
            spectrometer_updater:branch_sort_key(<<"1.0.x">>)
        )
    end}.

branch_sort_key_unknown_test_() ->
    {"unknown branches are tier 1", fun() ->
        ?assertEqual(
            {1, <<"feature-x">>},
            spectrometer_updater:branch_sort_key(<<"feature-x">>)
        ),
        ?assertEqual(
            {1, <<"custom">>},
            spectrometer_updater:branch_sort_key(<<"custom">>)
        )
    end}.

%% =============================================================================
%% parse_semver/1 tests
%% =============================================================================

parse_semver_valid_test_() ->
    {"parses valid semantic versions", fun() ->
        ?assertEqual(
            {ok, {1, 2, 3}}, spectrometer_updater:parse_semver("v1.2.3")
        ),
        ?assertEqual(
            {ok, {0, 5, 0}}, spectrometer_updater:parse_semver("v0.5.0")
        ),
        ?assertEqual(
            {ok, {1, 2, 3}}, spectrometer_updater:parse_semver("1.2.3")
        ),
        ?assertEqual(
            {ok, {0, 5, 0}}, spectrometer_updater:parse_semver("0.5.0")
        )
    end}.

parse_semver_prerelease_test_() ->
    {"strips prerelease suffix for comparison", fun() ->
        ?assertEqual(
            {ok, {0, 5, 0}},
            spectrometer_updater:parse_semver("v0.5.0-alpha.1")
        ),
        ?assertEqual(
            {ok, {0, 6, 0}},
            spectrometer_updater:parse_semver("v0.6.0-rc.2")
        )
    end}.

parse_semver_partial_test_() ->
    {"handles partial versions", fun() ->
        ?assertEqual(
            {ok, {1, 2, 0}}, spectrometer_updater:parse_semver("v1.2")
        ),
        ?assertEqual({ok, {1, 0, 0}}, spectrometer_updater:parse_semver("v1")),
        ?assertEqual({ok, {0, 5, 0}}, spectrometer_updater:parse_semver("0.5"))
    end}.

parse_semver_invalid_test_() ->
    {"returns error for invalid versions", fun() ->
        ?assertEqual(
            {error, non_integer_version},
            spectrometer_updater:parse_semver("notaversion")
        ),
        ?assertEqual(
            {error, non_integer_version},
            spectrometer_updater:parse_semver("vabc.def.ghi")
        )
    end}.

%% =============================================================================
%% compare_semver/2 tests
%% =============================================================================

compare_semver_ordering_test_() ->
    {"compares semantic version ordering", fun() ->
        ?assertEqual(
            older,
            spectrometer_updater:compare_semver(<<"v0.4.0">>, <<"v0.5.0">>)
        ),
        ?assertEqual(
            newer,
            spectrometer_updater:compare_semver(<<"v0.6.0">>, <<"v0.5.0">>)
        ),
        ?assertEqual(
            same,
            spectrometer_updater:compare_semver(<<"v0.5.0">>, <<"v0.5.0">>)
        )
    end}.

compare_semver_patch_test_() ->
    {"compares patch versions", fun() ->
        ?assertEqual(
            older,
            spectrometer_updater:compare_semver(<<"v0.5.0">>, <<"v0.5.1">>)
        ),
        ?assertEqual(
            newer,
            spectrometer_updater:compare_semver(<<"v0.5.2">>, <<"v0.5.1">>)
        )
    end}.

%% =============================================================================
%% merge_platforms_all/2 tests
%% =============================================================================

merge_platforms_all_both_all_test_() ->
    {"all + all = all", fun() ->
        ?assertEqual(all, spectrometer_updater:merge_platforms_all(all, all))
    end}.

merge_platforms_all_all_with_list_test_() ->
    {"all + list = all", fun() ->
        ?assertEqual(
            all, spectrometer_updater:merge_platforms_all(all, [esp32])
        ),
        ?assertEqual(
            all, spectrometer_updater:merge_platforms_all([esp32], all)
        )
    end}.

merge_platforms_all_two_lists_test_() ->
    {"merges two platform lists", fun() ->
        ?assertEqual(
            [esp32, rp2],
            spectrometer_updater:merge_platforms_all([esp32], [rp2])
        ),
        ?assertEqual(
            [esp32, rp2],
            spectrometer_updater:merge_platforms_all([rp2], [esp32])
        )
    end}.

merge_platforms_all_all_platforms_test_() ->
    {"all platforms combined become 'all'", fun() ->
        AllPlatforms = [emscripten, esp32, generic_unix, rp2, stm32],
        ?assertEqual(
            all,
            spectrometer_updater:merge_platforms_all(AllPlatforms, [])
        )
    end}.

%% =============================================================================
%% merge_platforms/2 tests
%% =============================================================================

merge_platforms_all_case_test_() ->
    {"all + platform = all", fun() ->
        ?assertEqual(all, spectrometer_updater:merge_platforms(all, esp32)),
        ?assertEqual(all, spectrometer_updater:merge_platforms(all, stm32))
    end}.

merge_platforms_new_platform_test_() ->
    {"adds new platform to list", fun() ->
        ?assertEqual(
            [esp32, rp2],
            spectrometer_updater:merge_platforms([esp32], rp2)
        )
    end}.

merge_platforms_duplicate_test_() ->
    {"duplicate platform not added", fun() ->
        ?assertEqual(
            [esp32],
            spectrometer_updater:merge_platforms([esp32], esp32)
        )
    end}.

merge_platforms_all_platforms_test_() ->
    {"all five platforms combined become 'all'", fun() ->
        ?assertEqual(
            all,
            spectrometer_updater:merge_platforms(
                [emscripten, esp32, rp2, stm32], generic_unix
            )
        )
    end}.

%% =============================================================================
%% is_digit_binary/1 tests
%% =============================================================================

is_digit_binary_valid_test_() ->
    {"returns true for digit-only binaries", fun() ->
        ?assert(spectrometer_updater:is_digit_binary(<<"123">>)),
        ?assert(spectrometer_updater:is_digit_binary(<<"0">>)),
        ?assert(spectrometer_updater:is_digit_binary(<<"999999">>))
    end}.

is_digit_binary_invalid_test_() ->
    {"returns false for non-digit binaries", fun() ->
        ?assertNot(spectrometer_updater:is_digit_binary(<<"abc">>)),
        ?assertNot(spectrometer_updater:is_digit_binary(<<"12a3">>)),
        ?assertNot(spectrometer_updater:is_digit_binary(<<>>))
    end}.

%% =============================================================================
%% build_db_from_list/1 tests
%% =============================================================================
build_db_from_list_test_() ->
    {"builds database map from list of entries", fun() ->
        Data = [
            {<<"my_module">>, [
                {<<"func1">>, 1, all, {unreleased, <<"main">>}},
                {<<"func2">>, 2, [esp32], {unreleased, <<"main">>}}
            ]}
        ],
        DB = spectrometer_updater:build_db_from_list(Data),
        ?assertEqual(
            {all, {unreleased, <<"main">>}},
            maps:get({<<"my_module">>, <<"func1">>, 1}, DB)
        ),
        ?assertEqual(
            {[esp32], {unreleased, <<"main">>}},
            maps:get({<<"my_module">>, <<"func2">>, 2}, DB)
        )
    end}.

build_db_from_list_atom_keys_test_() ->
    {"builds database map from atom keys (backward compat)", fun() ->
        Data = [
            {my_module, [
                {func1, 1, all, {unreleased, <<"main">>}}
            ]}
        ],
        DB = spectrometer_updater:build_db_from_list(Data),
        ?assertEqual(
            {all, {unreleased, <<"main">>}},
            maps:get({<<"my_module">>, <<"func1">>, 1}, DB)
        )
    end}.

%% =============================================================================
%% find_first_match/2,3 tests
%% =============================================================================

find_first_match_found_test_() ->
    {"finds first matching line", fun() ->
        Lines = [
            "% Some comment",
            "-module(test_mod).",
            "-export([test/0])."
        ],
        ?assertEqual(
            <<"test_mod">>,
            spectrometer_updater:find_first_match(
                "-module\\s*\\(\\s*([a-z_][a-z0-9_]*)\\s*\\)\\s*\\.", Lines
            )
        )
    end}.

find_first_match_not_found_test_() ->
    {"returns undefined when no match", fun() ->
        Lines = ["something else", "-export([test/0])."],
        ?assertEqual(
            undefined,
            spectrometer_updater:find_first_match(
                "-module\\s*\\(\\s*([a-z_][a-z0-9_]*)\\s*\\)\\s*\\.", Lines
            )
        )
    end}.

%% =============================================================================
%% find_exports/1 tests
%% =============================================================================

find_exports_single_test_() ->
    {"finds exports from single-line -export", fun() ->
        Lines = ["-export([func/1, other/2])."],
        Result =
            lists:sort(spectrometer_updater:find_exports(Lines)),
        ?assertEqual([{<<"func">>, 1}, {<<"other">>, 2}], Result)
    end}.

find_exports_multiline_test_() ->
    {"finds exports from multi-line -export", fun() ->
        Lines = [
            "-export([",
            "    func1/1,",
            "    func2/2",
            "])."
        ],
        ?assertEqual(
            [{<<"func1">>, 1}, {<<"func2">>, 2}],
            lists:sort(spectrometer_updater:find_exports(Lines))
        )
    end}.

find_exports_none_test_() ->
    {"returns empty for no exports", fun() ->
        ?assertEqual([], spectrometer_updater:find_exports(["-module(test)."])),
        ?assertEqual([], spectrometer_updater:find_exports([]))
    end}.

%% =============================================================================
%% parse_export_list/1 tests
%% =============================================================================

parse_export_list_basic_test_() ->
    {"parses basic export list", fun() ->
        ?assertEqual(
            [{<<"bar">>, 2}, {<<"foo">>, 1}],
            lists:sort(spectrometer_updater:parse_export_list("[foo/1,bar/2]"))
        )
    end}.

parse_export_list_with_spaces_test_() ->
    {"handles spaces around commas", fun() ->
        ?assertEqual(
            [{<<"bar">>, 2}, {<<"foo">>, 1}],
            lists:sort(spectrometer_updater:parse_export_list("foo/1 , bar/2"))
        )
    end}.

%% =============================================================================
%% find_erl_files/2 tests
%% =============================================================================

find_erl_files_test_() ->
    {"finds .erl files recursively",
        {setup,
            fun() ->
                Dir = spectrometer_utils:make_temp_dir("erl_files_test_"),
                ok = filelib:ensure_path(filename:join(Dir, "subdir")),
                ok = file:write_file(filename:join(Dir, "a.erl"), ""),
                ok = file:write_file(
                    filename:join(filename:join(Dir, "subdir"), "b.erl"), ""
                ),
                ok = file:write_file(filename:join(Dir, "skip.txt"), ""),
                Dir
            end,
            fun(Dir) -> spectrometer_utils:purge_dir(Dir) end, fun(
                Dir
            ) ->
                ?_test(begin
                    Files = spectrometer_updater:find_erl_files(Dir),
                    ?assertEqual(2, length(Files)),
                    Names = lists:sort([filename:basename(F) || F <- Files]),
                    ?assertEqual(["a.erl", "b.erl"], Names)
                end)
            end}}.

%% =============================================================================
%% count_arity/1 tests
%% =============================================================================

count_arity_test_() ->
    {"counts function arity from argument string", fun() ->
        ?assertEqual(0, spectrometer_updater:count_arity("")),
        ?assertEqual(1, spectrometer_updater:count_arity("x")),
        ?assertEqual(2, spectrometer_updater:count_arity("x, y")),
        ?assertEqual(3, spectrometer_updater:count_arity("x, y, z")),
        ?assertEqual(2, spectrometer_updater:count_arity("  x  ,  y  "))
    end}.

%% =============================================================================
%% find_elixir_module_def/1 tests
%% =============================================================================

find_elixir_module_def_defmodule_test_() ->
    {"detects defmodule declarations", fun() ->
        ?assertEqual(
            {defmodule, "MyModule"},
            spectrometer_updater:find_elixir_module_def("defmodule MyModule do")
        ),
        ?assertEqual(
            {defmodule, "GPIO.Driver"},
            spectrometer_updater:find_elixir_module_def(
                "  defmodule GPIO.Driver do"
            )
        )
    end}.

find_elixir_module_def_defimpl_test_() ->
    {"detects defimpl declarations", fun() ->
        ?assertEqual(
            {defimpl, "SomeProtocol", "SomeModule"},
            spectrometer_updater:find_elixir_module_def(
                "defimpl SomeProtocol, for: SomeModule do"
            )
        ),
        ?assertEqual(
            {defimpl, "SomeProtocol"},
            spectrometer_updater:find_elixir_module_def(
                "defimpl SomeProtocol do"
            )
        )
    end}.

find_elixir_module_def_defimpl_for_test_() ->
    {"detects defimpl for keyword", fun() ->
        ?assertEqual(
            {defimpl, "Enumerable", "List"},
            spectrometer_updater:find_elixir_module_def(
                "defimpl Enumerable, for: List do"
            )
        )
    end}.

find_elixir_module_def_end_test_() ->
    {"detects end keyword", fun() ->
        ?assertEqual(
            {end_block}, spectrometer_updater:find_elixir_module_def("end")
        ),
        ?assertEqual(
            {end_block}, spectrometer_updater:find_elixir_module_def("  end  ")
        )
    end}.

find_elixir_module_def_none_test_() ->
    {"returns error for non-matching lines", fun() ->
        ?assertEqual(
            error, spectrometer_updater:find_elixir_module_def("some code")
        ),
        ?assertEqual(
            error, spectrometer_updater:find_elixir_module_def("def foo() do")
        )
    end}.

%% =============================================================================
%% find_elixir_def/1 tests
%% =============================================================================

find_elixir_def_public_test_() ->
    {"detects public def functions", fun() ->
        ?assertEqual(
            {ok, "my_func", "x, y"},
            spectrometer_updater:find_elixir_def("  def my_func(x, y) do")
        ),
        ?assertEqual(
            {ok, "valid?", "x"},
            spectrometer_updater:find_elixir_def("def valid?(x) do")
        ),
        ?assertEqual(
            {ok, "risky!", "x"},
            spectrometer_updater:find_elixir_def("def risky!(x) do")
        )
    end}.

find_elixir_def_private_test_() ->
    {"skips defp private functions", fun() ->
        ?assertEqual(
            skip,
            spectrometer_updater:find_elixir_def("defp private_func(x) do")
        ),
        ?assertEqual(
            skip, spectrometer_updater:find_elixir_def("  defp hidden() do")
        )
    end}.

find_elixir_def_none_test_() ->
    {"returns skip for non-def lines", fun() ->
        ?assertEqual(
            skip, spectrometer_updater:find_elixir_def("some other code")
        ),
        ?assertEqual(
            skip, spectrometer_updater:find_elixir_def("defmodule Test do")
        )
    end}.

%% =============================================================================
%% extract_function_from_line/1 tests
%% =============================================================================

extract_function_from_line_basic_test_() ->
    {"extracts function name and args", fun() ->
        ?assertEqual(
            {ok, "func", "x, y"},
            spectrometer_updater:extract_function_from_line(
                "  def func(x, y) do"
            )
        ),
        ?assertEqual(
            {ok, "check?", "x"},
            spectrometer_updater:extract_function_from_line("def check?(x) do")
        )
    end}.

extract_function_from_line_no_parens_test_() ->
    {"handles function with empty args", fun() ->
        ?assertEqual(
            {ok, "noargs", ""},
            spectrometer_updater:extract_function_from_line("def noargs() do")
        )
    end}.

extract_function_from_line_error_test_() ->
    {"returns error for malformed lines", fun() ->
        ?assertEqual(
            skip, spectrometer_updater:extract_function_from_line("def")
        )
    end}.

%% =============================================================================
%% find_elixir_exports/1 tests
%% =============================================================================

find_elixir_exports_test_() ->
    {"extracts exports from elixir source lines", fun() ->
        Lines = [
            "defmodule TestModule do",
            "  def public(x) do",
            "    x",
            "  end",
            "  defp private(x) do",
            "    x",
            "  end",
            "  def with_qmark?(x) do",
            "    x",
            "  end",
            "  def bang!() do",
            "    :ok",
            "  end",
            "end"
        ],
        Exports = spectrometer_updater:find_elixir_exports(Lines),
        Expected = [
            {<<"Elixir.TestModule">>, <<"bang!">>, 0},
            {<<"Elixir.TestModule">>, <<"public">>, 1},
            {<<"Elixir.TestModule">>, <<"with_qmark?">>, 1}
        ],
        ?assertEqual(Expected, lists:sort(Exports))
    end}.

scan_exavmlib_dir_test_() ->
    {"scans exavmlib directory for .ex files",
        {setup,
            fun() ->
                Dir = spectrometer_utils:make_temp_dir("exavmlib_test_"),
                ExDir = filename:join(Dir, "exavmlib"),
                ok = filelib:ensure_path(filename:join(ExDir, "sub")),
                ExContent = <<
                    "defmodule MyModule do\n",
                    "  def public_func(x) do\n",
                    "    x\n",
                    "  end\n",
                    "  defp private_func(x) do\n",
                    "    x\n",
                    "  end\n",
                    "end\n",
                    "\n",
                    "defmodule OtherMod do\n",
                    "  def another() do\n",
                    "    :ok\n",
                    "  end\n",
                    "end\n"
                >>,
                ok = file:write_file(
                    filename:join(ExDir, "my_module.ex"), ExContent
                ),
                Dir
            end,
            fun(Dir) -> fun() -> spectrometer_utils:purge_dir(Dir) end end, fun(
                Dir
            ) ->
                ?_test(begin
                    ExDir = filename:join(Dir, "exavmlib"),
                    Acc = spectrometer_updater:scan_exavmlib_dir(
                        ExDir, #{}, all, {unreleased, <<"main">>}
                    ),
                    ?assert(is_map(Acc)),
                    ?assert(
                        maps:is_key(
                            {<<"Elixir.MyModule">>, <<"public_func">>, 1}, Acc
                        )
                    ),
                    ?assert(
                        maps:is_key(
                            {<<"Elixir.OtherMod">>, <<"another">>, 0}, Acc
                        )
                    ),
                    ?assertNot(
                        maps:is_key(
                            {<<"Elixir.MyModule">>, <<"private_func">>, 1}, Acc
                        )
                    )
                end)
            end}}.

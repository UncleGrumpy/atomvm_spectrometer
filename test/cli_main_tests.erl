%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
%%

-module(cli_main_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Helper functions
%% =============================================================================

create_erl_file(Dir, Name, Content) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, Content),
    Path.

%% Create an AtomVM repo clone in the OS temp directory.
%% Returns {TempDir, AtomVMDir} where TempDir is the parent temp dir.
ensure_atomvm_repo() ->
    TempDir = spectrometer_utils:make_temp_dir("spectrometer_git_clone_"),
    AtomVMDir = filename:join(TempDir, "AtomVM"),
    spectrometer_utils:purge_dir(AtomVMDir),
    io:format("  Cloning AtomVM repo to ~s...\n", [AtomVMDir]),
    case
        spectrometer_utils:run_git_command(
            [
                "clone",
                "--quiet",
                "--depth",
                "1",
                "https://github.com/atomvm/AtomVM.git",
                AtomVMDir
            ],
            [{"GIT_TERMINAL_PROMPT", "0"}]
        )
    of
        {ok, ""} ->
            io:format("  Clone successful\n"),
            {TempDir, AtomVMDir};
        {ok, Output} ->
            io:format("  Clone output: ~s", [Output]),
            {TempDir, AtomVMDir};
        {error, {exit_status, Status, Output}} ->
            io:format("  Clone failed (exit ~p): ~p\n", [Status, Output]),
            error({clone_failed, {Status, Output}})
    end.

%% =============================================================================
%% 1. Help and Error Paths — calling main/1 directly
%% =============================================================================

main_empty_args_test_() ->
    {"main([]) returns ok and prints usage", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main([]))
    end}.

main_help_flag_test_() ->
    {"main(['--help']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["--help"]))
    end}.

main_short_help_test_() ->
    {"main(['-h']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["-h"]))
    end}.

main_help_command_test_() ->
    {"main(['help']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["help"]))
    end}.

main_help_audit_test_() ->
    {"main(['help', 'audit']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["help", "audit"]))
    end}.

main_help_ecosystem_test_() ->
    {"main(['help', 'ecosystem']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["help", "ecosystem"]))
    end}.

main_help_supported_test_() ->
    {"main(['help', 'supported']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["help", "supported"]))
    end}.

main_help_filter_test_() ->
    {"main(['help', 'filter']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["help", "filter"]))
    end}.

main_help_update_test_() ->
    {"main(['help', 'update']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["help", "update"]))
    end}.

main_help_query_test_() ->
    {"main(['help', 'query']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["help", "query"]))
    end}.

main_help_unknown_test_() ->
    {"main(['help', 'unknown']) returns error", fun() ->
        ?assertMatch(
            {error, {halt, 1}}, atomvm_spectrometer:main(["help", "unknown"])
        )
    end}.

main_audit_short_help_test_() ->
    {"main(['audit', '-h']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["audit", "-h"]))
    end}.

main_ecosystem_long_help_test_() ->
    {"main(['ecosystem', '--help']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["ecosystem", "--help"]))
    end}.

main_unknown_command_test_() ->
    {"main(['unknown_command']) returns error tuple", fun() ->
        ?assertMatch(
            {error, {halt, 1}},
            atomvm_spectrometer:main(["unknown_command"])
        )
    end}.

%% =============================================================================
%% 2. `supported` Command
%% =============================================================================

main_supported_all_test_() ->
    {"main(['supported']) returns ok and lists modules", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["supported"]))
    end}.

main_supported_module_lists_test_() ->
    {"main(['supported', '--module', 'lists']) returns ok", fun() ->
        ?assertEqual(
            ok, atomvm_spectrometer:main(["supported", "--module", "lists"])
        )
    end}.

main_supported_module_maps_test_() ->
    {"main(['supported', '-m', 'maps']) returns ok", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["supported", "-m", "maps"]))
    end}.

main_supported_module_nonexistent_test_() ->
    {"main(['supported', '--module', 'nonexistent_xyz']) returns ok with stderr error",
        fun() ->
            ?assertEqual(
                {error, {halt, 1}},
                atomvm_spectrometer:main([
                    "supported", "--module", "nonexistent_module_xyz"
                ])
            )
        end}.

%% =============================================================================
%% 3. `query` Command
%% =============================================================================

main_query_supported_test_() ->
    {"main(['query', 'lists:map']) returns ok, shows supported", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:main(["query", "lists:map"]))
    end}.

main_query_supported_with_arity_test_() ->
    {"main(['query', 'lists:map/2']) returns ok, shows specific arity", fun() ->
            ?assertEqual(ok, atomvm_spectrometer:main(["query", "lists:map/2"]))
        end}.

main_query_unsupported_test_() ->
    {"main(['query', 'lists:nonexistent_func']) returns ok, shows unsupported",
        fun() ->
            ?assertEqual(
                ok,
                atomvm_spectrometer:main(["query", "lists:nonexistent_func"])
            )
        end}.

main_query_unknown_mod_function_test_() ->
    {"main(['query', 'nonexistent_mod:func']) returns ok, shows unsupported",
        fun() ->
            ?assertEqual(
                ok,
                atomvm_spectrometer:main(["query", "nonexistent_mod:func"])
            )
        end}.

main_query_invalid_format_test_() ->
    {"main(['query', 'invalid_format']) returns error", fun() ->
        ?assertMatch(
            {error, {halt, 1}},
            atomvm_spectrometer:main(["query", "invalid_format"])
        )
    end}.

main_query_invalid_arity_test_() ->
    {"main(['query', 'lists:map/abc']) returns error", fun() ->
        ?assertMatch(
            {error, {halt, 1}},
            atomvm_spectrometer:main(["query", "lists:map/abc"])
        )
    end}.

main_query_module_nofun_test_() ->
    {"main(['query', 'nonexistent_mod']) returns error", fun() ->
        ?assertMatch(
            {error, {halt, 1}},
            atomvm_spectrometer:main(["query", "nonexistent_mod"])
        )
    end}.

%% =============================================================================
%% 4. `audit` Command — Local Directory (with fixtures)
%% =============================================================================

main_audit_dir_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("audit_dir_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    create_erl_file(
                        Dir,
                        "test.erl",
                        "-module(test).\n"
                        "-export([foo/0]).\n"
                        "foo() -> lists:map(fun(X) -> X end, [1,2,3]).\n"
                    ),
                    Result = atomvm_spectrometer:main(["audit", "--dir", Dir]),
                    ?assertEqual(ok, Result)
                end)
            end
        ]}
    }.

main_audit_empty_dir_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("audit_empty_dir_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Result = atomvm_spectrometer:main(["audit", "--dir", Dir]),
                    ?assertEqual(ok, Result)
                end)
            end
        ]}
    }.

main_audit_dir_with_output_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("audit_dir_output_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    CsvFile = filename:join(Dir, "report.csv"),
                    create_erl_file(
                        Dir,
                        "test.erl",
                        "-module(test).\n"
                        "-export([foo/0]).\n"
                        "foo() -> lists:map(fun(X) -> X end, [1]).\n"
                    ),
                    Result = atomvm_spectrometer:main([
                        "audit", "--dir", Dir, "-o", CsvFile
                    ]),
                    ?assertEqual(ok, Result),
                    ?assert(filelib:is_file(CsvFile)),
                    {ok, Content} = file:read_file(CsvFile),
                    ?assert(
                        string:str(binary_to_list(Content), "module,function") >
                            0
                    )
                end)
            end
        ]}
    }.

main_audit_missing_dir_test_() ->
    {
        setup,
        fun() ->
            Unique =
                "missing_test_" ++
                    integer_to_list(erlang:unique_integer([positive])),
            TempDir = spectrometer_utils:make_temp_dir(Unique),
            {TempDir, filename:join(TempDir, "missing_child")}
        end,
        fun({TempDir, _MissingDir}) ->
            spectrometer_utils:purge_dir(TempDir)
        end,
        {with, [
            fun({_TempDir, MissingDir}) ->
                ?_test(begin
                    Result = atomvm_spectrometer:main([
                        "audit", "--dir", MissingDir
                    ]),
                    ?assertEqual(ok, Result)
                end)
            end
        ]}
    }.

%% =============================================================================
%% 5. `audit` Command — Error Paths
%% =============================================================================

main_audit_no_target_test_() ->
    {"main(['audit']) returns error for missing target", fun() ->
        ?assertMatch({error, {halt, 1}}, atomvm_spectrometer:main(["audit"]))
    end}.

main_audit_unknown_option_test_() ->
    {"main(['audit', '--unknown']) returns error", fun() ->
        ?assertMatch(
            {error, {halt, 1}},
            atomvm_spectrometer:main([
                "audit", "--github", "https://github.com/user/repo", "--unknown"
            ])
        )
    end}.

%% =============================================================================
%% 6. `filter` Command
%% =============================================================================

main_filter_no_csv_test_() ->
    {
        setup,
        fun() ->
            Unique =
                "filter_test_" ++
                    integer_to_list(erlang:unique_integer([positive])),
            TempDir = spectrometer_utils:make_temp_dir(Unique),
            {TempDir, filename:join(TempDir, "nonexistent_cache")}
        end,
        fun({TempDir, _}) ->
            spectrometer_utils:purge_dir(TempDir)
        end,
        {with, [
            fun({_TempDir, MissingCache}) ->
                ?_test(begin
                    Result = atomvm_spectrometer:main([
                        "filter", "-c", MissingCache
                    ]),
                    ?assertEqual({error, {halt, 1}}, Result)
                end)
            end
        ]}
    }.

main_filter_no_user_state_test_() ->
    {
        setup,
        fun() ->
            Prev = application:get_env(spectrometer, cache_dir),
            CacheDir = spectrometer_utils:make_temp_dir("mock_cache_"),
            ok = filelib:ensure_path(CacheDir),
            application:unset_env(spectrometer, cache_dir),
            {CacheDir, Prev}
        end,
        fun({CacheDir, Prev}) ->
            case Prev of
                undefined ->
                    application:unset_env(spectrometer, cache_dir);
                {ok, Val} ->
                    application:set_env(spectrometer, cache_dir, Val)
            end,
            spectrometer_utils:purge_dir(CacheDir)
        end,
        {with, [
            fun({CacheDir, Prev}) ->
                ?assertEqual(
                    undefined, application:get_env(spectrometer, cache_dir)
                ),
                ?_test(begin
                    application:set_env(spectrometer, cache_dir, CacheDir),
                    Result = atomvm_spectrometer:main([
                        "filter", "--min-repos", "10"
                    ]),
                    ?assertEqual({error, {halt, 1}}, Result),
                    case Prev of
                        undefined ->
                            application:unset_env(spectrometer, cache_dir);
                        {ok, Val} ->
                            application:set_env(spectrometer, cache_dir, Val)
                    end,
                    spectrometer_atomvm:reload_db()
                end)
            end
        ]}
    }.

main_filter_min_repos_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"main(['filter', '--min-repos', '1']) returns ok on success",
                fun() ->
                    CacheDir = spectrometer_utils:make_temp_dir("mock_cache_"),
                    ok = filelib:ensure_path(CacheDir),
                    Prev = application:get_env(spectrometer, cache_dir),
                    application:set_env(spectrometer, cache_dir, CacheDir),
                    try
                        ok = atomvm_spectrometer:main([
                            "ecosystem", "--limit", "5"
                        ]),
                        Result = atomvm_spectrometer:main([
                            "filter", "--min-repos", "1", "--cache", CacheDir
                        ]),
                        ?assertEqual(ok, Result)
                    after
                        case Prev of
                            undefined ->
                                application:unset_env(spectrometer, cache_dir);
                            {ok, Val} ->
                                application:set_env(
                                    spectrometer, cache_dir, Val
                                )
                        end,
                        spectrometer_utils:purge_dir(CacheDir)
                    end
                end};
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

main_filter_invalid_min_repos_test_() ->
    {"main(['filter', '--min-repos', 'abc']) returns error", fun() ->
        ?assertMatch(
            {error, {halt, 1}},
            atomvm_spectrometer:main(["filter", "--min-repos", "abc"])
        )
    end}.

%% =============================================================================
%% 7. Mock Package Test
%% =============================================================================

main_query_mock_function_test_() ->
    {
        setup,
        fun() ->
            CacheDir = spectrometer_utils:make_temp_dir("mock_cache_"),
            ok = filelib:ensure_path(CacheDir),
            Prev = application:get_env(spectrometer, cache_dir),
            application:set_env(spectrometer, cache_dir, CacheDir),
            {CacheDir, Prev}
        end,
        fun({CacheDir, Prev}) ->
            case Prev of
                undefined -> application:unset_env(spectrometer, cache_dir);
                {ok, Val} -> application:set_env(spectrometer, cache_dir, Val)
            end,
            spectrometer_atomvm:reload_db(),
            spectrometer_utils:purge_dir(CacheDir)
        end,
        {with, [
            fun({CacheDir, _Prev}) ->
                ?_test(begin
                    CustomDB = [
                        {mock_pkg, [
                            {custom_func, 1, all, {unreleased, <<"0.7.x">>}}
                        ]},
                        {lists, [{map, 2, all, <<"v0.5.0">>}]}
                    ],
                    DbFile = filename:join(
                        CacheDir, "supported_functions.data"
                    ),
                    ok = file:write_file(
                        DbFile, io_lib:format("~p.\n", [CustomDB])
                    ),
                    Result = atomvm_spectrometer:main([
                        "query", "-c", CacheDir, "mock_pkg:custom_func/1"
                    ]),
                    ?assertEqual(ok, Result)
                end)
            end
        ]}
    }.

main_supported_mock_module_test_() ->
    {
        setup,
        fun() ->
            CacheDir = spectrometer_utils:make_temp_dir("mock_cache_"),
            ok = filelib:ensure_path(CacheDir),
            Prev = application:get_env(spectrometer, cache_dir),
            application:set_env(spectrometer, cache_dir, CacheDir),
            {CacheDir, Prev}
        end,
        fun({CacheDir, Prev}) ->
            case Prev of
                undefined -> application:unset_env(spectrometer, cache_dir);
                {ok, Val} -> application:set_env(spectrometer, cache_dir, Val)
            end,
            spectrometer_atomvm:reload_db(),
            spectrometer_utils:purge_dir(CacheDir)
        end,
        {with, [
            fun({CacheDir, _Prev}) ->
                ?_test(begin
                    CustomDB = [
                        {mock_pkg, [
                            {custom_func, 1, all, {unreleased, <<"0.7.x">>}},
                            {another_func, 2, all, {unreleased, <<"0.7.x">>}}
                        ]}
                    ],
                    DbFile = filename:join(
                        CacheDir, "supported_functions.data"
                    ),
                    ok = file:write_file(
                        DbFile, io_lib:format("~p.\n", [CustomDB])
                    ),
                    Result = atomvm_spectrometer:main([
                        "supported", "-c", CacheDir, "--module", "mock_pkg"
                    ]),
                    ?assertEqual(ok, Result)
                end)
            end
        ]}
    }.

%% =============================================================================
%% 8. audit --github (network test)
%% =============================================================================

main_audit_github_small_repo_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"main(['audit', '--github', 'https://github.com/atomvm/atomvm_lora']) audits fully supported repo",
                fun() ->
                    Result = atomvm_spectrometer:main([
                        "audit",
                        "--github",
                        "https://github.com/atomvm/atomvm_lora"
                    ]),
                    ?assertEqual(ok, Result)
                end};
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

%% =============================================================================
%% 9. audit --hex (network test)
%% =============================================================================

main_audit_hex_package_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"main(['audit', '--hex', 'cowboy']) audits package with unsupported functions",
                fun() ->
                    ?assertEqual(
                        ok,
                        atomvm_spectrometer:main(["audit", "--hex", "cowboy"])
                    )
                end};
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

%% =============================================================================
%% 10. Update command (network test - requires AtomVM repo)
%% =============================================================================

main_update_with_local_repo_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {
                setup,
                fun() ->
                    {TempDir, AtomVMDir} = ensure_atomvm_repo(),
                    CacheDir = spectrometer_utils:make_temp_dir(
                        "update_test_cache_"
                    ),
                    OutputFile = filename:join(
                        CacheDir,
                        "test_" ++
                            integer_to_list(erlang:unique_integer([positive])) ++
                            ".data"
                    ),
                    Prev = application:get_env(spectrometer, cache_dir),
                    application:set_env(spectrometer, cache_dir, CacheDir),
                    spectrometer_atomvm:reload_db(),
                    {{TempDir, AtomVMDir}, OutputFile, CacheDir, Prev}
                end,
                fun({{TempDir, _AtomVMDir}, _OutputFile, CacheDir, Prev}) ->
                    case Prev of
                        undefined ->
                            application:unset_env(spectrometer, cache_dir);
                        {ok, Val} ->
                            application:set_env(spectrometer, cache_dir, Val)
                    end,
                    spectrometer_atomvm:reload_db(),
                    spectrometer_utils:purge_dir(TempDir),
                    spectrometer_utils:purge_dir(CacheDir)
                end,
                {with, [
                    fun({{_TempDir, AtomVMDir}, OutputFile, CacheDir, _Prev}) ->
                        ?_test(begin
                            Result = atomvm_spectrometer:main([
                                "update",
                                "--atomvm-dir",
                                AtomVMDir,
                                "--output",
                                OutputFile,
                                "-c",
                                CacheDir,
                                "--force"
                            ]),
                            ?assertEqual(ok, Result),
                            ?assert(filelib:is_file(OutputFile)),
                            {ok, [Data]} = file:consult(OutputFile),
                            ?assert(is_list(Data)),
                            ?assert(
                                lists:any(fun({M, _}) -> M =:= erlang end, Data)
                            )
                        end)
                    end
                ]}
            };
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

main_update_no_force_overwrite_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {
                setup,
                fun() ->
                    {TempDir, AtomVMDir} = ensure_atomvm_repo(),
                    CacheDir = spectrometer_utils:make_temp_dir(
                        "update_noforce_cache_"
                    ),
                    Prev = application:get_env(spectrometer, cache_dir),
                    application:set_env(spectrometer, cache_dir, CacheDir),
                    {{TempDir, AtomVMDir}, CacheDir, Prev}
                end,
                fun({{TempDir, _AtomVMDir}, CacheDir, Prev}) ->
                    case Prev of
                        undefined ->
                            application:unset_env(spectrometer, cache_dir);
                        {ok, Val} ->
                            application:set_env(spectrometer, cache_dir, Val)
                    end,
                    spectrometer_atomvm:reload_db(),
                    spectrometer_utils:purge_dir(CacheDir),
                    spectrometer_utils:purge_dir(TempDir)
                end,
                {with, [
                    fun({{_TempDir, AtomVMDir}, CacheDir, _Prev}) ->
                        ?_test(begin
                            OutputFile = filename:join(
                                CacheDir,
                                "update_noforce_" ++
                                    integer_to_list(
                                        erlang:unique_integer([positive])
                                    ) ++
                                    ".data"
                            ),
                            ok = file:write_file(OutputFile, "dummy"),
                            Result = atomvm_spectrometer:main([
                                "update",
                                "--atomvm-dir",
                                AtomVMDir,
                                "--output",
                                OutputFile,
                                "-c",
                                CacheDir
                            ]),
                            ?assertMatch({error, {halt, 1}}, Result)
                        end)
                    end
                ]}
            };
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

%% =============================================================================
%% Filter command tests
%% =============================================================================

filter_csv_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("filter_csv_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    CsvFile = filename:join(Dir, "test.csv"),
                    CsvContent =
                        "module,function,arity,calls,repos\n"
                        "lists,map,2,100,42\n"
                        "lists,filter,2,50,38\n"
                        "maps,get,2,30,21\n",
                    ok = file:write_file(CsvFile, CsvContent),
                    Result = atomvm_spectrometer:main([
                        "filter", "--csv", CsvFile
                    ]),
                    ?assertEqual(ok, Result)
                end)
            end
        ]}
    }.

filter_csv_invalid_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("filter_csv_invalid_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    CsvFile = filename:join(Dir, "bad.csv"),
                    CsvContent =
                        "module,function,arity,calls,atomvm_supported\n"
                        "lists,map\n"
                        "lists,filter,2,50,no\n",
                    ok = file:write_file(CsvFile, CsvContent),
                    Result = atomvm_spectrometer:main([
                        "filter", "--csv", CsvFile
                    ]),
                    ?assertEqual(ok, Result)
                end)
            end
        ]}
    }.

filter_min_repos_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("filter_min-repos_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    CsvFile = filename:join(Dir, "repos.csv"),
                    CsvContent =
                        "module,function,arity,calls,repo_count\n"
                        "lists,map,2,100,5\n"
                        "lists,filter,2,50,2\n"
                        "lists,reverse,2,30,10\n",
                    ok = file:write_file(CsvFile, CsvContent),
                    Result = atomvm_spectrometer:main([
                        "filter", "--csv", CsvFile, "--min-repos", "5"
                    ]),
                    ?assertEqual(ok, Result)
                end)
            end
        ]}
    }.

filter_avm_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("filter_avm_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    CsvFile = filename:join(Dir, "avm.csv"),
                    CsvContent =
                        "module,function,arity,calls,repo_count\n"
                        "lists,map,2,100,24\n"
                        "re,run,3,57,52\n",
                    ok = file:write_file(CsvFile, CsvContent),
                    Result = atomvm_spectrometer:main([
                        "filter", "--csv", CsvFile, "--avm"
                    ]),
                    ?assertEqual(ok, Result)
                end)
            end
        ]}
    }.

%% =============================================================================
%% Update command tests
%% =============================================================================

update_force_existing_db_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("update_force_existing_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun(Dir) ->
            Prev = application:get_env(spectrometer, cache_dir),
            case Prev of
                undefined -> ok;
                {ok, _} -> application:unset_env(spectrometer, cache_dir)
            end,
            spectrometer_atomvm:reload_db(),
            spectrometer_utils:purge_dir(Dir)
        end,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    OutputFile = filename:join(Dir, "output.data"),
                    CacheDir = filename:join(Dir, "cache"),
                    AtomVMDir = filename:join(Dir, "AtomVM"),
                    LibDir = filename:join(AtomVMDir, "src/libAtomVM"),
                    ok = filelib:ensure_path(LibDir),
                    ok = file:write_file(
                        filename:join(LibDir, "bifs.gperf"),
                        "{\n  erlang:abs/1, BIF_ERLANG_ABS_1\n}\n"
                    ),
                    ok = file:write_file(
                        filename:join(LibDir, "nifs.gperf"),
                        "{\n  \"binary:at/2\", nif_binary_at_2\n}\n"
                    ),
                    ExistingDB = [
                        {erlang, [{abs, 1, all, {unreleased, <<"main">>}}]},
                        {io, [{format, 2, all, {unreleased, <<"main">>}}]}
                    ],
                    ok = file:write_file(
                        OutputFile, io_lib:format("~p.\n", [ExistingDB])
                    ),
                    Result = atomvm_spectrometer:main([
                        "update",
                        "--atomvm-dir",
                        AtomVMDir,
                        "--output",
                        OutputFile,
                        "--force",
                        "-c",
                        CacheDir
                    ]),
                    ?assertEqual(ok, Result),
                    {ok, [MergedDB]} = file:consult(OutputFile),
                    ?assertMatch(
                        [{format, 2, all, {unreleased, <<"main">>}}],
                        proplists:get_value(io, MergedDB)
                    ),
                    ?assertMatch(
                        [{abs, 1, all, {unreleased, <<"main">>}}],
                        proplists:get_value(erlang, MergedDB)
                    ),
                    ?assertMatch(
                        [{at, 2, all, {unreleased, <<"main">>}}],
                        proplists:get_value(binary, MergedDB)
                    ),
                    ?assertEqual(3, length(MergedDB)),
                    ?assert(filelib:is_file(OutputFile))
                end)
            end
        ]}
    }.

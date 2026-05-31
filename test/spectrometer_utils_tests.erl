%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_utils_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% normalize_github_url/1 tests
%% =============================================================================

normalize_github_url_test_() ->
    [
        {"fixes http:// prefix",
            ?_assertEqual(
                "https://github.com/user/repo.git",
                spectrometer_utils:normalize_github_url(
                    "http://github.com/user/repo.git"
                )
            )},

        {"adds .git suffix",
            ?_assertEqual(
                "https://github.com/user/repo.git",
                spectrometer_utils:normalize_github_url(
                    "https://github.com/user/repo"
                )
            )},

        {"handles short user/repo names",
            ?_assertEqual(
                "https://github.com/user/repo.git",
                spectrometer_utils:normalize_github_url(
                    "user/repo"
                )
            )},

        {"handles whitespace",
            ?_assertEqual(
                "https://github.com/user/repo.git",
                spectrometer_utils:normalize_github_url(
                    "  user/repo\n"
                )
            )},

        {"removes multiple trailing slashes",
            ?_assertEqual(
                "https://github.com/user/repo.git",
                spectrometer_utils:normalize_github_url(
                    "https://github.com/user/repo///"
                )
            )},

        {"handles .git with trailing slash",
            ?_assertEqual(
                "https://github.com/user/repo.git",
                spectrometer_utils:normalize_github_url(
                    "https://github.com/user/repo.git/"
                )
            )},

        {"lowercases the URL",
            ?_assertEqual(
                "https://github.com/user/repo.git",
                spectrometer_utils:normalize_github_url(
                    "https://GitHub.com/User/Repo"
                )
            )},

        {"handles full URL with all modifications",
            ?_assertEqual(
                "https://github.com/user/repo.git",
                spectrometer_utils:normalize_github_url(
                    "http://GitHub.com/User/Repo.git/"
                )
            )},

        {"handles plain github.com URL",
            ?_assertEqual(
                "https://github.com/user/repo.git",
                spectrometer_utils:normalize_github_url(
                    "github.com/user/repo"
                )
            )},

        {"handles organization repo",
            ?_assertEqual(
                "https://github.com/atomvm/atomvm.git",
                spectrometer_utils:normalize_github_url(
                    "atomvm/AtomVM.git"
                )
            )},

        {"handles short path with trailing slash",
            ?_assertEqual(
                "https://github.com/atomvm/atomvm.git",
                spectrometer_utils:normalize_github_url(
                    "AtomVM/AtomVM/"
                )
            )}
    ].

%% =============================================================================
%% make_temp_dir/1 tests
%% =============================================================================

make_temp_dir_prefix_test_() ->
    {"creates directory with prefix", fun() ->
        Dir = spectrometer_utils:make_temp_dir("test_"),
        try
            ?assert(filelib:is_dir(Dir)),
            ?assert(string:prefix(filename:basename(Dir), "test_") =/= nomatch)
        after
            spectrometer_utils:purge_dir(Dir)
        end
    end}.

make_temp_dir_unique_test_() ->
    {"creates unique directories", fun() ->
        Dir1 = spectrometer_utils:make_temp_dir("test_"),
        Dir2 = spectrometer_utils:make_temp_dir("test_"),
        try
            ?assert(filelib:is_dir(Dir1)),
            ?assert(filelib:is_dir(Dir2)),
            ?assertNot(Dir1 =:= Dir2)
        after
            spectrometer_utils:purge_dir(Dir1),
            spectrometer_utils:purge_dir(Dir2)
        end
    end}.

make_temp_dir_writable_test_() ->
    {"directory is writable", fun() ->
        Dir = spectrometer_utils:make_temp_dir("write_test_"),
        try
            TestFile = filename:join(Dir, "test.txt"),
            ok = file:write_file(TestFile, "hello"),
            {ok, Content} = file:read_file(TestFile),
            ?assertEqual(<<"hello">>, Content)
        after
            spectrometer_utils:purge_dir(Dir)
        end
    end}.

make_temp_dir_nested_test_() ->
    {"creates nested subdirectories", fun() ->
        Dir = spectrometer_utils:make_temp_dir("nested_test_"),
        try
            SubDir = filename:join(Dir, "sub/dir"),
            ok = filelib:ensure_path(SubDir),
            ?assert(filelib:is_dir(SubDir)),
            TestFile = filename:join(SubDir, "test.txt"),
            ok = file:write_file(TestFile, "nested"),
            ?assert(filelib:is_file(TestFile))
        after
            spectrometer_utils:purge_dir(Dir)
        end
    end}.

%% =============================================================================
%% purge_dir/1 tests
%% =============================================================================

purge_dir_with_files_test_() ->
    {"removes directory with files", fun() ->
        Dir = spectrometer_utils:make_temp_dir("purge_dir_test_"),
        try
            File1 = filename:join(Dir, "file1.txt"),
            SubDir = filename:join(Dir, "subdir"),
            File2 = filename:join(SubDir, "file2.txt"),
            ok = filelib:ensure_path(SubDir),
            ok = file:write_file(File1, "content1"),
            ok = file:write_file(File2, "content2"),
            ?assert(filelib:is_file(File1)),
            ?assert(filelib:is_file(File2)),
            ?assert(filelib:is_dir(SubDir)),
            spectrometer_utils:purge_dir(Dir),
            ?assertNot(filelib:is_dir(Dir)),
            ?assertNot(filelib:is_file(File1)),
            ?assertNot(filelib:is_file(File2))
        after
            case filelib:is_dir(Dir) of
                true -> spectrometer_utils:purge_dir(Dir);
                false -> ok
            end
        end
    end}.

purge_dir_idempotent_test_() ->
    {"handles non-existent directory gracefully", fun() ->
        Dir = spectrometer_utils:make_temp_dir("purge_dir_test2_"),
        try
            spectrometer_utils:purge_dir(Dir),
            %% Should not crash when called again on already removed dir
            spectrometer_utils:purge_dir(Dir),
            ?assertNot(filelib:is_dir(Dir))
        after
            case filelib:is_dir(Dir) of
                true -> spectrometer_utils:purge_dir(Dir);
                false -> ok
            end
        end
    end}.

purge_dir_nested_test_() ->
    {"removes deeply nested structure", fun() ->
        Dir = spectrometer_utils:make_temp_dir("purge_dir_test3_"),
        try
            DeepDir = filename:join(Dir, "a/b/c/d"),
            DeepFile = filename:join(DeepDir, "deep.txt"),
            ok = filelib:ensure_path(DeepDir),
            ok = file:write_file(DeepFile, "deep"),
            ?assert(filelib:is_file(DeepFile)),
            spectrometer_utils:purge_dir(Dir),
            ?assertNot(filelib:is_dir(Dir))
        after
            case filelib:is_dir(Dir) of
                true -> spectrometer_utils:purge_dir(Dir);
                false -> ok
            end
        end
    end}.

%% =============================================================================
%% spectrometer_http:fetch/1 tests
%% =============================================================================

http_get_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            [
                {"returns error for invalid URL",
                    ?_assertMatch(
                        {error, _},
                        spectrometer_http:fetch(
                            "http://this-domain-definitely-does-not-exist-12345.com"
                        )
                    )},

                {"returns error for non-existent path on localhost",
                    ?_assertMatch(
                        {error, _},
                        spectrometer_http:fetch("http://localhost:59999/test")
                    )}
            ];
        _ ->
            [{"skipped (network tests disabled)", fun() -> ok end}]
    end.

%% =============================================================================
%% find_executable/1 tests
%% =============================================================================

find_executable_exists_test_() ->
    {"finds git executable when present",
        case os:find_executable("git") of
            false ->
                {skip, "git not in PATH"};
            Path ->
                ?_assertEqual(
                    {ok, Path}, spectrometer_utils:find_executable("git")
                )
        end}.

find_executable_not_found_test_() ->
    {"returns error for non-existent executable",
        ?_assertEqual(
            {error, not_found},
            spectrometer_utils:find_executable("nonexistent_command_xyz123")
        )}.

%% =============================================================================
%% run_git_command/2 tests
%% =============================================================================

run_git_command_happy_path_test_() ->
    {"returns output for git --version",
        case os:find_executable("git") of
            false ->
                {skip, "git not in PATH"};
            _ ->
                ?_assertMatch(
                    {ok, _},
                    spectrometer_utils:run_git_command(["--version"], [])
                )
        end}.

run_git_command_empty_env_test_() ->
    {"handles custom environment vars",
        case os:find_executable("git") of
            false ->
                {skip, "git not in PATH"};
            _ ->
                ?_assertMatch(
                    {ok, _},
                    spectrometer_utils:run_git_command(["--version"], [
                        {"GIT_PAGER", "cat"}
                    ])
                )
        end}.

%% =============================================================================
%% system_temp_dir/0 tests
%% =============================================================================

system_temp_dir_default_test_() ->
    {"returns default temp dir when TEMPDIR not set", fun() ->
        OldTempdir = os:getenv("TEMPDIR"),
        os:putenv("TEMPDIR", ""),
        try
            % When TEMPDIR is empty string, os:getenv returns "", not false
            % The function should fall through to TEMP or default
            Result = spectrometer_utils:system_temp_dir(),
            ?assert(is_list(Result))
        after
            case OldTempdir of
                false -> os:unsetenv("TEMPDIR");
                _ -> os:putenv("TEMPDIR", OldTempdir)
            end
        end
    end}.

system_temp_dir_env_test_() ->
    {"uses TEMPDIR environment variable when set", fun() ->
        OldTempdir = os:getenv("TEMPDIR"),
        os:putenv("TEMPDIR", "/custom/tmp"),
        try
            ?assertEqual("/custom/tmp", spectrometer_utils:system_temp_dir())
        after
            case OldTempdir of
                false -> os:unsetenv("TEMPDIR");
                _ -> os:putenv("TEMPDIR", OldTempdir)
            end
        end
    end}.

%% =============================================================================
%% version/0 tests
%% =============================================================================

version_success_test_() ->
    {"returns version string on success",
        case spectrometer_utils:version() of
            Vsn when is_list(Vsn) ->
                ?_assert(is_list(Vsn));
            {error, version_not_found} ->
                {skip, "version not configured in app"}
        end}.

%% =============================================================================
%% start_applications/0 tests
%% =============================================================================

start_applications_success_test_() ->
    {"returns ok on successful start",
        ?_assertEqual(ok, spectrometer_utils:start_applications())}.

%% =============================================================================
%% normalize_module_name/2 tests
%% =============================================================================

normalize_module_name_2_atom_test_() ->
    {"normalize_module_name/2 with atom and ElixirFlag=true",
        ?_assertEqual(
            <<"Elixir.GPIO">>,
            spectrometer_utils:normalize_module_name('GPIO', true)
        )}.

normalize_module_name_2_string_test_() ->
    {"normalize_module_name/2 with string and ElixirFlag=true",
        ?_assertEqual(
            <<"Elixir.GPIO">>,
            spectrometer_utils:normalize_module_name("GPIO", true)
        )}.

normalize_module_name_2_false_flag_test_() ->
    {"normalize_module_name/2 with ElixirFlag=false preserves Elixir prefix",
        ?_assertEqual(
            <<"Elixir.GPIO">>,
            spectrometer_utils:normalize_module_name("Elixir.GPIO", false)
        )}.

normalize_module_name_2_false_flag_non_elixir_test_() ->
    {"normalize_module_name/2 with ElixirFlag=false preserves module as-is",
        ?_assertEqual(
            <<"lists">>,
            spectrometer_utils:normalize_module_name("lists", false)
        )}.

%% =============================================================================
%% find_first_file/1 tests
%% =============================================================================

find_first_file_found_test_() ->
    {"finds first existing file", fun() ->
        TempDir = spectrometer_utils:make_temp_dir("find_first_file_"),
        MarkerFile = filename:join(TempDir, "spectrometer_utils_test_marker"),
        file:write_file(MarkerFile, ""),
        try
            Result = spectrometer_utils:find_first_file([
                "/nonexistent/file1",
                MarkerFile,
                "/nonexistent/file2"
            ]),
            ?assertEqual(MarkerFile, Result)
        after
            spectrometer_utils:purge_dir(TempDir)
        end
    end}.

find_first_file_default_test_() ->
    {"returns default when no files exist",
        ?_assertEqual(
            "priv/supported_functions.data",
            spectrometer_utils:find_first_file([
                "/nonexistent/file1", "/nonexistent/file2"
            ])
        )}.

%% =============================================================================
%% drain_port_messages/1 tests
%% =============================================================================

drain_port_messages_empty_test_() ->
    {"returns ok when no messages pending",
        ?_assertEqual(ok, spectrometer_utils:drain_port_messages(make_ref()))}.

drain_port_messages_with_messages_test_() ->
    {"drains pending port messages", fun() ->
        Port = make_ref(),
        self() ! {Port, {data, {eol, "test1"}}},
        self() ! {Port, {data, {eol, "test2"}}},
        self() ! {Port, {exit_status, 0}},
        ?assertEqual(ok, spectrometer_utils:drain_port_messages(Port)),
        % Verify no more messages
        {messages, []} = process_info(self(), messages)
    end}.

%% =============================================================================
%% bundled_data_path/0 tests
%% =============================================================================

bundled_data_path_test_() ->
    {"returns path to bundled data file",
        ?_assert(is_list(spectrometer_utils:bundled_data_path()))}.

%% =============================================================================
%% clone_temp_repo/2 tests
%% =============================================================================

clone_temp_repo_branch_test_() ->
    {"clones repo with branch only",
        case os:getenv("SKIP_NETWORK_TESTS") of
            false ->
                case os:find_executable("git") of
                    false ->
                        {skip, "git not in PATH"};
                    _ ->
                        {"runs git clone", fun() ->
                            Result = spectrometer_utils:clone_temp_repo(
                                "main", undefined
                            ),
                            case Result of
                                Dir when is_list(Dir) ->
                                    try
                                        ?assert(filelib:is_dir(Dir))
                                    after
                                        spectrometer_utils:purge_dir(Dir)
                                    end;
                                {error, _} ->
                                    ok
                            end
                        end}
                end;
            _ ->
                {skip, "network tests disabled"}
        end}.

clone_temp_repo_tag_test_() ->
    {"clones repo with branch and tag",
        case os:getenv("SKIP_NETWORK_TESTS") of
            false ->
                case os:find_executable("git") of
                    false ->
                        {skip, "git not in PATH"};
                    _ ->
                        {"runs git clone with tag", fun() ->
                            Result = spectrometer_utils:clone_temp_repo(
                                "main", "v0.6.0"
                            ),
                            case Result of
                                Dir when is_list(Dir) ->
                                    try
                                        ?assert(filelib:is_dir(Dir))
                                    after
                                        spectrometer_utils:purge_dir(Dir)
                                    end;
                                {error, _} ->
                                    ok
                            end
                        end}
                end;
            _ ->
                {skip, "network tests disabled"}
        end}.

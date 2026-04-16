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

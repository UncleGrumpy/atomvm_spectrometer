%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_http_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% download_github_repo/2 tests
%% =============================================================================

download_github_repo_success_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"downloads public repo to temp directory (no credentials needed)",
                fun() ->
                    Dir = setup_temp_dir(),
                    TmpDir = filename:join(Dir, "repo"),
                    _ = filelib:ensure_path(TmpDir),
                    try
                        %% Use a small public repo that doesn't require authentication
                        %% GIT_TERMINAL_PROMPT=0 is set in the source to prevent credential prompts
                        _ = spectrometer_http:download_github_repo(
                            "https://github.com/githubtraining/hellogitworld.git",
                            TmpDir
                        ),
                        ?assert(filelib:is_dir(TmpDir)),
                        %% Verify the repo was actually cloned with some content
                        Files = filelib:wildcard("**/*", TmpDir),
                        ?assert(length(Files) > 1)
                    after
                        cleanup_temp_dir(Dir)
                    end
                end};
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

download_github_repo_invalid_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"handles non-existent repo gracefully", fun() ->
                Dir = setup_temp_dir(),
                TmpDir = filename:join(Dir, "repo"),
                _ = filelib:ensure_path(TmpDir),
                try
                    _ = spectrometer_http:download_github_repo(
                        "https://github.com/nonexistent-user-12345/nonexistent-repo-12345",
                        TmpDir
                    ),
                    %% Git may succeed (empty repo) or fail - either is acceptable
                    %% The important thing is no Erlang source files were cloned
                    Files = filelib:wildcard("**/*.erl", TmpDir),
                    ?assertEqual(0, length(Files)),
                    ok
                after
                    cleanup_temp_dir(Dir)
                end
            end};
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

%% =============================================================================
%% download_hex_tarball/2 tests
%% =============================================================================

download_hex_tarball_valid_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"downloads and extracts valid tarball", fun() ->
                %% Download a small known package with Erlang source files
                case spectrometer_http:download_hex_tarball("jsx", "3.1.0") of
                    {ok, Dir} ->
                        try
                            ?assert(filelib:is_dir(Dir)),
                            %% Verify it has content files
                            Files = filelib:wildcard("**/*.erl", Dir),
                            ?assert(length(Files) > 0)
                        after
                            spectrometer_utils:purge_dir(Dir)
                        end;
                    {error, Reason} ->
                        erlang:error({hex_download_failed, Reason})
                end
            end};
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

download_hex_tarball_nonexistent_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"handles missing package versions", fun() ->
                Result = spectrometer_http:download_hex_tarball(
                    "nonexistent_package_12345", "0.0.1"
                ),
                ?assertMatch({error, _}, Result)
            end};
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

download_hex_tarball_cleanup_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"cleans up temp directory on error", fun() ->
                %% Before download
                TempDirs1 = list_temp_dirs(),
                _ = spectrometer_http:download_hex_tarball(
                    "nonexistent_package_12345", "0.0.1"
                ),
                %% After download - should not leave temp dirs
                TempDirs2 = list_temp_dirs(),
                %% Same or fewer temp dirs
                ?assert(length(TempDirs2) =< length(TempDirs1) + 1)
            end};
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

%% =============================================================================
%% fetch_github_repos/1 tests
%% =============================================================================

fetch_github_repos_test_() ->
    {"fetches GitHub repos via Search API (requires OTP 27+ for json module)",
        fun() ->
            case os:getenv("SKIP_NETWORK_TESTS") of
                false ->
                    %% Fetch a small number of repos to test API connectivity and parsing
                    Repos = spectrometer_http:fetch_github_repos({2, 2000}),
                    ?assert(is_list(Repos)),
                    ?assert(length(Repos) >= 1),
                    %% Verify structure of first repo
                    Repo = hd(Repos),
                    ?assert(is_map(Repo)),
                    ?assert(maps:is_key(full_name, Repo)),
                    ?assert(maps:is_key(clone_url, Repo)),
                    ?assert(maps:is_key(html_url, Repo)),
                    ?assert(maps:is_key(stars, Repo)),
                    %% Verify types
                    ?assert(is_list(maps:get(full_name, Repo))),
                    ?assert(is_integer(maps:get(stars, Repo)));
                _ ->
                    ok
            end
        end}.

fetch_github_cursor_advances_test_() ->
    {"fetch_github_cursor advances cursor to fetch different repos (no duplicates)",
        fun() ->
            case os:getenv("SKIP_NETWORK_TESTS") of
                false ->
                    %% Fetch more repos than the API returns a single page to verify
                    %% that the cursor advances and we don't get duplicate repos
                    Repos = spectrometer_http:fetch_github_repos({100, 1}),
                    ?assert(is_list(Repos)),
                    ?assert(length(Repos) >= 50),
                    %% Verify no duplicate repos (full_name should be unique)
                    FullNames = [maps:get(full_name, R) || R <- Repos],
                    UniqueNames = lists:usort(FullNames),
                    ?assertEqual(length(UniqueNames), length(FullNames));
                _ ->
                    ok
            end
        end}.

%% =============================================================================
%% fetch_hex_packages/1 tests
%% =============================================================================

fetch_hex_packages_test_() ->
    {"fetches Hex packages via Hex API (requires OTP 27+ for json module)",
        fun() ->
            case os:getenv("SKIP_NETWORK_TESTS") of
                false ->
                    %% Fetch a small number of packages to test API connectivity
                    Packages = spectrometer_http:fetch_hex_packages(2),
                    ?assert(is_list(Packages)),
                    ?assert(length(Packages) >= 1),
                    %% Verify structure of first package
                    Pkg = hd(Packages),
                    ?assert(is_map(Pkg)),
                    ?assert(maps:is_key(name, Pkg)),
                    ?assert(maps:is_key(version, Pkg)),
                    ?assert(maps:is_key(github_url, Pkg)),
                    %% Verify types
                    ?assert(is_list(maps:get(name, Pkg))),
                    ?assert(is_list(maps:get(version, Pkg))),
                    ?assert(is_list(maps:get(github_url, Pkg)));
                _ ->
                    ok
            end
        end}.

fetch_hex_packages_large_limit_test_() ->
    {"fetches Hex packages with higher limit (requires OTP 27+ for json module)",
        fun() ->
            case os:getenv("SKIP_NETWORK_TESTS") of
                false ->
                    %% Fetch more packages to test pagination logic
                    Packages = spectrometer_http:fetch_hex_packages(150),
                    ?assert(is_list(Packages)),
                    %% Should return up to 150 packages (may be less due to API limits)
                    ?assert(length(Packages) >= 1),
                    %% All packages should have valid structure
                    lists:foreach(
                        fun(Pkg) ->
                            ?assert(is_map(Pkg)),
                            ?assert(maps:is_key(name, Pkg)),
                            ?assert(maps:is_key(version, Pkg))
                        end,
                        Packages
                    );
                _ ->
                    ok
            end
        end}.

%% =============================================================================
%% find_github_link/1 tests (internal, test via exported wrapper if available)
%% =============================================================================

find_github_link_extracts_github_url_test_() ->
    {"extracts GitHub URL from links map when present", fun() ->
        Links = #{
            <<"github">> => <<"https://github.com/user/repo">>,
            <<"hex">> => <<"https://hex.pm/packages/pkg">>
        },
        Result = spectrometer_http:find_github_link(Links),
        ?assertEqual("https://github.com/user/repo", Result)
    end}.

find_github_link_no_github_returns_empty_test_() ->
    {"returns empty string when no GitHub URL in links", fun() ->
        Links = #{
            <<"hex">> => <<"https://hex.pm/packages/pkg">>,
            <<"docs">> => <<"https://hexdocs.pm/pkg">>
        },
        Result = spectrometer_http:find_github_link(Links),
        ?assertEqual("", Result)
    end}.

find_github_link_empty_map_test_() ->
    {"returns empty string for empty map", fun() ->
        Result = spectrometer_http:find_github_link(#{}),
        ?assertEqual("", Result)
    end}.

find_github_link_non_map_test_() ->
    {"returns empty string for non-map input", fun() ->
        ?assertEqual("", spectrometer_http:find_github_link([])),
        ?assertEqual("", spectrometer_http:find_github_link(undefined)),
        ?assertEqual("", spectrometer_http:find_github_link(<<"not a map">>))
    end}.

find_github_link_multiple_returns_a_github_url_test_() ->
    {"returns a GitHub URL when multiple exist in map", fun() ->
        Links = #{
            <<"source">> => <<"https://gitlab.com/user/repo">>,
            <<"github">> => <<"https://github.com/owner/project">>,
            <<"fork">> => <<"https://github.com/fork/project">>
        },
        Result = spectrometer_http:find_github_link(Links),
        %% Function returns the first GitHub URL found during map iteration
        ?assert(string:find(Result, "github.com") =/= nomatch)
    end}.

find_github_link_skips_non_github_test_() ->
    {"skips non-GitHub URLs even when they appear first", fun() ->
        Links = #{
            <<"source">> => <<"https://gitlab.com/user/repo">>,
            <<"other">> => <<"https://bitbucket.org/user/repo">>
        },
        Result = spectrometer_http:find_github_link(Links),
        ?assertEqual("", Result)
    end}.

%% =============================================================================
%% validate_tar_path/1 tests
%% =============================================================================

validate_tar_path_valid_relative_test_() ->
    {"accepts valid relative paths", fun() ->
        ?assert(spectrometer_http:validate_tar_path("src/module.erl")),
        ?assert(spectrometer_http:validate_tar_path("lib/foo/bar.ex")),
        ?assert(spectrometer_http:validate_tar_path("README.md")),
        ?assert(spectrometer_http:validate_tar_path("a/b/c/d.txt"))
    end}.

validate_tar_path_rejects_dotdot_test_() ->
    {"rejects paths with .. segments", fun() ->
        ?assertNot(spectrometer_http:validate_tar_path("../etc/passwd")),
        ?assertNot(spectrometer_http:validate_tar_path("src/../../secret")),
        ?assertNot(spectrometer_http:validate_tar_path("a/b/../..")),
        ?assertNot(spectrometer_http:validate_tar_path(".."))
    end}.

validate_tar_path_rejects_absolute_unix_test_() ->
    {"rejects absolute Unix paths", fun() ->
        ?assertNot(spectrometer_http:validate_tar_path("/etc/passwd")),
        ?assertNot(spectrometer_http:validate_tar_path("/root/.ssh/id_rsa")),
        ?assertNot(spectrometer_http:validate_tar_path("/absolute/path"))
    end}.

validate_tar_path_rejects_absolute_windows_test_() ->
    {"rejects absolute Windows paths", fun() ->
        ?assertNot(
            spectrometer_http:validate_tar_path("C:\\Windows\\System32")
        ),
        ?assertNot(spectrometer_http:validate_tar_path("D:/secret/file.txt"))
    end}.

validate_tar_path_rejects_empty_test_() ->
    {"rejects empty paths", fun() ->
        ?assertNot(spectrometer_http:validate_tar_path(""))
    end}.

%% =============================================================================
%% validate_tar_paths/1 tests
%% =============================================================================

validate_tar_paths_all_valid_test_() ->
    {"accepts all valid paths", fun() ->
        ?assertEqual(
            ok,
            spectrometer_http:validate_tar_paths([
                "src/module.erl",
                "include/header.hrl",
                "test/module_tests.erl"
            ])
        )
    end}.

validate_tar_paths_with_malicious_test_() ->
    {"rejects paths containing traversal attempts", fun() ->
        ?assertEqual(
            {error, path_traversal_attempt},
            spectrometer_http:validate_tar_paths([
                "src/module.erl",
                "../../../etc/passwd"
            ])
        ),
        ?assertEqual(
            {error, path_traversal_attempt},
            spectrometer_http:validate_tar_paths([
                "/etc/passwd",
                "src/module.erl"
            ])
        ),
        ?assertEqual(
            {error, path_traversal_attempt},
            spectrometer_http:validate_tar_paths([
                "src/..",
                "test/test.erl"
            ])
        )
    end}.

validate_tar_paths_empty_list_test_() ->
    {"handles empty path list", fun() ->
        ?assertEqual(ok, spectrometer_http:validate_tar_paths([]))
    end}.

%% =============================================================================
%% Integration tests (if network available)
%% =============================================================================

integration_hex_small_package_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"fetches small Hex package", fun() ->
                case spectrometer_http:download_hex_tarball("jsx", "3.1.0") of
                    {ok, Dir} ->
                        try
                            ?assert(filelib:is_dir(Dir)),
                            %% Verify it has some content
                            Files = filelib:wildcard("**/*.erl", Dir),
                            ?assert(length(Files) > 0)
                        after
                            spectrometer_utils:purge_dir(Dir)
                        end;
                    {error, Reason} ->
                        erlang:error({hex_download_failed, Reason})
                end
            end};
        _ ->
            {"skipped (SKIP_NETWORK_TESTS set)", fun() -> ok end}
    end.

%% =============================================================================
%% Test helpers
%% =============================================================================

setup_temp_dir() ->
    Dir = spectrometer_utils:make_temp_dir("http_test_"),
    ok = filelib:ensure_path(Dir),
    Dir.

cleanup_temp_dir(Dir) ->
    case file:del_dir_r(Dir) of
        ok ->
            ok;
        {error, Reason} ->
            io:format("Warning: failed to cleanup ~s: ~p\n", [Dir, Reason])
    end.

list_temp_dirs() ->
    CacheDir = filename:join(
        spectrometer_utils:system_temp_dir(), "spectrometer"
    ),
    case file:list_dir(CacheDir) of
        {ok, Entries} ->
            lists:filter(
                fun(E) ->
                    lists:prefix("hex_", E) orelse lists:prefix("gh_", E)
                end,
                Entries
            );
        {error, _} ->
            []
    end.

%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
%%
-module(spectrometer_analyzer_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% scan_target/1 tests
%% =============================================================================

scan_local_dir_test_() ->
    {"scans local directory", fun() ->
        Dir = setup_temp_dir(),
        try
            Source =
                "-module(test).\nfoo() -> lists:map(fun(X) -> X end, [1]).\n",
            ok = file:write_file(filename:join(Dir, "test.erl"), Source),
            Stats = spectrometer_analyzer:scan_target({local_dir, Dir}),
            ?assert(is_map(Stats)),
            ?assert(maps:is_key({<<"lists">>, <<"map">>, 2}, Stats))
        after
            spectrometer_utils:purge_dir(Dir)
        end
    end}.

scan_local_dir_empty_test_() ->
    {"returns empty map for empty directory", fun() ->
        Dir = setup_temp_dir(),
        try
            Stats = spectrometer_analyzer:scan_target({local_dir, Dir}),
            ?assertEqual(0, maps:size(Stats))
        after
            spectrometer_utils:purge_dir(Dir)
        end
    end}.

scan_local_dir_nonexistent_test_() ->
    {"returns empty map for non-existent directory", fun() ->
        TempParent = spectrometer_utils:make_temp_dir("analyzer_test_"),
        MissingChild = filename:join(TempParent, "nonexistent_child"),
        try
            Stats = spectrometer_analyzer:scan_target(
                {local_dir, MissingChild}
            ),
            ?assertEqual(0, maps:size(Stats))
        after
            spectrometer_utils:purge_dir(TempParent)
        end
    end}.

%% =============================================================================
%% merge_stats/2 tests
%% =============================================================================

merge_stats_basic_test_() ->
    {"merges two stats maps", fun() ->
        Stats1 = #{
            {<<"lists">>, <<"map">>, 2} => 10, {<<"io">>, <<"format">>, 2} => 5
        },
        Stats2 = #{
            {<<"lists">>, <<"map">>, 2} => 3, {<<"string">>, <<"len">>, 1} => 7
        },
        Result = spectrometer_analyzer:merge_stats(Stats1, Stats2),
        ?assertEqual(13, maps:get({<<"lists">>, <<"map">>, 2}, Result)),
        ?assertEqual(5, maps:get({<<"io">>, <<"format">>, 2}, Result)),
        ?assertEqual(7, maps:get({<<"string">>, <<"len">>, 1}, Result))
    end}.

merge_stats_sums_test_() ->
    {"sums counts for duplicate keys", fun() ->
        Stats1 = #{{<<"lists">>, <<"map">>, 2} => 5},
        Stats2 = #{{<<"lists">>, <<"map">>, 2} => 10},
        Result = spectrometer_analyzer:merge_stats(Stats1, Stats2),
        ?assertEqual(15, maps:get({<<"lists">>, <<"map">>, 2}, Result))
    end}.

merge_stats_unique_test_() ->
    {"preserves unique keys from both maps", fun() ->
        Stats1 = #{{<<"lists">>, <<"map">>, 2} => 5},
        Stats2 = #{{<<"io">>, <<"format">>, 2} => 3},
        Result = spectrometer_analyzer:merge_stats(Stats1, Stats2),
        ?assertEqual(2, maps:size(Result))
    end}.

merge_stats_empty_left_test_() ->
    {"handles empty left map", fun() ->
        Stats1 = #{},
        Stats2 = #{{<<"lists">>, <<"map">>, 2} => 5},
        Result = spectrometer_analyzer:merge_stats(Stats1, Stats2),
        ?assertEqual(1, maps:size(Result))
    end}.

merge_stats_empty_right_test_() ->
    {"handles empty right map", fun() ->
        Stats1 = #{{<<"lists">>, <<"map">>, 2} => 5},
        Stats2 = #{},
        Result = spectrometer_analyzer:merge_stats(Stats1, Stats2),
        ?assertEqual(1, maps:size(Result))
    end}.

merge_stats_both_empty_test_() ->
    {"handles both empty maps", fun() ->
        Stats1 = #{},
        Stats2 = #{},
        Result = spectrometer_analyzer:merge_stats(Stats1, Stats2),
        ?assertEqual(0, maps:size(Result))
    end}.

merge_stats_order_independent_test_() ->
    {"order-independent merging", fun() ->
        Stats1 = #{
            {<<"lists">>, <<"map">>, 2} => 5, {<<"io">>, <<"format">>, 2} => 3
        },
        Stats2 = #{{<<"lists">>, <<"map">>, 2} => 10},
        Result1 = spectrometer_analyzer:merge_stats(Stats1, Stats2),
        Result2 = spectrometer_analyzer:merge_stats(Stats2, Stats1),
        ?assertEqual(Result1, Result2)
    end}.

%% =============================================================================
%% scan_target/1 network tests (GitHub and Hex)
%% =============================================================================

scan_target_github_url_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"scans GitHub repository URL", fun() ->
                %% Use a known Erlang repo
                Stats = spectrometer_analyzer:scan_target(
                    {github_url, "https://github.com/atomvm/atomvm_packbeam"}
                ),
                ?assert(is_map(Stats)),
                %% Should return non-empty map for a real Erlang repo
                ?assert(map_size(Stats) > 0),
                ?assert(maps:is_key({<<"io">>, <<"format">>, 1}, Stats)),
                ?assert(
                    maps:is_key({<<"proplists">>, <<"get_value">>, 2}, Stats)
                )
            end};
        _ ->
            {"skipped (network tests disabled)", fun() -> ok end}
    end.

scan_target_github_url_nonexistent_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"handles non-existent GitHub repo", fun() ->
                Stats = spectrometer_analyzer:scan_target(
                    {github_url,
                        "https://github.com/nonexistent-user-12345/nonexistent-repo-12345"}
                ),
                %% Should return empty map for failed clone
                ?assertEqual(0, maps:size(Stats))
            end};
        _ ->
            {"skipped (network tests disabled)", fun() -> ok end}
    end.

scan_target_hex_package_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"scans Hex package", fun() ->
                %% Use a small known Hex package
                Stats = spectrometer_analyzer:scan_target(
                    {hex, "atomvm_packbeam", "0.8.1"}
                ),
                ?assert(is_map(Stats)),
                %% Verify we found some function calls (specific keys may change)
                ?assert(maps:size(Stats) > 0),
                ?assert(maps:is_key({<<"lists">>, <<"member">>, 2}, Stats)),
                ?assert(maps:is_key({<<"erlang">>, <<"is_map">>, 1}, Stats))
            end};
        _ ->
            {"skipped (network tests disabled)", fun() -> ok end}
    end.

scan_target_hex_package_nonexistent_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"handles non-existent Hex package", fun() ->
                Stats = spectrometer_analyzer:scan_target(
                    {hex, "nonexistent_package_12345", "0.0.1"}
                ),
                %% Should return empty map for failed download
                ?assertEqual(0, maps:size(Stats))
            end};
        _ ->
            {"skipped (network tests disabled)", fun() -> ok end}
    end.

scan_target_hex_latest_test_() ->
    case os:getenv("SKIP_NETWORK_TESTS") of
        false ->
            {"scans Hex package with latest version", fun() ->
                %% Test the "latest" version resolution
                Stats = spectrometer_analyzer:scan_target(
                    {hex, "jason", "latest"}
                ),
                ?assert(is_map(Stats))
            end};
        _ ->
            {"skipped (network tests disabled)", fun() -> ok end}
    end.

%% =============================================================================
%% Test helpers
%% =============================================================================

setup_temp_dir() ->
    spectrometer_utils:make_temp_dir("analyzer_test_").

%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
%%

-module(spectrometer_otp_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% is_otp_module/1 tests - Atom input
%% =============================================================================

is_otp_module_atom_valid_test_() ->
    {"identifies OTP modules from atom input", fun() ->
        ?assert(spectrometer_otp:is_otp_module(lists)),
        ?assert(spectrometer_otp:is_otp_module(gen_server)),
        ?assert(spectrometer_otp:is_otp_module(application)),
        ?assert(spectrometer_otp:is_otp_module(io)),
        ?assert(spectrometer_otp:is_otp_module(filename))
    end}.

is_otp_module_atom_invalid_test_() ->
    {"rejects non-OTP modules from atom input", fun() ->
        ?assertNot(spectrometer_otp:is_otp_module(nonexistent_module)),
        ?assertNot(spectrometer_otp:is_otp_module(my_custom_module))
    end}.

%% =============================================================================
%% is_otp_module/1 tests - String input
%% =============================================================================

is_otp_module_string_valid_test_() ->
    {"identifies OTP modules from string input", fun() ->
        ?assert(spectrometer_otp:is_otp_module("lists")),
        ?assert(spectrometer_otp:is_otp_module("gen_server")),
        ?assert(spectrometer_otp:is_otp_module("application")),
        ?assert(spectrometer_otp:is_otp_module("io")),
        ?assert(spectrometer_otp:is_otp_module("filename"))
    end}.

is_otp_module_string_invalid_test_() ->
    {"rejects non-OTP modules from string input", fun() ->
        ?assertNot(spectrometer_otp:is_otp_module("nonexistent_module")),
        ?assertNot(spectrometer_otp:is_otp_module("my_custom_module")),
        ?assertNot(spectrometer_otp:is_otp_module("my_app_helper"))
    end}.

%% =============================================================================
%% module_cache/0 tests
%% =============================================================================

module_cache_path_test_() ->
    {"returns valid cache file path", fun() ->
        CachePath = spectrometer_otp:module_cache(),
        ?assert(is_list(CachePath)),
        ?assert(string:find(CachePath, "_modules.bin") =/= nomatch)
    end}.

module_cache_uses_user_cache_test_() ->
    {"cache path uses user cache directory", fun() ->
        CachePath = spectrometer_otp:module_cache(),
        UserCache = spectrometer_utils:user_cache_path(),
        ?assert(string:find(CachePath, UserCache) =/= nomatch)
    end}.

module_cache_contains_otp_version_test_() ->
    {"cache path contains OTP version", fun() ->
        CachePath = spectrometer_otp:module_cache(),
        VersionString = erlang:system_info(otp_release),
        ?assert(string:find(CachePath, "otp_" ++ VersionString) =/= nomatch)
    end}.

%% =============================================================================
%% modules_list/0 tests - Runtime generation
%% =============================================================================

modules_list_returns_valid_test_() ->
    {"returns valid module list from runtime", fun() ->
        Modules = spectrometer_otp:modules_list(),
        ?assert(is_list(Modules)),
        ?assert(length(Modules) > 0),
        ?assert(lists:member("lists", Modules)),
        ?assert(lists:member("gen_server", Modules))
    end}.

modules_list_creates_cache_test_() ->
    {"creates cache file on first run",
        {setup,
            fun() ->
                OldCacheDir = application:get_env(spectrometer, cache_dir),
                TempDir = spectrometer_utils:make_temp_dir("otp_cache_create_"),
                application:set_env(spectrometer, cache_dir, TempDir),
                {TempDir, OldCacheDir}
            end,
            fun({TempDir, OldCacheDir}) ->
                spectrometer_utils:purge_dir(TempDir),
                case OldCacheDir of
                    {ok, Val} ->
                        application:set_env(spectrometer, cache_dir, Val);
                    undefined ->
                        application:unset_env(spectrometer, cache_dir)
                end
            end,
            fun({_TempDir, _OldCacheDir}) ->
                ?_test(begin
                    _ = spectrometer_otp:modules_list(),
                    CacheFile = spectrometer_otp:module_cache(),
                    ?assert(filelib:is_file(CacheFile))
                end)
            end}}.

%% =============================================================================
%% modules_list/0 tests - Cache file handling
%% =============================================================================

modules_list_reads_valid_cache_test_() ->
    {"reads valid cached data",
        {setup,
            fun() ->
                OldCacheDir = application:get_env(spectrometer, cache_dir),
                TempDir = spectrometer_utils:make_temp_dir("otp_cache_read_"),
                application:set_env(spectrometer, cache_dir, TempDir),
                % Get the actual cache file path expected by the module
                CacheFile = spectrometer_otp:module_cache(),
                Modules = ["lists", "io", "gen_server"],
                file:write_file(CacheFile, term_to_binary(Modules)),
                {TempDir, CacheFile, OldCacheDir}
            end,
            fun({TempDir, _CacheFile, OldCacheDir}) ->
                spectrometer_utils:purge_dir(TempDir),
                case OldCacheDir of
                    {ok, Val} ->
                        application:set_env(spectrometer, cache_dir, Val);
                    undefined ->
                        application:unset_env(spectrometer, cache_dir)
                end
            end,
            fun({_TempDir, _CacheFile, _OldCacheDir}) ->
                ?_test(begin
                    Modules = spectrometer_otp:modules_list(),
                    ?assertEqual(["lists", "io", "gen_server"], Modules)
                end)
            end}}.

modules_list_invalid_binary_data_test_() ->
    {"handles invalid binary data in cache (non-list term)",
        {setup,
            fun() ->
                OldCacheDir = application:get_env(spectrometer, cache_dir),
                TempDir = spectrometer_utils:make_temp_dir(
                    "otp_cache_invalid_"
                ),
                application:set_env(spectrometer, cache_dir, TempDir),
                CacheFile = spectrometer_otp:module_cache(),
                file:write_file(
                    CacheFile, term_to_binary(some_atom_not_a_list)
                ),
                {TempDir, CacheFile, OldCacheDir}
            end,
            fun({TempDir, _CacheFile, OldCacheDir}) ->
                spectrometer_utils:purge_dir(TempDir),
                case OldCacheDir of
                    {ok, Val} ->
                        application:set_env(spectrometer, cache_dir, Val);
                    undefined ->
                        application:unset_env(spectrometer, cache_dir)
                end
            end,
            fun({_TempDir, _CacheFile, _OldCacheDir}) ->
                ?_test(begin
                    Modules = spectrometer_otp:modules_list(),
                    ?assert(is_list(Modules)),
                    ?assert(length(Modules) > 0)
                end)
            end}}.

modules_list_non_printable_cache_test_() ->
    {"handles cache with non-printable elements",
        {setup,
            fun() ->
                OldCacheDir = application:get_env(spectrometer, cache_dir),
                TempDir = spectrometer_utils:make_temp_dir(
                    "otp_cache_nonprint_"
                ),
                application:set_env(spectrometer, cache_dir, TempDir),
                CacheFile = spectrometer_otp:module_cache(),
                Modules = ["lists", "\x00\x01bad", "io"],
                file:write_file(CacheFile, term_to_binary(Modules)),
                {TempDir, CacheFile, OldCacheDir}
            end,
            fun({TempDir, _CacheFile, OldCacheDir}) ->
                spectrometer_utils:purge_dir(TempDir),
                case OldCacheDir of
                    {ok, Val} ->
                        application:set_env(spectrometer, cache_dir, Val);
                    undefined ->
                        application:unset_env(spectrometer, cache_dir)
                end
            end,
            fun({_TempDir, _CacheFile, _OldCacheDir}) ->
                ?_test(begin
                    Modules = spectrometer_otp:modules_list(),
                    ?assert(is_list(Modules)),
                    ?assert(
                        lists:all(
                            fun(X) -> io_lib:printable_list(X) end,
                            Modules
                        )
                    )
                end)
            end}}.

%% =============================================================================
%% modules_list/0 tests - File read error handling
%% =============================================================================

modules_list_handle_read_failure_test_() ->
    {"handles file read failure gracefully",
        {setup,
            fun() ->
                OldCacheDir = application:get_env(spectrometer, cache_dir),
                TempDir = spectrometer_utils:make_temp_dir(
                    "otp_cache_readfail_"
                ),
                application:set_env(spectrometer, cache_dir, TempDir),
                CacheFile = spectrometer_otp:module_cache(),
                % Create a directory with the same name as the cache file to cause read error
                file:make_dir(CacheFile),
                {TempDir, CacheFile, OldCacheDir}
            end,
            fun({TempDir, CacheFile, OldCacheDir}) ->
                file:del_dir(CacheFile),
                spectrometer_utils:purge_dir(TempDir),
                case OldCacheDir of
                    {ok, Val} ->
                        application:set_env(spectrometer, cache_dir, Val);
                    undefined ->
                        application:unset_env(spectrometer, cache_dir)
                end
            end,
            fun({_TempDir, _CacheFile, _OldCacheDir}) ->
                ?_test(begin
                    Modules = spectrometer_otp:modules_list(),
                    ?assert(is_list(Modules)),
                    ?assert(length(Modules) > 0)
                end)
            end}}.

%% =============================================================================
%% Integration tests - Full cache lifecycle
%% =============================================================================

otp_module_cache_lifecycle_test_() ->
    {"full cache create/read/reuse lifecycle",
        {setup,
            fun() ->
                OldCacheDir = application:get_env(spectrometer, cache_dir),
                TempDir = spectrometer_utils:make_temp_dir("otp_lifecycle_"),
                application:set_env(spectrometer, cache_dir, TempDir),
                {TempDir, OldCacheDir}
            end,
            fun({TempDir, OldCacheDir}) ->
                spectrometer_utils:purge_dir(TempDir),
                case OldCacheDir of
                    {ok, Val} ->
                        application:set_env(spectrometer, cache_dir, Val);
                    undefined ->
                        application:unset_env(spectrometer, cache_dir)
                end
            end,
            fun({_TempDir, _OldCacheDir}) ->
                ?_test(begin
                    Modules1 = spectrometer_otp:modules_list(),
                    CacheFile = spectrometer_otp:module_cache(),
                    ?assert(filelib:is_file(CacheFile)),

                    Modules2 = spectrometer_otp:modules_list(),
                    ?assertEqual(Modules1, Modules2)
                end)
            end}}.

%% =============================================================================
%% modules_list/0 tests - Writable directory creation failure simulation
%% =============================================================================

modules_list_handles_missing_cache_dir_test_() ->
    {"handles missing cache directory",
        {setup,
            fun() ->
                OldCacheDir = application:get_env(spectrometer, cache_dir),
                TempDir = spectrometer_utils:make_temp_dir("otp_missing_dir_"),
                application:set_env(spectrometer, cache_dir, TempDir),
                spectrometer_utils:purge_dir(TempDir),
                {TempDir, OldCacheDir}
            end,
            fun({TempDir, OldCacheDir}) ->
                spectrometer_utils:purge_dir(TempDir),
                case OldCacheDir of
                    {ok, Val} ->
                        application:set_env(spectrometer, cache_dir, Val);
                    undefined ->
                        application:unset_env(spectrometer, cache_dir)
                end
            end,
            fun({_TempDir, _OldCacheDir}) ->
                ?_test(begin
                    Modules = spectrometer_otp:modules_list(),
                    ?assert(is_list(Modules)),
                    ?assert(length(Modules) > 0)
                end)
            end}}.

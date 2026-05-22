%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
%%

-module(spectrometer_scanner_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% find_erl_files/1 tests (simple tests)
%% =============================================================================

find_erl_files_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_simple_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    create_file(Dir, "mod1.erl", "-module(mod1).\n"),
                    create_file(Dir, "mod2.erl", "-module(mod2).\n"),
                    create_file(Dir, "readme.txt", "not erlang"),
                    Expected = find_expected(Dir, ["mod1.erl", "mod2.erl"]),
                    Result = spectrometer_scanner:find_erl_files(Dir),
                    ?assertEqual(lists:sort(Expected), lists:sort(Result))
                end)
            end,
            fun(Dir) ->
                ?_test(begin
                    create_file(Dir, "mod1.erl", "-module(mod1).\n"),
                    SubDir = filename:join(Dir, "src"),
                    ok = file:make_dir(SubDir),
                    create_file(SubDir, "mod2.erl", "-module(mod2).\n"),
                    Result = spectrometer_scanner:find_erl_files(Dir),
                    ?assert(length(Result) =:= 2),
                    ?assert(
                        lists:any(
                            fun(F) -> filename:basename(F) =:= "mod1.erl" end,
                            Result
                        )
                    ),
                    ?assert(
                        lists:any(
                            fun(F) -> filename:basename(F) =:= "mod2.erl" end,
                            Result
                        )
                    )
                end)
            end,
            fun(Dir) ->
                ?_test(begin
                    Result = spectrometer_scanner:find_erl_files(Dir),
                    ?assertEqual([], Result)
                end)
            end
        ]}
    }.

find_erl_files_nonexistent_test_() ->
    {"returns empty list for non-existent directory", fun() ->
        Result = spectrometer_scanner:find_erl_files(
            "/nonexistent/path/12345"
        ),
        ?assertEqual([], Result)
    end}.

%% =============================================================================
%% parse_file/1 tests (simple tests)
%% =============================================================================

parse_file_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_parse_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(test).\n-export([foo/0]).\nfoo() -> lists:map(fun(X) -> X + 1 end, [1,2,3]).\n",
                    File = create_file(Dir, "test.erl", Source),
                    {ok, Calls} = spectrometer_scanner:parse_file(File),
                    ?assert(is_map(Calls)),
                    ?assert(maps:is_key({lists, map, 2}, Calls))
                end)
            end,
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(nocalls).\n-export([foo/0]).\nfoo() -> 42.\n",
                    File = create_file(Dir, "nocalls.erl", Source),
                    {ok, Calls} = spectrometer_scanner:parse_file(File),
                    ?assertEqual(0, maps:size(Calls))
                end)
            end,
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(multi).\n-export([test/0]).\n"
                        "test() ->\n"
                        "    A = lists:map(fun(X) -> X * 2 end, [1,2,3]),\n"
                        "    B = lists:filter(fun(X) -> X > 1 end, A),\n"
                        "    io:format(\"~p\n\", [B]).\n",
                    File = create_file(Dir, "multi.erl", Source),
                    {ok, Calls} = spectrometer_scanner:parse_file(File),
                    ?assert(maps:is_key({lists, map, 2}, Calls)),
                    ?assert(maps:is_key({lists, filter, 2}, Calls)),
                    ?assert(maps:is_key({io, format, 2}, Calls))
                end)
            end
        ]}
    }.

parse_file_nonexistent_test_() ->
    {"returns error for non-existent file", fun() ->
        Result = spectrometer_scanner:parse_file("/nonexistent/file.erl"),
        ?assertMatch({error, _}, Result)
    end}.

%% =============================================================================
%% merge_file_calls/2 tests
%% =============================================================================

merge_file_calls_test_() ->
    [
        {"merges two stats maps correctly", fun() ->
            Result = spectrometer_scanner:merge_file_calls(
                #{{lists, map, 2} => 2, {io, format, 2} => 1},
                #{{lists, map, 2} => 1}
            ),
            ?assertEqual(3, maps:get({lists, map, 2}, Result)),
            ?assertEqual(1, maps:get({io, format, 2}, Result))
        end},

        {"sums counts for duplicate keys", fun() ->
            Result = spectrometer_scanner:merge_file_calls(
                #{{lists, map, 2} => 3},
                #{{lists, map, 2} => 2}
            ),
            ?assertEqual(5, maps:get({lists, map, 2}, Result))
        end},

        {"preserves unique keys", fun() ->
            Result = spectrometer_scanner:merge_file_calls(
                #{{lists, map, 2} => 1},
                #{{io, format, 2} => 1}
            ),
            ?assertEqual(2, maps:size(Result))
        end},

        {"handles empty maps - left", fun() ->
            Result = spectrometer_scanner:merge_file_calls(
                #{},
                #{{lists, map, 2} => 1}
            ),
            ?assertEqual(1, maps:size(Result))
        end},

        {"handles empty maps - right", fun() ->
            Result = spectrometer_scanner:merge_file_calls(
                #{{lists, map, 2} => 1},
                #{}
            ),
            ?assertEqual(1, maps:size(Result))
        end}
    ].

%% =============================================================================
%% scan_directory/1 tests
%% =============================================================================

scan_directory_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_scan_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(test).\nfoo() -> lists:map(fun(X) -> X end, [1]).\n",
                    create_file(Dir, "test.erl", Source),
                    Stats = spectrometer_scanner:scan_directory(Dir),
                    ?assert(is_map(Stats)),
                    ?assert(maps:is_key({lists, map, 2}, Stats)),
                    ?assertEqual(1, maps:get({lists, map, 2}, Stats))
                end)
            end,
            fun(Dir) ->
                ?_test(begin
                    Stats = spectrometer_scanner:scan_directory(Dir),
                    ?assertEqual(0, maps:size(Stats))
                end)
            end,
            fun(Dir) ->
                ?_test(begin
                    Source1 =
                        "-module(mod1).\nfoo() -> lists:map(fun(X) -> X end, [1]).\n",
                    Source2 =
                        "-module(mod2).\nbar() -> lists:map(fun(X) -> X end, [2]).\n",
                    create_file(Dir, "mod1.erl", Source1),
                    create_file(Dir, "mod2.erl", Source2),
                    Stats = spectrometer_scanner:scan_directory(Dir),
                    ?assertEqual(2, maps:get({lists, map, 2}, Stats))
                end)
            end
        ]}
    }.

scan_directory_nonexistent_test_() ->
    {"returns empty map for non-existent directory", fun() ->
        Stats = spectrometer_scanner:scan_directory(
            "/nonexistent/path/12345"
        ),
        ?assertEqual(0, maps:size(Stats))
    end}.

%% =============================================================================
%% Test helpers
%% =============================================================================

create_file(Dir, Name, Content) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, Content),
    Path.

find_expected(Dir, Basenames) ->
    [filename:join(Dir, B) || B <- Basenames].

%% =============================================================================
%% parse_calls/1 tests - module-aware call extraction with filtering
%% =============================================================================

parse_calls_returns_module_name_test_() ->
    {setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_parse_calls_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(myapp). -export([start/0]). "
                        "start() -> lists:map(fun(X) -> X end, [1,2,3]), myapp:internal().\n",
                    File = filename:join(Dir, "myapp.erl"),
                    ok = file:write_file(File, Source),
                    {ok, ModName, Calls} = spectrometer_scanner:parse_calls(
                        File
                    ),
                    ?assertEqual(myapp, ModName),
                    ?assert(maps:is_key({lists, map, 2}, Calls)),
                    ?assertNot(maps:is_key({myapp, internal, 0}, Calls))
                end)
            end
        ]}}.

parse_calls_filters_same_module_test_() ->
    {setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_filter_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(testmod). -export([a/0, b/0, c/0]). "
                        "a() -> b(). b() -> c(). c() -> external:func().\n",
                    File = filename:join(Dir, "testmod.erl"),
                    ok = file:write_file(File, Source),
                    {ok, _, Calls} = spectrometer_scanner:parse_calls(File),
                    ?assertEqual(1, maps:size(Calls)),
                    ?assert(maps:is_key({external, func, 0}, Calls))
                end)
            end
        ]}}.

%% =============================================================================
%% extract_module_name/2 tests - module name extraction edge cases
%% =============================================================================

extract_module_name_non_atom_test_() ->
    {setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_modname_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(?NonAtom). -export([foo/0]). foo() -> ok.\n",
                    File = filename:join(Dir, "bad.erl"),
                    ok = file:write_file(File, Source),
                    {ok, Forms} = epp_dodger:parse_file(File),
                    Result = spectrometer_scanner:extract_module_name(Forms),
                    ?assertEqual(undefined, Result)
                end)
            end
        ]}}.

extract_module_name_multiple_attrs_test_() ->
    {setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_multi_modname_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(first). -module(second). -export([foo/0]). foo() -> ok.\n",
                    File = filename:join(Dir, "multi.erl"),
                    ok = file:write_file(File, Source),
                    {ok, Forms} = epp_dodger:parse_file(File),
                    Result = spectrometer_scanner:extract_module_name(Forms),
                    ?assertEqual(first, Result)
                end)
            end
        ]}}.

%% =============================================================================
%% Implicit fun extraction tests - fun Module:Function/Arity syntax
%% =============================================================================

implicit_fun_extraction_test_() ->
    {setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_implicit_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(test). -export([start/0]). "
                        "start() -> F1 = fun lists:map/2, F2 = fun lists:filter/2, {F1, F2}.\n",
                    File = filename:join(Dir, "implicit.erl"),
                    ok = file:write_file(File, Source),
                    {ok, Calls} = spectrometer_scanner:parse_file(File),
                    ?assert(maps:is_key({lists, map, 2}, Calls)),
                    ?assert(maps:is_key({lists, filter, 2}, Calls))
                end)
            end
        ]}}.

%% =============================================================================
%% BIF detection tests - erl_internal:bif/2 attribution to erlang module
%% =============================================================================

bif_detection_test_() ->
    {setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_bif_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(biftest). -export([test/0]). "
                        "test() -> L = [1,2,3], Len = length(L), tuple_size({a,b}), size({a,b}).\n",
                    File = filename:join(Dir, "biftest.erl"),
                    ok = file:write_file(File, Source),
                    {ok, Calls} = spectrometer_scanner:parse_file(File),
                    ?assert(maps:is_key({erlang, length, 1}, Calls)),
                    ?assert(maps:is_key({erlang, tuple_size, 1}, Calls)),
                    ?assert(maps:is_key({erlang, size, 1}, Calls))
                end)
            end
        ]}}.

%% =============================================================================
%% Directory skipping tests - _build, deps, .git, .rebar3 exclusion
%% =============================================================================

find_erl_files_skips_build_dir_test() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_skip_build_"),
            ok = filelib:ensure_path(Dir),
            BuildDir = filename:join(Dir, "_build"),
            ok = file:make_dir(BuildDir),
            create_file(BuildDir, "ignored.erl", "-module(ignored)."),
            MainFile = create_file(Dir, "main.erl", "-module(main)."),
            {Dir, MainFile}
        end,
        fun({Dir, _}) -> spectrometer_utils:purge_dir(Dir) end,
        {with, [
            fun({Dir, MainFile}) ->
                ?_test(begin
                    Result = spectrometer_scanner:find_erl_files(Dir),
                    ?assert(length(Result) =:= 1),
                    ?assert(lists:member(MainFile, Result))
                end)
            end
        ]}
    }.

find_erl_files_skips_deps_dir_test() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_skip_deps_"),
            ok = filelib:ensure_path(Dir),
            DepsDir = filename:join(Dir, "deps"),
            ok = file:make_dir(DepsDir),
            create_file(DepsDir, "dep.erl", "-module(dep)."),
            MainFile = create_file(Dir, "main.erl", "-module(main)."),
            {Dir, MainFile}
        end,
        fun({Dir, _}) -> spectrometer_utils:purge_dir(Dir) end,
        {with, [
            fun({Dir, MainFile}) ->
                ?_test(begin
                    Result = spectrometer_scanner:find_erl_files(Dir),
                    ?assert(length(Result) =:= 1),
                    ?assert(lists:member(MainFile, Result))
                end)
            end
        ]}
    }.

find_erl_files_skips_git_dir_test() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_skip_git_"),
            ok = filelib:ensure_path(Dir),
            GitDir = filename:join(Dir, ".git"),
            ok = file:make_dir(GitDir),
            create_file(GitDir, "packed.erl", "-module(packed)."),
            MainFile = create_file(Dir, "main.erl", "-module(main)."),
            {Dir, MainFile}
        end,
        fun({Dir, _}) -> spectrometer_utils:purge_dir(Dir) end,
        {with, [
            fun({Dir, MainFile}) ->
                ?_test(begin
                    Result = spectrometer_scanner:find_erl_files(Dir),
                    ?assert(length(Result) =:= 1),
                    ?assert(lists:member(MainFile, Result))
                end)
            end
        ]}
    }.

find_erl_files_skips_rebar3_dir_test() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_skip_rebar3_"),
            ok = filelib:ensure_path(Dir),
            Rebar3Dir = filename:join(Dir, ".rebar3"),
            ok = file:make_dir(Rebar3Dir),
            create_file(Rebar3Dir, "cache.erl", "-module(cache)."),
            MainFile = create_file(Dir, "main.erl", "-module(main)."),
            {Dir, MainFile}
        end,
        fun({Dir, _}) -> spectrometer_utils:purge_dir(Dir) end,
        {with, [
            fun({Dir, MainFile}) ->
                ?_test(begin
                    Result = spectrometer_scanner:find_erl_files(Dir),
                    ?assert(length(Result) =:= 1),
                    ?assert(lists:member(MainFile, Result))
                end)
            end
        ]}
    }.

%% =============================================================================
%% Error recovery tests - malformed source handling
%% =============================================================================

parse_file_malformed_source_test() ->
    {setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_malformed_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Source =
                        "-module(broken). -export([foo/0]). foo() -> [unclosed_list.\n",
                    File = filename:join(Dir, "broken.erl"),
                    ok = file:write_file(File, Source),
                    Result = spectrometer_scanner:parse_file(File),
                    ?assertMatch({error, _}, Result)
                end)
            end
        ]}}.

parse_file_binary_garbage_test() ->
    {setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("scanner_binary_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    File = filename:join(Dir, "bad.erl"),
                    ok = file:write_file(File, <<255, 254, 253>>),
                    Result = spectrometer_scanner:parse_file(File),
                    ?assertMatch({error, _}, Result)
                end)
            end
        ]}}.

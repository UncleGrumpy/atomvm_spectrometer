%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

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

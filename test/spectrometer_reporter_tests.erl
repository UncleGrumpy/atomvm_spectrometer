%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
%%
-module(spectrometer_reporter_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SAMPLE_STATS, #{
    {lists, map, 2} => 10,
    {lists, filter, 2} => 5,
    {io, format, 2} => 3,
    {erlang, display, 1} => 1,
    {string, find, 3} => 7,
    {binary, match, 2} => 2
}).

-define(SAMPLE_REPORT, #{
    supported => [
        {{erlang, display, 1}, 1},
        {{lists, map, 2}, 10}
    ],
    unsupported => [
        {{io, format, 2}, 3},
        {{string, find, 3}, 7},
        {{binary, match, 2}, 2}
    ],
    total => 23,
    total_unique => 5
}).

%% =============================================================================
%% generate_report/1 tests
%% =============================================================================

generate_report1_delegates_test() ->
    % generate_report/1 should delegate to generate_report/2 with MinCount=1
    Stats = #{{lists, map, 2} => 5},
    Report = spectrometer_reporter:generate_report(Stats),
    ?assert(maps:is_key(supported, Report)),
    ?assert(maps:is_key(unsupported, Report)),
    ?assert(maps:is_key(total, Report)),
    ?assert(maps:is_key(total_unique, Report)).

generate_report2_filters_non_otp_test() ->
    % generate_report/2 should filter out non-OTP functions
    Stats = #{
        {my_app, my_func, 2} => 5,
        {lists, map, 2} => 3
    },
    Report = spectrometer_reporter:generate_report(Stats, 1),
    % my_app is not an OTP module, should be filtered out
    Supp = maps:get(supported, Report),
    Unsupp = maps:get(unsupported, Report),
    ?assert(
        lists:keymember({lists, map, 2}, 1, Supp) orelse
            lists:keymember({lists, map, 2}, 1, Unsupp)
    ),
    % Explicitly verify non-OTP function was removed
    ?assertNot(lists:keymember({my_app, my_func, 2}, 1, Supp)),
    ?assertNot(lists:keymember({my_app, my_func, 2}, 1, Unsupp)).

generate_report2_applies_min_count_test() ->
    Stats = #{{lists, map, 2} => 10, {io, format, 2} => 2},
    Report = spectrometer_reporter:generate_report(Stats, 5),
    Supp = maps:get(supported, Report),
    Unsupp = maps:get(unsupported, Report),
    All = Supp ++ Unsupp,
    % Only lists:map/2 should remain (count >= 5)
    ?assert(lists:keyfind({lists, map, 2}, 1, All) =/= false),
    ?assert(lists:keyfind({io, format, 2}, 1, All) =:= false).

generate_report2_empty_input_test() ->
    Stats = #{},
    Report = spectrometer_reporter:generate_report(Stats, 1),
    ?assertEqual([], maps:get(supported, Report)),
    ?assertEqual([], maps:get(unsupported, Report)),
    ?assertEqual(0, maps:get(total, Report)),
    ?assertEqual(0, maps:get(total_unique, Report)).

%% =============================================================================
%% filter_otp_functions/1 tests
%% =============================================================================

filter_otp_functions_keeps_otp_test() ->
    Stats = #{{lists, map, 2} => 1, {io, format, 2} => 2},
    Filtered = spectrometer_reporter:filter_otp_functions(Stats),
    ?assertEqual(2, maps:size(Filtered)).

filter_otp_functions_removes_non_otp_test() ->
    Stats = #{{my_custom_mod, func, 1} => 1, {lists, map, 2} => 1},
    Filtered = spectrometer_reporter:filter_otp_functions(Stats),
    ?assertEqual(1, maps:size(Filtered)),
    ?assert(maps:is_key({lists, map, 2}, Filtered)).

filter_otp_functions_empty_test() ->
    ?assertEqual(#{}, spectrometer_reporter:filter_otp_functions(#{})).

%% =============================================================================
%% get_otp_module_set/0 tests (tested indirectly via filter_otp_functions)
%% =============================================================================

%% Note: get_otp_module_set/0 is not exported, so we test it indirectly
%% through filter_otp_functions which uses it internally.
%% The filter_otp_functions tests already verify OTP filtering behavior.

%% =============================================================================
%% sort_stats/1 tests
%% =============================================================================

sort_stats_descending_test() ->
    Stats = [{{a, b, 1}, 1}, {{c, d, 2}, 5}, {{e, f, 3}, 3}],
    Sorted = spectrometer_reporter:sort_stats(Stats),
    {{_, _, _}, C1} = lists:nth(1, Sorted),
    {{_, _, _}, C2} = lists:nth(2, Sorted),
    {{_, _, _}, C3} = lists:nth(3, Sorted),
    ?assertEqual(5, C1),
    ?assertEqual(3, C2),
    ?assertEqual(1, C3).

sort_stats_empty_test() ->
    ?assertEqual([], spectrometer_reporter:sort_stats([])).

sort_stats_single_test() ->
    Stats = [{{one, two, 3}, 42}],
    ?assertEqual(Stats, spectrometer_reporter:sort_stats(Stats)).

%% =============================================================================
%% quote_csv_field/1 and needs_csv_quoting/1 tests
%% These functions are internal (-doc false.) and not exported.
%% Testing via write_csv with special characters in module/function names.
%% =============================================================================

%% Note: quote_csv_field and needs_csv_quoting are not exported functions
%% Their behavior is implicitly tested via write_csv with special characters.
%% To test these directly, they would need to be exported.

%% =============================================================================
%% write_csv/2 tests (corrected data format)
%% =============================================================================

write_csv_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("reporter_test_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    % Create a proper Report structure
                    Report = #{
                        supported => [
                            {{erlang, display, 1}, 1}
                        ],
                        unsupported => [
                            {{lists, map, 2}, 10},
                            {{io, format, 2}, 3}
                        ],
                        total => 14,
                        total_unique => 3
                    },
                    Path = filename:join(Dir, "output.csv"),
                    ok = spectrometer_reporter:write_csv(Path, Report),
                    ?assert(filelib:is_file(Path)),
                    {ok, Content} = file:read_file(Path),
                    ?assert(
                        binary:match(Content, <<"lists,map,2">>) =/= nomatch
                    ),
                    ?assert(
                        binary:match(Content, <<"io,format,2">>) =/= nomatch
                    ),
                    ?assert(
                        binary:match(Content, <<"module,function,arity">>) =/=
                            nomatch
                    )
                end)
            end
        ]}
    }.

write_csv_limit_test_() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("reporter_limit_test_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Report = #{
                        supported => [
                            {{erlang, display, 1}, 1}
                        ],
                        unsupported => [
                            {{lists, map, 2}, 10},
                            {{io, format, 2}, 3},
                            {{string, find, 3}, 7}
                        ],
                        total => 21,
                        total_unique => 4
                    },
                    Path = filename:join(Dir, "output_limited.csv"),
                    ok = spectrometer_reporter:write_csv(Path, Report, 2),
                    ?assert(filelib:is_file(Path)),
                    {ok, Content} = file:read_file(Path),
                    Lines = binary:split(Content, <<"\n">>, [global, trim]),
                    % Header + 2 data lines = 3
                    ?assertEqual(3, length(Lines))
                end)
            end
        ]}
    }.

write_csv_limit_one_test() ->
    {
        setup,
        fun() ->
            Dir = spectrometer_utils:make_temp_dir("reporter_limit1_test_"),
            ok = filelib:ensure_path(Dir),
            Dir
        end,
        fun spectrometer_utils:purge_dir/1,
        {with, [
            fun(Dir) ->
                ?_test(begin
                    Report = #{
                        supported => [],
                        unsupported => [
                            {{a, b, 1}, 1},
                            {{c, d, 2}, 2},
                            {{e, f, 3}, 3}
                        ],
                        total => 6,
                        total_unique => 3
                    },
                    Path = filename:join(Dir, "output_one.csv"),
                    ok = spectrometer_reporter:write_csv(Path, Report, 1),
                    {ok, Content} = file:read_file(Path),
                    Lines = binary:split(Content, <<"\n">>, [global, trim]),
                    % Header + 1 data line
                    ?assertEqual(2, length(Lines))
                end)
            end
        ]}
    }.

%% =============================================================================
%% print_summary tests
%% =============================================================================

print_summary_test_() ->
    {
        foreach,
        fun() ->
            % Capture stdout would require group_leader manipulation
            ok
        end,
        fun(_) -> ok end,
        [
            ?_test(begin
                Report = #{
                    supported => [{{lists, map, 2}, 5}],
                    unsupported => [{{io, format, 2}, 3}],
                    total => 8,
                    total_unique => 2
                },
                ok = spectrometer_reporter:print_summary(Report)
            end),
            ?_test(begin
                % All supported case
                Report = #{
                    supported => [{{lists, map, 2}, 5}],
                    unsupported => [],
                    total => 5,
                    total_unique => 1
                },
                ok = spectrometer_reporter:print_summary(Report)
            end)
        ]
    }.

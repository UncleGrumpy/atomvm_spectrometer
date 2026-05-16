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

%% =============================================================================
%% write_csv/2 tests
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
                    Stats = #{
                        {lists, map, 2} => {all, <<"v1.0.0">>},
                        {io, format, 2} => {[esp32], <<"v2.0.0">>}
                    },
                    Path = filename:join(Dir, "output.csv"),
                    ok = spectrometer_reporter:write_csv(Path, Stats),
                    ?assert(filelib:is_file(Path)),
                    {ok, Content} = file:read_file(Path),
                    ?assert(
                        binary:match(Content, <<"lists,map,2">>) =/= nomatch
                    ),
                    ?assert(
                        binary:match(Content, <<"io,format,2">>) =/= nomatch
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
                    Stats = #{
                        {lists, map, 2} => {all, <<"v1.0.0">>},
                        {io, format, 2} => {[esp32], <<"v2.0.0">>},
                        {erlang, display, 1} => {all, <<"v0.5.0">>}
                    },
                    Path = filename:join(Dir, "output.csv"),
                    ok = spectrometer_reporter:write_csv(Path, Stats),
                    ?assert(filelib:is_file(Path)),
                    {ok, Content} = file:read_file(Path),
                    Lines = binary:split(Content, <<"\n">>, [global]),
                    %% Should have header + 3 data lines + trailing empty = 5
                    ?assertEqual(5, length(Lines))
                end)
            end
        ]}
    }.

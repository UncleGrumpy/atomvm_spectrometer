%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
%%

-module(spectrometer_reporter).

-include_lib("kernel/include/file.hrl").

-moduledoc """
Generates portability audit reports of OTP function usage.

This module is responsible for user-facing reporting. It takes scan statistics
and splits them into supported and unsupported functions (based on the AtomVM
database), prints terminal summaries ordered by call frequency, and writes
CSV output for further analysis.

Only OTP (non-local) functions are included in reports — the module uses a
heuristic list of known OTP module names to filter out application-specific
code.
""".

-export([
    generate_report/1,
    generate_report/2,
    print_summary/1,
    print_summary/3,
    write_csv/2,
    write_csv/3
]).

-doc """
Generate a full report with default options (min_count = 1).

Delegates to `generate_report/2` with `#{min_count => 1}`.
""".
-spec generate_report(#{
    {atom(), atom(), non_neg_integer()} => non_neg_integer()
}) ->
    #{
        'supported' => [
            {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
        ],
        'unsupported' => [
            {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
        ],
        'total' => non_neg_integer(),
        'total_unique' => non_neg_integer()
    }.
generate_report(Stats) ->
    generate_report(Stats, 1).

-doc """
Generate a full report with options.

Filters the scan statistics to OTP functions only, splits them into
supported and unsupported lists, and applies the `min_count` filter.
Returns a map with `supported`, `unsupported`, `total`, and `total_unique`
keys.

#### Options

- `min_count` — Minimum call count to include (default: 1)
""".
-spec generate_report(
    #{{atom(), atom(), non_neg_integer()} => non_neg_integer()},
    non_neg_integer()
) ->
    #{
        supported := [
            {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
        ],
        unsupported := [
            {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
        ],
        total := non_neg_integer(),
        total_unique := non_neg_integer()
    }.
generate_report(Stats, MinCount) ->
    OtpStats = filter_otp_functions(Stats),
    Unsupported = spectrometer_atomvm:get_unsupported(OtpStats),
    Supported = lists:filter(
        fun({Key, _Count}) ->
            spectrometer_atomvm:is_supported(Key)
        end,
        lists:sort(fun({_, C1}, {_, C2}) -> C1 > C2 end, maps:to_list(OtpStats))
    ),
    FilteredUnsupported = lists:filter(
        fun({_, Count}) -> Count >= MinCount end, Unsupported
    ),
    FilteredSupported = lists:filter(
        fun({_, Count}) -> Count >= MinCount end, Supported
    ),

    TotalCalls =
        lists:sum([C0 || {_, C0} <- FilteredUnsupported]) +
            lists:sum([C1 || {_, C1} <- FilteredSupported]),
    TotalUnique = length(FilteredUnsupported ++ FilteredSupported),

    #{
        supported => FilteredSupported,
        total => TotalCalls,
        total_unique => TotalUnique,
        unsupported => FilteredUnsupported
    }.

-doc false.
%% Filter statistics to only OTP (non-local) functions.
%% Uses a heuristic set of known OTP module names.
filter_otp_functions(Stats) ->
    OtpModules = get_otp_module_set(),
    maps:filter(
        fun({Mod, _Fun, _Arity}, _Count) ->
            sets:is_element(Mod, OtpModules)
        end,
        Stats
    ).

-doc false.
%% Get or generate the OTP module set with caching.
%% Checks for a cached version first, generates if not found.
-spec get_otp_module_set() -> sets:set(atom()).
get_otp_module_set() ->
    OtpMods = spectrometer_otp:modules_list(),
    %% Convert string module names to atoms for matching
    OtpAtoms = [spectrometer_utils:atom_from_string(Mod) || Mod <- OtpMods],
    sets:from_list(OtpAtoms, [{version, 2}]).

-doc """
Print a terminal summary with default top count (50).
""".
-spec print_summary(#{
    supported := [
        {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
    ],
    unsupported := [{{atom(), atom(), arity()}, non_neg_integer()}],
    total := non_neg_integer(),
    total_unique := non_neg_integer()
}) -> ok.
print_summary(Report) ->
    print_summary(Report, 50, false),
    ok.

-doc """
Print a terminal summary with configurable top count.

Displays the top `TopN` unsupported functions ordered by call count,
with totals.
""".
-spec print_summary(
    #{
        supported := [
            {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
        ],
        unsupported := [
            {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
        ],
        total := non_neg_integer(),
        total_unique := non_neg_integer()
    },
    TopN :: pos_integer(),
    OnlyUnsupported :: true | false
) -> ok.
print_summary(Report, TopN, true) ->
    #{
        unsupported := Unsupported,
        supported := _,
        total_unique := _TotalUnique
    } =
        Report,
    UnsupportedTotal = lists:sum([Count || {{_, _, _}, Count} <- Unsupported]),
    TopList = lists:sublist(Unsupported, TopN),

    io:format("\n"),
    io:format("~s\n", [string:copies("=", 80)]),
    io:format("  AtomVM Portability Audit — Unsupported OTP Functions\n"),
    io:format("~s\n", [string:copies("=", 80)]),
    io:format(
        "  Total unsupported unique functions: ~p (~p total calls)\n",
        [length(Unsupported), UnsupportedTotal]
    ),
    io:format("~s\n", [string:copies("-", 80)]),

    case TopList of
        [] ->
            io:format(
                "  All top ~p scanned OTP functions are supported by AtomVM!\n",
                [TopN]
            );
        _ ->
            io:format("  ~-4s  ~-40s  ~10s\n", [
                "", "Module:Function/Arity", "Calls"
            ]),
            io:format("  ~s\n", [string:copies("-", 80)]),
            lists:foldl(
                fun({{Mod, Fun, Arity}, Count}, Idx) ->
                    MFA = io_lib:format("~ts:~ts/~p", [Mod, Fun, Arity]),
                    MFAList = lists:flatten(MFA),
                    io:format(
                        "  ~-4w  ~-40s  ~10w\n",
                        [Idx, MFAList, Count]
                    ),
                    Idx + 1
                end,
                1,
                TopList
            ),
            case length(Unsupported) > TopN of
                true ->
                    io:format(
                        "  ... and ~p more (use higher --top count to see more)\n",
                        [length(Unsupported) - TopN]
                    );
                false ->
                    ok
            end
    end,
    ok = io:format("~s\n", [string:copies("=", 80)]);
print_summary(Report, TopN, false) ->
    Supported = maps:get(supported, Report),
    Unsupported = maps:get(unsupported, Report),
    Sorted = sort_stats(Supported ++ Unsupported),
    Results = lists:sublist(Sorted, TopN),
    io:format("\n"),
    io:format("~s\n", [string:copies("=", 78)]),
    io:format("  Top ~p Most Used Erlang/OTP Functions\n", [
        min(TopN, length(Results))
    ]),
    io:format("~s\n", [string:copies("=", 78)]),
    io:format("~4s  ~-40s ~10s\n", [
        "#", "Module:Function/Arity", "Calls"
    ]),
    io:format("~s\n", [string:copies("-", 78)]),
    lists:foldl(
        fun({{Mod, Fun, Arity}, Count}, Idx) ->
            MFA = io_lib:format("~ts:~ts/~p", [Mod, Fun, Arity]),
            io:format("~4p  ~-40ts ~10p\n", [
                Idx, lists:flatten(MFA), Count
            ]),
            Idx + 1
        end,
        1,
        Results
    ),
    io:format("~s\n", [string:copies("=", 78)]),
    ok = io:format("Total unique MFAs: ~p\n", [length(Sorted)]).

sort_stats(Stats) ->
    lists:sort(fun({_, C1}, {_, C2}) -> C1 > C2 end, Stats).

-doc false.
%% Quote a field for CSV output.
%% Wraps in double quotes if contains comma, double-quote, or newline,
%% and doubles any internal double quotes per RFC 4180.
-spec quote_csv_field(string()) -> string().
quote_csv_field(Field) ->
    case needs_csv_quoting(Field) of
        true ->
            Quoted = string:replace(Field, "\"", "\"\"", all),
            "\"" ++ Quoted ++ "\"";
        false ->
            Field
    end.

-doc false.
%% Check if a field needs CSV quoting.
-spec needs_csv_quoting(string()) -> boolean().
needs_csv_quoting(Field) ->
    string:find(Field, ",") =/= nomatch orelse
        string:find(Field, "\"") =/= nomatch orelse
        string:find(Field, [10]) =/= nomatch.

-doc """
Write CSV output with all unsupported functions.
""".
-spec write_csv(
    string(),
    #{
        supported := [
            {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
        ],
        unsupported := [
            {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
        ],
        total := non_neg_integer(),
        total_unique := non_neg_integer()
    }
) -> ok | {error, term()}.
write_csv(File, Report) ->
    write_csv(File, Report, all).

-doc """
Write CSV output with a limit on the number of unsupported functions.

Pass `all` as `Limit` to include all unsupported functions.
""".
-spec write_csv(
    string(),
    #{
        supported := [
            {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
        ],
        unsupported := [
            {{atom(), atom(), non_neg_integer()}, non_neg_integer()}
        ],
        total := non_neg_integer(),
        total_unique := non_neg_integer()
    },
    pos_integer() | all
) -> ok | {error, term()}.
write_csv(File, Report, all) ->
    #{unsupported := Unsupported} = Report,
    do_write_csv(File, Unsupported);
write_csv(File, Report, Limit) when is_integer(Limit), Limit > 0 ->
    #{unsupported := Unsupported} = Report,
    Limited = lists:sublist(Unsupported, Limit),
    do_write_csv(File, Limited).

-doc false.
%% Internal CSV writer — opens file, writes header and rows, closes.
-spec do_write_csv(file:name_all(), [
    {{atom(), atom(), arity()}, non_neg_integer()}
]) -> ok | {error, term()}.
do_write_csv(File, Unsupported) ->
    try
        case file:open(File, [write, {encoding, utf8}]) of
            {error, Reason0} ->
                io:format("  Failed to open file ~s for writing: ~p\n", [
                    File, Reason0
                ]),
                error(Reason0);
            {ok, Fd} ->
                io:format(
                    Fd, "module,function,arity,calls,atomvm_supported\n", []
                ),
                lists:foreach(
                    fun({{Mod, Fun, Arity}, Count}) ->
                        io:format(Fd, "~s,~s,~p,~p,no\n", [
                            quote_csv_field(atom_to_list(Mod)),
                            quote_csv_field(atom_to_list(Fun)),
                            Arity,
                            Count
                        ])
                    end,
                    Unsupported
                ),
                case file:close(Fd) of
                    ok ->
                        ok;
                    {error, Reason1} ->
                        io:format("  Failed to close file ~s: ~p\n", [
                            File, Reason1
                        ]),
                        error(Reason1)
                end,
                io:format("  Results written to ~s\n", [File])
        end
    catch
        error:Reason ->
            {error, Reason}
    end.

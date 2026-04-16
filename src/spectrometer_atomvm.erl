%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
-module(spectrometer_atomvm).

-include_lib("kernel/include/file.hrl").

-moduledoc """
Queries AtomVM supported functions database.

This module is the source of truth for AtomVM compatibility data. It loads the
supported functions database from a bundled `supported_functions.data` file or
a user override, and provides functions for checking whether a specific OTP
function is supported by AtomVM, along with platform and version information.

### Data Source

The bundled database is at `priv/supported_functions.data` — a human-readable
Erlang term list loadable with `file:consult/1`. The format is:

```erlang
[{module(), [{function(), arity(), platforms(), since()}]}]
```

Where `platforms` is `all` or a list of platform atoms
(`esp32`, `stm32`, `rp2`, `emscripten`, or `generic_unix`), and `since` is a
binary version string or `{unreleased, Branch :: binary()}`.

### User Override

Place a custom `supported_functions.data` in your cache directory to
completely replace the bundled database:

- **Linux:** `~/.cache/spectrometer/supported_functions.data`
- **macOS:** `~/Library/Caches/spectrometer/supported_functions.data`
- **Windows:** `%APPDATA%/spectrometer/supported_functions.data`

The override file uses the same human-readable format as the bundled file. The
user cache override may also be updated using
`spectrometer_updater:update_datafile/2`.
""".

-export([
    get_unsupported/1,
    is_supported/1,
    load_db/0,
    query/1,
    reload_db/0,
    report_supported/1
]).

-doc """
List all modules supported by AtomVM.

Returns a list of module atoms that appear in the supported functions database.
""".
-spec supported_modules() -> [atom()].
supported_modules() ->
    maps:keys(load_db()).

-doc """
Check if a function is supported and return platforms and version information.

Returns `{true, Platforms, Since}` if the function is supported, or `false`
otherwise. `Platforms` is the atom `all` or a list of platform atoms.
`Since` is a binary version string (e.g. `<<"v0.5.0">>`) or
`{unreleased, Branch :: binary()}` for functions not yet in a release.
""".
-spec support_info({atom(), atom(), non_neg_integer()}) ->
    {true, [atom()] | all, binary() | {unreleased, binary()}} | false.
support_info({Mod, Fun, Arity}) ->
    DB = load_db(),
    case DB of
        #{Mod := Funs} ->
            FunMatches = [E || E <- Funs, element(1, E) =:= Fun],
            case find_arity(FunMatches, Arity) of
                none -> false;
                {Platforms, Since} -> {true, Platforms, Since}
            end;
        _ ->
            false
    end.

-doc """
Check if a function is supported

Returns `boolean()`.
""".
-spec is_supported({atom(), atom(), non_neg_integer()}) -> boolean().
is_supported({Mod, Fun, Arity}) ->
    DB = load_db(),
    case DB of
        #{Mod := Funs} ->
            FunMatches = [E || E <- Funs, element(1, E) =:= Fun],
            case find_arity(FunMatches, Arity) of
                none -> false;
                {_, _} -> true
            end;
        _ ->
            false
    end.

-doc false.
%% Find matching arity in function entries and return platforms and since info.
find_arity(FunMatches, Arity) ->
    find_arity(FunMatches, Arity, none).

-doc false.
find_arity([], _Arity, Acc) ->
    Acc;
find_arity(
    [{_, all, Platforms, Since} | _Rest], _Arity, _Acc
) ->
    {Platforms, Since};
find_arity(
    [{_, A, Platforms, Since} | Rest], Arity, _Acc
) when is_integer(A) ->
    case A =:= Arity of
        true -> {Platforms, Since};
        false -> find_arity(Rest, Arity, none)
    end;
find_arity(
    [{_, ArityList, Platforms, Since} | Rest], Arity, _Acc
) when is_list(ArityList) ->
    case lists:member(Arity, ArityList) of
        true -> {Platforms, Since};
        false -> find_arity(Rest, Arity, none)
    end;
find_arity([_ | Rest], Arity, Acc) ->
    %% Skip entries with unexpected format
    find_arity(Rest, Arity, Acc).

-doc """
Return all supported functions with platform and version information.

Returns a list of `{Module, Function, Arity, Platforms, Since}` tuples
for every function in the database.
""".
-spec get_supported_functions() ->
    [
        {
            atom(),
            atom(),
            non_neg_integer() | all | [non_neg_integer()],
            [atom()] | all,
            binary() | {unreleased, binary()}
        }
    ].
get_supported_functions() ->
    DB = load_db(),
    lists:flatten([
        {M, F, A, Platforms, Since}
     || {M, Funs} <- maps:to_list(DB), {F, A, Platforms, Since} <- Funs
    ]).

-doc """
Filter scan statistics to return unsupported functions only.

Given a statistics map from a scan, returns a list of
`{{Module, Function, Arity}, Count}` tuples for all functions that are
not supported by AtomVM, sorted by call count descending.
""".
-spec get_unsupported(#{
    {atom(), atom(), non_neg_integer()} => non_neg_integer()
}) ->
    [{{atom(), atom(), non_neg_integer()}, non_neg_integer()}].
get_unsupported(Stats) ->
    Unsupported = maps:filter(
        fun(Key, _Count) ->
            not is_supported(Key)
        end,
        Stats
    ),
    lists:sort(
        fun({_, C1}, {_, C2}) -> C1 > C2 end,
        maps:to_list(Unsupported)
    ).

-doc """
Force reload of the database from disk.

Clears the cached database stored in the process dictionary. Subsequent
calls to `load_db/0` or `is_supported/1` will re-read the database file.
""".
-spec reload_db() -> ok.
reload_db() ->
    erase(supported_db),
    ok.

-doc false.
%% Load database with platform and since information, cached in process dictionary.
load_db() ->
    case get(supported_db) of
        undefined ->
            DB = load_db_internal(),
            put(supported_db, DB),
            DB;
        DB ->
            DB
    end.

-doc false.
%% Load the database supporting platform and version information.
%% Checks user override first, then bundled file.
load_db_internal() ->
    UserPath = spectrometer_utils:user_db_file(),
    BundledPath = spectrometer_utils:bundled_data_path(),
    case filelib:is_regular(UserPath) of
        true ->
            consult_db(UserPath);
        false ->
            case filelib:is_regular(BundledPath) of
                true ->
                    consult_db(BundledPath);
                false ->
                    io:format(
                        standard_error,
                        "Warning: No supported functions database found.\n"
                        "  Expected at: ~s\n"
                        "  Or user file at: ~s\n"
                        "  A minimal database may be created by running `spectrometer update </PATH/TO/CLONE/OF/AtomVM>`\n"
                        "  A complete dataset may be generated by running the generate_fun_data.sh in the project root.\n",
                        [BundledPath, UserPath]
                    ),
                    #{}
            end
    end.

-doc false.
%% Read a human-readable database file (list of tuples).
-spec consult_db(file:name_all()) ->
    #{
        atom() => [
            {
                atom(),
                arity() | all | [arity()],
                [atom()] | all,
                binary() | {unreleased, binary()}
            }
        ]
    }.
consult_db(Path) ->
    case file:consult(Path) of
        {ok, Data} ->
            try
                maps:from_list(lists:flatten(Data))
            catch
                _:Reason ->
                    io:format(
                        standard_error,
                        "Warning: Could not read data: ~p, using empty database\n",
                        [Reason]
                    ),
                    #{}
            end;
        {error, Reason} ->
            io:format(
                standard_error,
                "Warning: Could not read ~s: ~p, using empty database\n",
                [Path, Reason]
            ),
            #{}
    end.

-doc """
Display a report of functions unsupported by AtomVM.

Opts = #{cache_dir => Dir, query => Query}
""".
-spec query(Opts :: atomvm_spectrometer:opts_map()) ->
    ok | {error, Reason :: term()}.
query(Opts) ->
    case Opts of
        #{cache_dir := CacheDir} ->
            application:set_env(spectrometer, cache_dir, CacheDir),
            reload_db();
        #{} ->
            ok
    end,
    Query = maps:get(query, Opts),
    case parse_query_string(Query) of
        {ok, Mod, Fun} ->
            show_query({Mod, Fun}),
            ok;
        {ok, Mod, Fun, Arity} ->
            show_query({Mod, Fun, Arity}),
            ok;
        {error, Reason} ->
            io:format(standard_error, "Error: ~s\n", [Reason]),
            io:format(
                standard_error, "Usage: query Module:Function[/Arity]\n", []
            ),
            {error, Reason}
    end.

-doc """
Parse a query string in `Module:Function[/Arity]` format.

Returns `{ok, Module, Function, Arity}` or `{ok, Module, Function}`
when no arity is specified, or `{error, Reason}` on invalid input.
""".
-spec parse_query_string(string()) ->
    {ok, atom(), atom(), arity()} | {ok, atom(), atom()} | {error, string()}.
parse_query_string(Query) ->
    case string:split(Query, ":") of
        [ModStr, Rest] ->
            case string:split(Rest, "/") of
                [FunStr, ArityStr] ->
                    case string:to_integer(ArityStr) of
                        {Arity, []} when Arity >= 0 ->
                            {ok, spectrometer_utils:atom_from_string(ModStr),
                                spectrometer_utils:atom_from_string(FunStr),
                                Arity};
                        _ ->
                            {error, "Invalid arity: " ++ ArityStr}
                    end;
                [FunStr] ->
                    {ok, spectrometer_utils:atom_from_string(ModStr),
                        spectrometer_utils:atom_from_string(FunStr)}
            end;
        _ ->
            {error,
                "Invalid format. Use Module:Function or Module:Function/Arity"}
    end.

-spec show_query({atom(), atom()} | {atom(), atom(), arity()}) -> ok.
show_query({Mod, Fun}) ->
    Supported = get_supported_functions(),
    Matches = [
        {A, Platforms, Since}
     || {M, F, A, Platforms, Since} <- Supported,
        M =:= Mod,
        F =:= Fun
    ],
    case lists:sort(Matches) of
        [] ->
            io:format("~ts:~ts is NOT supported by AtomVM\n", [Mod, Fun]);
        ArityList ->
            io:format("~ts:~ts supported arities:\n", [Mod, Fun]),
            lists:foreach(
                fun({Arity, Platforms, Since}) ->
                    io:format(
                        "  /~p  (~s, since: ~s)\n",
                        [
                            Arity,
                            format_platforms(Platforms),
                            format_since(Since)
                        ]
                    )
                end,
                ArityList
            )
    end;
show_query({Mod, Fun, Arity}) ->
    case support_info({Mod, Fun, Arity}) of
        {true, Platforms, Since} ->
            io:format(
                "~ts:~ts/~p is SUPPORTED by AtomVM (~s, since: ~s)\n",
                [
                    Mod,
                    Fun,
                    Arity,
                    format_platforms(Platforms),
                    format_since(Since)
                ]
            );
        false ->
            io:format(
                "~ts:~ts/~p is NOT supported by AtomVM\n",
                [Mod, Fun, Arity]
            )
    end.

-doc """
Format a platform list for display.

Returns `"all"` for the atom `all`, or a comma-separated
string of platform names.
""".
-spec format_platforms([atom()] | all) -> string().
format_platforms(all) ->
    "all";
format_platforms(Platforms) when is_list(Platforms) ->
    string:join([atom_to_list(P) || P <- Platforms], ", ").

-doc """
Format since data for display.

Formats release branch names to "unreleased {{VERSION}}", binary tags to
`t:string()`. Functions from unrecognized branches or tags will shown as an
"unknown" release, this would happen if users added downstream drivers to their
supported functions data using the `spectrometer update` command.
""".
-spec format_since(binary() | {unreleased, binary()}) -> string().
format_since(<<"unknown">>) ->
    "unknown";
format_since({unreleased, Branch}) when is_binary(Branch) ->
    "unreleased " ++ binary_to_list(Branch);
format_since(Version) when is_binary(Version) ->
    binary_to_list(Version).

-doc false.
-spec report_supported(atomvm_spectrometer:opts_map()) ->
    ok | {error, unsupported}.
report_supported(Opts) ->
    case Opts of
        #{cache_dir := CacheDir} ->
            application:set_env(spectrometer, cache_dir, CacheDir),
            reload_db();
        #{} ->
            ok
    end,
    case Opts of
        #{module := Mod} ->
            print_supported(Mod);
        #{} ->
            print_supported()
    end.

-spec print_supported() -> ok.
print_supported() ->
    Mods = supported_modules(),
    io:format("AtomVM supported OTP modules (~p total):\n\n", [length(Mods)]),
    lists:foreach(
        fun print_supported/1,
        lists:sort(Mods)
    ).

-spec print_supported(atom()) -> ok | {error, unsupported}.
print_supported(Mod) ->
    case supported_db_lookup(Mod) of
        {ok, Funs} ->
            io:format("~ts (~p functions):\n", [atom_to_list(Mod), length(Funs)]),
            lists:foreach(
                fun({F, A, Platform, Since}) ->
                    case A of
                        all ->
                            io:format(
                                "  ~ts/*  (all arities, ~s since: ~s)\n",
                                [
                                    atom_to_list(F),
                                    format_platforms(Platform),
                                    format_since(Since)
                                ]
                            );
                        List when is_list(List) ->
                            ArityStr = string:join(
                                [integer_to_list(X) || X <- List], "/"
                            ),
                            io:format(
                                "  ~ts/~s  (~s since: ~s)\n",
                                [
                                    atom_to_list(F),
                                    ArityStr,
                                    format_platforms(Platform),
                                    format_since(Since)
                                ]
                            );
                        Int when is_integer(Int) ->
                            io:format(
                                "  ~ts/~p  (~s since: ~s)\n",
                                [
                                    atom_to_list(F),
                                    Int,
                                    format_platforms(Platform),
                                    format_since(Since)
                                ]
                            )
                    end
                end,
                lists:sort(Funs)
            ),
            io:format("\n");
        not_found ->
            io:format(
                standard_error,
                "Module ~ts not found in AtomVM supported database\n",
                [atom_to_list(Mod)]
            ),
            {error, unsupported}
    end.

-spec supported_db_lookup(atom()) ->
    {ok, [
        {
            atom(),
            arity() | all | [arity()],
            [atom()] | all,
            binary() | {unreleased, binary()}
        }
    ]}
    | not_found.
supported_db_lookup(Mod) ->
    Supported = get_supported_functions(),
    ModFuns =
        [
            {F, A, Platforms, Since}
         || {M, F, A, Platforms, Since} <- Supported, M =:= Mod
        ],
    %  ++
    %     %% Also support entries without module prefix (for test compatibility)
    %     [
    %         {F, A, Since}
    %      || {F, A, _Platforms, Since} <- Supported, F =:= Mod
    %     ] ++
    %     %% Also support entries in format {F, A, Platforms, Since} (without module)
    %     [
    %         {F, A, Since}
    %      || {F, A, Platforms, Since} <- Supported,
    %         is_list(Platforms),
    %         F =:= Mod
    %     ],
    case ModFuns of
        [] -> not_found;
        _ -> {ok, ModFuns}
    end.

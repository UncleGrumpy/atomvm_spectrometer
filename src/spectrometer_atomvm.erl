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
-include("function.hrl").

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

The override file uses the same format as the bundled file. The user cache
override may also be updated using `spectrometer_updater:update/1` with no
`output` key defined in the config map.
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

Returns a list of module binaries that appear in the supported functions database.
""".
-spec supported_modules() -> [binary()].
supported_modules() ->
    maps:keys(load_db()).

-doc """
Check if a function is supported and return platforms and version information.

Returns `{true, Platforms, Since}` if the function is supported, or `false`
otherwise. `Platforms` is the atom `all` or a list of platform atoms.
`Since` is a binary version string (e.g. `<<"v0.5.0">>`) or
`{unreleased, Branch :: binary()}` for functions not yet in a release.
""".
-spec support_info({atom() | binary(), atom() | binary(), non_neg_integer()}) ->
    {true, map(), version_tuple() | undefined} | false.
support_info({Mod, Fun, Arity}) ->
    DB = load_db(),
    BinMod = ensure_binary(Mod),
    BinFun = ensure_binary(Fun),
    case DB of
        #{BinMod := Funs} ->
            FunMatches = [E || E <- Funs, element(2, E) =:= BinFun],
            case find_arity(FunMatches, Arity) of
                none -> false;
                {SinceMap, Removed} -> {true, SinceMap, Removed}
            end;
        _ ->
            false
    end.

-doc """
Check if a function is supported

Returns `boolean()`.
""".
-spec is_supported({atom() | binary(), atom() | binary(), non_neg_integer()}) ->
    boolean().
is_supported({Mod, Fun, Arity}) ->
    DB = load_db(),
    % Convert keys to binaries for DB lookup
    BinMod = ensure_binary(Mod),
    BinFun = ensure_binary(Fun),
    case DB of
        #{BinMod := Funs} ->
            FunMatches = [E || E <- Funs, element(2, E) =:= BinFun],
            case find_arity(FunMatches, Arity) of
                none -> false;
                {_, _} -> true
            end;
        _ ->
            false
    end.

-doc false.
%% Find matching arity in function entries and return platforms and since info.
%% Find matching arity in function entries and return SinceMap and Removed info.
-spec find_arity([#function{}], non_neg_integer() | all) -> {map(), version_tuple() | undefined} | none.
find_arity(FunMatches, Arity) ->
    find_arity(FunMatches, Arity, none).

find_arity([], _Arity, Acc) ->
    Acc;
find_arity(
    [#function{arity = all, since_map = SM, removed = Removed} | _Rest],
    _Arity,
    _Acc
) ->
    {SM, Removed};
find_arity(
    [#function{arity = A, since_map = SM, removed = Removed} | Rest],
    Arity,
    _Acc
) when is_integer(A) ->
    case A =:= Arity of
        true -> {SM, Removed};
        false -> find_arity(Rest, Arity, none)
    end;
find_arity([_ | Rest], Arity, Acc) ->
    %% Skip entries with unexpected format
    find_arity(Rest, Arity, Acc).

-doc "\n"
"Return all supported functions with platform version and removal information.\n"
"\n"
"Returns a list of `{Module, #function{}}` pairs for every function in the database.\n".
-spec get_supported_functions() -> [{binary(), #function{}}].
get_supported_functions() ->
    DB = load_db(),
    lists:flatten([
        {M, Rec}
     || {M, Funs} <- maps:to_list(DB), Rec <- Funs
    ]).

-doc """
Filter scan statistics to return unsupported functions only.

Given a statistics map from a scan, returns a list of
`{{Module, Function, Arity}, Count}` tuples for all functions that are
not supported by AtomVM, sorted by call count descending.
""".
-spec get_unsupported(#{
    {atom() | binary(), atom() | binary(), non_neg_integer()} => non_neg_integer()
}) ->
    [
        {
            {atom() | binary(), atom() | binary(), non_neg_integer()},
            non_neg_integer()
        }
    ].
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
-spec load_db() -> #{binary() := [#function{}]}.
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
-spec load_db_internal() -> #{binary() := [#function{}]}.
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
%% Convert key to binary for DB lookup. If already a binary, return as-is.
-spec ensure_binary(atom() | binary()) -> binary().
ensure_binary(Bin) when is_binary(Bin) ->
    Bin;
ensure_binary(Atom) when is_atom(Atom) ->
    erlang:atom_to_binary(Atom, utf8).

-doc false.
%% Read a human-readable database file, supporting both old and new formats.
%% Old format: [{Module, [{Fun, Arity, Platforms, Since}]}]
%% New format: [{Module, [{Fun, Arity, SinceMap, Removed}]}]
%% Returns #{binary() => [#function{}]}.
-spec consult_db(file:name_all()) -> #{binary() => [#function{}]}.
consult_db(Path) ->
    case file:consult(Path) of
        {ok, Data} ->
            try
                AtomData = lists:flatten(Data),
                lists:foldl(
                    fun({Mod, Funs}, Acc) ->
                        ModBin = ensure_binary(Mod),
                        Records = lists:map(
                            fun({Fun, A, Arg3, Arg4}) ->
                                FB = ensure_binary(Fun),
                                case is_map(Arg3) of
                                    true ->
                                        %% New format: {Fun, Arity, SinceMap, Removed}
                                        %% Normalize binary version values to version tuples
                                        NormSM = maps:map(
                                            fun(_, V) ->
                                                ensure_compat_version(V)
                                            end,
                                            Arg3
                                        ),
                                        #function{
                                            name = FB,
                                            arity = A,
                                            since_map = NormSM,
                                            removed = ensure_compat_version(
                                                Arg4
                                            )
                                        };
                                    false ->
                                        %% Old format: {Fun, Arity, Platforms, Since}
                                        %% Convert old platforms to since_map
                                        SM =
                                            case Arg3 of
                                                all ->
                                                    #{
                                                        all => ensure_compat_version(
                                                            Arg4
                                                        )
                                                    };
                                                PList when is_list(PList) ->
                                                    maps:from_list([
                                                        {P,
                                                            ensure_compat_version(
                                                                Arg4
                                                            )}
                                                     || P <- PList
                                                    ])
                                            end,
                                        #function{
                                            name = FB,
                                            arity = A,
                                            since_map = SM,
                                            removed = undefined
                                        }
                                end
                            end,
                            Funs
                        ),
                        maps:put(ModBin, Records, Acc)
                    end,
                    #{},
                    AtomData
                )
            catch
                _:Reason ->
                    io:format(
                        standard_error,
                        "Warning: Could not read data: ~p, using empty database~n",
                        [Reason]
                    ),
                    #{}
            end;
        {error, Reason} ->
            io:format(
                standard_error,
                "Warning: Could not read ~s: ~p, using empty database~n",
                [Path, Reason]
            ),
            #{}
    end.

%% Ensure backward compatibility for version values (old binary → version tuple)
-spec ensure_compat_version(term()) -> version_tuple() | undefined.
ensure_compat_version(undefined) ->
    undefined;
ensure_compat_version({unreleased, Branch}) when is_binary(Branch) ->
    case binary:split(Branch, <<".">>, [global]) of
        [Maj, <<"x">>] ->
            try
                {release, binary_to_integer(Maj), 0}
            catch
                _:_ -> {release, 0, 0}
            end;
        [Maj, Min, <<"x">>] ->
            try
                {release, binary_to_integer(Maj), binary_to_integer(Min)}
            catch
                _:_ -> {release, 0, 0}
            end;
        _ ->
            {release, 0, 0}
    end;
ensure_compat_version(V) when is_tuple(V) -> V;
ensure_compat_version(V) when is_binary(V) ->
    case V of
        <<"v", Rest/binary>> ->
            try
                Parts = binary:split(Rest, <<".">>, [global]),
                case Parts of
                    [Maj, Min, Pat] ->
                        {
                            binary_to_integer(Maj),
                            binary_to_integer(Min),
                            binary_to_integer(Pat)
                        };
                    _ ->
                        V
                end
            catch
                _:_ -> V
            end;
        _ ->
            V
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
                standard_error,
                "Usage: query Module:Function[/Arity] or Module.Function[/Arity]\n",
                []
            ),
            {error, Reason}
    end.

-doc """
Parse a query string in `Module:Function[/Arity]` format, or `Module.Function[/Arity]` format for Elixir modules.

Returns `{ok, Module, Function, Arity}` or `{ok, Module, Function}`
when no arity is specified, or `{error, Reason}` on invalid input.
""".
-spec parse_query_string(string()) ->
    {ok, binary(), binary(), arity()}
    | {ok, binary(), binary()}
    | {error, string()}.
parse_query_string(Query) ->
    % Try colon separator first (Erlang format)
    case string:split(Query, ":") of
        [ModStr, Rest] when ModStr =/= [] ->
            % Strip "Elixir." prefix for colon-form queries (Erlang format)
            StrippedModStr =
                case ModStr of
                    "Elixir." ++ RestMod -> RestMod;
                    _ -> ModStr
                end,
            case string:split(Rest, "/") of
                [FunStr, ArityStr] when FunStr =/= [] ->
                    case string:to_integer(ArityStr) of
                        {Arity, []} when Arity >= 0 ->
                            ModBin =
                                spectrometer_utils:normalize_module_name(
                                    StrippedModStr, false
                                ),
                            FunBin =
                                spectrometer_utils:string_to_binary(FunStr),
                            {ok, ModBin, FunBin, Arity};
                        _ ->
                            {error, "Invalid arity: " ++ ArityStr}
                    end;
                [FunStr] when FunStr =/= [] ->
                    ModBin =
                        spectrometer_utils:normalize_module_name(
                            StrippedModStr, false
                        ),
                    FunBin = spectrometer_utils:string_to_binary(FunStr),
                    {ok, ModBin, FunBin};
                _ ->
                    {error, "Empty function or invalid format"}
            end;
        _ ->
            % Try dot separator for Elixir format (Module.Function[/Arity])
            % Split on the last dot to separate module from function
            case string:split(Query, ".", trailing) of
                [ModStr, Rest] ->
                    case ModStr =/= [] andalso Rest =/= [] of
                        true ->
                            case string:split(Rest, "/") of
                                [FunStr, ArityStr] when FunStr =/= [] ->
                                    case string:to_integer(ArityStr) of
                                        {Arity, []} when Arity >= 0 ->
                                            ModBin =
                                                spectrometer_utils:normalize_module_name(
                                                    ModStr, true
                                                ),
                                            FunBin =
                                                spectrometer_utils:string_to_binary(
                                                    FunStr
                                                ),
                                            {ok, ModBin, FunBin, Arity};
                                        _ ->
                                            {error,
                                                "Invalid arity: " ++ ArityStr}
                                    end;
                                [FunStr] when FunStr =/= [] ->
                                    ModBin =
                                        spectrometer_utils:normalize_module_name(
                                            ModStr, true
                                        ),
                                    FunBin =
                                        spectrometer_utils:string_to_binary(
                                            FunStr
                                        ),
                                    {ok, ModBin, FunBin};
                                _ ->
                                    {error, "Empty function or invalid format"}
                            end;
                        false ->
                            {error, "Empty module or function"}
                    end;
                _ ->
                    {error,
                        "Invalid format. Use Module:Function, Module.Function, "
                        "Module:Function/Arity, or Module.Function/Arity"}
            end
    end.

-spec show_query({binary(), binary()} | {binary(), binary(), arity()}) -> ok.
show_query({Mod, Fun}) ->
    Supported = get_supported_functions(),
    Matches = [
        {Arity, Platforms, Removed}
     || {M, #function{
            name = Fn, arity = Arity, since_map = SM, removed = Removed
        }} <- Supported,
        M =:= Mod,
        Fn =:= Fun,
        begin
            Platforms = SM,
            true
        end
    ],
    case lists:sort(Matches) of
        [] ->
            io:format("~ts:~ts is NOT supported by AtomVM\n", [Mod, Fun]);
        ArityList ->
            io:format("~ts:~ts supported arities:\n", [Mod, Fun]),
            lists:foreach(
                fun({Arity, SinceMap, _Removed}) ->
                    io:format(
                        "  /~p  (~s)\n",
                        [
                            Arity,
                            format_platform_versions(SinceMap)
                        ]
                    )
                end,
                ArityList
            )
    end;
show_query({Mod, Fun, Arity}) ->
    case support_info({Mod, Fun, Arity}) of
        {true, SinceMap, Removed} ->
            RemovedStr =
                case Removed of
                    undefined -> "";
                    _ -> ", " ++ format_removed(Removed)
                end,
            io:format(
                "~ts:~ts/~p is SUPPORTED by AtomVM (~s~s)\n",
                [
                    Mod,
                    Fun,
                    Arity,
                    format_platform_versions(SinceMap),
                    RemovedStr
                ]
            );
        false ->
            io:format(
                "~ts:~ts/~p is NOT supported by AtomVM\n",
                [Mod, Fun, Arity]
            )
    end.

%% Format function name for display.
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
    Filter = maps:get(filter, Opts, undefined),
    case Opts of
        #{module := Mod} ->
            print_supported(Mod, Filter);
        #{} ->
            print_supported(Filter)
    end.

-spec print_supported(atom() | undefined) -> ok.
print_supported(Filter) ->
    Mods = supported_modules(),
    FilteredMods = filter_modules_by_type(Mods, Filter),
    io:format("AtomVM supported OTP modules (~p total):\n\n", [
        length(FilteredMods)
    ]),
    lists:foreach(
        fun(Mod) -> print_supported(Mod, Filter) end,
        lists:sort(FilteredMods)
    ).

-spec print_supported(binary(), atom() | undefined) ->
    ok | {error, unsupported}.
print_supported(Mod, Filter) ->
    % Validate filter matches module type
    case Filter of
        elixir_only ->
            case spectrometer_utils:is_elixir_module_name(Mod) of
                false ->
                    io:format(
                        standard_error,
                        "Module ~ts is not an Elixir module (filter: --ex)\n",
                        [format_mod_name(Mod)]
                    ),
                    {error, unsupported};
                true ->
                    do_print_supported(Mod)
            end;
        erlang_only ->
            case spectrometer_utils:is_elixir_module_name(Mod) of
                true ->
                    io:format(
                        standard_error,
                        "Module ~ts is not an Erlang module (filter: --erl)\n",
                        [format_mod_name(Mod)]
                    ),
                    {error, unsupported};
                false ->
                    do_print_supported(Mod)
            end;
        undefined ->
            do_print_supported(Mod)
    end.

-spec do_print_supported(binary()) -> ok.
do_print_supported(Mod) ->
    case supported_db_lookup(Mod) of
        {ok, Funs} ->
            io:format("~ts (~p functions):\n", [
                format_mod_name(Mod), length(Funs)
            ]),
            lists:foreach(
                fun(
                    #function{
                        name = Fn, arity = A, since_map = SM, removed = Removed
                    }
                ) ->
                    format_function_line(Fn, A, SM, Removed)
                end,
                lists:sort(Funs)
            ),
            io:format("\n");
        not_found ->
            io:format(
                standard_error,
                "Module ~ts not found in AtomVM supported database\n",
                [format_mod_name(Mod)]
            ),
            {error, unsupported}
    end.

-spec filter_modules_by_type([binary()], atom() | undefined) -> [binary()].
filter_modules_by_type(Mods, erlang_only) ->
    lists:filter(
        fun(Mod) -> not spectrometer_utils:is_elixir_module_name(Mod) end, Mods
    );
filter_modules_by_type(Mods, elixir_only) ->
    lists:filter(
        fun(Mod) -> spectrometer_utils:is_elixir_module_name(Mod) end, Mods
    );
filter_modules_by_type(Mods, undefined) ->
    Mods.

-spec supported_db_lookup(binary()) ->
    {ok, [#function{}]}
    | not_found.
supported_db_lookup(Mod) ->
    Supported = get_supported_functions(),
    ModFuns =
        [
            Rec
         || {M, Rec} <- Supported, M =:= Mod
        ],
    case ModFuns of
        [] -> not_found;
        _ -> {ok, ModFuns}
    end.

%% Format a single function line for output, showing per-platform versions
%% and optional removal annotation.
-spec format_function_line(binary(), non_neg_integer() | all, map(), version_tuple() | undefined) -> ok.
format_function_line(Fun, Arity, SinceMap, Removed) ->
    FunStr = format_fun_name(Fun),
    ArityStr =
        case Arity of
            all ->
                "*";
            _ when is_integer(Arity) -> integer_to_list(Arity)
        end,
    PlatformsStr = format_platform_versions(SinceMap),
    RemovedStr =
        case Removed of
            undefined -> "";
            _ -> ", " ++ format_removed(Removed)
        end,
    io:format(
        "  ~ts/~s  (~s~s)\n",
        [FunStr, ArityStr, PlatformsStr, RemovedStr]
    ).

%% Format a platform_versions() map for display.
%% e.g., #{esp32 => {0,5,0}, rp2 => {0,6,0}} → "esp32 since: v0.5.0, rp2 since: v0.6.0"
%%        #{all => {0,5,0}} → "all since: v0.5.0"
-spec format_platform_versions(map()) -> string().
format_platform_versions(SinceMap) ->
    Pairs = lists:map(
        fun({Platform, Version}) ->
            io_lib:format("~ts since: ~s", [
                atom_to_list(Platform),
                format_version_tuple(Version)
            ])
        end,
        lists:sort(fun({A, _}, {B, _}) -> A =< B end, maps:to_list(SinceMap))
    ),
    lists:flatten(string:join(Pairs, ", ")).

%% Format a version_tuple() for display.
%% {0,5,0} → "v0.5.0", {release,0,7} → "unreleased 0.7.x", {main,0,8} → "unreleased main"
-spec format_version_tuple(version_tuple() | binary()) -> string().
format_version_tuple({Maj, Min, Pat}) when
    is_integer(Maj), is_integer(Min), is_integer(Pat)
->
    "v" ++ integer_to_list(Maj) ++ "." ++ integer_to_list(Min) ++ "." ++
        integer_to_list(Pat);
format_version_tuple({release, Maj, Min}) ->
    "unreleased " ++ integer_to_list(Maj) ++ "." ++ integer_to_list(Min) ++
        ".x";
format_version_tuple({main, _Maj, _Min}) ->
    "unreleased main";
format_version_tuple({unreleased, Branch}) when is_binary(Branch) ->
    "unreleased " ++ binary_to_list(Branch);
format_version_tuple(Version) when is_binary(Version) ->
    binary_to_list(Version).

%% Format a removed version for display.
%% {0,7,0} → "REMOVED in v0.7.0"
-spec format_removed(version_tuple() | undefined) -> string().
format_removed(Removed) ->
    "REMOVED in " ++ format_version_tuple(Removed).

-spec format_fun_name(binary()) -> string().
format_fun_name(Fun) when is_binary(Fun) ->
    binary_to_list(Fun).

-spec format_mod_name(atom() | binary()) -> string().
format_mod_name(Mod) when is_atom(Mod) ->
    atom_to_list(Mod);
format_mod_name(Mod) when is_binary(Mod) ->
    binary_to_list(Mod).

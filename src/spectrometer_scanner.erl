%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
%%

-module(spectrometer_scanner).

-moduledoc """
Scans directories for Erlang source files and extracts function call statistics.

This module is the core scanning engine used by all scan operations. It
discovers `.erl` files in a directory tree (skipping symlinks), parses them
using `epp_dodger` and `erl_syntax_lib` for robust handling of malformed
source code, and extracts `Module:Function/Arity` call statistics.

The result is a map from `{<<"Module">>, <<"Function">>, Arity}` binary tuple
keys to call counts, which is consumed by the analyzer and reporter modules.
Binary keys prevent atom table exhaustion when scanning large ecosystems.
""".

-export([scan_directory/1, parse_calls/1]).

-include_lib("kernel/include/file.hrl").

-doc """
Scan a directory tree for Erlang source files and return function call statistics.

Walks the directory tree recursively, skipping symlinks to avoid infinite
loops. For each `.erl` file found, parses the source and extracts all
`Module:Function(...)` calls and `fun Module:Function/Arity` references.
BIF calls (e.g. `length/1`) are attributed to the `erlang` module.

Returns a map where keys are `{<<"Module">>, <<"Function">>, Arity}` binary tuples
and values are the number of times that function was called across all files.

#### Example

```erlang
1> spectrometer_scanner:scan_directory("/path/to/project").
#{<<"lists",map,2>> => 42, <<"io",format,2>> => 17, ...}
```
""".
-spec scan_directory(Dir :: string()) ->
    #{{binary(), binary(), non_neg_integer()} => non_neg_integer()}.
scan_directory(Dir) ->
    ErlFiles = find_erl_files(Dir),
    lists:foldl(
        fun(File, Acc) ->
            case parse_file(File) of
                {ok, Calls} ->
                    merge_file_calls(Calls, Acc);
                {error, _} ->
                    Acc
            end
        end,
        #{},
        ErlFiles
    ).

-doc false.
%% Recursively find .erl files in a directory, skipping symlinks.
find_erl_files(Dir) ->
    find_erl_files(Dir, []).

-doc false.
%% Accumulator variant of find_erl_files/1.
find_erl_files(Dir, Acc) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foldl(
                fun(Entry, A) ->
                    Path = filename:join(Dir, Entry),
                    case file:read_link_info(Path) of
                        {ok, #file_info{type = directory}} ->
                            case Entry of
                                "_build" -> A;
                                "deps" -> A;
                                ".rebar3" -> A;
                                ".git" -> A;
                                _ -> find_erl_files(Path, A)
                            end;
                        {ok, #file_info{type = regular}} ->
                            case filename:extension(Entry) of
                                ".erl" -> [Path | A];
                                _ -> A
                            end;
                        _ ->
                            A
                    end
                end,
                Acc,
                Entries
            );
        {error, _} ->
            Acc
    end.

-doc false.
%% Parse a single .erl file using epp_dodger for robust parsing.
%% Returns {ok, Calls} where Calls is a map of {ModBin,FunBin,Arity} => Count,
%% or {error, Reason} on failure.
parse_file(File) ->
    try
        case epp_dodger:parse_file(File) of
            {ok, Forms} ->
                Calls = lists:foldl(
                    fun extract_calls/2,
                    #{},
                    Forms
                ),
                {ok, Calls};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        _:Err ->
            {error, Err}
    end.

-doc false.
%% Parse an Erlang file and return module name with external function calls.
%% Returns {ok, ModuleName, Calls} or {error, Reason}.
%% Calls is a map from {<<"Module">>, <<"Function">>, Arity} to call count.
%% ModuleName is returned as binary for consistency.
-spec parse_calls(string()) ->
    {ok, binary() | undefined, map()}
    | {error, term()}.
parse_calls(File) ->
    try
        case epp_dodger:parse_file(File) of
            {ok, Forms} ->
                ModName = extract_module_name(Forms),
                {ok, ModName, extract_calls_filtered(Forms, ModName)};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        _:Err ->
            {error, Err}
    end.

-doc false.
%% Extract the module name from parsed forms.
%% Returns binary module name for consistency with scanner output format.
extract_module_name(Forms) ->
    extract_module_name(Forms, undefined).

extract_module_name([], Mod) ->
    Mod;
extract_module_name([Form | Rest], _Acc) ->
    case erl_syntax:type(Form) of
        attribute ->
            case erl_syntax:atom_value(erl_syntax:attribute_name(Form)) of
                module ->
                    case erl_syntax:attribute_arguments(Form) of
                        [ModArg] ->
                            case erl_syntax:type(ModArg) of
                                atom ->
                                    atom_to_binary(
                                        erl_syntax:atom_value(ModArg), utf8
                                    );
                                _ ->
                                    extract_module_name(Rest, undefined)
                            end;
                        _ ->
                            extract_module_name(Rest, undefined)
                    end;
                _ ->
                    extract_module_name(Rest, undefined)
            end;
        _ ->
            extract_module_name(Rest, undefined)
    end.

-doc false.
%% Extract calls, filtering out calls to the same module.
extract_calls_filtered(Forms, FilterMod) ->
    lists:foldl(
        fun(Form, Acc) ->
            erl_syntax_lib:fold(
                fun(Node, A) ->
                    case erl_syntax:type(Node) of
                        application ->
                            extract_application_filtered(Node, A, FilterMod);
                        implicit_fun ->
                            extract_implicit_fun(Node, A, FilterMod);
                        _ ->
                            A
                    end
                end,
                Acc,
                Form
            )
        end,
        #{},
        Forms
    ).

-doc false.
%% Extract application call, filtering out calls to FilterMod.
extract_application_filtered(Node, Acc, FilterMod) ->
    Op = erl_syntax:application_operator(Node),
    Args = erl_syntax:application_arguments(Node),
    Arity = length(Args),
    case erl_syntax:type(Op) of
        module_qualifier ->
            ModNode = erl_syntax:module_qualifier_argument(Op),
            FunNode = erl_syntax:module_qualifier_body(Op),
            case {erl_syntax:type(ModNode), erl_syntax:type(FunNode)} of
                {atom, atom} ->
                    Mod = erl_syntax:atom_value(ModNode),
                    Fun = erl_syntax:atom_value(FunNode),
                    ModBin = atom_to_binary(Mod, utf8),
                    % Skip calls to the same module being tested
                    case ModBin =:= FilterMod of
                        true ->
                            Acc;
                        false ->
                            Key = {ModBin, atom_to_binary(Fun, utf8), Arity},
                            maps:update_with(Key, fun(V) -> V + 1 end, 1, Acc)
                    end;
                _ ->
                    Acc
            end;
        atom ->
            Fun = erl_syntax:atom_value(Op),
            case erl_internal:bif(Fun, Arity) of
                true ->
                    Key = {<<"erlang">>, atom_to_binary(Fun, utf8), Arity},
                    maps:update_with(Key, fun(V) -> V + 1 end, 1, Acc);
                false ->
                    Acc
            end;
        _ ->
            Acc
    end.

-doc false.
%% Extract function calls from a parsed form by walking the syntax tree.
extract_calls(Form, Acc) ->
    erl_syntax_lib:fold(
        fun(Node, A) ->
            case erl_syntax:type(Node) of
                application ->
                    extract_application_call(Node, A);
                implicit_fun ->
                    extract_implicit_fun(Node, A);
                _ ->
                    A
            end
        end,
        Acc,
        Form
    ).

-doc false.
%% Extract Module:Function(...) application calls from a syntax node.
extract_application_call(Node, Acc) ->
    Op = erl_syntax:application_operator(Node),
    Args = erl_syntax:application_arguments(Node),
    Arity = length(Args),
    case erl_syntax:type(Op) of
        module_qualifier ->
            ModNode = erl_syntax:module_qualifier_argument(Op),
            FunNode = erl_syntax:module_qualifier_body(Op),
            case {erl_syntax:type(ModNode), erl_syntax:type(FunNode)} of
                {atom, atom} ->
                    Mod = erl_syntax:atom_value(ModNode),
                    Fun = erl_syntax:atom_value(FunNode),
                    Key = {
                        atom_to_binary(Mod, utf8),
                        atom_to_binary(Fun, utf8),
                        Arity
                    },
                    maps:update_with(Key, fun(V) -> V + 1 end, 1, Acc);
                _ ->
                    Acc
            end;
        atom ->
            Fun = erl_syntax:atom_value(Op),
            case erl_internal:bif(Fun, Arity) of
                true ->
                    Key = {<<"erlang">>, atom_to_binary(Fun, utf8), Arity},
                    maps:update_with(Key, fun(V) -> V + 1 end, 1, Acc);
                false ->
                    Acc
            end;
        _ ->
            Acc
    end.

-doc false.
%% Extract fun Module:Function/Arity references from a syntax node.
extract_implicit_fun(Node, Acc) ->
    Name = erl_syntax:implicit_fun_name(Node),
    case erl_syntax:type(Name) of
        module_qualifier ->
            ModNode = erl_syntax:module_qualifier_argument(Name),
            Body = erl_syntax:module_qualifier_body(Name),
            case erl_syntax:type(Body) of
                arity_qualifier ->
                    FunNode = erl_syntax:arity_qualifier_body(Body),
                    ArityNode = erl_syntax:arity_qualifier_argument(Body),
                    case
                        {
                            erl_syntax:type(ModNode),
                            erl_syntax:type(FunNode),
                            erl_syntax:type(ArityNode)
                        }
                    of
                        {atom, atom, integer} ->
                            Mod = erl_syntax:atom_value(ModNode),
                            Fun = erl_syntax:atom_value(FunNode),
                            Arity = erl_syntax:integer_value(ArityNode),
                            Key = {
                                atom_to_binary(Mod, utf8),
                                atom_to_binary(Fun, utf8),
                                Arity
                            },
                            maps:update_with(Key, fun(V) -> V + 1 end, 1, Acc);
                        _ ->
                            Acc
                    end;
                _ ->
                    Acc
            end;
        _ ->
            Acc
    end.

-doc false.
%% Extract fun Module:Function/Arity references from a syntax node,
%% filtering out references to the same module being tested.
extract_implicit_fun(Node, Acc, FilterMod) ->
    Name = erl_syntax:implicit_fun_name(Node),
    case erl_syntax:type(Name) of
        module_qualifier ->
            ModNode = erl_syntax:module_qualifier_argument(Name),
            Body = erl_syntax:module_qualifier_body(Name),
            case erl_syntax:type(Body) of
                arity_qualifier ->
                    FunNode = erl_syntax:arity_qualifier_body(Body),
                    ArityNode = erl_syntax:arity_qualifier_argument(Body),
                    case
                        {
                            erl_syntax:type(ModNode),
                            erl_syntax:type(FunNode),
                            erl_syntax:type(ArityNode)
                        }
                    of
                        {atom, atom, integer} ->
                            Mod = erl_syntax:atom_value(ModNode),
                            Fun = erl_syntax:atom_value(FunNode),
                            Arity = erl_syntax:integer_value(ArityNode),
                            ModBin = atom_to_binary(Mod, utf8),
                            % Skip references to the same module being tested
                            case ModBin =:= FilterMod of
                                true ->
                                    Acc;
                                false ->
                                    Key =
                                        {ModBin, atom_to_binary(Fun, utf8),
                                            Arity},
                                    maps:update_with(
                                        Key, fun(V) -> V + 1 end, 1, Acc
                                    )
                            end;
                        _ ->
                            Acc
                    end;
                _ ->
                    Acc
            end;
        _ ->
            Acc
    end.

-doc false.
%% Merge per-file call statistics into the repository accumulator.
merge_file_calls(FileCalls, RepoAcc) ->
    maps:fold(
        fun(Key, Count, Acc) ->
            maps:update_with(Key, fun(V) -> V + Count end, Count, Acc)
        end,
        RepoAcc,
        FileCalls
    ).

%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
-module(atomvm_spectrometer).

-moduledoc """
Main entry point for the atomvm_spectrometer application.

This module is the primary user-facing interface that orchestrates all CLI
commands. It handles argument parsing, command dispatch, and coordination
of audit, ecosystem, supported, filter, update, and query operations.
""".

-export([main/1]).

-export_type([opts_map/0]).

-type parse_arg_result() :: {error, string()} | opts_map().

-type command_name() ::
    audit | ecosystem | examine | supported | filter | update | query.

-type opts_map() :: #{atom() => term()}.

-doc """
Entry point for the CLI.

Parses the given arguments, dispatches to the appropriate command handler,
and terminates the process. In test mode (`TEST=true`), returns `ok` or
`{error, {halt, Code}}` instead of calling `halt/1`.
""".
-ifdef(TEST).
-spec main([string()]) -> ok | {error, {halt, non_neg_integer()}}.
-else.
-spec main([string()]) -> no_return().
-endif.
main(Args) ->
    case parse_args(Args) of
        {error, Msg} ->
            io:format(standard_error, "Error: ~s\n", [Msg]),
            spectrometer_help:usage(),
            maybe_halt(1);
        version ->
            case spectrometer_utils:version() of
                {error, Reason} ->
                    io:format("Unable to determine version: ~p\n", [Reason]),
                    maybe_halt(1);
                Version ->
                    io:format("~s\n", [Version]),
                    maybe_halt(0)
            end;
        help ->
            spectrometer_help:usage(),
            maybe_halt(0);
        {help, Cmd} ->
            spectrometer_help:usage(Cmd),
            maybe_halt(0);
        {command, audit, Opts} ->
            case spectrometer_analyzer:audit(Opts) of
                ok ->
                    maybe_halt(0);
                {error, Reason} ->
                    io:format("Audit failed, ~p.\n", [Reason]),
                    maybe_halt(1)
            end;
        {command, ecosystem, Opts} ->
            case spectrometer_ecosystem:run(Opts) of
                ok ->
                    maybe_halt(0);
                {error, Reason} ->
                    io:format("Ecosystem scanning failed, ~p.\n", [Reason]),
                    maybe_halt(1)
            end;
        {command, examine, Opts} ->
            case spectrometer_analyzer:examine(Opts) of
                ok ->
                    maybe_halt(0);
                {error, Reason} ->
                    io:format("Examine failed, ~p.\n", [Reason]),
                    maybe_halt(1)
            end;
        {command, supported, Opts} ->
            case spectrometer_atomvm:report_supported(Opts) of
                ok -> maybe_halt(0);
                {error, _} -> maybe_halt(1)
            end;
        {command, filter, Opts} ->
            case spectrometer_analyzer:filter(Opts) of
                ok ->
                    maybe_halt(0);
                {error, Reason} ->
                    io:format("Filter failed: ~p\n", [Reason]),
                    maybe_halt(1)
            end;
        {command, update, Opts} ->
            case spectrometer_updater:update(Opts) of
                ok -> maybe_halt(0);
                {error, _} -> maybe_halt(1)
            end;
        {command, query, Opts} ->
            case spectrometer_atomvm:query(Opts) of
                ok -> maybe_halt(0);
                {error, _} -> maybe_halt(1)
            end
    end.

-doc false.
-ifdef(TEST).
-spec maybe_halt(non_neg_integer()) -> ok | {error, {halt, non_neg_integer()}}.
maybe_halt(0) ->
    ok;
maybe_halt(Code) ->
    {error, {halt, Code}}.
-else.
-spec maybe_halt(non_neg_integer()) -> no_return().
maybe_halt(Code) ->
    halt(Code).
-endif.

-doc """
Parse command-line arguments and return the command dispatch tuple.

Returns `help`, `{help, Command}`, `{command, Command, Opts}`, or
`{error, Message}`.
""".
-spec parse_args([string()]) ->
    {error, string()}
    | version
    | help
    | {help, command_name()}
    | {command, command_name(), opts_map()}.
parse_args([]) ->
    help;
parse_args(["--help" | _]) ->
    help;
parse_args(["-h" | _]) ->
    help;
parse_args(["help" | Args]) ->
    parse_help_args(Args);
parse_args(["--version" | Args]) ->
    parse_version_args(Args);
parse_args(["version" | Args]) ->
    parse_version_args(Args);
parse_args(["audit" | Rest]) ->
    case lists:any(fun(E) -> lists:member(E, ["-h", "--help"]) end, Rest) of
        false ->
            case parse_audit_args(Rest, #{}) of
                {error, Msg} -> {error, Msg};
                Opts when is_map(Opts) -> {command, audit, Opts}
            end;
        _ ->
            {help, audit}
    end;
parse_args(["ecosystem" | Rest]) ->
    case lists:any(fun(E) -> lists:member(E, ["-h", "--help"]) end, Rest) of
        false ->
            case parse_ecosystem_args(Rest, default_eco_opts()) of
                {error, Msg} -> {error, Msg};
                Opts when is_map(Opts) -> {command, ecosystem, Opts}
            end;
        _ ->
            {help, ecosystem}
    end;
parse_args(["examine" | Rest]) ->
    case lists:any(fun(E) -> lists:member(E, ["-h", "--help"]) end, Rest) of
        false ->
            %% examine and audit have the same options
            case parse_audit_args(Rest, #{}) of
                {error, Msg} -> {error, Msg};
                Opts when is_map(Opts) -> {command, examine, Opts}
            end;
        _ ->
            {help, examine}
    end;
parse_args(["supported" | Rest]) ->
    case lists:any(fun(E) -> lists:member(E, ["-h", "--help"]) end, Rest) of
        false ->
            case parse_supported_args(Rest, #{}) of
                {error, Msg} -> {error, Msg};
                Opts when is_map(Opts) -> {command, supported, Opts}
            end;
        _ ->
            {help, supported}
    end;
parse_args(["filter" | Rest]) ->
    case lists:any(fun(E) -> lists:member(E, ["-h", "--help"]) end, Rest) of
        false ->
            case parse_filter_args(Rest, #{}) of
                {error, Msg} -> {error, Msg};
                Opts when is_map(Opts) -> {command, filter, Opts}
            end;
        _ ->
            {help, filter}
    end;
parse_args(["update" | Rest]) ->
    case lists:any(fun(E) -> lists:member(E, ["-h", "--help"]) end, Rest) of
        false ->
            case parse_update_args(Rest, #{}) of
                {error, Msg} -> {error, Msg};
                Opts when is_map(Opts) -> {command, update, Opts}
            end;
        _ ->
            {help, update}
    end;
parse_args(["query" | Rest]) ->
    case lists:any(fun(E) -> lists:member(E, ["-h", "--help"]) end, Rest) of
        false ->
            case parse_query_args(Rest, #{}) of
                {error, Msg} -> {error, Msg};
                Opts when is_map(Opts) -> {command, query, Opts}
            end;
        _ ->
            {help, query}
    end;
parse_args([Unknown | _]) ->
    {error, "Unsupported command " ++ Unknown}.

parse_help_args([Cmd | _]) ->
    case Cmd of
        "audit" -> {help, audit};
        "ecosystem" -> {help, ecosystem};
        "examine" -> {help, examine};
        "supported" -> {help, supported};
        "filter" -> {help, filter};
        "update" -> {help, update};
        "query" -> {help, query};
        _ -> {error, "Unknown command: " ++ Cmd}
    end;
parse_help_args([]) ->
    help.

-spec parse_version_args(Args :: [string()]) -> version | help.
parse_version_args([]) ->
    version;
parse_version_args(Args) ->
    case lists:any(fun(E) -> lists:member(E, ["-h", "--help"]) end, Args) of
        false -> version;
        _ -> help
    end.

-spec parse_audit_args([string()], opts_map()) -> parse_arg_result().
parse_audit_args([], #{target := _} = Opts) ->
    Opts#{
        top => maps:get(top, Opts, 50),
        min_count => maps:get(min_count, Opts, 1),
        output => maps:get(output, Opts, undefined)
    };
parse_audit_args([], #{multi_file := _} = Opts) ->
    Opts#{
        top => maps:get(top, Opts, 50),
        min_count => maps:get(min_count, Opts, 1),
        output => maps:get(output, Opts, undefined)
    };
parse_audit_args([], Opts) ->
    case Opts of
        #{target := _} ->
            Opts;
        #{} ->
            {error,
                "No target specified. Use --github, --hex, --dir, or --multi"}
    end;
parse_audit_args(["--github", Url | Rest], Opts) ->
    Target = {github_url, Url},
    parse_audit_args(Rest, Opts#{target => Target});
parse_audit_args(["--hex", Pkg | Rest], #{version := Ver} = Opts) ->
    NewOpts = maps:remove(version, Opts),
    parse_audit_args(Rest, NewOpts#{target => {hex, Pkg, Ver}});
parse_audit_args(["--hex", Pkg | Rest], Opts) ->
    parse_audit_args(Rest, Opts#{target => {hex, Pkg}});
parse_audit_args(["--version", Ver | Rest], Opts) ->
    case Opts of
        #{target := {hex, Name}} ->
            parse_audit_args(Rest, Opts#{target => {hex, Name, Ver}});
        #{} ->
            parse_audit_args(Rest, Opts#{version => Ver})
    end;
parse_audit_args(["--dir", Dir | Rest], Opts) ->
    Target = {local_dir, Dir},
    parse_audit_args(Rest, Opts#{target => Target});
parse_audit_args(["--multi", File | Rest], Opts) ->
    parse_audit_args(Rest, Opts#{multi_file => File});
parse_audit_args(["-o", File | Rest], Opts) ->
    parse_audit_args(Rest, Opts#{output => File});
parse_audit_args(["--output", File | Rest], Opts) ->
    parse_audit_args(Rest, Opts#{output => File});
parse_audit_args(["--cache", Dir | Rest], Opts) ->
    parse_audit_args(Rest, Opts#{cache_dir => Dir});
parse_audit_args(["-c", Dir | Rest], Opts) ->
    parse_audit_args(Rest, Opts#{cache_dir => Dir});
parse_audit_args(["--top", N | Rest], Opts) ->
    case string:to_integer(N) of
        {V, []} when V > 0 -> parse_audit_args(Rest, Opts#{top => V});
        _ -> {error, "Invalid --top value: " ++ N}
    end;
parse_audit_args(["--min-count", N | Rest], Opts) ->
    case string:to_integer(N) of
        {V, []} when V > 0 ->
            parse_audit_args(Rest, Opts#{min_count => V});
        _ ->
            {error, "Invalid --min-count value: " ++ N}
    end;
parse_audit_args([Unknown | _], _Opts) ->
    {error, "Unknown option: " ++ Unknown}.

-spec default_eco_opts() -> opts_map().
default_eco_opts() ->
    #{
        workers => 4,
        github => true,
        hex => true,
        limit => infinity,
        resume => false
    }.

-spec parse_ecosystem_args([string()], opts_map()) ->
    parse_arg_result() | {error, Reason :: term()}.
parse_ecosystem_args([], Opts) ->
    Opts;
parse_ecosystem_args(["--workers", N | Rest], Opts) ->
    case string:to_integer(N) of
        {V, []} when V > 0 ->
            parse_ecosystem_args(Rest, Opts#{workers => V});
        _ ->
            {error, "Invalid --workers value: " ++ N}
    end;
parse_ecosystem_args(["--github-only" | Rest], Opts) ->
    parse_ecosystem_args(Rest, Opts#{hex => false});
parse_ecosystem_args(["--hex-only" | Rest], Opts) ->
    parse_ecosystem_args(Rest, Opts#{github => false});
parse_ecosystem_args(["--limit", N | Rest], Opts) ->
    case string:to_integer(N) of
        {V, []} when V > 0 ->
            parse_ecosystem_args(Rest, Opts#{limit => V});
        _ ->
            {error, "Invalid --limit value: " ++ N}
    end;
parse_ecosystem_args(["--stars", N | Rest], Opts) ->
    case string:to_integer(N) of
        {V, []} when V > 0 ->
            parse_ecosystem_args(Rest, Opts#{stars => V});
        _ ->
            {error, "Invalid --stars value: " ++ N}
    end;
parse_ecosystem_args(["--resume" | Rest], Opts) ->
    parse_ecosystem_args(Rest, Opts#{resume => true});
parse_ecosystem_args(["--cache-dir", Dir | Rest], Opts) ->
    parse_ecosystem_args(Rest, Opts#{cache_dir => Dir});
parse_ecosystem_args([Unknown | _], _Opts) ->
    {error, "Unknown option: " ++ Unknown}.

-spec parse_supported_args([string()], opts_map()) ->
    parse_arg_result() | {error, Reason :: term()}.
parse_supported_args([], Opts) ->
    Opts;
parse_supported_args(["--module", Mod | Rest], Opts) ->
    Bin = spectrometer_utils:normalize_module_name(Mod),
    parse_supported_args(Rest, Opts#{module => Bin});
parse_supported_args(["-m", Mod | Rest], Opts) ->
    Bin = spectrometer_utils:normalize_module_name(Mod),
    parse_supported_args(Rest, Opts#{module => Bin});
parse_supported_args(["--cache", Dir | Rest], Opts) ->
    parse_supported_args(Rest, Opts#{cache_dir => Dir});
parse_supported_args(["-c", Dir | Rest], Opts) ->
    parse_supported_args(Rest, Opts#{cache_dir => Dir});
parse_supported_args(["--erl" | Rest], Opts) ->
    parse_supported_args(Rest, Opts#{filter => erlang_only});
parse_supported_args(["--ex" | Rest], Opts) ->
    parse_supported_args(Rest, Opts#{filter => elixir_only});
parse_supported_args([Unknown | _], _) ->
    Reason = io_lib:format("unknown option ~s", [Unknown]),
    {error, Reason}.

-spec parse_filter_args([string()], opts_map()) -> parse_arg_result().
parse_filter_args([], Opts) ->
    Opts#{min_repos => maps:get(min_repos, Opts, 1)};
parse_filter_args(["--cache", Dir | Rest], Opts) ->
    parse_filter_args(Rest, Opts#{cache_dir => Dir});
parse_filter_args(["-c", Dir | Rest], Opts) ->
    parse_filter_args(Rest, Opts#{cache_dir => Dir});
parse_filter_args(["--min-repos", N | Rest], Opts) ->
    case string:to_integer(N) of
        {V, []} when V > 0 ->
            parse_filter_args(Rest, Opts#{min_repos => V});
        _ ->
            {error, "Invalid --min-repos value: " ++ N}
    end;
parse_filter_args(["--avm" | Rest], Opts) ->
    parse_filter_args(Rest, Opts#{avm => true});
parse_filter_args(["--csv", File | Rest], Opts) ->
    parse_filter_args(Rest, Opts#{csv_file => File});
parse_filter_args([MaybeFile | Rest], Opts) ->
    case MaybeFile of
        "--" ++ _ ->
            {error, "unknown option " ++ MaybeFile};
        "-" ++ _ ->
            {error, "unknown option " ++ MaybeFile};
        _ ->
            case maps:is_key(csv_file, Opts) of
                false ->
                    parse_filter_args(Rest, Opts#{csv_file => MaybeFile});
                true ->
                    {error, "unsupported option " ++ MaybeFile}
            end
    end.

-spec parse_query_args([string()], opts_map()) -> parse_arg_result().
parse_query_args([], #{query := _Q} = Opts) ->
    Opts;
parse_query_args([], _) ->
    {error,
        "No function specified. Usage: query Module:Function/Arity or Module.Function[/Arity]"};
parse_query_args(["--cache", Dir | Rest], Opts) ->
    parse_query_args(Rest, Opts#{cache_dir => Dir});
parse_query_args(["-c", Dir | Rest], Opts) ->
    parse_query_args(Rest, Opts#{cache_dir => Dir});
parse_query_args([Query | Rest], Opts) ->
    case maps:is_key(query, Opts) of
        false -> parse_query_args(Rest, Opts#{query => Query});
        true -> {error, "Multiple queries specified"}
    end.

-spec parse_update_args([string()], opts_map()) -> parse_arg_result().
parse_update_args([], Opts) ->
    Opts#{
        branch => maps:get(branch, Opts, "main"),
        tests => maps:get(tests, Opts, true),
        cache_dir => maps:get(
            cache_dir,
            Opts,
            spectrometer_utils:user_cache_path()
        )
    };
parse_update_args(["--atomvm-dir", Dir | Rest], Opts) ->
    parse_update_args(Rest, Opts#{atomvm_dir => Dir});
parse_update_args(["--branch", Branch | Rest], Opts) ->
    parse_update_args(Rest, Opts#{branch => Branch});
parse_update_args(["--tag", Tag | Rest], Opts) ->
    parse_update_args(Rest, Opts#{tag => Tag});
parse_update_args(["--output", File | Rest], Opts) ->
    parse_update_args(Rest, Opts#{output => File});
parse_update_args(["--cache", Dir | Rest], Opts) ->
    parse_update_args(Rest, Opts#{cache_dir => Dir});
parse_update_args(["-c", Dir | Rest], Opts) ->
    parse_update_args(Rest, Opts#{cache_dir => Dir});
parse_update_args(["--no-tests" | Rest], Opts) ->
    parse_update_args(Rest, Opts#{tests => false});
parse_update_args(["--force" | Rest], Opts) ->
    parse_update_args(Rest, Opts#{force => true});
parse_update_args([Unknown | _], _Opts) ->
    {error, "Unknown option: " ++ Unknown}.

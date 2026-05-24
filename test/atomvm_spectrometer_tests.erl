%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(atomvm_spectrometer_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% maybe_halt/1 tests - Test mode exit handling
%% =============================================================================

maybe_halt_zero_test_() ->
    {"maybe_halt(0) returns ok in test mode", fun() ->
        ?assertEqual(ok, atomvm_spectrometer:maybe_halt(0))
    end}.

maybe_halt_nonzero_test_() ->
    {"maybe_halt(Code) returns error tuple in test mode", fun() ->
        ?assertEqual({error, {halt, 1}}, atomvm_spectrometer:maybe_halt(1)),
        ?assertEqual({error, {halt, 2}}, atomvm_spectrometer:maybe_halt(2)),
        ?assertEqual({error, {halt, 127}}, atomvm_spectrometer:maybe_halt(127))
    end}.

%% =============================================================================
%% parse_args/1 tests - Top-level argument parsing
%% =============================================================================

parse_args_empty_test_() ->
    {"returns help for empty args", fun() ->
        Result = atomvm_spectrometer:parse_args([]),
        ?assertEqual(help, Result)
    end}.

parse_args_help_flags_test_() ->
    {"recognizes --help and -h flags", fun() ->
        ?assertEqual(help, atomvm_spectrometer:parse_args(["--help"])),
        ?assertEqual(help, atomvm_spectrometer:parse_args(["-h"])),
        ?assertEqual(help, atomvm_spectrometer:parse_args(["--help", "audit"])),
        ?assertEqual(help, atomvm_spectrometer:parse_args(["-h", "ecosystem"])),
        %% Test --help for each command
        ?assertEqual(
            {help, supported},
            atomvm_spectrometer:parse_args(["supported", "--help"])
        ),
        ?assertEqual(
            {help, examine},
            atomvm_spectrometer:parse_args(["examine", "--help"])
        ),
        ?assertEqual(
            {help, filter}, atomvm_spectrometer:parse_args(["filter", "--help"])
        ),
        ?assertEqual(
            {help, update}, atomvm_spectrometer:parse_args(["update", "--help"])
        ),
        ?assertEqual(
            {help, query}, atomvm_spectrometer:parse_args(["query", "--help"])
        )
    end}.

parse_args_help_command_test_() ->
    {"handles help subcommands", fun() ->
        ?assertEqual(help, atomvm_spectrometer:parse_args(["help"])),
        ?assertEqual(
            {help, audit}, atomvm_spectrometer:parse_args(["help", "audit"])
        ),
        ?assertEqual(
            {help, examine}, atomvm_spectrometer:parse_args(["help", "examine"])
        ),
        ?assertEqual(
            {help, ecosystem},
            atomvm_spectrometer:parse_args(["help", "ecosystem"])
        ),
        ?assertEqual(
            {help, supported},
            atomvm_spectrometer:parse_args(["help", "supported"])
        ),
        ?assertEqual(
            {help, filter}, atomvm_spectrometer:parse_args(["help", "filter"])
        ),
        ?assertEqual(
            {help, update}, atomvm_spectrometer:parse_args(["help", "update"])
        ),
        ?assertEqual(
            {help, query}, atomvm_spectrometer:parse_args(["help", "query"])
        )
    end}.

parse_args_command_help_flags_test_() ->
    {"handles COMMAND -h and COMMAND --help", fun() ->
        ?assertEqual(
            {help, audit}, atomvm_spectrometer:parse_args(["audit", "-h"])
        ),
        ?assertEqual(
            {help, audit}, atomvm_spectrometer:parse_args(["audit", "--help"])
        ),
        ?assertEqual(
            {help, ecosystem},
            atomvm_spectrometer:parse_args(["ecosystem", "-h"])
        ),
        ?assertEqual(
            {help, ecosystem},
            atomvm_spectrometer:parse_args(["ecosystem", "--help"])
        ),
        ?assertEqual(
            {help, supported},
            atomvm_spectrometer:parse_args(["supported", "-h"])
        ),
        ?assertEqual(
            {help, supported},
            atomvm_spectrometer:parse_args(["supported", "--help"])
        ),
        ?assertEqual(
            {help, examine}, atomvm_spectrometer:parse_args(["examine", "-h"])
        ),
        ?assertEqual(
            {help, examine},
            atomvm_spectrometer:parse_args(["examine", "--help"])
        ),
        ?assertEqual(
            {help, filter}, atomvm_spectrometer:parse_args(["filter", "-h"])
        ),
        ?assertEqual(
            {help, update}, atomvm_spectrometer:parse_args(["update", "-h"])
        ),
        ?assertEqual(
            {help, query}, atomvm_spectrometer:parse_args(["query", "-h"])
        )
    end}.

parse_args_unknown_help_test_() ->
    {"returns error for unknown help command", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args(["help", "unknown"]),
        ?assert(string:str(Msg, "Unknown command") > 0)
    end}.

parse_args_unknown_command_test_() ->
    {"returns error for unknown command", fun() ->
        %% Unknown commands at top level cause function_clause (intentional)
        ?assertEqual(
            {error, "Unsupported command foobar"},
            atomvm_spectrometer:parse_args(["foobar"])
        )
    end}.

%% =============================================================================
%% parse_scan_args/2 tests
%% =============================================================================

parse_scan_args_github_test_() ->
    {"parses --github URL", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit", "--github", "https://github.com/user/repo"
        ]),
        ?assertEqual(
            {github_url, "https://github.com/user/repo"}, maps:get(target, Opts)
        )
    end}.

parse_scan_args_hex_test_() ->
    {"parses --hex package", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit", "--hex", "jsx"
        ]),
        ?assertEqual({hex, "jsx"}, maps:get(target, Opts))
    end}.

parse_scan_args_hex_version_test_() ->
    {"parses --hex with --version", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit", "--hex", "cowboy", "--version", "3.1.0"
        ]),
        ?assertEqual({hex, "cowboy", "3.1.0"}, maps:get(target, Opts))
    end}.

parse_scan_args_version_hex_test_() ->
    {"parses --version before --hex folds version into target", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit", "--version", "3.1.0", "--hex", "cowboy"
        ]),
        ?assertEqual({hex, "cowboy", "3.1.0"}, maps:get(target, Opts)),
        % Ensure version key is removed from final opts
        ?assertNot(maps:is_key(version, Opts))
    end}.

parse_scan_args_dir_test_() ->
    {"parses --dir path", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit", "--dir", "/path/to/project"
        ]),
        ?assertEqual({local_dir, "/path/to/project"}, maps:get(target, Opts))
    end}.

parse_scan_args_output_test_() ->
    {"parses -o and --output", fun() ->
        {command, audit, Opts1} = atomvm_spectrometer:parse_args([
            "audit",
            "--github",
            "https://github.com/user/repo",
            "-o",
            "report.csv"
        ]),
        ?assertEqual("report.csv", maps:get(output, Opts1)),
        {command, audit, Opts2} = atomvm_spectrometer:parse_args([
            "audit",
            "--github",
            "https://github.com/user/repo",
            "--output",
            "report.csv"
        ]),
        ?assertEqual("report.csv", maps:get(output, Opts2))
    end}.

parse_scan_args_top_test_() ->
    {"parses --top N", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit", "--github", "https://github.com/user/repo", "--top", "20"
        ]),
        ?assertEqual(20, maps:get(top, Opts))
    end}.

parse_scan_args_min_count_test_() ->
    {"parses --min-count N", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit",
            "--github",
            "https://github.com/user/repo",
            "--min-count",
            "5"
        ]),
        ?assertEqual(5, maps:get(min_count, Opts))
    end}.

parse_scan_args_missing_target_test_() ->
    {"returns error for missing target", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args(["audit"]),
        ?assert(string:str(Msg, "No target") > 0)
    end}.

parse_scan_args_invalid_top_test_() ->
    {"returns error for invalid --top value", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args([
            "audit", "--github", "https://github.com/user/repo", "--top", "abc"
        ]),
        ?assert(string:str(Msg, "Invalid") > 0)
    end}.

parse_scan_args_invalid_min_count_test_() ->
    {"returns error for invalid --min-count value", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args([
            "audit",
            "--github",
            "https://github.com/user/repo",
            "--min-count",
            "-1"
        ]),
        ?assert(string:str(Msg, "Invalid") > 0)
    end}.

parse_scan_args_cache_long_test_() ->
    {"parses audit --cache dir", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit",
            "--github",
            "https://github.com/user/repo",
            "--cache",
            "/tmp/custom"
        ]),
        ?assertEqual("/tmp/custom", maps:get(cache_dir, Opts))
    end}.

parse_scan_args_cache_short_test_() ->
    {"parses audit -c dir", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit",
            "--github",
            "https://github.com/user/repo",
            "-c",
            "/tmp/custom"
        ]),
        ?assertEqual("/tmp/custom", maps:get(cache_dir, Opts))
    end}.

parse_supported_args_cache_long_test_() ->
    {"parses supported --cache dir", fun() ->
        {command, supported, Opts} = atomvm_spectrometer:parse_args([
            "supported", "--cache", "/tmp/custom"
        ]),
        ?assertEqual("/tmp/custom", maps:get(cache_dir, Opts))
    end}.

parse_update_args_cache_long_test_() ->
    {"parses update --cache dir", fun() ->
        {command, update, Opts} = atomvm_spectrometer:parse_args([
            "update", "--cache", "/tmp/custom"
        ]),
        ?assertEqual("/tmp/custom", maps:get(cache_dir, Opts))
    end}.

parse_filter_avm_test_() ->
    {"parses filter --avm", fun() ->
        {command, filter, Opts} = atomvm_spectrometer:parse_args([
            "filter", "--avm"
        ]),
        ?assertEqual(true, maps:get(avm, Opts))
    end}.

parse_query_cache_long_test_() ->
    {"parses query --cache dir", fun() ->
        {command, query, Opts} = atomvm_spectrometer:parse_args([
            "query", "--cache", "/tmp/custom", "lists:map"
        ]),
        ?assertEqual("/tmp/custom", maps:get(cache_dir, Opts))
    end}.

parse_scan_args_unknown_option_test_() ->
    {"returns error for unknown option", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args([
            "audit", "--github", "https://github.com/user/repo", "--unknown"
        ]),
        ?assert(string:str(Msg, "Unknown option") > 0)
    end}.

parse_scan_args_multi_test_() ->
    {"parses --multi file", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit", "--multi", "targets.txt"
        ]),
        ?assertEqual("targets.txt", maps:get(multi_file, Opts))
    end}.

parse_scan_args_version_standalone_test_() ->
    {"parses --version without --hex", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit",
            "--github",
            "https://github.com/user/repo",
            "--version",
            "1.0.0"
        ]),
        ?assertEqual("1.0.0", maps:get(version, Opts))
    end}.

parse_scan_args_output_flag_test_() ->
    {"parses --output flag", fun() ->
        {command, audit, Opts} = atomvm_spectrometer:parse_args([
            "audit",
            "--github",
            "https://github.com/user/repo",
            "--output",
            "report.csv"
        ]),
        ?assertEqual("report.csv", maps:get(output, Opts))
    end}.

%% =============================================================================
%% parse_ecosystem_args/2 tests
%% =============================================================================

parse_ecosystem_args_defaults_test_() ->
    {"uses default options", fun() ->
        {command, ecosystem, Opts} = atomvm_spectrometer:parse_args([
            "ecosystem"
        ]),
        ?assertEqual(4, maps:get(workers, Opts)),
        ?assertEqual(true, maps:get(github, Opts)),
        ?assertEqual(true, maps:get(hex, Opts)),
        ?assertEqual(infinity, maps:get(limit, Opts)),
        ?assertEqual(false, maps:get(resume, Opts))
    end}.

parse_ecosystem_args_workers_test_() ->
    {"parses --workers N", fun() ->
        {command, ecosystem, Opts} = atomvm_spectrometer:parse_args([
            "ecosystem", "--workers", "8"
        ]),
        ?assertEqual(8, maps:get(workers, Opts))
    end}.

parse_ecosystem_args_source_test_() ->
    {"parses --github-only and --hex-only", fun() ->
        {command, ecosystem, Opts1} = atomvm_spectrometer:parse_args([
            "ecosystem", "--github-only"
        ]),
        ?assertEqual(true, maps:get(github, Opts1)),
        ?assertEqual(false, maps:get(hex, Opts1)),
        {command, ecosystem, Opts2} = atomvm_spectrometer:parse_args([
            "ecosystem", "--hex-only"
        ]),
        ?assertEqual(false, maps:get(github, Opts2)),
        ?assertEqual(true, maps:get(hex, Opts2))
    end}.

parse_ecosystem_args_limit_test_() ->
    {"parses --limit N", fun() ->
        {command, ecosystem, Opts} = atomvm_spectrometer:parse_args([
            "ecosystem", "--limit", "100"
        ]),
        ?assertEqual(100, maps:get(limit, Opts))
    end}.

parse_ecosystem_args_resume_test_() ->
    {"parses --resume", fun() ->
        {command, ecosystem, Opts} = atomvm_spectrometer:parse_args([
            "ecosystem", "--resume"
        ]),
        ?assertEqual(true, maps:get(resume, Opts))
    end}.

parse_ecosystem_args_invalid_workers_test_() ->
    {"returns error for invalid --workers", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args([
            "ecosystem", "--workers", "abc"
        ]),
        ?assert(string:str(Msg, "Invalid") > 0)
    end}.

parse_ecosystem_args_invalid_limit_test_() ->
    {"returns error for invalid --limit value", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args([
            "ecosystem", "--limit", "abc"
        ]),
        ?assert(string:str(Msg, "Invalid") > 0)
    end}.

%% =============================================================================
%% parse_supported_args/2 tests
%% =============================================================================

parse_supported_args_basic_test_() ->
    {"parses supported command", fun() ->
        {command, supported, Opts} = atomvm_spectrometer:parse_args([
            "supported"
        ]),
        ?assertEqual(true, is_map(Opts))
    end}.

parse_supported_args_module_test_() ->
    {"parses --module option", fun() ->
        {command, supported, Opts} = atomvm_spectrometer:parse_args([
            "supported", "--module", "lists"
        ]),
        ?assertEqual(lists, maps:get(module, Opts))
    end}.

parse_supported_args_short_module_test_() ->
    {"parses -m option", fun() ->
        {command, supported, Opts} = atomvm_spectrometer:parse_args([
            "supported", "-m", "maps"
        ]),
        ?assertEqual(maps, maps:get(module, Opts))
    end}.

parse_supported_args_erl_test_() ->
    {"parses --erl flag", fun() ->
        {command, supported, Opts} = atomvm_spectrometer:parse_args(
            ["supported", "--erl"]
        ),
        ?assertEqual(erlang_only, maps:get(filter, Opts))
    end}.

parse_supported_args_ex_test_() ->
    {"parses --ex flag", fun() ->
        {command, supported, Opts} = atomvm_spectrometer:parse_args(
            ["supported", "--ex"]
        ),
        ?assertEqual(elixir_only, maps:get(filter, Opts))
    end}.

parse_supported_args_module_elixir_prefix_test_() ->
    {"parses --module with Elixir. prefix", fun() ->
        {command, supported, Opts} = atomvm_spectrometer:parse_args([
            "supported", "--module", "Elixir.GPIO"
        ]),
        ?assertEqual('Elixir.GPIO', maps:get(module, Opts))
    end}.

parse_supported_args_short_module_elixir_prefix_test_() ->
    {"parses -m with Elixir. prefix", fun() ->
        {command, supported, Opts} = atomvm_spectrometer:parse_args([
            "supported", "-m", "Elixir.List"
        ]),
        ?assertEqual('Elixir.List', maps:get(module, Opts))
    end}.

parse_supported_args_module_capitalized_no_prefix_test_() ->
    {"parses --module with capitalized name without Elixir. prefix (no auto-prefix with false flag)", fun() ->
        {command, supported, Opts} = atomvm_spectrometer:parse_args([
            "supported", "--module", "GPIO"
        ]),
        %% normalize_module_name/1 with false flag: "GPIO" -> 'GPIO'
        ?assertEqual('GPIO', maps:get(module, Opts))
    end}.

%% =============================================================================
%% parse_filter_args/2 tests
%% =============================================================================

parse_filter_args_csv_file_test_() ->
    {"parses CSV file argument", fun() ->
        {command, filter, Opts} = atomvm_spectrometer:parse_args([
            "filter", "results.csv"
        ]),
        ?assertEqual("results.csv", maps:get(csv_file, Opts)),
        ?assertEqual(1, maps:get(min_repos, Opts))
    end}.

parse_filter_args_min_repos_test_() ->
    {"parses --min-repos N", fun() ->
        {command, filter, Opts} = atomvm_spectrometer:parse_args([
            "filter", "results.csv", "--min-repos", "10"
        ]),
        ?assertEqual("results.csv", maps:get(csv_file, Opts)),
        ?assertEqual(10, maps:get(min_repos, Opts))
    end}.

parse_filter_args_no_csv_test_() ->
    {"allows no CSV file (loads from binary state)", fun() ->
        {command, filter, Opts} = atomvm_spectrometer:parse_args(["filter"]),
        %% Should not have csv_file key, will load from binary state at runtime
        ?assertNot(maps:is_key(csv_file, Opts)),
        ?assertEqual(1, maps:get(min_repos, Opts))
    end}.

parse_filter_args_csv_option_test_() ->
    {"parses --csv option", fun() ->
        {command, filter, Opts} = atomvm_spectrometer:parse_args([
            "filter", "--csv", "data.csv"
        ]),
        ?assertEqual("data.csv", maps:get(csv_file, Opts))
    end}.

parse_filter_args_multiple_csv_test_() ->
    {"returns error for multiple CSV files", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args([
            "filter", "file1.csv", "file2.csv"
        ]),
        ?assert(string:str(Msg, "unsupported option file2.csv") > 0)
    end}.

parse_filter_args_invalid_min_repos_test_() ->
    {"returns error for invalid --min-repos", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args([
            "filter", "results.csv", "--min-repos", "abc"
        ]),
        ?assert(string:str(Msg, "Invalid") > 0)
    end}.

parse_filter_args_flag_as_file_test_() ->
    {"returns error for flag-shaped option where csv_file expected", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args([
            "filter", "--unknown-flag"
        ]),
        ?assert(string:str(Msg, "unknown option") > 0),
        {error, Msg2} = atomvm_spectrometer:parse_args([
            "filter", "-x"
        ]),
        ?assert(string:str(Msg2, "unknown option") > 0)
    end}.

%% =============================================================================
%% parse_update_args/2 tests
%% =============================================================================

parse_update_args_defaults_test_() ->
    {"uses default options", fun() ->
        {command, update, Opts} = atomvm_spectrometer:parse_args(["update"]),
        ?assertEqual("main", maps:get(branch, Opts)),
        ?assertEqual(true, maps:get(tests, Opts))
    end}.

parse_update_args_atomvm_dir_test_() ->
    {"parses --atomvm-dir", fun() ->
        {command, update, Opts} = atomvm_spectrometer:parse_args([
            "update", "--atomvm-dir", "~/work/AtomVM"
        ]),
        ?assertEqual("~/work/AtomVM", maps:get(atomvm_dir, Opts))
    end}.

parse_update_args_branch_test_() ->
    {"parses --branch", fun() ->
        {command, update, Opts} = atomvm_spectrometer:parse_args([
            "update", "--branch", "release-0.6"
        ]),
        ?assertEqual("release-0.6", maps:get(branch, Opts))
    end}.

parse_update_args_tag_test_() ->
    {"parses --tag", fun() ->
        {command, update, Opts} = atomvm_spectrometer:parse_args([
            "update", "--tag", "v0.6.5"
        ]),
        ?assertEqual("v0.6.5", maps:get(tag, Opts))
    end}.

parse_update_args_no_tests_test_() ->
    {"parses --no-tests", fun() ->
        {command, update, Opts} = atomvm_spectrometer:parse_args([
            "update", "--no-tests"
        ]),
        ?assertEqual(false, maps:get(tests, Opts))
    end}.

parse_update_args_force_test_() ->
    {"parses --force", fun() ->
        {command, update, Opts} = atomvm_spectrometer:parse_args([
            "update", "--force"
        ]),
        ?assertEqual(true, maps:get(force, Opts))
    end}.

parse_update_args_output_test_() ->
    {"parses --output", fun() ->
        {command, update, Opts} = atomvm_spectrometer:parse_args([
            "update", "--output", "~/custom.term"
        ]),
        ?assertEqual("~/custom.term", maps:get(output, Opts))
    end}.

parse_update_args_unknown_test_() ->
    {"returns error for unknown option", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args(["update", "--unknown"]),
        ?assert(string:str(Msg, "Unknown option") > 0)
    end}.

%% =============================================================================
%% parse_query_args/2 tests
%% =============================================================================

parse_query_args_basic_test_() ->
    {"parses query argument", fun() ->
        {command, query, Opts} = atomvm_spectrometer:parse_args([
            "query", "lists:map"
        ]),
        ?assertEqual("lists:map", maps:get(query, Opts))
    end}.

parse_query_args_with_arity_test_() ->
    {"parses query with arity", fun() ->
        {command, query, Opts} = atomvm_spectrometer:parse_args([
            "query", "lists:map/2"
        ]),
        ?assertEqual("lists:map/2", maps:get(query, Opts))
    end}.

parse_query_args_missing_test_() ->
    {"returns error for missing query", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args(["query"]),
        ?assert(
            string:str(Msg, "No function") > 0 orelse
                string:str(Msg, "No query") > 0
        )
    end}.

parse_query_args_multiple_test_() ->
    {"returns error for multiple queries", fun() ->
        {error, Msg} = atomvm_spectrometer:parse_args([
            "query", "lists:map", "maps:get"
        ]),
        ?assert(string:str(Msg, "Multiple queries") > 0)
    end}.

%% =============================================================================
%% parse_query_string/1 tests
%% =============================================================================

parse_query_string_basic_test_() ->
    {"parses Module:Function", fun() ->
        ?assertEqual(
            {ok, lists, map},
            spectrometer_atomvm:parse_query_string("lists:map")
        )
    end}.

parse_query_string_with_arity_test_() ->
    {"parses Module:Function/Arity", fun() ->
        ?assertEqual(
            {ok, lists, map, 2},
            spectrometer_atomvm:parse_query_string("lists:map/2")
        ),
        ?assertEqual(
            {ok, gen_server, call, 3},
            spectrometer_atomvm:parse_query_string(
                "gen_server:call/3"
            )
        ),
        ?assertEqual(
            {ok, file, read_file, 1},
            spectrometer_atomvm:parse_query_string("file:read_file/1")
        )
    end}.

parse_query_string_zero_arity_test_() ->
    {"parses zero arity", fun() ->
        ?assertEqual(
            {ok, erlang, now, 0},
            spectrometer_atomvm:parse_query_string("erlang:now/0")
        )
    end}.

parse_query_string_without_arity_test_() ->
    {"returns ok for module query without arity", fun() ->
        ?assertEqual(
            {ok, module_xyz, foo},
            spectrometer_atomvm:parse_query_string("module_xyz:foo")
        )
    end}.

parse_invalid_query_string_test_() ->
    {"returns error for invalid query string", fun() ->
        {error, _} = spectrometer_atomvm:parse_query_string("foobar"),
        {error, Msg1} = spectrometer_atomvm:parse_query_string("foobar"),
        ?assert(string:str(Msg1, "Invalid format") > 0)
    end}.

parse_query_string_invalid_arity_test_() ->
    {"returns error for invalid arity", fun() ->
        {error, Msg} = spectrometer_atomvm:parse_query_string("foo:bar/abc"),
        ?assert(string:str(Msg, "Invalid arity") > 0)
    end}.

parse_query_string_elixir_formats_test_() ->
    {"parse Elixir query formats for Elixir.GPIO:digital_read", fun() ->
        FormatsWithArity = [
            {"Elixir.GPIO.digital_read/1",
                {ok, 'Elixir.GPIO', digital_read, 1}},
            {"GPIO.digital_read/1", {ok, 'Elixir.GPIO', digital_read, 1}},
            {"Elixir.GPIO:digital_read/1",
                {ok, 'Elixir.GPIO', digital_read, 1}},
            {"GPIO:digital_read/1", {ok, 'Elixir.GPIO', digital_read, 1}}
        ],
        FormatsNoArity = [
            {"Elixir.GPIO.digital_read", {ok, 'Elixir.GPIO', digital_read}},
            {"Elixir.GPIO:digital_read", {ok, 'Elixir.GPIO', digital_read}},
            {"GPIO.digital_read", {ok, 'Elixir.GPIO', digital_read}},
            {"GPIO:digital_read", {ok, 'Elixir.GPIO', digital_read}}
        ],
        lists:foreach(
            fun({Format, Expected}) ->
                ?assertEqual(
                    Expected, spectrometer_atomvm:parse_query_string(Format)
                )
            end,
            FormatsWithArity ++ FormatsNoArity
        )
    end}.

%% =============================================================================
%% Helper function tests
%% =============================================================================

parse_target_lines_test_() ->
    {"parses multi-file target lines", fun() ->
        Lines = [
            "https://github.com/user/repo",
            "hex:jsx",
            "/path/to/local/dir",
            "",
            "# This is a comment",
            "https://github.com/other/project.git"
        ],
        Targets = spectrometer_analyzer:parse_target_lines(Lines),
        ?assertEqual(4, length(Targets)),
        ?assert(
            lists:member({github_url, "https://github.com/user/repo"}, Targets)
        ),
        ?assert(lists:member({hex, "jsx"}, Targets)),
        ?assert(
            lists:member({github_url, "/path/to/local/dir"}, Targets)
        ),
        ?assert(
            lists:member(
                {github_url, "https://github.com/other/project.git"}, Targets
            )
        )
    end}.

parse_target_lines_local_dir_test_() ->
    {"detects local directories", fun() ->
        %% Create a temp directory to test local dir detection
        Dir = spectrometer_utils:make_temp_dir("test_local_dir_"),
        ok = filelib:ensure_path(Dir),
        try
            Lines = [Dir],
            Targets = spectrometer_analyzer:parse_target_lines(Lines),
            ?assert(lists:member({local_dir, Dir}, Targets))
        after
            cleanup_temp_dir(Dir)
        end
    end}.

cleanup_temp_dir(Dir) ->
    case file:del_dir_r(Dir) of
        ok ->
            ok;
        {error, Reason} ->
            io:format("Warning: failed to cleanup ~s: ~p\n", [Dir, Reason])
    end.

format_platforms_test_() ->
    {"formats platform lists", fun() ->
        ?assertEqual(
            "all", spectrometer_atomvm:format_platforms(all)
        ),
        ?assertEqual("esp32", spectrometer_atomvm:format_platforms([esp32])),
        ?assertEqual(
            "esp32, rp2", spectrometer_atomvm:format_platforms([esp32, rp2])
        ),
        ?assertEqual(
            "esp32, stm32, rp2",
            spectrometer_atomvm:format_platforms([esp32, stm32, rp2])
        )
    end}.

merge_repo_stats_test_() ->
    {"merges repository statistics", fun() ->
        RepoStats = #{
            {lists, map, 2} => 10,
            {io, format, 2} => 5
        },
        GlobalStats = #{
            {lists, map, 2} => {20, 2},
            {string, len, 1} => {7, 1}
        },
        Result = spectrometer_ecosystem:merge_repo_stats(
            RepoStats, GlobalStats
        ),
        %% Should sum total calls and repo count
        {TotalCalls1, RepoCount1} = maps:get({lists, map, 2}, Result),
        ?assertEqual(30, TotalCalls1),
        ?assertEqual(3, RepoCount1),
        {_, RepoCount2} = maps:get({io, format, 2}, Result),
        ?assertEqual(1, RepoCount2)
    end}.

work_key_test_() ->
    {"generates unique work keys", fun() ->
        ?assertEqual(
            "github:user/repo",
            spectrometer_ecosystem:work_key(github, #{full_name => "user/repo"})
        ),
        ?assertEqual(
            "hex:jsx",
            spectrometer_ecosystem:work_key(hex, #{name => "jsx"})
        )
    end}.

deduplicate_test_() ->
    {"removes duplicate repos", fun() ->
        GithubRepos = [
            #{
                full_name => "user/repo",
                html_url => "https://github.com/user/repo",
                clone_url => "https://github.com/user/repo.git",
                stars => 100
            }
        ],
        HexPackages = [
            #{
                name => "repo",
                version => "1.0.0",
                github_url => "https://github.com/user/repo"
            }
        ],
        {FilteredGithub, FilteredHex} = spectrometer_ecosystem:deduplicate(
            GithubRepos, HexPackages
        ),
        %% GitHub repos should remain
        ?assertEqual(1, length(FilteredGithub)),
        %% Hex package with same GitHub URL should be filtered out
        ?assertEqual(0, length(FilteredHex))
    end}.

is_otp_module_test_() ->
    {"identifies OTP modules", fun() ->
        ?assert(spectrometer_otp:is_otp_module(lists)),
        ?assert(spectrometer_otp:is_otp_module("lists")),
        ?assert(spectrometer_otp:is_otp_module(io)),
        ?assert(spectrometer_otp:is_otp_module("io")),
        ?assert(spectrometer_otp:is_otp_module("gen_server")),
        ?assertNot(spectrometer_otp:is_otp_module(some_random_fun)),
        ?assertNot(spectrometer_otp:is_otp_module("my_app_helper")),
        ?assertNot(spectrometer_otp:is_otp_module("nonexistent_module_xyz"))
    end}.

parse_csv_rows_test_() ->
    {"parses CSV data rows", fun() ->
        %% parse_csv_rows expects data lines only (header already removed by caller)
        Lines = [
            "lists,map,2,10,3",
            "io,format,2,5,2",
            ""
        ],
        Rows = spectrometer_analyzer:parse_csv_rows(Lines),
        ?assertEqual(2, length(Rows)),
        {Mod1, Fun1, Arity1, Calls1, RC1} = hd(Rows),
        ?assertEqual("lists", Mod1),
        ?assertEqual("map", Fun1),
        ?assertEqual(2, Arity1),
        ?assertEqual(10, Calls1),
        ?assertEqual(3, RC1)
    end}.

parse_csv_rows_with_repo_count_test_() ->
    {"parses CSV with repo_count column", fun() ->
        Lines = [
            "lists,map,2,10,5",
            ""
        ],
        Rows = spectrometer_analyzer:parse_csv_rows(Lines),
        ?assertEqual(1, length(Rows)),
        {_, _, _, _, RC} = hd(Rows),
        ?assertEqual(5, RC)
    end}.

%% =============================================================================
%% Usage/help output tests (verify functions exist and return ok)
%% =============================================================================

usage_functions_exist_test_() ->
    {"all usage functions return ok", fun() ->
        ?assertEqual(ok, spectrometer_help:usage()),
        ?assertEqual(ok, spectrometer_help:usage(audit)),
        ?assertEqual(ok, spectrometer_help:usage(ecosystem)),
        ?assertEqual(ok, spectrometer_help:usage(supported)),
        ?assertEqual(ok, spectrometer_help:usage(filter)),
        ?assertEqual(ok, spectrometer_help:usage(update)),
        ?assertEqual(ok, spectrometer_help:usage(query))
    end}.

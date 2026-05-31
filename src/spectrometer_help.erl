%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_help).

-export([
    usage/0,
    usage/1
]).

-type command() ::
    audit | ecosystem | examine | supported | filter | update | query.

-doc "Print general help text listing all commands.".
-spec usage() -> ok.
usage() ->
    io:format(
        "\nspectrometer ~s\n"
        "Usage: spectrometer [OPTIONS] COMMAND [COMMAND_OPTIONS]\n"
        "\n"
        "Options:\n"
        "  -h, --help     Display this help message\n"
        "  --version      Display version number\n"
        "\n"
        "Commands:\n"
        "  help         Show this help message\n"
        "  audit        Audit a single target (GitHub repo, Hex package, or directory)\n"
        "  ecosystem    Scan top GitHub repos and/or Hex packages\n"
        "  examine      Examine modules and functions provided by an application\n"
        "  supported    List all AtomVM-supported OTP functions\n"
        "  filter       Filter ecosystem audit CSV output by OTP module\n"
        "  update       Regenerate supported functions database from AtomVM sources\n"
        "  query        Query AtomVM function support by Module:Function[/Arity]\n"
        "  version      Display version number and exit\n"
        "\n"
        "Get detailed help on a command:\n"
        "  spectrometer help audit\n"
        "  spectrometer help ecosystem\n"
        "  spectrometer help examine\n"
        "  spectrometer help supported\n"
        "  spectrometer help filter\n"
        "  spectrometer help update\n"
        "  spectrometer help query\n",
        [spectrometer_utils:version()]
    ).

-doc "Print help text for the given command.".
-spec usage(command() | term()) -> ok.
usage(Command) ->
    case Command of
        audit ->
            usage_audit();
        ecosystem ->
            usage_ecosystem();
        examine ->
            usage_examine();
        supported ->
            usage_supported();
        filter ->
            usage_filter();
        update ->
            usage_update();
        query ->
            usage_query();
        _ ->
            io:format("Unsupported command: ~p\n", [Command]),
            usage()
    end.

%% Print help text for the 'audit' command.
-spec usage_audit() -> ok.
usage_audit() ->
    io:format(
        "Usage: spectrometer audit [TARGET] [OPTIONS]\n"
        "\n"
        "Audit a single target, or a list of targets from a file for OTP function usage and\n"
        "report which functions are NOT supported by AtomVM.\n"
        "\n"
        "Target (exactly one):\n"
        "  --github <url>     GitHub repository URL (e.g. https://github.com/ninenines/cowboy)\n"
        "  --hex <package>    Hex package name (optionally with --version)\n"
        "  --dir <path>       Local directory containing .erl source files\n"
        "  --multi <file>     File with one target per line (see format below)\n"
        "\n"
        "Options:\n"
        "  -o <file>          Write full CSV report to file\n"
        "  --output <file>    Same as -o\n"
        "  -c <dir>           Use alternate cache directory for supported functions DB\n"
        "  --cache <dir>      Same as -c\n"
        "  --top <N>          Show top N results in terminal summary (default: 50)\n"
        "  --min-count <N>    Only show functions called at least N times (default: 1)\n"
        "\n"
        "Multi-file format:\n"
        "  One target per line. Lines starting with '#' are comments.\n"
        "  Hex packages prefixed with 'hex:'. GitHub URLs or local paths detected\n"
        "  automatically.\n"
        "\n"
        "Examples:\n"
        "  spectrometer audit --github https://github.com/ninenines/cowboy\n"
        "  spectrometer audit --hex jsx\n"
        "  spectrometer audit --hex cowboy --version 3.1.0\n"
        "  spectrometer audit --dir /path/to/project -o report.csv\n"
        "  spectrometer audit --multi targets.txt --top 20\n"
    ).

%% Print help text for the 'ecosystem' command.
-spec usage_ecosystem() -> ok.
usage_ecosystem() ->
    io:format(
        "Usage: spectrometer ecosystem [OPTIONS]\n"
        "\n"
        "Scan the top Erlang GitHub repositories and/or Hex packages to gather\n"
        "raw statistics about OTP function usage in the BEAM ecosystem.\n"
        "Use the 'filter' command to analyze the results.\n"
        "\n"
        "Source selection (default: both):\n"
        "  --github-only      Only audit GitHub repositories\n"
        "  --hex-only         Only audit Hex packages\n"
        "\n"
        "Performance:\n"
        "  --workers <N>      Number of parallel workers (default: 4)\n"
        "  --limit <N>        Maximum number of repos/packages to audit\n"
        "  --stars <N>        Minimum number of stars for GitHub repos (default: 1)\n"
        "\n"
        "State:\n"
        "  --resume           Resume from a previous audit\n"
        "  --cache-dir        Directory to store beam_ecosystem data file (beam_ecosystem.bin)\n"
        "\n"
        "Examples:\n"
        "  spectrometer ecosystem\n"
        "  spectrometer ecosystem --github-only --limit 100\n"
        "  spectrometer ecosystem --hex-only --workers 8 --resume\n"
    ).

%% Print help text for the 'examine' command.
-spec usage_examine() -> ok.
usage_examine() ->
    io:format(
        "Usage: spectrometer examine [TARGET] [OPTIONS]\n"
        "\n"
        "Examine a single target, or a list of targets from a file for OTP M:F/A usage statistics.\n"
        "\n"
        "Target (exactly one):\n"
        "  --github <url>     GitHub repository URL (e.g. https://github.com/ninenines/cowboy)\n"
        "  --hex <package>    Hex package name (optionally with --version)\n"
        "  --dir <path>       Local directory containing .erl source files\n"
        "  --multi <file>     File with one target per line (see format below)\n"
        "\n"
        "Options:\n"
        "  -o <file>          Write full CSV report to file\n"
        "  --output <file>    Same as -o\n"
        "  -c <dir>           Use alternate cache directory for supported functions DB\n"
        "  --cache <dir>      Same as -c\n"
        "  --top <N>          Show top N results in terminal summary (default: 50)\n"
        "  --min-count <N>    Only show functions called at least N times (default: 1)\n"
        "\n"
        "Multi-file format:\n"
        "  One target per line. Lines starting with '#' are comments.\n"
        "  Hex packages prefixed with 'hex:'. GitHub URLs or local paths detected\n"
        "  automatically.\n"
        "\n"
        "Examples:\n"
        "  spectrometer examine --github https://github.com/ninenines/cowboy\n"
        "  spectrometer examine --hex jsx\n"
        "  spectrometer examine --hex cowboy --version 3.1.0\n"
        "  spectrometer examine --dir /path/to/project -o report.csv\n"
        "  spectrometer examine --multi targets.txt --top 20\n"
        "\n"
    ).

%% Print help text for the 'supported' command.
-spec usage_supported() -> ok.
usage_supported() ->
    io:format(
        "Usage: spectrometer supported [OPTIONS]\n"
        "\n"
        "List all OTP functions that AtomVM currently supports.\n"
        "\n"
        "Options:\n"
        "  --module <mod>     Show functions for a specific OTP module\n"
        "  -m <mod>           Same as --module\n"
        "  --erl              Show only Erlang functions (exclude Elixir)\n"
        "  --ex               Filter output to Elixir modules (does not rename or strip module prefixes)\n"
        "  -c <dir>           Use alternate cache directory for supported functions DB\n"
        "  --cache <dir>      Same as -c\n"
        "\n"
        "Examples:\n"
        "  spectrometer supported\n"
        "  spectrometer supported --module gen_server\n"
        "  spectrometer supported -m lists\n"
        "  spectrometer supported --ex\n"
        "  spectrometer supported --erl\n"
        "  spectrometer supported -c /tmp/custom_cache\n"
        "\n"
    ).

%% Print help text for the 'filter' command.
-spec usage_filter() -> ok.
usage_filter() ->
    io:format(
        "Usage: spectrometer filter [OPTIONS]\n"
        "\n"
        "Filter ecosystem audit results to show OTP function usage statistics.\n"
        "Loads from the ecosystem binary state file unless --csv is specified.\n"
        "\n"
        "Options:\n"
        "  --min-repos <N>    Only show functions used by >= N repos (default: 1)\n"
        "  --avm              Filter to show only AtomVM unsupported functions\n"
        "  -c <dir>           Use alternate cache directory for supported functions DB\n"
        "  --cache <dir>      Same as -c\n"
        "\n"
        "Examples:\n"
        "  spectrometer filter\n"
        "  spectrometer filter --min-repos 10\n"
        "  spectrometer filter --avm\n"
        "  spectrometer filter --avm --min-repos 5\n"
        "  spectrometer filter --csv results.csv --min-repos 10\n"
    ).

%% Print help text for the 'update' command.
-spec usage_update() -> ok.
usage_update() ->
    io:format(
        "Usage: spectrometer update [OPTIONS]\n"
        "\n"
        "Scan an AtomVM source tree and regenerate the supported functions\n"
        "database. Writes the result as a .term file.\n"
        "\n"
        "Source selection:\n"
        "  --atomvm-dir <path>   Path to a local AtomVM clone (read-only, ignores --branch/--tag)\n"
        "                        Default: clones https://github.com/atomvm/AtomVM to a temp dir\n"
        "\n"
        "Branch/tag selection (only for remote clone, ignored with --atomvm-dir):\n"
        "  --branch <name>       Branch to checkout (default: main)\n"
        "  --tag <name>          Tag to checkout\n"
        "\n"
        "Options:\n"
        "  --output <file>       Write to specific file instead of cache directory\n"
        "  -c <dir>              Use alternate cache directory for supported functions DB\n"
        "  --cache <dir>         Same as -c\n"
        "  --no-tests            Skip scanning test files for external calls\n"
        "  --force               Overwrite existing database without confirmation\n"
        "\n"
        "Examples:\n"
        "  spectrometer update\n"
        "  spectrometer update --atomvm-dir /home/user/work/AtomVM\n"
        "  spectrometer update --branch release-0.6\n"
        "  spectrometer update --tag v0.6.5 --output /home/user/custom_db.term\n"
        "  spectrometer update --cache /tmp/custom_cache\n"
    ).

%% Print help text for the 'query' command.
-spec usage_query() -> ok.
usage_query() ->
    io:format(
        "Usage: spectrometer query <Module:Function[/Arity]> [OPTIONS]\n"
        "\n"
        "Query whether a specific function is supported by AtomVM and on\n"
        "which platforms it is available.\n"
        "\n"
        "Erlang function queries:\n"
        "  Module:Function       Show all supported arities for the function\n"
        "  Module:Function/Arity Show support for a specific arity\n"
        "\n"
        "Elixir queries may omit the 'Elixir' prefix (examples for Elixir.GPIO.digital_read/1):\n"
        "  GPIO.digital_read\n"
        "  Elixir.GPIO.digital_read\n"
        "  GPIO.digital_read/1\n"
        "  Elixir.GPIO.digital_read/1\n"
        "\n"
        "Options:\n"
        "  -c <dir>              Use alternate cache directory for supported functions DB\n"
        "  --cache <dir>         Same as -c\n"
        "\n"
        "Examples:\n"
        "  spectrometer query lists:map\n"
        "  spectrometer query lists:map/2\n"
        "  spectrometer query gen_server:call/3\n"
        "  spectrometer query file:read_file\n"
        "  spectrometer query Elixir.GPIO.digital_read/1\n"
        "  spectrometer query GPIO.digital_read/1\n"
        "  spectrometer query -c /tmp/custom_cache mock_pkg:custom_func/1\n"
    ).

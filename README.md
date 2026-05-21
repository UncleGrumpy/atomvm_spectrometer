<!--
SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
SPDX-License-Identifier: Apache-2.0
-->

# spectrometer

This is a multi-purpose tool for examining the BEAM ecosystem as well as
AtomVM-supported OTP functions. A dataset can be created and filtered to find
the most common MFA usage of OTP libraries/applications across the Erlang
(support is planned for Elixir as well) ecosystem on hex.pm and GitHub.com.
This dataset can also be filtered to only list the most frequently used MFA
that AtomVM does not currently support. AtomVM-supported MFA can be listed or
queried by module:function or full module:function/arity.

The ecosystem scanning and filtering is based on Paul Guyot's GitHub Gist
[pguyot/beam_stats.escript](https://gist.github.com/pguyot/da327972f1ecdb7041c97addd4e76bb5).

## Dependencies

This tool uses `git` for gathering ecosystem data and scanning repositories for
compatibility with AtomVM.

**Runtime requirements:**

- Erlang/OTP 27+ (uses `json`, `uri_string` modules)
- `git` CLI (for cloning GitHub repositories during ecosystem and compatibility
scans)

## Build

    rebar3 compile

This compiles the application modules. To produce a standalone executable:

    rebar3 escriptize

This bundles all modules into a single escript at
`_build/default/bin/spectrometer`, which can be run directly or
installed system-wide.

## Install

Prepare the application for installation:

    rebar3 as prod release
    rebar3 as prod tar

Thanks to the magic of rebar3 post-hooks this will create an executable
self-extracting install script that can take an optional install prefix
directory, or use the default `/usr/local` (this will likely require root
privileges).

Example for a user install on Linux:

    _build/prod/rel/atomvm_spectrometer/install.sh ${HOME}/.local

Or for a system-wide install to the default directory

    sudo _build/prod/rel/atomvm_spectrometer/install.sh

This will install the runtime and application into
`<prefix>/lib/atomvm_spectrometer/` and an executable launcher as
`<prefix>/bin/spectrometer`, for convenience make sure `<prefix>/bin` is in
the user PATH. If not already present, it can be added permanently by adding
`export PATH="${PATH}:<prefix>/bin"` to $HOME/.bashrc or the config file for
your shell of choice.

### Uninstall

The installation includes an uninstall script that will remove all the
application files, and optionally clean up the user cache directory too.

To uninstall atomvm_spectrometer run:

    sh ${INSTALL_PREFIX}/lib/atomvm_spectrometer/uninstall.sh

If the application is installed to `/usr/local` and required sudo for
installation then sudo will be required to uninstall.

To uninstall and delete any user cache files run:

    sh ${INSTALL_PREFIX}/lib/atomvm_spectrometer/uninstall.sh --full

You may also use the short option `-f` for a full uninstall of the
application and user cache files. If sudo was required for installation then
it will be needed to uninstall, and will miss cleanup of any user cache files
from users other than root. If this is a concern use an install prefix in the
users home directory, such as `~/.local`.

## Commands

| Command    | Description                                                                       |
|------------|-----------------------------------------------------------------------------------|
| `audit`    | Audit a single target (or list in a file) for AtomVM support _*_                  |
| `ecosystem`| Scan top GitHub repos and/or Hex packages (gathers raw stats)                     |
| `examine`  | Examine the modules and functions used in a single target (or list in a file) _*_ |
| `supported`| List all AtomVM-supported OTP functions                                           |
| `filter`   | Filter ecosystem scan results (use `--avm` for unsupported only)                  |
| `update`   | Regenerate supported functions database from AtomVM sources                       |
| `query`    | Query whether a specific OTP function is supported by AtomVM                      |

_*_ _GitHub repo, Hex package, or directory_

### Help

Get the help overview using any of the following:

    spectrometer help
    spectrometer --help
    spectrometer -h

Get detailed help on any command:

    spectrometer help audit
    spectrometer help ecosystem
    spectrometer help examine
    spectrometer help supported
    spectrometer help filter
    spectrometer help update
    spectrometer help query

Or use `-h` or `--help` option:

    spectrometer audit -h
    spectrometer query --help

## Examples

### Audit a single target

    spectrometer audit --github https://github.com/atomvm/atomvm_packbeam
    spectrometer audit --hex jsx
    spectrometer audit --hex cowboy --version 3.1.0
    spectrometer audit --dir /path/to/project
    spectrometer audit --multi targets.txt -o report.csv

### Scan the ecosystem

    spectrometer ecosystem
    spectrometer ecosystem --github-only --limit 100
    spectrometer ecosystem --hex-only --workers 8 --resume

### Filter ecosystem output

    spectrometer filter
    spectrometer filter --avm
    spectrometer filter --avm --min-repos 50
    spectrometer filter --min-repos 75

### Query function support

Functions can be queried by specific arity, or arity may be omitted.

    spectrometer query lists:map
    spectrometer query lists:map/2

#### Elixir function support

Elixir functions can be queried using several formats:

    spectrometer query Elixir.List.keyfind
    spectrometer query List.keyfind
    spectrometer query Elixir.List.keyfind/4
    spectrometer query List.keyfind/4

### List supported functions

    spectrometer supported
    spectrometer supported --module gen_server
    spectrometer supported -m lists
    spectrometer supported -m Elixir.List
    spectrometer supported -m List
    spectrometer supported --ex     # Show only Elixir functions
    spectrometer supported --erl    # Show only Erlang functions

### Regenerate supported functions database

    spectrometer update
    spectrometer update --tag v0.7.0-alpha.1
    spectrometer update --atomvm-dir ~/work/AtomVM
    spectrometer update --branch release-0.7 --force
    spectrometer update --branch main --force

## Supported Functions Data

The AtomVM-supported functions data is stored in
`priv/supported_functions.data`, a human-readable Erlang term list containing
`[{Module, [{Function, Arity, Platforms, Since}]}]` entries. This file can be
regenerated by running the included `generate_fun_data.sh` (a backup of the
current file will be saved).

### User Override

You can override the bundled database by placing your own
`supported_functions.data` in your cache directory:

| Platform | Path                                                     |
|----------|----------------------------------------------------------|
| Linux    | `~/.cache/spectrometer/supported_functions.data`         |
| macOS    | `~/Library/Caches/spectrometer/supported_functions.data` |
| Windows  | `%APPDATA%/spectrometer/supported_functions.data`        |

Use the `update` command to generate, or update using the `--force` option, the
user override database and add new functions supported by AtomVM:

    spectrometer update --atomvm-dir ~/work/AtomVM --force
    spectrometer update --branch main
    spectrometer update --tag v0.7.0-alpha.1 --force

Note: --atomvm-dir ignores --branch/--tag

This can be used to keep the application in sync with changes to AtomVM between
update releases of the spectrometer tool. This project is still under early
development, and the data structure of this file may change between releases
until APIs are finalized.

## Roadmap - planned enhancements

See: [todo](TODO.md)

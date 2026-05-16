<!--
SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
SPDX-License-Identifier: Apache-2.0
-->

# TODOs for atomvm spectrometer

## Must have

### Elixir support

All of the current functions only work for the Erlang ecosystem. Support needs
to be added for all commands.

* `ecosystem` command should have an --elixir option for creating an Elixir
ecosystem data-set.
* `update` and `audit` commands should automatically include `exavmlib` in the
supported functions data and lookups.
* `supported` command should list all supported modules/functions by default
and accept optional `--erl` and `--ex` flags to filter the modules/functions
output to only the selected language.

### Change data structure for stored version info

The current version data is stored as a binary string for tags and branches,
this is brittle when comparing versions in the `update` command, and will cause
noticeable errors if any AtomVM release versions use double digits for major,
minor or patch levels. The storage format should be migrated to tuples.

#### Tagged releases

```erlang
{
    Major :: non_neg_integer(),
    Minor :: non_neg_integer(),
    Patch :: non_neg_integer()
}
```

#### Branches

##### main

```erlang
{
    unreleased,
    main
}
```

##### `release-X.X`

```erlang
{
    unreleased,
    {release, Major :: non_neg_integer(), Minor :: non_neg_integer()}
}
```

## Should have

### Handle shadowed BIFs

`spectrometer_scanner:scan_directory/1` counts unqualified atom calls as
`{erlang, Fun, Arity}` based only on erl_internal:bif/2, which returns true for
compiler-recognized auto-imported BIFs without resolving shadowing. Using
`-compile({no_auto_import, [...]})` plus a local function definition causes a
bare call like length(X) to resolve to the local function instead of the BIF,
but the code will still count it as an OTP call, misclassifying user-defined
functions and skewing scan results.

### `supported` modules

The `supported` command should print a list of all AtomVM modules if the `-m`
or `--module` option is given without a module name.

### Finer platform support tracking

The tracking of platform support is not perfect. Some modules, like `network`
end up being assigned too broad of platform support, in this case including
`generic_unix` in the supported platforms, due to modules being assigned by
library so all modules in `avm_network` are reported as supported by `esp32`,
`generic_unix`, and `rp2` platforms. The `network` module is not supported on
`generic_unix`, only `esp32` and `rp2`, but to track these exceptions specific
filtering rules will be needed.

The version added data should be tracked per-platform. For example `i2c` and
`spi` added support for `rp2` and `stm32` platforms in version 0.7.0, while
`esp32` had support in 0.5.0 and the `supported` command reports support for
all platforms, and reports 0.5.0 as the release these functions were introduced
(inaccurate for `rp2` and `stm32` platforms). The data storage format needs to
be altered to track support for each platform, with `all` only requiring a
single entry with the version.

#### Track when modules or functions are deprecated and removed

The supported functions data should track when modules are deprecated, and
also when they are removed. Some new data structure will need to be devised,
either a new field entirely, or expanding the `since` which will also be
holding platform specific release introductions. The deprecation and removal
releases may need to be hard-coded into the application, as these are rare, and
parsing doc strings could potentially lead to false positives.

### Add support for adding (and reporting) downstream drivers and libraries

The `update` command should have an option for adding downstream drivers or
libraries supporting AtomVM. These entries should be marked in a way that when
reporting with the `supported` command they clearly indicate the dependency
required for support. One possible storage strategy would be to put the
application or repository name (i.e. `atomvm_lib`) in a tuple with the module
name in the `supported_functions.data` file. This would leave AtomVM native
supported functions as bare atoms, and downstream libraries as
`{Library, Module}`. The downstream option should take optional platform and
AtomVM version parameters, defaulting to `all` platforms and unknown for the
AtomVM release.

## Would be nice

### Use logger with configurable levels

Logger should be used instead of `io:format/2` for log messages. A configurable
log file should be used, defaulting to a log file in the users cache directory
that is overwritten on each run. The log level should be configurable, as well
as the option for changing the log file name and location.

#### Refactor error handling and logging

Errors should be refactored to return atom() "reasons", and the conversion to
log messages should be handled by dispatch to an error logger.

### Reusable APIs

Most modules should be refactored to better separate logic and IO (reporting
and file operations). All user facing reporting should be consolidated into
`spectrometer_reporter.erl` and pure outputs should be returned from command
logic functions.

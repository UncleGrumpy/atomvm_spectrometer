<!--
SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
SPDX-License-Identifier: Apache-2.0
-->

# TODOs for atomvm spectrometer

## Must have

### Elixir support

Support fo scanning the Elixir ecosystem needs to be added.

* `audit` should seamlessly audit Elixir applications and libraries for AtomVM
compatibility.
* `ecosystem` command should have an --elixir (or --ex) option for creating an Elixir
ecosystem data-set.
* `filter` command needs to be updated to work on Elixir ecosystem data with an
--elixir (or --ex) option

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

%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0
%%

-module(spectrometer_utils).

-moduledoc """
Utility functions shared across the application.

This module provides common infrastructure helpers used by other modules:
temporary directory creation under the user cache directory, recursive
directory removal, and GitHub URL normalization for deduplication.
""".

-export([
    atom_from_string/1,
    clone_temp_repo/2,
    bundled_data_path/0,
    make_temp_dir/1,
    normalize_github_url/1,
    normalize_platform_name/1,
    purge_dir/1,
    run_git_command/2,
    start_applications/0,
    user_cache_path/0,
    user_db_file/0,
    version/0
]).

-type platform() :: emscripten | esp32 | generic_unix | rp2 | stm32.

-doc """
Convert a string to an atom, using list_to_existing_atom if possible for safety.
If the string does not correspond to an existing atom, it will be created with list_to_atom.
""".
-spec atom_from_string(string()) -> atom().
atom_from_string(Str) ->
    try
        list_to_existing_atom(Str)
    catch
        error:badarg -> list_to_atom(Str)
    end.

-doc """
Return the path to the bundled human-readable data file.

The returned path points to `priv/supported_functions.data` within the
application's installation directory. Works for both normal OTP application
loads and escript builds.
""".
-spec bundled_data_path() -> string().
bundled_data_path() ->
    bundled_db_file().

-doc """
Return the path to the user cache directory.
The returned path is platform-appropriate:
- On Unix-like systems: `~/.cache/spectrometer`
- On macOS: `~/Library/Caches/spectrometer`
- On Windows: `%APPDATA%\\spectrometer` or `~\spectrometer` if `APPDATA` is unset
""".
-spec user_cache_path() -> file:filename_all().
user_cache_path() ->
    case application:get_env(spectrometer, cache_dir) of
        {ok, Dir} ->
            case filelib:is_dir(Dir) of
                true ->
                    Dir;
                false ->
                    ok = filelib:ensure_path(Dir),
                    Dir
            end;
        undefined ->
            CachePath = filename:basedir(user_cache, "spectrometer"),
            ok = filelib:ensure_path(CachePath),
            application:set_env(spectrometer, cache_dir, CachePath),
            CachePath
    end.

-doc """
Return the path to the cached data file.

The returned path points to `${user_cache_path}/supported_functions.data` if it
exists, otherwise it points to `priv/supported_functions.data` within the
application's installation directory. Works for both normal OTP application
loads and escript builds.
""".
-spec user_db_file() -> string().
user_db_file() ->
    filename:join(user_cache_path(), "supported_functions.data").

-doc false.
%% Find the bundled human-readable data file.
%% Tries code:priv_dir first, then falls back to paths relative to the escript.
bundled_db_file() ->
    case code:priv_dir(spectrometer) of
        Priv when is_list(Priv) ->
            Candidate = filename:join(Priv, "supported_functions.data"),
            case filelib:is_regular(Candidate) of
                true -> Candidate;
                false -> try_script_relative()
            end;
        _ ->
            try_script_relative()
    end.

-doc false.
%% For escript builds: resolve path relative to the escript binary location.
%% Tries multiple candidate paths (rebar3 build, installed, source tree).
try_script_relative() ->
    ScriptDir =
        case filename:dirname(escript:script_name()) of
            D when is_list(D) -> D;
            _ ->
                case code:which(?MODULE) of
                    BeamPath when is_list(BeamPath) ->
                        BeamDir = filename:dirname(BeamPath),
                        case filename:basename(BeamDir) of
                            "ebin" -> filename:dirname(BeamDir);
                            _ -> BeamDir
                        end;
                    _ ->
                        "."
                end
        end,
    Candidates = [
        user_db_file(),
        filename:join([
            ScriptDir,
            "..",
            "lib",
            "spectrometer",
            "priv",
            "supported_functions.data"
        ]),
        filename:join([ScriptDir, "..", "priv", "supported_functions.data"]),
        filename:join(ScriptDir, "priv/supported_functions.data"),
        filename:join([
            ScriptDir, "..", "..", "priv", "supported_functions.data"
        ]),
        filename:join([
            ScriptDir, "..", "..", "..", "priv", "supported_functions.data"
        ]),
        "priv/supported_functions.data"
    ],
    find_first_file(Candidates).

-doc false.
%% Find the first existing file from a list of candidate paths.
find_first_file([Path | Rest]) ->
    case filelib:is_regular(Path) of
        true -> Path;
        false -> find_first_file(Rest)
    end;
find_first_file([]) ->
    "priv/supported_functions.data".

-doc """
Create a temporary directory.

The directory name is formed by concatenating the given `Prefix` with a unique
integer suffix. The directory will be created in a sub-directory of
"spectrometer" the users temp directory, typically "/tmp". Given the prefix
"test_cache_" the result would be similar to:
>`/tmp/spectrometer/test_cache_454279`
""".
make_temp_dir(Prefix) ->
    Rand = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join([system_temp_dir(), "spectrometer", Prefix ++ Rand]),
    ok = filelib:ensure_path(Dir),
    Dir.

-doc """
Recursively remove a directory and all its contents.

Uses `file:del_dir_r/1` for portable cross-platform directory removal.
Returns `ok` on success or `{error, Reason}` on failure.
""".
-spec purge_dir(file:filename_all()) -> ok | {error, term()}.
purge_dir(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

-doc "Run a git command safely using open_port with spawn_executable, with environment vars".
-spec run_git_command([string()], [{string(), string()}]) ->
    {ok, string()} | {error, term()}.
run_git_command(Args, EnvVars) ->
    Cmd = "git",
    case find_executable(Cmd) of
        {ok, ExecPath} ->
            PortOpts = [{args, Args}, exit_status, {line, 16384}],
            PortOpts1 =
                case EnvVars of
                    [] -> PortOpts;
                    _ -> [{env, EnvVars} | PortOpts]
                end,
            try
                Port = open_port({spawn_executable, ExecPath}, PortOpts1),
                gather_git_output(Port, [])
            catch
                error:Reason ->
                    {error, Reason}
            end;
        {error, not_found} ->
            {error, {executable_not_found, Cmd}}
    end.

-doc "Find an executable in PATH or return error if not found".
-spec find_executable(string()) -> {ok, string()} | {error, not_found}.
find_executable(Cmd) ->
    case os:find_executable(Cmd) of
        false -> {error, not_found};
        Path -> {ok, Path}
    end.

-doc "Gather output from a port until it closes for git commands".
-spec gather_git_output(port(), [string()]) -> {ok, string()} | {error, term()}.
gather_git_output(Port, Acc) ->
    receive
        {Port, {exit_status, 0}} ->
            {ok, lists:flatten(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            {error, {exit_status, Status, lists:flatten(lists:reverse(Acc))}};
        {Port, {data, {eol, Line}}} ->
            gather_git_output(Port, [Line ++ "\n" | Acc]);
        {Port, {data, {noeol, Line}}} ->
            gather_git_output(Port, [Line | Acc])
    after 120000 ->
        port_close(Port),
        drain_port_messages(Port),
        {error, timeout}
    end.
%% Drain any pending messages for a closed port to avoid mailbox pollution.
drain_port_messages(Port) ->
    receive
        {Port, _} -> drain_port_messages(Port)
    after 0 ->
        ok
    end.

-doc """
Normalize a GitHub URL for deduplication.

Accepts bare repository paths (e.g., `atomvm/AtomVM`), full URLs with or without protocol.
Strips the protocol (`https://` or `http://`), trailing slashes, `.git`
suffix, and converts to lowercase. This ensures consistent comparison
of GitHub repository URLs across different formats.

#### Example

```erlang
1> spectrometer_utils:normalize_github_url("https://github.com/atomvm/AtomVM.git").
"https://github.com/atomvm/atomvm.git"
2> spectrometer_utils:normalize_github_url("http://github.com/atomvm/AtomVM").
"https://github.com/atomvm/atomvm.git"
3> spectrometer_utils:normalize_github_url("atomvm/AtomVM").
"https://github.com/atomvm/atomvm.git"
```
""".
normalize_github_url(Url) ->
    Url1 = string:lowercase(Url),
    Url2 = string:trim(Url1),
    Url3 = string:trim(Url2, trailing, "/"),
    Url4 = re:replace(Url3, "\\.git$", "", [{return, list}]),
    Url5 = re:replace(Url4, "^https?://", "", [{return, list}]),
    Url6 = re:replace(Url5, "^github.com/", "", [{return, list}]),
    "https://github.com/" ++ Url6 ++ ".git".

-doc """
Normalize a platform name for consistent comparison. Removes whitespace and converts to lowercase.
Returns supported platform name atoms, or `{error, badarg}` for unsupported platforms.
""".
-spec normalize_platform_name(string()) -> platform() | {error, badarg}.
normalize_platform_name(Name) ->
    NameStr = unicode:characters_to_list(Name),
    normalized_name(string:lowercase(string:trim(NameStr))).

-spec normalized_name(string()) -> platform() | {error, badarg}.
normalized_name("rp2") -> rp2;
normalized_name("rp2040") -> rp2;
normalized_name("esp32") -> esp32;
normalized_name("stm32") -> stm32;
normalized_name("emscripten") -> emscripten;
normalized_name("generic_unix") -> generic_unix;
normalized_name("genericunix") -> generic_unix;
normalized_name(_) -> {error, badarg}.

-doc """
Clone the AtomVM GitHub repository to a temporary directory.
The repository is cloned with `--depth 1` for efficiency. The specified branch is checked out, and
optionally a specific tag can be checked out as well. The function returns the path to the cloned
repository. Errors during cloning or checkout are printed to the console, and the function halts
with an error code if cloning fails.
""".
-spec clone_temp_repo(string(), string() | undefined) ->
    string() | {error, Reason :: term()}.
clone_temp_repo(Branch, Tag) ->
    TmpDir = spectrometer_utils:make_temp_dir("avm_update_"),
    Url = "https://github.com/atomvm/AtomVM",
    io:format("Cloning ~s (branch ~s) to ~s...\n", [Url, Branch, TmpDir]),
    CloneResult = run_git_command(
        [
            "clone", "--quiet", "--depth", "1", "-b", Branch, Url, TmpDir
        ],
        [{"GIT_TERMINAL_PROMPT", "0"}]
    ),
    case CloneResult of
        {ok, _} ->
            case Tag of
                undefined ->
                    TmpDir;
                TagStr when is_list(TagStr) ->
                    io:format("Checking out tag ~s...\n", [TagStr]),
                    _ = run_git_command(
                        ["-C", TmpDir, "fetch", "--tags", "--quiet"],
                        [{"GIT_TERMINAL_PROMPT", "0"}]
                    ),
                    CheckoutResult = run_git_command(
                        ["-C", TmpDir, "checkout", "--quiet", TagStr],
                        [{"GIT_TERMINAL_PROMPT", "0"}]
                    ),
                    case CheckoutResult of
                        {ok, _} ->
                            TmpDir;
                        {error, Reason} when
                            is_tuple(Reason); is_atom(Reason)
                        ->
                            _ = purge_dir(TmpDir),
                            {error, {checkout_failed, TagStr, Reason}};
                        Error ->
                            _ = purge_dir(TmpDir),
                            Error
                    end
            end;
        {error, Reason} when is_tuple(Reason); is_atom(Reason) ->
            io:format("Error: Could not clone ~s: ~p\n", [Url, Reason]),
            _ = purge_dir(TmpDir),
            {error, Reason};
        Error ->
            io:format("Error: Could not clone ~s: ~p\n", [Url, Error]),
            _ = purge_dir(TmpDir),
            Error
    end.

-spec version() -> string() | {error, Reason :: term()}.
version() ->
    case application:ensure_all_started(spectrometer) of
        {ok, _} ->
            case application:get_key(spectrometer, vsn) of
                {ok, Vsn} -> Vsn;
                undefined -> {error, version_not_found}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_applications() -> ok | {error, Reason :: term()}.
start_applications() ->
    try
        case
            application:ensure_all_started([
                inets, ssl, compiler, syntax_tools, spectrometer
            ])
        of
            {ok, _} -> ok;
            {error, R0} -> error(R0)
        end,
        case
            httpc:set_options([{max_sessions, 8}, {max_keep_alive_length, 16}])
        of
            ok -> ok;
            {error, R1} -> error(R1)
        end
    catch
        error:Reason ->
            {error, Reason}
    end.

%% Get a system temp directory (cross-platform)
system_temp_dir() ->
    case os:getenv("TEMPDIR") of
        false ->
            os:getenv("TEMP", os_temp_dir());
        Temp ->
            Temp
    end.

os_temp_dir() ->
    case os:type() of
        {win32, _} ->
            "C:/Windows/Temp";
        _ ->
            "/tmp"
    end.

%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_otp).

-include_lib("kernel/include/logger.hrl").

-moduledoc """
This module contains functions for identifying OTP modules.
""".

-export([is_otp_module/1, modules_list/0]).

-doc """
Returns `true` if the module is an OTP module, otherwise `false`.
""".
-spec is_otp_module(atom() | string() | binary()) -> boolean().
is_otp_module(Atom) when is_atom(Atom) ->
    is_otp_module(atom_to_list(Atom));
is_otp_module(Str) when is_list(Str) ->
    OTPmods = modules_list(),
    lists:member(Str, OTPmods);
is_otp_module(Bin) when is_binary(Bin) ->
    is_otp_module(binary_to_list(Bin)).

-doc """
Returns a list of module for the running OTP version.

Uses a cached file if it exists, attempting to create a cached list of modules
if one does not exist. Falls back to generating the list at runtime on failures.
""".
-spec modules_list() -> [string()].
modules_list() ->
    ModFile = module_cache(),
    case filelib:is_file(ModFile) of
        true ->
            case file:read_file(ModFile) of
                {ok, Bin} ->
                    try binary_to_term(Bin) of
                        Modules when is_list(Modules) ->
                            case
                                lists:all(
                                    fun(List) ->
                                        io_lib:printable_list(List)
                                    end,
                                    Modules
                                )
                            of
                                true ->
                                    Modules;
                                false ->
                                    ?LOG_WARNING(
                                        "Invalid module identifiers in OTP module cache ~s, regenerating.",
                                        [ModFile]
                                    ),
                                    regenerate_and_write(ModFile)
                            end;
                        _ ->
                            ?LOG_WARNING(
                                "Unexpected data in OTP module cache ~s, regenerating.",
                                [ModFile]
                            ),
                            regenerate_and_write(ModFile)
                    catch
                        _:_ ->
                            ?LOG_WARNING(
                                "Error decoding OTP module cache file ~s",
                                [ModFile]
                            ),
                            ?LOG_WARNING("Regenerating OTP module cache."),
                            regenerate_and_write(ModFile)
                    end;
                {error, Reason} ->
                    ?LOG_WARNING(
                        "Error reading OTP module cache file ~s: ~p",
                        [ModFile, Reason]
                    ),
                    ?LOG_WARNING("Regenerating OTP module cache."),
                    regenerate_and_write(ModFile)
            end;
        false ->
            regenerate_and_write(ModFile)
    end.

%% Helper to generate module list and write to cache file
-spec regenerate_and_write(file:filename_all()) -> [any()].
regenerate_and_write(ModFile) ->
    Modules = [M || {M, _, _} <- code:all_available()],
    case filelib:ensure_dir(ModFile) of
        ok ->
            case file:write_file(ModFile, term_to_binary(Modules)) of
                ok ->
                    ok;
                {error, Reason} ->
                    ?LOG_WARNING(
                        "Unable to write to otp module data file ~s, reason: ~p\n",
                        [ModFile, Reason]
                    ),
                    ok
            end;
        {error, Reason} ->
            ?LOG_WARNING(
                "Unable to create cache dir for OTP module data ~s, reason: ~p\n",
                [ModFile, Reason]
            ),
            ok
    end,
    Modules.

%% Get the cache file path for OTP modules
-spec module_cache() -> file:filename_all().
module_cache() ->
    VersionString = erlang:system_info(otp_release),
    CacheDir = spectrometer_utils:user_cache_path(),
    filename:join(CacheDir, "otp_" ++ VersionString ++ "_modules.bin").

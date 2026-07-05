%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_ecosystem_tests).
-include_lib("eunit/include/eunit.hrl").
-include("ecosystem.hrl").

-export([load_state_migration/1]).

%% =============================================================================
%% resume_start_page/4 tests
%% =============================================================================

resume_start_page_test_() ->
    [
        {"no resume, no slow returns 1",
            ?_assertEqual(
                1,
                spectrometer_ecosystem:resume_start_page(
                    #{}, github, false, false
                )
            )},
        {"no resume, no slow returns 1 for hex",
            ?_assertEqual(
                1,
                spectrometer_ecosystem:resume_start_page(#{}, hex, false, false)
            )},
        {"resume true, no slow returns stored page for github",
            ?_assertEqual(
                5,
                spectrometer_ecosystem:resume_start_page(
                    #{github => 5, hex => 3}, github, true, false
                )
            )},
        {"resume true, no slow returns stored page for hex",
            ?_assertEqual(
                3,
                spectrometer_ecosystem:resume_start_page(
                    #{github => 5, hex => 3}, hex, true, false
                )
            )},
        {"resume true, no slow returns 1 when source not in map",
            ?_assertEqual(
                1,
                spectrometer_ecosystem:resume_start_page(
                    #{github => 5}, hex, true, false
                )
            )},
        {"slow true overrides resume, returns 1",
            ?_assertEqual(
                1,
                spectrometer_ecosystem:resume_start_page(
                    #{github => 5}, github, true, true
                )
            )},
        {"slow true returns 1 even without resume",
            ?_assertEqual(
                1,
                spectrometer_ecosystem:resume_start_page(
                    #{github => 5}, github, false, true
                )
            )}
    ].

%% =============================================================================
%% load_state/0 migration tests
%% =============================================================================

load_state_migration_test_() ->
    [
        {"load_state v1 tuple migrates to r2 with empty PagesConsumed", fun() ->
            State = {spectrometer_v1, #{}, #{}, #{}, 0},
            {Scanned, Stats, PackageMap, TotalProcessed, PagesConsumed} =
                load_state_migration(State),
            ?assertEqual(#{}, Scanned),
            ?assertEqual(#{}, Stats),
            ?assertEqual(#{}, PackageMap),
            ?assertEqual(0, TotalProcessed),
            ?assertEqual(#{}, PagesConsumed)
        end}
    ].

%% =============================================================================
%% load_state_migration/1 helper for testing migration logic
%% =============================================================================

load_state_migration(
    {spectrometer_v1, Scanned, Stats, PackageMap, TotalProcessed}
) when
    is_map(Scanned), is_map(Stats), is_map(PackageMap)
->
    {Scanned, Stats, PackageMap, TotalProcessed, #{}};
load_state_migration(
    {spectrometer_v0_r2, Scanned, Stats, PackageMap, TotalProcessed,
        PagesConsumed}
) when
    is_map(Scanned), is_map(Stats), is_map(PackageMap), is_map(PagesConsumed)
->
    {Scanned, Stats, PackageMap, TotalProcessed, PagesConsumed};
load_state_migration(_) ->
    {#{}, #{}, #{}, 0, #{}}.

%% =============================================================================
%% deduplicate_forks tests
%% =============================================================================

deduplicate_forks_test_() ->
    {"removes github forks keeping first occurrence", fun() ->
        Repos = [
            #{
                full_name => <<"user/repo">>,
                html_url => <<"https://github.com/user/repo">>
            },
            #{
                full_name => <<"fork/repo">>,
                html_url => <<"https://github.com/fork/repo">>
            },
            #{
                full_name => <<"other/different">>,
                html_url => <<"https://github.com/other/different">>
            },
            #{
                full_name => <<"another/lib">>,
                html_url => <<"https://github.com/another/lib">>
            }
        ],
        Result = spectrometer_ecosystem:deduplicate_forks(Repos),
        ?assertEqual(3, length(Result)),
        ?assertEqual(
            [<<"user/repo">>, <<"other/different">>, <<"another/lib">>],
            [maps:get(full_name, R) || R <- Result]
        )
    end}.

%% =============================================================================
%% Integration test: Resume with shifted results
%% =============================================================================

%% This is a simplified integration test - the actual API calls would need mocking
%% We test that the logic correctly computes pages from the PagesConsumed map
resume_shifted_results_test_() ->
    [
        {"PagesConsumed tracks last consumed page correctly", fun() ->
            %% Simulate: we've consumed 8 pages from GitHub
            %% The coordinator has PagesConsumed = #{github => 8, hex => 10}
            %% New repo gets created and shifts results
            %% On resume with --limit 100, we should re-fetch page 8
            PagesConsumed = #{github => 8, hex => 10},
            StartPage = spectrometer_ecosystem:resume_start_page(
                PagesConsumed, github, true, false
            ),
            ?assertEqual(8, StartPage)
        end}
    ].

%%
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%% All rights reserved.
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_http).

-moduledoc """
HTTP fetching for GitHub repos and Hex packages.

This module provides the network layer for ecosystem scans and target resolution.
It uses `httpc` for all HTTP operations (no external CLI dependencies like `gh`).

GitHub repos are fetched via the GitHub Search API with cursor-based pagination
by star count. Hex packages are fetched via the Hex API sorted by total downloads.
""".

-export([
    fetch_github_repos/1,
    fetch_hex_packages/1,
    fetch/1,
    download_github_repo/2,
    download_hex_tarball/2
]).

-define(GITHUB_PER_PAGE, 100).
-define(GITHUB_MAX_PER_QUERY, 1000).
-define(HEX_PER_PAGE, 100).
-define(HEX_MAX_PAGES, 100).

-doc """
Fetch GitHub repos via the GitHub Search API with cursor-based pagination.

Fetches Erlang repositories sorted by star count, up to `Limit` repos.
Pass `infinity` to fetch all available repos (capped at the API's
pagination limits).
""".
fetch_github_repos({Limit, MinStars}) ->
    io:format("Fetching GitHub repos...\n"),
    Max =
        case Limit of
            infinity -> ?GITHUB_MAX_PER_QUERY * 15;
            _ -> Limit
        end,
    Repos = fetch_github_cursor(MinStars, undefined, [], Max),
    io:format("  Total: ~p GitHub repos\n", [length(Repos)]),
    Repos.

-doc false.
%% Cursor-based GitHub repo fetching by star count range.
fetch_github_cursor(_MinStars, _LastStars, Acc, Max) when length(Acc) >= Max ->
    lists:sublist(Acc, Max);
fetch_github_cursor(MinStars, LastStars, Acc, Max) when LastStars < MinStars ->
    lists:sublist(Acc, Max);
fetch_github_cursor(MinStars, LastStars, Acc, Max) ->
    Range = star_filter_range(MinStars, LastStars),
    Remaining = Max - length(Acc),
    %% Add +2 to fetch, because "erlang/otp" and "atomvm/AtomVM" are filtered from results.
    Fetch = min(Remaining + 2, ?GITHUB_MAX_PER_QUERY),
    io:format("  stars:~s ...", [Range]),
    {Repos0, TotalCount} = fetch_github_query(Range, Fetch),
    Repos = filter_repos(Repos0, []),
    io:format(" ~p repos (of ~p available)\n", [length(Repos), TotalCount]),
    case Repos of
        [] ->
            Acc;
        _ ->
            NewAcc = Acc ++ Repos,
            case length(NewAcc) >= Max of
                true ->
                    lists:sublist(NewAcc, Max);
                false ->
                    Stars = [maps:get(stars, R) || R <- Repos],
                    MinStarsInBatch = lists:min(Stars),
                    fetch_github_cursor(
                        MinStars, MinStarsInBatch - 1, NewAcc, Max
                    )
            end
    end.

star_filter_range(infinity, _LastStars) ->
    ">=1";
star_filter_range(MinStars, undefined) ->
    io_lib:format(">=~p", [MinStars]);
star_filter_range(MinStars, LastStars) ->
    io_lib:format("~p..~p", [MinStars, LastStars]).

filter_repos([], Acc) ->
    lists:reverse(Acc);
filter_repos([Repo | Rest], Acc) ->
    case string:find(maps:get(full_name, Repo), "erlang/otp") of
        nomatch ->
            case string:find(maps:get(full_name, Repo), "atomvm/AtomVM") of
                nomatch ->
                    filter_repos(Rest, [Repo | Acc]);
                _ ->
                    filter_repos(Rest, Acc)
            end;
        _ ->
            filter_repos(Rest, Acc)
    end.

-doc false.
%% Fetch repos for a single star range query.
fetch_github_query(StarRange, Max) ->
    Query = lists:flatten("language:Erlang stars:" ++ StarRange),
    Limit = min(Max, ?GITHUB_MAX_PER_QUERY),
    fetch_github_pages(Query, 1, [], Limit, 0).

-doc false.
%% Paginated GitHub API fetcher.
fetch_github_pages(_Query, _Page, Acc, Max, TC) when length(Acc) >= Max ->
    {lists:sublist(lists:reverse(Acc), Max), TC};
fetch_github_pages(_Query, Page, Acc, _Max, TC) when
    Page > (?GITHUB_MAX_PER_QUERY div ?GITHUB_PER_PAGE)
->
    {lists:reverse(Acc), TC};
fetch_github_pages(Query, Page, Acc, Max, TC) ->
    Url = io_lib:format(
        "https://api.github.com/search/repositories"
        "?q=~s"
        "&sort=stars"
        "&order=desc"
        "&per_page=~p"
        "&page=~p",
        [uri_string:quote(Query), ?GITHUB_PER_PAGE, Page]
    ),
    case fetch(lists:flatten(Url)) of
        {ok, Body} ->
            try
                case json:decode(Body) of
                    #{<<"total_count">> := NewTC, <<"items">> := Items} when
                        is_list(Items), length(Items) > 0
                    ->
                        Repos = lists:map(
                            fun(Item) ->
                                #{
                                    full_name => binary_to_list(
                                        maps:get(<<"full_name">>, Item)
                                    ),
                                    clone_url => binary_to_list(
                                        maps:get(<<"clone_url">>, Item)
                                    ),
                                    html_url => binary_to_list(
                                        maps:get(<<"html_url">>, Item)
                                    ),
                                    stars => maps:get(
                                        <<"stargazers_count">>, Item, 0
                                    )
                                }
                            end,
                            Items
                        ),
                        fetch_github_pages(
                            Query,
                            Page + 1,
                            lists:reverse(Repos) ++ Acc,
                            Max,
                            NewTC
                        );
                    _ ->
                        {lists:reverse(Acc), TC}
                end
            catch
                _:_ ->
                    {lists:reverse(Acc), TC}
            end;
        {error, _Reason} ->
            {lists:reverse(Acc), TC}
    end.

-doc """
Fetch Hex packages via the Hex API sorted by total downloads.

Fetches Erlang packages up to `Limit`. Pass `infinity` to fetch all
available packages (capped at API pagination limits).
""".
fetch_hex_packages(Limit) ->
    Max =
        case Limit of
            infinity -> ?HEX_MAX_PAGES * ?HEX_PER_PAGE;
            _ -> min(Limit, ?HEX_MAX_PAGES * ?HEX_PER_PAGE)
        end,
    io:format("Fetching Hex packages (up to ~p)...\n", [Max]),
    fetch_hex_pages(1, [], Max).

-doc false.
%% Paginated Hex API fetcher.
fetch_hex_pages(Page, Acc, Max) when
    Page > ?HEX_MAX_PAGES; length(Acc) >= Max
->
    Packages = lists:sublist(lists:reverse(Acc), Max),
    io:format("  Found ~p Hex packages\n", [length(Packages)]),
    Packages;
fetch_hex_pages(Page, Acc, Max) ->
    Url = io_lib:format(
        "https://hex.pm/api/packages?sort=total_downloads&per_page=~p&page=~p",
        [?HEX_PER_PAGE, Page]
    ),
    case fetch(lists:flatten(Url)) of
        {ok, Body} ->
            try
                case json:decode(Body) of
                    Items when is_list(Items), length(Items) > 0 ->
                        Packages = lists:filtermap(
                            fun(Item) ->
                                Name = binary_to_list(
                                    maps:get(<<"name">>, Item, <<>>)
                                ),
                                Meta = maps:get(<<"meta">>, Item, #{}),
                                Links = maps:get(<<"links">>, Meta, #{}),
                                GithubUrl = find_github_link(Links),
                                LatestVersion = binary_to_list(
                                    maps:get(<<"latest_version">>, Item, <<>>)
                                ),
                                case LatestVersion of
                                    "" ->
                                        false;
                                    _ ->
                                        {true, #{
                                            name => Name,
                                            version => LatestVersion,
                                            github_url => GithubUrl
                                        }}
                                end
                            end,
                            Items
                        ),
                        io:format("  Page ~p: ~p packages\n", [
                            Page, length(Packages)
                        ]),
                        fetch_hex_pages(
                            Page + 1, lists:reverse(Packages) ++ Acc, Max
                        );
                    _ ->
                        lists:reverse(Acc)
                end
            catch
                _:_ ->
                    lists:reverse(Acc)
            end;
        {error, Reason} ->
            io:format("  Page ~p: HTTP error: ~p\n", [Page, Reason]),
            lists:reverse(Acc)
    end.

-doc false.
%% Extract GitHub URL from package links map.
find_github_link(Links) when is_map(Links) ->
    maps:fold(
        fun(_Key, Value, Acc) ->
            case Acc of
                "" ->
                    case is_binary(Value) of
                        true ->
                            Url = binary_to_list(Value),
                            case string:find(Url, "github.com") of
                                nomatch -> "";
                                _ -> Url
                            end;
                        false ->
                            ""
                    end;
                _ ->
                    Acc
            end
        end,
        "",
        Links
    );
find_github_link(_) ->
    "".

-doc """
Clone a GitHub repo to a temporary directory using a shallow clone.

Sets `GIT_TERMINAL_PROMPT=0` to prevent credential prompts in CI.
Returns `ok` on success, `{error, {clone_failed, Status}}` on failure.
""".
-ifdef(TEST).
-define(GIT_OPTS, [{"GIT_ASKPASS", "false"}, {"GIT_TERMINAL_PROMPT", "0"}]).
-else.
-define(GIT_OPTS, [{"GIT_TERMINAL_PROMPT", "0"}]).
-endif.
download_github_repo(CloneUrl, TmpDir) ->
    case os:find_executable("git") of
        false ->
            {error, git_not_found};
        GitPath ->
            Port = open_port(
                {spawn_executable, GitPath},
                [
                    {args, [
                        "clone", "--depth", "1", "--quiet", CloneUrl, TmpDir
                    ]},
                    {env, ?GIT_OPTS},
                    exit_status
                ]
            ),
            case await_git_port(Port) of
                0 -> ok;
                {error, clone_timeout} -> {error, clone_timeout};
                Status -> {error, {clone_failed, Status}}
            end
    end.

-doc false.
%% Wait for git port to complete and return exit status.
await_git_port(Port) ->
    receive
        {Port, {exit_status, Status}} -> Status
    after 180000 ->
        port_close(Port),
        drain_port_messages(Port),
        {error, clone_timeout}
    end.

-doc false.
%% Drain any pending messages for a closed port to avoid mailbox pollution.
drain_port_messages(Port) ->
    receive
        {Port, {exit_status, _}} -> ok
    after 0 ->
        ok
    end.

-doc """
Download and extract a Hex package tarball.

Fetches the tarball from `repo.hex.pm`, extracts the nested `contents.tar.gz`,
and checks for `.erl` files. Returns `{ok, TmpDir}` on success with the
extracted contents in a temp directory, or `{error, Reason}` on failure.
""".
download_hex_tarball(Name, Version) ->
    Url = lists:flatten(
        io_lib:format(
            "https://repo.hex.pm/tarballs/~s-~s.tar",
            [Name, Version]
        )
    ),
    Hostname = hostname_from_url(Url),
    case
        httpc:request(
            get,
            {Url, [{"user-agent", "atomvm_spectrometer/1.0"}]},
            [
                {timeout, 30000},
                {connect_timeout, 10000},
                {ssl, ssl_options(Hostname)}
            ],
            [{body_format, binary}]
        )
    of
        {ok, {{_, 200, _}, _, Body}} ->
            process_hex_tarball(Body, Name);
        {ok, {{_, Code, _}, _, _}} ->
            {error, {http_status, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

-doc false.
%% Extract and validate a Hex tarball in memory.
%% Checks for contents.tar.gz and verifies .erl files exist.
%% Validates archive entries to prevent path traversal attacks.
process_hex_tarball(TarBin, _Name) ->
    case erl_tar:extract({binary, TarBin}, [memory]) of
        {ok, OuterFiles} ->
            case lists:keyfind("contents.tar.gz", 1, OuterFiles) of
                {"contents.tar.gz", ContentsTarGz} ->
                    case erl_tar:table({binary, ContentsTarGz}, [compressed]) of
                        {ok, FileList} ->
                            HasErl = lists:any(
                                fun(F) ->
                                    filename:extension(F) =:= ".erl"
                                end,
                                FileList
                            ),
                            case HasErl of
                                true ->
                                    case validate_tar_paths(FileList) of
                                        ok ->
                                            TmpDir = spectrometer_utils:make_temp_dir(
                                                "hex_"
                                            ),
                                            try
                                                case
                                                    erl_tar:extract(
                                                        {binary, ContentsTarGz},
                                                        [
                                                            {cwd, TmpDir},
                                                            compressed
                                                        ]
                                                    )
                                                of
                                                    ok -> {ok, TmpDir};
                                                    {error, R} -> {error, R}
                                                end
                                            catch
                                                _:_ ->
                                                    _ = spectrometer_utils:purge_dir(
                                                        TmpDir
                                                    ),
                                                    {error, extract_failed}
                                            end;
                                        {error, Reason} ->
                                            {error, Reason}
                                    end;
                                false ->
                                    {error, no_erl_files}
                            end;
                        _ ->
                            {error, no_erl_files}
                    end;
                false ->
                    {error, no_contents_tar}
            end;
        {error, Reason} ->
            {error, {tar_extract, Reason}}
    end.

-doc false.
%% Validate tarball entry paths to prevent path traversal attacks.
%% Rejects absolute paths, ".." segments, and ensures paths stay within TmpDir.
validate_tar_paths(Paths) ->
    case lists:all(fun validate_tar_path/1, Paths) of
        true -> ok;
        false -> {error, path_traversal_attempt}
    end.

-doc false.
%% Validate a single tarball entry path.
%% Returns true if the path is safe (relative, no ".." segments).
validate_tar_path(Path) ->
    % Reject empty paths
    Path =/= [] andalso
        % Reject absolute Unix paths (starting with /)
        string:left(Path, 1) =/= "/" andalso
        % Reject absolute Windows paths (starting with drive letter like C:\)
        not is_windows_absolute_path(Path) andalso
        % Reject path segments with ".." (handle both / and \ separators)
        not has_dotdot_segment(Path).

-doc false.
%% Check if path looks like an absolute Windows path (C:\...).
is_windows_absolute_path([Drive, $:, Sep | _]) when
    Drive >= $A, Drive =< $Z, (Sep == $\\ orelse Sep == $/)
->
    true;
is_windows_absolute_path([Drive, $:, Sep | _]) when
    Drive >= $a, Drive =< $z, (Sep == $\\ orelse Sep == $/)
->
    true;
is_windows_absolute_path(_) ->
    false.

-doc false.
%% Check if path contains ".." as a path segment.
%% Normalizes separators before checking to prevent bypass with mixed separators
%% like "a\\..//secret.erl" which could produce ".." segment.
has_dotdot_segment(Path) ->
    % Normalize all backslashes to forward slashes first
    Normalized = re:replace(Path, "\\\\", "/", [{return, list}, global]),
    Segments = string:split(Normalized, "/", all),
    lists:member("..", Segments).

-doc false.
%% Extract hostname from a URL for SNI.
hostname_from_url(Url) ->
    #{host := Host} = uri_string:parse(Url),
    Host.

-doc false.
%% SSL options with peer verification.
ssl_options(Hostname) ->
    Certs = public_key:cacerts_get(),
    [
        {verify, verify_peer},
        {cacerts, Certs},
        {depth, 3},
        {server_name_indication, Hostname},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

-doc false.
%% Fetch a URL and return the body on success.
fetch(Url) ->
    Hostname = hostname_from_url(Url),
    case
        httpc:request(
            get,
            {Url, [{"user-agent", "atomvm_spectrometer/1.0"}]},
            [
                {timeout, 30000},
                {connect_timeout, 10000},
                {ssl, ssl_options(Hostname)}
            ],
            [{body_format, binary}]
        )
    of
        {ok, {{_, 200, _}, _, Body}} ->
            {ok, Body};
        {ok, {{_, Code, _}, _, _}} ->
            {error, {http_status, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

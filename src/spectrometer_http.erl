%%
%% Copyright 2026 Paul Guyot <pguyot@kallisys.net>
%% GitHub Gist @pguyot/beam_stats.escript
%% https://gist.github.com/pguyot/da327972f1ecdb7041c97addd4e76bb5
%% 
%% Adapted for atomvm_spectrometer:
%% Copyright (c) 2026 Winford (UncleGrumpy) <winford@object.stream>
%%
%% This is part of atomvm_spectrometer
%%
%% SPDX-FileCopyrightText: 2026 Paul Guyot <pguyot@kallisys.net>
%% SPDX-FileCopyrightText: 2026 Winford (UncleGrumpy)  <winford@object.stream>
%% SPDX-License-Identifier: Apache-2.0

-module(spectrometer_http).

-include_lib("kernel/include/logger.hrl").

-moduledoc """
HTTP fetching for GitHub repos and Hex packages.

This module provides the network layer for ecosystem scans and target resolution.
It uses `httpc` for all HTTP operations (no external CLI dependencies like `gh`).

GitHub repos are fetched via the GitHub Search API with page-based pagination
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
Fetch GitHub repos via the GitHub Search API with page-based pagination.

Fetches Erlang repositories sorted by star count, up to `Limit` repos.
Pass `infinity` to fetch all available repos (capped at the API's
pagination limits).
""".
fetch_github_repos({Limit, MinStars}) ->
    fetch_github_repos({Limit, MinStars}, 1).

-doc false.
fetch_github_repos({Limit, MinStars}, StartPage) ->
    ?LOG_INFO("Fetching GitHub repos"),
    Max =
        case Limit of
            infinity -> ?GITHUB_MAX_PER_QUERY * 15;
            _ -> Limit
        end,
    {Repos0, BoundaryStars} = fetch_github_page(MinStars, StartPage, [], Max),
    Repos =
        case StartPage =< (?GITHUB_MAX_PER_QUERY div ?GITHUB_PER_PAGE) of
            true ->
                fetch_github_repos_below_cap(
                    MinStars, Repos0, BoundaryStars, Max
                );
            false ->
                Repos0
        end,
    ?LOG_INFO("Processing ~p GitHub repos", [length(Repos)]),
    Repos.

-doc false.
%% Page-based GitHub repo fetching with a stable star range.
-spec fetch_github_page(
    integer() | infinity, pos_integer(), [map()], integer()
) -> {[map()], integer() | undefined}.
fetch_github_page(MinStars, Page, Acc, Max) ->
    fetch_github_page_range(MinStars, undefined, Page, Acc, Max, "desc").

-spec fetch_github_repos_below_cap(
    integer() | infinity, [map()], integer() | undefined, integer()
) -> [map()].
fetch_github_repos_below_cap(_MinStars, Acc, _BoundaryStars, Max) when
    length(Acc) >= Max
->
    Acc;
fetch_github_repos_below_cap(MinStars, Acc, BoundaryStars, Max) when
    Max >= ?GITHUB_MAX_PER_QUERY, is_integer(BoundaryStars)
->
    MinStarsForRange = min_star_floor(MinStars),
    LowerMaxStars = BoundaryStars - 1,
    case LowerMaxStars >= MinStarsForRange of
        true ->
            {Repos1, _BoundaryStars1} = fetch_github_page_range(
                MinStarsForRange,
                LowerMaxStars,
                1,
                Acc,
                Max,
                "asc"
            ),
            Repos1;
        false ->
            Acc
    end;
fetch_github_repos_below_cap(_MinStars, Acc, _BoundaryStars, _Max) ->
    Acc.

-spec fetch_github_page_range(
    integer() | infinity,
    integer() | undefined,
    pos_integer(),
    [map()],
    integer(),
    string()
) -> {[map()], integer() | undefined}.
fetch_github_page_range(MinStars, MaxStars, Page, Acc, Max, SortOrder) ->
    fetch_github_page_range(
        MinStars, MaxStars, Page, Acc, Max, SortOrder, undefined
    ).

-spec fetch_github_page_range(
    integer() | infinity,
    integer() | undefined,
    pos_integer(),
    [map()],
    integer(),
    string(),
    integer() | undefined
) -> {[map()], integer() | undefined}.
fetch_github_page_range(
    _MinStars, _MaxStars, _Page, Acc, Max, _SortOrder, BoundaryStars
) when
    length(Acc) >= Max
->
    {lists:sublist(Acc, Max), BoundaryStars};
fetch_github_page_range(
    _MinStars, _MaxStars, Page, Acc, Max, _SortOrder, BoundaryStars
) when
    Page > (?GITHUB_MAX_PER_QUERY div ?GITHUB_PER_PAGE)
->
    {lists:sublist(Acc, Max), BoundaryStars};
fetch_github_page_range(
    MinStars, MaxStars, Page, Acc, Max, SortOrder, BoundaryStars0
) ->
    Range = star_filter_range(MinStars, MaxStars),
    case fetch_github_page(Range, Page, SortOrder) of
        {[], _TotalCount} ->
            io:format("\n"),
            {lists:sublist(Acc, Max), BoundaryStars0};
        {RawPage, TotalCount} ->
            NewAcc = Acc ++ RawPage,
            BoundaryStars = boundary_from_raw_page(
                Page, RawPage, BoundaryStars0
            ),
            io:format(
                "\r\tstars:~s page ~p (~s) ... ~p repos (of ~p available)",
                [Range, Page, SortOrder, length(NewAcc), TotalCount]
            ),
            case length(NewAcc) >= Max of
                true ->
                    io:format("\n"),
                    {lists:sublist(NewAcc, Max), BoundaryStars};
                false ->
                    fetch_github_page_range(
                        MinStars,
                        MaxStars,
                        Page + 1,
                        NewAcc,
                        Max,
                        SortOrder,
                        BoundaryStars
                    )
            end
    end.

-spec star_filter_range(integer() | infinity, integer() | undefined) ->
    string().
star_filter_range(infinity, undefined) ->
    ">=1";
star_filter_range(infinity, MaxStars) when is_integer(MaxStars) ->
    io_lib:format(">=1..~p", [MaxStars]);
star_filter_range(MinStars, undefined) ->
    io_lib:format(">=~p", [MinStars]);
star_filter_range(MinStars, MaxStars) ->
    io_lib:format("~p..~p", [MinStars, MaxStars]).

-dialyzer({nowarn_function, [boundary_from_raw_page/3]}).
%% The [] clause is a defensive fallback; Dialyzer's success typing
%% for fetch_github_page/3 infers a non-empty list, making this
%% clause unreachable per static analysis. The clause is kept for
%% runtime safety in case the API behavior changes.
-spec boundary_from_raw_page(pos_integer(), [map()], integer() | undefined) ->
    integer() | undefined.
boundary_from_raw_page(_Page, [], BoundaryStars) ->
    BoundaryStars;
boundary_from_raw_page(_Page, RawPage, _BoundaryStars) ->
    Stars = [maps:get(stars, Repo) || Repo <- RawPage],
    lists:min(Stars).

-spec min_star_floor(integer() | infinity) -> integer().
min_star_floor(infinity) ->
    1;
min_star_floor(MinStars) when is_integer(MinStars) ->
    MinStars.

-doc false.
%% Fetch one raw GitHub Search API page.
-spec fetch_github_page(
    string(), pos_integer(), string()
) -> {[map()], non_neg_integer()}.
fetch_github_page(StarRange, Page, SortOrder) ->
    Query = lists:flatten("language:Erlang stars:" ++ StarRange),
    Url = io_lib:format(
        "https://api.github.com/search/repositories"
        "?q=~s"
        "&sort=stars"
        "&order=~s"
        "&per_page=~p"
        "&page=~p",
        [uri_string:quote(Query), SortOrder, ?GITHUB_PER_PAGE, Page]
    ),
    case fetch(lists:flatten(Url)) of
        {ok, Body} ->
            try
                case json:decode(Body) of
                    #{
                        <<"total_count">> := TotalCount, <<"items">> := Items
                    } when
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
                        {Repos, TotalCount};
                    _ ->
                        {[], 0}
                end
            catch
                _:_ -> {[], 0}
            end;
        {error, _Reason} ->
            {[], 0}
    end.

-doc """
Fetch Hex packages via the Hex API sorted by total downloads.

Fetches Erlang packages up to `Limit`. Pass `infinity` to fetch all
available packages (capped at API pagination limits).
""".
-spec fetch_hex_packages(integer() | infinity) -> [map()].
fetch_hex_packages(Limit) ->
    Max =
        case Limit of
            infinity -> ?HEX_MAX_PAGES * ?HEX_PER_PAGE;
            _ -> min(Limit, ?HEX_MAX_PAGES * ?HEX_PER_PAGE)
        end,
    ?LOG_INFO("Fetching Hex packages (up to ~p)...\n", [Max]),
    fetch_hex_pages(StartPage, [], Max).

-doc false.
%% Paginated Hex API fetcher.
-spec fetch_hex_pages(pos_integer(), [map()], non_neg_integer()) -> [map()].
fetch_hex_pages(Page, Acc, Max) when
    Page > ?HEX_MAX_PAGES; length(Acc) >= Max
->
    Packages = lists:sublist(lists:reverse(Acc), Max),
    ?LOG_INFO("Found ~p Hex packages\n", [length(Packages)]),
    Packages;
fetch_hex_pages(Page, Acc, Max) ->
    Url = io_lib:format(
        "https://hex.pm/api/packages?sort=total_downloads&per_page=~p&page=~p",
        [?HEX_PER_PAGE, Page]
    ),
    ?LOG_DEBUG("fetch url: ~s", [lists:flatten(Url)]),
    case fetch(lists:flatten(Url)) of
        {ok, Body} ->
            ?LOG_DEBUG("fetch body prefix: ~p", [
                binary:part(Body, 0, min(byte_size(Body), 200))
            ]),
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
                        ?LOG_DEBUG("Page ~p: ~p packages\n", [
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
            ?LOG_ERROR("Page ~p: HTTP error: ~p\n", [Page, Reason]),
            lists:reverse(Acc)
    end.

-doc false.
%% Extract GitHub URL from package links map.
-spec find_github_link(map() | term()) -> string().
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
-define(GIT_ENV, [
    {"PATH", os:getenv("PATH", "/bin:/usr/bin:/usr/local/bin")},
    {"GIT_TERMINAL_PROMPT", "0"},
    {"SSH_ASKPASS", false}
]).
-else.
-define(GIT_ENV, [
    {"PATH", os:getenv("PATH", "/bin:/usr/bin:/usr/local/bin")},
    {"GIT_TERMINAL_PROMPT", "0"}
]).
-endif.
-spec download_github_repo(string(), string()) -> ok | {error, term()}.
download_github_repo(CloneUrl, TmpDir) ->
    _ =
        case {filelib:is_dir(TmpDir), filelib:is_file(TmpDir)} of
            {true, _} ->
                file:del_dir_r(TmpDir);
            {_, true} ->
                file:delete(TmpDir);
            {false, false} ->
                ok
        end,
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
                    {env, ?GIT_ENV},
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
-spec await_git_port(port()) -> non_neg_integer() | {error, term()}.
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
-spec drain_port_messages(port()) -> ok.
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
-spec download_hex_tarball(string(), string()) ->
    {ok, string()} | {error, term()}.
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
-spec process_hex_tarball(binary(), string()) ->
    {ok, string()} | {error, term()}.
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
-spec validate_tar_paths([string()]) -> ok | {error, term()}.
validate_tar_paths(Paths) ->
    case lists:all(fun validate_tar_path/1, Paths) of
        true -> ok;
        false -> {error, path_traversal_attempt}
    end.

-doc false.
%% Validate a single tarball entry path.
%% Returns true if the path is safe (relative, no ".." segments).
-spec validate_tar_path(string()) -> boolean().
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
-spec is_windows_absolute_path(string()) -> boolean().
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
-spec has_dotdot_segment(string()) -> boolean().
has_dotdot_segment(Path) ->
    % Normalize all backslashes to forward slashes first
    Normalized = re:replace(Path, "\\\\", "/", [{return, list}, global]),
    Segments = string:split(Normalized, "/", all),
    lists:member("..", Segments).

-doc false.
%% Extract hostname from a URL for SNI.
-spec hostname_from_url(string()) -> string().
hostname_from_url(Url) ->
    #{host := Host} = uri_string:parse(Url),
    Host.

-doc false.
%% SSL options with peer verification.
-spec ssl_options(string()) -> [tuple()].
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
-spec github_headers() -> [{string(), string()}].
github_headers() ->
    [
        {"user-agent", "atomvm_spectrometer/1.0"},
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"}
    ].

-spec fetch(string()) -> {ok, binary()} | {error, term()}.
fetch(Url) ->
    {ok, _Started} = application:ensure_all_started(inets),
    {ok, _StartedSsl} = application:ensure_all_started(ssl),
    Hostname = hostname_from_url(Url),
    case
        httpc:request(
            get,
            {Url, github_headers()},
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

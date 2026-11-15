%% HTTP POST for glean's providers, using OTP's httpc.
%%
%% This is glean's only FFI. It exists for two reasons:
%%
%% - Streaming. gleam_httpc returns whole responses, and the Gleam SSE
%%   packages pull in a second HTTP stack, so Server-Sent Events are read
%%   here with httpc's `{stream, self}` mode: body chunks arrive as
%%   messages to the calling process, which `next/2` turns into values the
%%   Gleam side can match on. Parsing SSE happens in Gleam
%%   (glean/providers/sse.gleam).
%% - Errors as values. gleam_httpc raises an exception for every httpc
%%   error it doesn't know (a connection the server closed, a reset, a
%%   response httpc can't parse), which would crash the process running an
%%   agent. `post/4` returns every failure as a value instead, so glean can
%%   retry it or report it.
-module(glean_http_ffi).
-export([post/4, start/4, next/2, cancel/1]).

%% Send the request and wait for the whole response. Returns
%% {ok, {Status, RetryAfterMs, RetryAfter, Body}}, {error, timed_out} when
%% no response came within TimeoutMs, or {error, {request_failed, Reason}}.
post(Url, Headers, Body, TimeoutMs) ->
    ok = ensure_started(),
    HttpOptions = [{timeout, TimeoutMs} | http_options(TimeoutMs)],
    try httpc:request(post, request(Url, Headers, Body), HttpOptions,
                      [{body_format, binary}]) of
        {ok, {{_Version, Status, _Reason}, RespHeaders, RespBody}} ->
            {ok, {Status,
                  header("retry-after-ms", RespHeaders),
                  header("retry-after", RespHeaders),
                  to_binary(RespBody)}};
        {error, timeout} ->
            {error, timed_out};
        {error, Reason} ->
            {error, {request_failed, describe(Reason)}}
    catch
        Class:Reason ->
            {error, {request_failed, describe({Class, Reason})}}
    end.

%% Start a streamed request. Returns {ok, RequestId} or {error, Reason}.
start(Url, Headers, Body, ConnectTimeoutMs) ->
    ok = ensure_started(),
    Options = [{sync, false}, {stream, self}, {body_format, binary}],
    case httpc:request(post, request(Url, Headers, Body),
                       http_options(ConnectTimeoutMs), Options) of
        {ok, RequestId} -> {ok, RequestId};
        {error, Reason} -> {error, describe(Reason)}
    end.

ensure_started() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    ok.

request(Url, Headers, Body) ->
    {
        binary_to_list(Url),
        [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers],
        "application/json",
        Body
    }.

http_options(ConnectTimeoutMs) ->
    [
        {ssl, ssl_options()},
        {autoredirect, false},
        {connect_timeout, ConnectTimeoutMs}
    ].

%% Wait up to TimeoutMs for the next message about RequestId.
next(RequestId, TimeoutMs) ->
    receive
        {http, {RequestId, stream_start, _Headers}} -> started;
        {http, {RequestId, stream, Chunk}} -> {chunk, Chunk};
        {http, {RequestId, stream_end, _Headers}} -> finished;
        {http, {RequestId, {{_Version, Status, _Reason}, RespHeaders, RespBody}}} ->
            {status, Status,
             header("retry-after-ms", RespHeaders),
             header("retry-after", RespHeaders),
             to_binary(RespBody)};
        {http, {RequestId, {error, Reason}}} -> {request_failed, describe(Reason)}
    after TimeoutMs ->
        timed_out
    end.

%% Cancel the request and drop any of its messages already in the mailbox,
%% so a stopped stream leaves nothing behind for the calling process.
cancel(RequestId) ->
    _ = httpc:cancel_request(RequestId),
    flush(RequestId).

flush(RequestId) ->
    receive
        {http, {RequestId, _}} -> flush(RequestId);
        {http, {RequestId, _, _}} -> flush(RequestId)
    after 0 ->
        nil
    end.

ssl_options() ->
    [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

%% A response header as {some, Binary} or none (a Gleam Option). httpc
%% gives header names in lower case.
header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> {some, unicode:characters_to_binary(Value)};
        false -> none
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> iolist_to_binary(L).

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).

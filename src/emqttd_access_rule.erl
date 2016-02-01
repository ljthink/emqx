%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2016 Feng Lee <feng@emqtt.io>. All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc emqttd ACL Rule
%%% 
%%% @author Feng Lee <feng@emqtt.io>
%%%-----------------------------------------------------------------------------
-module(emqttd_access_rule).

-include("emqttd.hrl").

-type who() :: all | binary() |
               {ipaddr, esockd_access:cidr()} |
               {client, binary()} |
               {user, binary()}.

-type access() :: subscribe | publish | pubsub.

-type topic() :: binary().

-type rule() :: {allow, all} |
                {allow, who(), access(), list(topic())} |
                {deny, all} |
                {deny, who(), access(), list(topic())}.

-export_type([rule/0]).

-export([compile/1, match/3]).

-define(ALLOW_DENY(A), ((A =:= allow) orelse (A =:= deny))).

%%------------------------------------------------------------------------------
%% @doc Compile access rule
%% @end
%%------------------------------------------------------------------------------
compile({A, all}) when ?ALLOW_DENY(A) ->
    {A, all};

compile({A, Who, Access, Topic}) when ?ALLOW_DENY(A) andalso is_binary(Topic) ->
    {A, compile(who, Who), Access, [compile(topic, Topic)]};

compile({A, Who, Access, TopicFilters}) when ?ALLOW_DENY(A) ->
    {A, compile(who, Who), Access, [compile(topic, Topic) || Topic <- TopicFilters]}.

compile(who, all) ->
    all;
compile(who, {ipaddr, CIDR}) ->
    {Start, End} = esockd_access:range(CIDR),
    {ipaddr, {CIDR, Start, End}};
compile(who, {client, all}) ->
    {client, all};
compile(who, {client, ClientId}) ->
    {client, bin(ClientId)};
compile(who, {user, all}) ->
    {user, all};
compile(who, {user, Username}) ->
    {user, bin(Username)};
compile(who, {'and', Conds}) when is_list(Conds) ->
    {'and', [compile(who, Cond) || Cond <- Conds]};
compile(who, {'or', Conds}) when is_list(Conds) ->
    {'or', [compile(who, Cond) || Cond <- Conds]};

compile(topic, {eq, Topic}) ->
    {eq, emqttd_topic:words(bin(Topic))};
compile(topic, Topic) ->
    Words = emqttd_topic:words(bin(Topic)),
    case 'pattern?'(Words) of
        true -> {pattern, Words};
        false -> Words
    end.

'pattern?'(Words) ->
    lists:member(<<"$u">>, Words)
        orelse lists:member(<<"$c">>, Words).

bin(L) when is_list(L) ->
    list_to_binary(L);
bin(B) when is_binary(B) ->
    B.

%%------------------------------------------------------------------------------
%% @doc Match rule
%% @end
%%------------------------------------------------------------------------------
-spec match(mqtt_client(), topic(), rule()) -> {matched, allow} | {matched, deny} | nomatch.
match(_Client, _Topic, {AllowDeny, all}) when (AllowDeny =:= allow) orelse (AllowDeny =:= deny) ->
    {matched, AllowDeny};
match(Client, Topic, {AllowDeny, Who, _PubSub, TopicFilters})
        when (AllowDeny =:= allow) orelse (AllowDeny =:= deny) ->
    case match_who(Client, Who) andalso match_topics(Client, Topic, TopicFilters) of
        true  -> {matched, AllowDeny};
        false -> nomatch
    end.

match_who(_Client, all) ->
    true;
match_who(_Client, {user, all}) ->
    true;
match_who(_Client, {client, all}) ->
    true;
match_who(#mqtt_client{client_id = ClientId}, {client, ClientId}) ->
    true;
match_who(#mqtt_client{username = Username}, {user, Username}) ->
    true;
match_who(#mqtt_client{peername = undefined}, {ipaddr, _Tup}) ->
    false;
match_who(#mqtt_client{peername = {IP, _}}, {ipaddr, {_CDIR, Start, End}}) ->
    I = esockd_access:atoi(IP),
    I >= Start andalso I =< End;
match_who(Client, {'and', Conds}) when is_list(Conds) ->
    lists:foldl(fun(Who, Allow) ->
                  match_who(Client, Who) andalso Allow
                end, true, Conds);
match_who(Client, {'or', Conds}) when is_list(Conds) ->
    lists:foldl(fun(Who, Allow) ->
                  match_who(Client, Who) orelse Allow
                end, false, Conds);
match_who(_Client, _Who) ->
    false.

match_topics(_Client, _Topic, []) ->
    false;
match_topics(Client, Topic, [{pattern, PatternFilter}|Filters]) ->
    TopicFilter = feed_var(Client, PatternFilter),
    case match_topic(emqttd_topic:words(Topic), TopicFilter) of
        true -> true;
        false -> match_topics(Client, Topic, Filters)
    end;
match_topics(Client, Topic, [TopicFilter|Filters]) ->
   case match_topic(emqttd_topic:words(Topic), TopicFilter) of
    true -> true;
    false -> match_topics(Client, Topic, Filters)
    end.

match_topic(Topic, {eq, TopicFilter}) ->
    Topic =:= TopicFilter;
match_topic(Topic, TopicFilter) ->
    emqttd_topic:match(Topic, TopicFilter).

feed_var(Client, Pattern) ->
    feed_var(Client, Pattern, []).
feed_var(_Client, [], Acc) ->
    lists:reverse(Acc);
feed_var(Client = #mqtt_client{client_id = undefined}, [<<"$c">>|Words], Acc) ->
    feed_var(Client, Words, [<<"$c">>|Acc]);
feed_var(Client = #mqtt_client{client_id = ClientId}, [<<"$c">>|Words], Acc) ->
    feed_var(Client, Words, [ClientId |Acc]);
feed_var(Client = #mqtt_client{username = undefined}, [<<"$u">>|Words], Acc) ->
    feed_var(Client, Words, [<<"$u">>|Acc]);
feed_var(Client = #mqtt_client{username = Username}, [<<"$u">>|Words], Acc) ->
    feed_var(Client, Words, [Username|Acc]);
feed_var(Client, [W|Words], Acc) ->
    feed_var(Client, Words, [W|Acc]).


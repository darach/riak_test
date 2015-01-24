%% -------------------------------------------------------------------
%%
%% Copyright (c) 2012 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(riak667_mixed).
-behavior(riak_test).
-export([confirm/0]).
-include_lib("eunit/include/eunit.hrl").

-define(HARNESS, (rt_config:get(rt_harness))).
-define(TYPE, <<"maps">>).
-define(KEY, <<"cmeiklejohn">>).
-define(KEY2, <<"cmeik">>).
-define(BUCKET, {?TYPE, <<"testbucket">>}).

-define(CONF, [
               {riak_core,
                [{ring_creation_size, 8}]
               },
               {riak_kv,
                [{crdt_mixed_versions, true}]}
              ]).

confirm() ->
    rt:set_advanced_conf(all, ?CONF),

    %% Configure cluster.
    TestMetaData = riak_test_runner:metadata(),
    OldVsn = proplists:get_value(upgrade_version, TestMetaData, "2.0.2"),
    _Nodes = [Node1, Node2] = rt:build_cluster([OldVsn, OldVsn]),

    CurrentVer = rt:get_version(),

    %% Create PB connection.
    Pid = rt:pbc(Node1),
    riakc_pb_socket:set_options(Pid, [queue_if_disconnected]),

    %% Create bucket type for maps.
    rt:create_and_activate_bucket_type(Node1, ?TYPE, [{datatype, map}]),

    %% Write some sample data.
    Map = riakc_map:update(
            {<<"names">>, set},
            fun(R) ->
                    riakc_set:add_element(<<"Original">>, R)
            end, riakc_map:new()),
    Map2 = riakc_map:update({<<"profile">>, map},
                            fun(M) ->
                                    riakc_map:update(
                                      {<<"name">>, register},
                                      fun(R) ->
                                              riakc_register:set(<<"Bob">>, R)
                                      end, M)
                            end, Map),

    ok = riakc_pb_socket:update_type(
            Pid,
            ?BUCKET,
            ?KEY,
            riakc_map:to_op(Map2)),

    %% Upgrade one node.
    upgrade(Node2, "2.0.4"),

    lager:info("running mixed 2.0.2 and 2.0.4"),

    %% Create PB connection.
    Pid2 = rt:pbc(Node2),
    riakc_pb_socket:set_options(Pid2, [queue_if_disconnected]),

    %% Read value.
    ?assertMatch({error, <<"Error processing incoming message: error:{badrecord,dict}", _/binary>>},
                 riakc_pb_socket:fetch_type(Pid2, ?BUCKET, ?KEY)),

    lager:info("Can't read a 2.0.2 map from 2.0.4 node"),

    %% Write some 2.0.4 data.
    Oh4Map = riakc_map:update(
            {<<"names">>, set},
            fun(R) ->
                    riakc_set:add_element(<<"Original">>, R)
            end, riakc_map:new()),
    Oh4Map2 = riakc_map:update({<<"profile">>, map},
                            fun(M) ->
                                    riakc_map:update(
                                      {"name", register},
                                      fun(R) ->
                                              riakc_register:set(<<"Bob">>, R)
                                      end, M)
                            end, Oh4Map),

    ok = riakc_pb_socket:update_type(
            Pid2,
            ?BUCKET,
            ?KEY2,
            riakc_map:to_op(Oh4Map2)),

    lager:info("Created a 2.0.4 map"),

    %% and read 2.0.4 data?? Nope, dict is not an orddict
    ?assertMatch({error,<<"Error processing incoming message: error:function_clause:[{orddict,fold", _/binary>>},
                 riakc_pb_socket:fetch_type(Pid, ?BUCKET, ?KEY2)),

    lager:info("Can't read 2.0.4 map from 2.0.2 node"),

    %% upgrade 2.0.4 to 2.0.5
    riakc_pb_socket:stop(Pid2),
    upgrade(Node2, current),

    lager:info("running mixed 2.0.2 and ~s", [CurrentVer]),

    %% Create PB connection.
    Pid3 = rt:pbc(Node2),
    riakc_pb_socket:set_options(Pid3, [queue_if_disconnected]),

    %% read both maps
    {ok, K1O} = riakc_pb_socket:fetch_type(Pid3, ?BUCKET, ?KEY),
    {ok, K2O} = riakc_pb_socket:fetch_type(Pid3, ?BUCKET, ?KEY2),

    lager:info("2.0.2 map ~p", [K1O]),
    lager:info("2.0.4 map ~p", [K2O]),

    %% update 2.0.2 map on new node ?KEY Pid3
    K1OU = riakc_map:update({<<"profile">>, map},
                            fun(M) ->
                                    riakc_map:update(
                                      {<<"name">>, register},
                                      fun(R) ->
                                              riakc_register:set(<<"Rita">>, R)
                                      end, M)
                            end, K1O),

    ok = riakc_pb_socket:update_type(Pid3, ?BUCKET, ?KEY, riakc_map:to_op(K1OU)),
    lager:info("Updated 2.0.2 map on ~s", [CurrentVer]),

    %% read 2.0.2 map from 2.0.2 node ?KEY Pid
    {ok, K1OR} = riakc_pb_socket:fetch_type(Pid, ?BUCKET, ?KEY),
    lager:info("Read 2.0.2 map from 2.0.2 node: ~p", [K1OR]),

    ?assertEqual(<<"Rita">>, orddict:fetch({<<"name">>, register},
                                           riakc_map:fetch({<<"profile">>, map}, K1OR))),

    %% update 2.0.2 map on old node ?KEY Pid
    K1O2 = riakc_map:update({<<"profile">>, map},
                            fun(M) ->
                                    riakc_map:update(
                                      {<<"name">>, register},
                                      fun(R) ->
                                              riakc_register:set(<<"Sue">>, R)
                                      end, M)
                            end, K1OR),

    ok = riakc_pb_socket:update_type(Pid, ?BUCKET, ?KEY, riakc_map:to_op(K1O2)),
    lager:info("Updated 2.0.2 map on 2.0.2 node"),

    %% read it from 2.0.5 node ?KEY Pid3
    {ok, K1OC} = riakc_pb_socket:fetch_type(Pid3, ?BUCKET, ?KEY),
    lager:info("Read 2.0.2 map from ~s node: ~p", [CurrentVer, K1OC]),

    ?assertEqual(<<"Sue">>, orddict:fetch({<<"name">>, register},
                                          riakc_map:fetch({<<"profile">>, map}, K1OC))),

    %% update 2.0.4 map node ?KEY2 Pid3
    K2OU = riakc_map:update({<<"people">>, set},
                            fun(S) ->
                                    riakc_set:add_element(<<"Joan">>, S)
                            end, riakc_map:new()),

    ok = riakc_pb_socket:update_type(Pid3, ?BUCKET, ?KEY2, riakc_map:to_op(K2OU)),
    lager:info("Updated 2.0.4 map on ~s node", [CurrentVer]),
    %% upgrade 2.0.2 node

    riakc_pb_socket:stop(Pid),
    upgrade(Node1, current),
    lager:info("Upgraded 2.0.2 node to ~s", [CurrentVer]),

    %% read and write maps
    Pid4 = rt:pbc(Node1),

    {ok, K1N1} = riakc_pb_socket:fetch_type(Pid4, ?BUCKET, ?KEY),
    {ok, K1N2} = riakc_pb_socket:fetch_type(Pid3, ?BUCKET, ?KEY),
    ?assertEqual(K1N1, K1N2),

    {ok, K2N1} = riakc_pb_socket:fetch_type(Pid4, ?BUCKET, ?KEY2),
    {ok, K2N2} = riakc_pb_socket:fetch_type(Pid3, ?BUCKET, ?KEY2),
    ?assertEqual(K2N1, K2N2),
    lager:info("Maps fetched from both nodes are same K1:~p K2:~p", [K1N1, K2N1]),

    %% (how???) check format is still v1 (maybe get raw kv object and inspect contents using riak_kv_crdt??
    %% unset env var
    %% read and write maps
    %% (how??? see above?) check ondisk format is now v2


    %% Stop PB connection.
    riakc_pb_socket:stop(Pid3),
    riakc_pb_socket:stop(Pid4),

    pass.

upgrade(Node, NewVsn) ->
    lager:info("Upgrading ~p to ~p", [Node, NewVsn]),
    rt:upgrade(Node, NewVsn),
    rt:wait_for_service(Node, riak_kv),
    ok.

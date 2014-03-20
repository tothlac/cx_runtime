%% %CopyrightBegin%
%%
%% Copyright Concurix Corporation 2012-2013. All Rights Reserved.
%%
%% The contents of this file are subject to the Concurix Terms of Service:
%% http://www.concurix.com/main/tos_main
%%
%% The Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. 
%%
%% %CopyrightEnd%
%%
%% Send data to a browser via a websocket for real time visualizations.
%%
-module(concurix_trace_send_to_viz).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("concurix_runtime.hrl").

-define(TIMER_INTERVAL_VIZ, 2 * 1000).    %% Update VIZ every 2 seconds

start_link(State) ->
  gen_server:start_link(?MODULE, [State], []).

init([State]) ->
  timer:send_after(?TIMER_INTERVAL_VIZ, send_to_viz),

  {ok, State}.
 
handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
handle_info(send_to_viz,                    State) ->
    if 
	(State#tcstate.sendUpdates == true) ->
	    timer:send_after(?TIMER_INTERVAL_VIZ, send_to_viz);
	true -> ok
    end,

    RunInfo = State#tcstate.runInfo,
    Url = "http://results.concurix.com:9090/results",
    Json = concurix_runtime:get_current_json(State),
    Request = viz_make_post_http_request(Url, Json),

    %%io:format("~p\n\n\n", [Request]),

    Rep = httpc:request(post, Request, [{timeout, 60000}], [{sync, true}]),

    %%io:format("~p\n\n\n", [Rep]),

    {noreply, State};

handle_info(stop_updating,                  State) ->
  {noreply, State#tcstate{sendUpdates = false}};

handle_info(Msg,                            State) ->
  io:format("~p:handle_info/2 Unexpected message ~p~n", [?MODULE, Msg]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.

viz_make_post_http_request(Url, Json) ->
    BinLen = io_lib:write(iolist_size(Json)),
    
    Headers = [{"Concurix-API-Key","1add9c809787226a18cf1b704b10ca34"},
	       %%{"content-type","application/json"},
	       {"content-length",BinLen}],
    {Url,Headers,"application/json",Json}.

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
%% This file contains both the top level API's as well as the root gen_server for the Concurix Runtime
%%
-module(concurix_runtime).

-behaviour(gen_server).

-export([start/0, start/2, start_link/0, stop/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("concurix_runtime.hrl").

-define(DEFAULT_TRACE_MF, {?MODULE, get_default_json}).

%%==============================================================================
%% External functions
%%==============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Starts the monitoring application.
%% When started with no parameters a default config will be downloaded from
%% a concurix server, and it will be used during the tracing.
%% @end
%%------------------------------------------------------------------------------
-spec start() -> {ok, pid()} | {error, Reason :: term()}.

start() ->
  application:start(inets),
  Result = httpc:request("http://concurix.com/bench/get_config_download/benchcode-381"),
  case Result of
    {ok, {{_, 200, "OK"}, _Headers, Body}} ->
      Config = eval_string(Body),
      internal_start([Config], [msg_trace]);
    Error ->
      io:format("error, could not autoconfigure concurix_runtime ~p ~n", [Error]),
      {error, Error}
  end.

%%------------------------------------------------------------------------------
%% @doc
%% Starts the monitoring application.
%% First pameter is the path to the config file, Option is a list of config
%% options.
%% @end
%%------------------------------------------------------------------------------
-spec start(FileName, Options) -> {ok, pid()} | {error, Reason :: term()} when
  FileName :: file:name_all(),
  Options :: list().

start(Filename, Options) ->
  {ok, CWD}           = file:get_cwd(),
  Dirs                = code:get_path(),

  {ok, Config, _File} = file:path_consult([CWD | Dirs], Filename),
  internal_start(Config, Options).

%%------------------------------------------------------------------------------
%% @doc stop tracing
%%------------------------------------------------------------------------------
-spec stop() -> ok.

stop() ->
  gen_server:call(?MODULE, stop_tracer),
  ok.

%%------------------------------------------------------------------------------
%% @doc Start the gen_server
%%------------------------------------------------------------------------------
-spec start_link() -> {ok, pid()}.

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%==============================================================================
%% gen_server callbacks
%%==============================================================================
init([]) ->
  {ok, undefined}.

handle_call({start_tracer, RunInfo, Options, Config},  _From, undefined) ->
  io:format("starting Concurix tracing ~n"),
  {ok, APIKey} = concurix_lib:config_option(Config, master, api_key),
  TraceMF = concurix_lib:config_option(Config, master, trace_mf, ?DEFAULT_TRACE_MF),
  DisplayPid = concurix_lib:config_option(Config, master, display_pid, false),
  DisablePosts = concurix_lib:config_option(Config, master, disable_posts, false),
  TimerIntervalViz =
    concurix_lib:config_option(Config, master, timer_interval_viz,
                               ?DEFAULT_TIMER_INTERVAL_VIZ),

  State     = #tcstate{run_info             = RunInfo,
                       %% Tables to communicate between data collectors
                       %% and data transmitters
                       process_table        = setup_ets_table(cx_procinfo),
                       link_table           = setup_ets_table(cx_linkstats),
                       sys_prof_table       = setup_ets_table(cx_sysprof),
                       proc_link_table      = setup_ets_table(cx_proclink),
                       reduction_table      = setup_ets_table(cx_reduction),

                       %% Tables to cache information from last snapshot
                       last_nodes           = ets:new(cx_lastnodes, [public, {keypos, 2}]),

                       trace_supervisor     = undefined,

                       collect_trace_data   = undefined,
                       send_updates         = undefined,
                       trace_mf             = TraceMF,
                       api_key              = APIKey,
                       display_pid          = DisplayPid,
                       timer_interval_viz   = TimerIntervalViz,
                       disable_posts        = DisablePosts},

  fill_initial_tables(State),
  {ok, Sup} = concurix_trace_supervisor:start_link(State, Options),
  {reply, ok, State#tcstate{trace_supervisor = Sup}};

handle_call({start_tracer, _Config, _Options, _Config}, _From, State) ->
  io:format("~p:handle_call/3   start_tracer but tracer is already running~n", [?MODULE]),
  {reply, ok, State};

handle_call(stop_tracer, _From, undefined) ->
  io:format("~p:handle_call/3   stop_tracer  but tracer is not running~n", [?MODULE]),
  {reply, ok, undefined};

handle_call(stop_tracer, _From, State) ->
  concurix_trace_supervisor:stop_tracing(State#tcstate.trace_supervisor),
  {reply, ok, undefined}.

%%==============================================================================
%% Internal funtions
%%==============================================================================
-spec tracer_is_enabled(list()) -> boolean().
tracer_is_enabled(Options) ->
  tracer_is_enabled(Options, [ msg_trace, enable_sys_profile, enable_send_to_viz ]).

tracer_is_enabled([], _TracerOptions) ->
  false;

tracer_is_enabled([Head | Tail], TracerOptions) ->
  case lists:member(Head, TracerOptions) of
    true  ->
      true;

    false ->
      tracer_is_enabled(Tail, TracerOptions)
  end.

-spec internal_start([any()],maybe_improper_list()) -> any().
internal_start(Config, Options) ->
  application:start(crypto),
  application:start(inets),

  application:start(ssl),
  application:start(timer),

  application:start(sasl),
  application:start(os_mon),

  ssl:start(),

  ok = application:start(concurix_runtime),

  case tracer_is_enabled(Options) of
    true  ->
      RunInfo = get_run_info(Config),
      gen_server:call(?MODULE, { start_tracer, RunInfo, Options, Config });
    false ->
      {error, {failed, bad_options}}
  end.

%% Make an http call back to concurix for a run id.
%% Assume that the synchronous version of httpc works, although
%% we know it has some intermittent problems under chicago boss.

%% Here is a representative response
%%
%% [ { run_id,    "benchrun-1426"},
%%   { trace_url, "https://concurix_trace_data.s3.amazonaws.com/"},
%%   { fields,    [ { key,             "benchrun-1426"},
%%                  {'AWSAccessKeyId', "<AWS generated string>"},
%%                  {policy,           "<AWS generated string>"},
%%                  {signature,        "<AWS generated string>"}]}]

-spec get_run_info([atom() | tuple()]) -> [{binary(),_}].
get_run_info(Config) ->
  { ok, Server } = concurix_lib:config_option(Config, master, concurix_server),
  { ok, APIkey } = concurix_lib:config_option(Config, master, api_key),

  Url            = "http://" ++ Server ++ "/bench/new_offline_run/" ++ APIkey,
  Reply          = httpc:request(Url),

  LocalRunInfo =
    case concurix_lib:config_option(Config, master, run_info) of
        undefined -> [];
        {ok, Value} -> Value
    end,

  case Reply of
    {_, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} ->
      RemoteRunInfo = cx_jsx:json_to_term(list_to_binary(Body)),
      concurix_lib:merge_run_info(RemoteRunInfo, LocalRunInfo);
    _ ->
      keys_to_b(LocalRunInfo)
  end.

-spec eval_string(nonempty_string()) -> any().
eval_string(Incoming_String) ->
  String = case lists:last(Incoming_String) of
    $. -> Incoming_String;
    _X -> lists:concat([Incoming_String, "."])
  end,
  {ok, Tokens, _} = erl_scan:string(String),
  {_Status, Term} = erl_parse:parse_term(Tokens),
  Term.

-spec setup_ets_table(Table) -> Result when
  Table :: 'cx_linkstats' | 'cx_procinfo' | 'cx_proclink' |
           'cx_reduction' | 'cx_sysprof',
  Result :: atom() | ets:tid().
setup_ets_table(T) ->
  case ets:info(T) of
    undefined ->
      ets:new(T, [public]);

    _ ->
      ets:delete_all_objects(T),
      T
  end.

-spec handle_cast(_,_) -> {'noreply',_}.
handle_cast(_Msg, State) ->
  {noreply, State}.


-spec handle_info(_,_) -> {'noreply',_}.
handle_info(_Msg, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  ets:delete(State#tcstate.process_table),
  ets:delete(State#tcstate.link_table),
  ets:delete(State#tcstate.sys_prof_table),
  ets:delete(State#tcstate.proc_link_table),
  ok.

-spec code_change(_,_,_) -> {'ok',_}.
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.

%%
%% on startup, we want to pre-populate our process and link tables with existing information
%% so that things like the supervision tree are realized properly.

fill_initial_tables(State) ->
  Processes = processes(),
  fill_initial_proctable(State#tcstate.process_table, Processes),
  fill_initial_proclinktable(State#tcstate.proc_link_table, Processes).

-spec fill_initial_proctable('undefined' | ets:tid(),[pid()]) ->
  'ok'.
fill_initial_proctable(Table, Processes) ->
  ProcList = concurix_lib:update_process_info(Processes, []),
  lists:foreach(fun(P) -> ets:insert(Table, P) end, ProcList).

-spec fill_initial_proclinktable('undefined' | ets:tid(),[pid()]) ->
  'ok'.
fill_initial_proclinktable(_Table, []) ->
  ok;
fill_initial_proclinktable(Table, [P | Tail]) ->
  lists:foreach(fun(P2) ->
    ets:insert(Table, {P, P2})
    end,
    get_proc_links(P)
    ),
  fill_initial_proclinktable(Table, Tail).

-spec get_proc_links(pid()) -> [pid()].
get_proc_links(Proc) ->
  %% Returns a list of linked processes.
  case concurix_lib:careful_process_info(Proc, links) of
    {links, Plinks} ->
      [P || P <- Plinks, is_pid(P)];
    _ ->
      []
  end.

-spec keys_to_b([any()]) -> [{binary(),_}].
keys_to_b(L) ->
  [{list_to_binary(atom_to_list(K)), V} || {K, V} <- L].

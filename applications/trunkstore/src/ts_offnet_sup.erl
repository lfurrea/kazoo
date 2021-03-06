%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2015, 2600Hz INC
%%% @doc
%%% Manage offnet calls
%%% @end
%%%-------------------------------------------------------------------
-module(ts_offnet_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_handler/2, stop_handler/1]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("whistle/include/wh_types.hrl").

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link({'local', ?SERVER}, ?MODULE, []).

start_handler(CallID, RouteReqJObj) ->
    supervisor:start_child(?SERVER, ?WORKER_NAME_ARGS('ts_from_offnet'
                                                      ,<<"offnet-", CallID/binary>>
                                                      ,[RouteReqJObj]
                                                     )).

stop_handler(CallID) ->
    'ok' = supervisor:terminate_child(?SERVER, <<"offnet-", CallID/binary>>),
    supervisor:delete_child(?SERVER, <<"offnet-", CallID/binary>>).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    RestartStrategy = 'one_for_one',
    MaxRestarts = 1,
    MaxSecondsBetweenRestarts = 5,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    {'ok', {SupFlags, []}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

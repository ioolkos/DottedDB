%% @doc The coordinator for stat get operations.  The key here is to
%% generate the preflist just like in wrtie_fsm and then query each
%% replica and wait until a quorum is met.
-module(dotted_db_get_fsm).
-behavior(gen_fsm).
-include("dotted_db.hrl").

%% API
-export([start_link/4]).

%% Callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([execute/2, waiting/2, waiting2/2, finalize/2]).

-record(state, {
    %% Unique request ID.
    req_id      :: pos_integer(),
    %% Pid from the caller process.
    from        :: pid(),
    %% The key to read.
    key         :: bkey(),
    %% The replica nodes for the key.
    replicas    :: riak_core_apl:preflist2(),
    %% Minimum number of acks from replica nodes.
    min_acks    :: non_neg_integer(),
    %% Maximum number of acks from replica nodes.
    max_acks    :: non_neg_integer(),
    %% Do read repair on outdated replica nodes.
    do_rr       :: boolean(),
    %% Return the final value or not
    return_val  :: boolean(),
    %% The current Object to return.
    replies     :: [{index_node(), dotted_db_object:object()}],
    %% The timeout value for this request.
    timeout     :: non_neg_integer()
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ReqID, From, BKey, Options) ->
    gen_fsm:start_link(?MODULE, [ReqID, From, BKey, Options], []).

%%%===================================================================
%%% States
%%%===================================================================

%% Initialize state data.
init([ReqId, From, BKey, Options]) ->
    State = #state{ req_id      = ReqId,
                    from        = From,
                    key         = BKey,
                    replicas    = dotted_db_utils:replica_nodes(BKey),
                    min_acks    = proplists:get_value(?OPT_READ_MIN_ACKS, Options),
                    max_acks    = ?REPLICATION_FACTOR,
                    do_rr       = proplists:get_value(?OPT_DO_RR, Options),
                    replies     = [],
                    return_val  = true,
                    timeout     = proplists:get_value(?OPT_TIMEOUT, Options, ?DEFAULT_TIMEOUT)
    },
    {ok, execute, State, 0}.

%% @doc Execute the get reqs.
execute(timeout, State=#state{  req_id      = ReqId,
                                key         = Key,
                                replicas    = ReplicaNodes}) ->
    % request this key from nodes that store it (ReplicaNodes)
    dotted_db_vnode:read(ReplicaNodes, ReqId, Key),
    {next_state, waiting, State}.

%% @doc Wait for W-1 write acks. Timeout is 5 seconds by default (see dotted_db.hrl).
waiting(timeout, State=#state{  req_id      = ReqID,
                                from        = From}) ->
    lager:warning("GET_FSM timeout in waiting state."),
    From ! {ReqID, timeout},
    {stop, timeout, State};

waiting({ok, ReqID, IndexNode, Response}, State=#state{
                                                req_id      = ReqID,
                                                from        = From,
                                                replies     = Replies,
                                                return_val  = ReturnValue,
                                                min_acks    = Min,
                                                max_acks    = Max}) ->
    %% Add the new response to Replies. If it's a not_found or an error, add an empty Object.
    Replies2 =  case Response of
                    {ok, Object} -> [{IndexNode, Object} | Replies];
                    _            -> [{IndexNode, dotted_db_object:new()} | Replies]
                end,
    NewState = State#state{replies = Replies2},
    % test if we have enough responses to respond to the client
    case length(Replies2) >= Min of
        true -> % we already have enough responses to acknowledge back to the client
            _ = create_client_reply(From, ReqID, Replies2, ReturnValue),
            case length(Replies2) >= Max of
                true -> % we got the maximum number of replies sent
                    {next_state, finalize, NewState, 0};
                false -> % wait for all replica nodes
                    {next_state, waiting2, NewState}
            end;
        false -> % we still miss some responses to respond to the client
            {next_state, waiting, NewState}
    end.

waiting2(timeout, State) ->
    {next_state, finalize, State, 0};
waiting2({ok, ReqID, IndexNode, Response}, State=#state{
                                                req_id      = ReqID,
                                                max_acks    = Max,
                                                replies     = Replies}) ->
    %% Add the new response to Replies. If it's a not_found or an error, add an empty object.
    Replies2 =  case Response of
                    {ok, Object}    -> [{IndexNode, Object} | Replies];
                    _               -> [{IndexNode, dotted_db_object:new()} | Replies]
                end,
    NewState = State#state{replies = Replies2},
    case length(Replies2) >= Max of
        true -> % we got the maximum number of replies sent
            {next_state, finalize, NewState, 0};
        false -> % wait for all replica nodes
            {next_state, waiting2, NewState}
    end.

finalize(timeout, State=#state{ do_rr       = false}) ->
    % lager:debug("GET_FSM: read repair OFF"),
    {stop, normal, State};
finalize(timeout, State=#state{ do_rr       = true,
                                key         = BKey,
                                replies     = Replies}) ->
    read_repair(BKey, Replies),
    {stop, normal, State}.



handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.


%%%===================================================================
%%% Internal Functions
%%%===================================================================

-spec read_repair(bkey(), [{index_node(), dotted_db_object:object()}]) -> ok.
read_repair(_BKey, Replies) ->
    %% Compute the final Object.
    _FinalObj = final_obj_from_replies(Replies),
    %% Computed what replicas have an outdated version of this key, and repair them.
    % [ dotted_db_vnode:repair([IndexNode], BKey, FinalObj) ||
    %     {IndexNode, Obj} <- Replies, not dotted_db_object:equal(Obj, FinalObj)],
    ok.

-spec final_obj_from_replies([{index_node(), dotted_db_object:object()}]) -> dotted_db_object:object().
final_obj_from_replies(Replies) ->
    Objs = [Obj || {_,Obj} <- Replies],
    lists:foldl(fun dotted_db_object:sync/2, dotted_db_object:new(), Objs).

create_client_reply(From, ReqID, _Replies, _ReturnValue = false) ->
    From ! {ReqID, ok, get, false};
create_client_reply(From, ReqID, Replies, _ReturnValue = true) ->
    FinalObj = final_obj_from_replies(Replies),
    Values = [V || V <- dotted_db_object:get_values(FinalObj), V =/= ?DELETE_OP],
    case Values =:= [] of
        true -> % no response found; return the context for possibly future writes
            From ! {ReqID, not_found, get, dotted_db_object:get_context(FinalObj)};
        false -> % there is at least on value for this key
            From ! {ReqID, ok, get, {Values, dotted_db_object:get_context(FinalObj)}}
    end.

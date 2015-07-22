-module(plumtree_metadata_cleanup).

-behaviour(gen_server).

%% API functions
-export([start_link/1,
         force_cleanup/1,
         force_cleanup/2,
         set_interval/1,
         set_interval/2,
         cancel_cleanup/0,
         cancel_cleanup/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {interval, deleted, tref, waiting}).

-define(TOMBSTONE, '$deleted').

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(FullPrefix) ->
    gen_server:start_link(?MODULE, [FullPrefix], []).

force_cleanup(AgeInSecs) when AgeInSecs > 0 ->
    for_all_cleaners(fun force_cleanup/2, [AgeInSecs]).

force_cleanup(FullPrefix, AgeInSecs) when is_tuple(FullPrefix) ->
    for_cleaner(FullPrefix, fun force_cleanup/2, [AgeInSecs]);
force_cleanup(Pid, AgeInSecs) when is_pid(Pid) and (AgeInSecs > 0) ->
    gen_server:call(Pid, {force_cleanup, AgeInSecs}, infinity).

set_interval(Int) when Int >= 0 ->
    for_all_cleaners(fun set_interval/2, [Int]).

set_interval(FullPrefix, Int) when is_tuple(FullPrefix) and (Int >= 0) ->
    for_cleaner(FullPrefix, fun set_interval/2, [Int]);
set_interval(Pid, Int) when is_pid(Pid) and (Int >= 0) ->
    gen_server:call(Pid, {set_interval, Int}, infinity).

cancel_cleanup() ->
    for_all_cleaners(fun cancel_cleanup/1, []).

cancel_cleanup(FullPrefix) when is_tuple(FullPrefix) ->
    for_cleaner(FullPrefix, fun cancel_cleanup/1, []);
cancel_cleanup(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, cancel_cleanup, infinity).


for_all_cleaners(Fun, Args) ->
    lists:foreach(fun({_FullPrefix, Pid}) ->
                          apply(Fun, [Pid|Args])
                  end, plumtree_metadata_cleanup_sup:get_full_prefix_and_pid()).

for_cleaner(FullPrefix, Fun, Args) ->
    case plumtree_metadata_cleanup_sup:get_pid(FullPrefix) of
        {ok, Pid} ->
            apply(Fun, [Pid|Args]);
        E ->
            E
    end.




%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([FullPrefix]) ->
    CleanupInterval = app_helper:get_prop_or_env(cleanup_interval, [],
                                                 plumtree, undefined),
    case CleanupInterval of
        undefined ->
            %% no cleanup happens
            {ok, #state{interval=undefined,
                        deleted={FullPrefix, gb_sets:new()}}};
        _ when CleanupInterval > 0 ->
            TRef = erlang:send_after(0, self(), cleanup),
            {ok, #state{interval=CleanupInterval * 1000,
                        tref=TRef,
                        deleted={FullPrefix, gb_sets:new()}}}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({force_cleanup, AgeInSecs}, From, #state{tref=TRef,
                                                     waiting=Waiting,
                                                     deleted=Deleted} = State) ->
    case Waiting of
        undefined ->
            case TRef of
                undefined ->
                    ignore;
                _ ->
                    erlang:cancel_timer(TRef)
            end,
            NewDeleted = cleanup_tombstones(Deleted),
            NewTRef = erlang:send_after(AgeInSecs * 1000, self(), cleanup),
            {noreply, State#state{deleted=NewDeleted,
                                  tref=NewTRef,
                                  waiting=From}};
        _ ->
            {reply, {error, already_scheduled}, State}
    end;
handle_call({set_interval, IntInSecs}, _From, #state{waiting=Waiting,
                                                     tref=TRef} = State) ->
    case Waiting of
        undefined ->
            {NewInterval, NewTRef} =
            case {IntInSecs, TRef} of
                {0, undefined} ->
                    {undefined, undefined};
                {0, _} ->
                    erlang:cancel_timer(TRef),
                    {undefined, undefined};
                {_, undefined} ->
                    NewIntInSecs = IntInSecs * 1000,
                    {NewIntInSecs, erlang:send_after(NewIntInSecs, self(), cleanup)};
                {_, _} ->
                    erlang:cancel_timer(TRef),
                    NewIntInSecs = IntInSecs * 1000,
                    {NewIntInSecs, erlang:send_after(NewIntInSecs, self(), cleanup)}
            end,
            {reply, ok, State#state{interval=NewInterval, tref=NewTRef}};
        _ ->
            {reply, {error, waiting_for_cleanup}, State}
    end;
handle_call(cancel_cleanup, _From, #state{waiting=Waiting,
                                          interval=Interval} = State) ->
    case Waiting of
        undefined ->
            {reply, {error, no_waiting_proc}, State};
        _ ->
            gen_server:reply(Waiting, canceled),
            case Interval of
                undefined ->
                    {reply, ok, State#state{waiting=undefined}};
                _ ->
                    NewTRef = erlang:send_after(Interval, self(), cleanup),
                    {reply, ok, State#state{waiting=undefined, tref=NewTRef}}
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(cleanup, #state{waiting=Waiting,
                            interval=Interval,
                            deleted=Deleted} = State) ->
    NewDeleted = cleanup_tombstones(Deleted),
    case Waiting of
        undefined ->
            ignore;
        _ ->
            gen_server:reply(Waiting, ok)
    end,
    NewState =
    case Interval of
        undefined ->
            State#state{waiting=undefined, deleted=NewDeleted};
        _ ->
            NewTRef = erlang:send_after(Interval, self(), cleanup),
            State#state{waiting=undefined, deleted=NewDeleted, tref=NewTRef}
    end,
    {noreply, NewState}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
cleanup_tombstones({FullPrefix, Set}) ->
    T1 = os:timestamp(),
    {_, Marked, Deleted, Total, NewSet} = plumtree_metadata:fold(
                                            fun cleanup_tombstones/2,
                                            {FullPrefix, 0, 0, 0, Set},
                                            FullPrefix, [{resolver, lww}]),
    T2 = os:timestamp(),
    DiffInMs = timer:now_diff(T2, T1) div 1000,
    lager:info("completed cleanup for ~p in ~pms. deleted ~p, marked ~p, good ~p",
               [FullPrefix, DiffInMs, Deleted, Marked, Total]),
    {FullPrefix, NewSet}.

cleanup_tombstones({Key, ?TOMBSTONE}, {FullPrefix, Marked, Deleted, Total, Set}) ->
    case gb_sets:is_element(Key, Set) of
        true ->
            %% delete
            plumtree_metadata_manager:force_delete({FullPrefix, Key}),
            {FullPrefix, Marked, Deleted + 1, Total, gb_sets:delete(Key, Set)};
        false ->
            {FullPrefix, Marked + 1, Deleted, Total, gb_sets:add(Key, Set)}
    end;
cleanup_tombstones({Key, _}, {FullPrefix, Marked, Deleted, Total, Set}) ->
    {FullPrefix, Marked, Deleted, Total + 1, gb_sets:delete_any(Key, Set)}.
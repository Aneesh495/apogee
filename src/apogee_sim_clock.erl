%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc High-Fidelity Discrete-Event Virtual Simulation Clock.
%%% Provides accelerated-time orbital clock management with event scheduling,
%%% pause/resume, variable time multipliers (1x to 10000x), and tick broadcast
%%% to registered avionics subsystem subscribers.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_sim_clock).

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    start_link/1,
    start_link/2,
    stop/0,
    stop/1,
    now_virtual/0,
    now_virtual/1,
    set_time_scale/1,
    set_time_scale/2,
    get_time_scale/0,
    get_time_scale/1,
    pause/0,
    pause/1,
    resume/0,
    resume/1,
    step/1,
    step/2,
    schedule_event/2,
    schedule_event/3,
    subscribe/0,
    subscribe/1,
    unsubscribe/0,
    unsubscribe/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(scheduled_event, {
    target_time :: float(),
    id :: reference(),
    payload :: term(),
    recipient :: pid()
}).

-record(state, {
    virtual_time = 0.0 :: float(),
    time_scale = 1.0 :: float(),
    paused = false :: boolean(),
    last_wall_ms = 0 :: integer(),
    subscribers = [] :: [pid()],
    events = [] :: [#scheduled_event{}],
    timer_ref = undefined :: reference() | undefined
}).

-define(DEFAULT_TICK_INTERVAL_MS, 50).
-define(SERVER, ?MODULE).

%%====================================================================
%% API Functions
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(0.0, 1.0).

-spec start_link(float()) -> {ok, pid()} | {error, term()}.
start_link(InitialVirtualTime) ->
    start_link(InitialVirtualTime, 1.0).

-spec start_link(float(), float()) -> {ok, pid()} | {error, term()}.
start_link(InitialVirtualTime, TimeScale) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [InitialVirtualTime, TimeScale], []).

-spec stop() -> ok.
stop() ->
    stop(?SERVER).

-spec stop(pid() | atom()) -> ok.
stop(Server) ->
    gen_server:stop(Server).

-spec now_virtual() -> float().
now_virtual() ->
    now_virtual(?SERVER).

-spec now_virtual(pid() | atom()) -> float().
now_virtual(Server) ->
    gen_server:call(Server, now_virtual).

-spec set_time_scale(float()) -> ok.
set_time_scale(Scale) ->
    set_time_scale(?SERVER, Scale).

-spec set_time_scale(pid() | atom(), float()) -> ok.
set_time_scale(Server, Scale) ->
    gen_server:call(Server, {set_time_scale, Scale}).

-spec get_time_scale() -> float().
get_time_scale() ->
    get_time_scale(?SERVER).

-spec get_time_scale(pid() | atom()) -> float().
get_time_scale(Server) ->
    gen_server:call(Server, get_time_scale).

-spec pause() -> ok.
pause() ->
    pause(?SERVER).

-spec pause(pid() | atom()) -> ok.
pause(Server) ->
    gen_server:call(Server, pause).

-spec resume() -> ok.
resume() ->
    resume(?SERVER).

-spec resume(pid() | atom()) -> ok.
resume(Server) ->
    gen_server:call(Server, resume).

-spec step(float()) -> float().
step(Dt) ->
    step(?SERVER, Dt).

-spec step(pid() | atom(), float()) -> float().
step(Server, Dt) ->
    gen_server:call(Server, {step, Dt}).

-spec schedule_event(float(), term()) -> reference().
schedule_event(TargetTime, Payload) ->
    schedule_event(?SERVER, TargetTime, Payload).

-spec schedule_event(pid() | atom(), float(), term()) -> reference().
schedule_event(Server, TargetTime, Payload) ->
    gen_server:call(Server, {schedule_event, TargetTime, Payload, self()}).

-spec subscribe() -> ok.
subscribe() ->
    subscribe(?SERVER).

-spec subscribe(pid() | atom()) -> ok.
subscribe(Server) ->
    gen_server:call(Server, {subscribe, self()}).

-spec unsubscribe() -> ok.
unsubscribe() ->
    unsubscribe(?SERVER).

-spec unsubscribe(pid() | atom()) -> ok.
unsubscribe(Server) ->
    gen_server:call(Server, {unsubscribe, self()}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([InitialVirtualTime, TimeScale]) ->
    WallNow = erlang:system_time(millisecond),
    TRef = erlang:send_after(?DEFAULT_TICK_INTERVAL_MS, self(), internal_tick),
    {ok, #state{
        virtual_time = float(InitialVirtualTime),
        time_scale = float(TimeScale),
        paused = false,
        last_wall_ms = WallNow,
        subscribers = [],
        events = [],
        timer_ref = TRef
    }}.

handle_call(now_virtual, _From, State) ->
    {reply, State#state.virtual_time, State};

handle_call({set_time_scale, Scale}, _From, State) ->
    {reply, ok, State#state{time_scale = max(0.0, float(Scale))}};

handle_call(get_time_scale, _From, State) ->
    {reply, State#state.time_scale, State};

handle_call(pause, _From, State) ->
    {reply, ok, State#state{paused = true}};

handle_call(resume, _From, State) ->
    WallNow = erlang:system_time(millisecond),
    {reply, ok, State#state{paused = false, last_wall_ms = WallNow}};

handle_call({step, Dt}, _From, State) ->
    NewTime = State#state.virtual_time + float(Dt),
    {DispatchedEvents, RemainingEvents} = partition_events(NewTime, State#state.events),
    dispatch_events(DispatchedEvents),
    notify_subscribers(State#state.subscribers, NewTime, float(Dt)),
    {reply, NewTime, State#state{virtual_time = NewTime, events = RemainingEvents}};

handle_call({schedule_event, TargetTime, Payload, Recipient}, _From, State) ->
    Ref = make_ref(),
    Ev = #scheduled_event{
        target_time = float(TargetTime),
        id = Ref,
        payload = Payload,
        recipient = Recipient
    },
    Sorted = lists:keysort(#scheduled_event.target_time, [Ev | State#state.events]),
    {reply, Ref, State#state{events = Sorted}};

handle_call({subscribe, Pid}, _From, State) ->
    Subs = lists:usort([Pid | State#state.subscribers]),
    {reply, ok, State#state{subscribers = Subs}};

handle_call({unsubscribe, Pid}, _From, State) ->
    Subs = lists:delete(Pid, State#state.subscribers),
    {reply, ok, State#state{subscribers = Subs}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(internal_tick, State) ->
    WallNow = erlang:system_time(millisecond),
    ElapsedMs = WallNow - State#state.last_wall_ms,
    NewState = case State#state.paused of
        true ->
            State#state{last_wall_ms = WallNow};
        false ->
            Dt = (ElapsedMs / 1000.0) * State#state.time_scale,
            NewTime = State#state.virtual_time + Dt,
            {Dispatched, Remaining} = partition_events(NewTime, State#state.events),
            dispatch_events(Dispatched),
            notify_subscribers(State#state.subscribers, NewTime, Dt),
            State#state{
                virtual_time = NewTime,
                last_wall_ms = WallNow,
                events = Remaining
            }
    end,
    TRef = erlang:send_after(?DEFAULT_TICK_INTERVAL_MS, self(), internal_tick),
    {noreply, NewState#state{timer_ref = TRef}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.timer_ref of
        undefined -> ok;
        Ref -> erlang:cancel_timer(Ref)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal Functions
%%====================================================================

partition_events(CurrentTime, Events) ->
    lists:partition(
        fun(#scheduled_event{target_time = T}) -> T =< CurrentTime end,
        Events
    ).

dispatch_events([]) ->
    ok;
dispatch_events([#scheduled_event{id = Ref, payload = P, recipient = R} | Rest]) ->
    R ! {sim_event, Ref, P},
    dispatch_events(Rest).

notify_subscribers([], _Time, _Dt) ->
    ok;
notify_subscribers([Sub | Rest], Time, Dt) ->
    Sub ! {sim_tick, Time, Dt},
    notify_subscribers(Rest, Time, Dt).

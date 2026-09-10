%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Real-Time Timed Automata Engine for Aerospace Flight Verification.
%%% Implements Alur-Dill timed automata with real-valued continuous clocks,
%%% location invariants, clock guard conditions, and clock reset actions.
%%% Formally models critical spacecraft timed sequences (e.g. thruster burns,
%%% deployment timers, and communication timeouts).
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_timed_automata).

-export([
    new/2,
    set_invariant/3,
    add_transition/6,
    advance_time/2,
    trigger/2,
    current_location/1,
    get_clock/2,
    get_clocks/1
]).

-record(transition, {
    from_loc :: atom(),
    to_loc :: atom(),
    event :: atom(),
    guard :: fun((#{atom() => float()}) -> boolean()),
    resets :: [atom()]
}).

-record(timed_automaton, {
    current_loc :: atom(),
    clocks = #{} :: #{atom() => float()},
    invariants = #{} :: #{atom() => fun((#{atom() => float()}) -> boolean())},
    transitions = [] :: [#transition{}]
}).

-type timed_automaton() :: #timed_automaton{}.
-export_type([timed_automaton/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec new(atom(), [atom()]) -> timed_automaton().
new(InitialLoc, ClockNames) when is_atom(InitialLoc), is_list(ClockNames) ->
    InitialClocks = maps:from_list([{C, 0.0} || C <- ClockNames]),
    #timed_automaton{
        current_loc = InitialLoc,
        clocks = InitialClocks,
        invariants = #{},
        transitions = []
    }.

-spec set_invariant(timed_automaton(), atom(), fun((#{atom() => float()}) -> boolean())) -> timed_automaton().
set_invariant(#timed_automaton{} = TA, Loc, InvariantFun) when is_function(InvariantFun, 1) ->
    NewInvariants = maps:put(Loc, InvariantFun, TA#timed_automaton.invariants),
    TA#timed_automaton{invariants = NewInvariants}.

-spec add_transition(
    timed_automaton(),
    atom(),
    atom(),
    fun((#{atom() => float()}) -> boolean()),
    [atom()],
    atom()
) -> timed_automaton().
add_transition(#timed_automaton{} = TA, FromLoc, Event, GuardFun, Resets, ToLoc) ->
    Trans = #transition{
        from_loc = FromLoc,
        to_loc = ToLoc,
        event = Event,
        guard = GuardFun,
        resets = Resets
    },
    TA#timed_automaton{transitions = [Trans | TA#timed_automaton.transitions]}.

-spec advance_time(timed_automaton(), number()) -> {ok, timed_automaton()} | {error, invariant_violated}.
advance_time(#timed_automaton{} = TA, DeltaT) when DeltaT >= 0 ->
    NewClocks = maps:map(fun(_K, Val) -> Val + float(DeltaT) end, TA#timed_automaton.clocks),
    % Check location invariant
    case check_invariant(TA#timed_automaton.current_loc, NewClocks, TA#timed_automaton.invariants) of
        true ->
            {ok, TA#timed_automaton{clocks = NewClocks}};
        false ->
            {error, invariant_violated}
    end.

-spec trigger(timed_automaton(), atom()) -> {ok, timed_automaton()} | {error, term()}.
trigger(#timed_automaton{} = TA, Event) ->
    CurLoc = TA#timed_automaton.current_loc,
    Matching = [T || T <- TA#timed_automaton.transitions, T#transition.from_loc =:= CurLoc, T#transition.event =:= Event],
    case Matching of
        [] ->
            {error, no_matching_transition};
        [Trans | _] ->
            Guard = Trans#transition.guard,
            case Guard(TA#timed_automaton.clocks) of
                true ->
                    % Apply clock resets
                    ResetClocks = lists:foldl(
                        fun(C, Acc) -> maps:put(C, 0.0, Acc) end,
                        TA#timed_automaton.clocks,
                        Trans#transition.resets
                    ),
                    TargetLoc = Trans#transition.to_loc,
                    case check_invariant(TargetLoc, ResetClocks, TA#timed_automaton.invariants) of
                        true ->
                            {ok, TA#timed_automaton{
                                current_loc = TargetLoc,
                                clocks = ResetClocks
                            }};
                        false ->
                            {error, target_invariant_violated}
                    end;
                false ->
                    {error, guard_not_satisfied}
            end
    end.

-spec current_location(timed_automaton()) -> atom().
current_location(#timed_automaton{current_loc = Loc}) ->
    Loc.

-spec get_clock(timed_automaton(), atom()) -> float().
get_clock(#timed_automaton{clocks = Clocks}, ClockName) ->
    maps:get(ClockName, Clocks, 0.0).

-spec get_clocks(timed_automaton()) -> #{atom() => float()}.
get_clocks(#timed_automaton{clocks = Clocks}) ->
    Clocks.

%%====================================================================
%% Internal Helpers
%%====================================================================

check_invariant(Loc, Clocks, InvariantsMap) ->
    case maps:find(Loc, InvariantsMap) of
        {ok, InvFun} ->
            InvFun(Clocks);
        error ->
            true
    end.

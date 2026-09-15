%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Explicit-State Model Checker for Spacecraft Avionics State Machines.
%%% Formally verifies flight software properties:
%%% - Deadlock-freedom (exhaustive state space exploration)
%%% - Safety invariant preservation with counterexample trace generation
%%% - Liveness and reachability (absence of livelock trapping cycles)
%%% Operates on Kripke structures and labeled transition systems.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_model_checker).

-export([
    new_model/2,
    add_transition/4,
    explore_state_space/1,
    verify_deadlock_freedom/1,
    verify_safety/2,
    verify_liveness_reachability/2,
    build_spacecraft_fsm/0
]).

-record(model, {
    initial_states = [] :: [term()],
    transitions = #{} :: #{term() => [{atom(), term()}]} % State => [{Action, NextState}]
}).

-type model() :: #model{}.
-export_type([model/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec new_model([term()], #{term() => [{atom(), term()}]}) -> model().
new_model(InitialStates, TransitionsMap) ->
    #model{
        initial_states = InitialStates,
        transitions = TransitionsMap
    }.

-spec add_transition(model(), term(), atom(), term()) -> model().
add_transition(#model{} = M, FromState, Action, ToState) ->
    Existing = maps:get(FromState, M#model.transitions, []),
    NewList = [{Action, ToState} | Existing],
    M#model{transitions = maps:put(FromState, NewList, M#model.transitions)}.

-spec explore_state_space(model()) -> [term()].
explore_state_space(#model{initial_states = Init, transitions = Trans}) ->
    bfs_explore(Init, sets:new([{version, 2}]), Trans, []).

-spec verify_deadlock_freedom(model()) -> {ok, non_neg_integer()} | {error, {deadlock, term()}}.
verify_deadlock_freedom(#model{} = M) ->
    Reachable = explore_state_space(M),
    case find_deadlock(Reachable, M#model.transitions) of
        {deadlock, St} ->
            {error, {deadlock, St}};
        none ->
            {ok, length(Reachable)}
    end.

-spec verify_safety(model(), fun((term()) -> boolean())) -> ok | {error, {counterexample, [term()]}}.
verify_safety(#model{initial_states = Init, transitions = Trans}, SafetyPred) ->
    % BFS search tracking paths
    Queue = [{St, [St]} || St <- Init],
    Visited = sets:from_list(Init, [{version, 2}]),
    search_safety(Queue, Visited, Trans, SafetyPred).

-spec verify_liveness_reachability(model(), fun((term()) -> boolean())) -> ok | {error, {unreachable_from, term()}}.
verify_liveness_reachability(#model{} = M, TargetPred) ->
    Reachable = explore_state_space(M),
    UnreachableFrom = [St || St <- Reachable, not can_reach_target(St, M#model.transitions, TargetPred)],
    case UnreachableFrom of
        [] ->
            ok;
        [FirstTrapped | _] ->
            {error, {unreachable_from, FirstTrapped}}
    end.

-spec build_spacecraft_fsm() -> model().
build_spacecraft_fsm() ->
    %% Spacecraft flight modes:
    %% States: {Mode, PowerState, ADCSState}
    Init = [{safe_hold, low_power, detumble}],
    Trans = #{
        {safe_hold, low_power, detumble} => [
            {battery_recharged, {standby, nominal_power, detumble}}
        ],
        {standby, nominal_power, detumble} => [
            {detumble_complete, {standby, nominal_power, pointing}},
            {battery_low, {safe_hold, low_power, detumble}}
        ],
        {standby, nominal_power, pointing} => [
            {start_science, {science_ops, nominal_power, pointing}},
            {battery_low, {safe_hold, low_power, detumble}}
        ],
        {science_ops, nominal_power, pointing} => [
            {pass_scheduled, {ground_downlink, high_power, pointing}},
            {battery_low, {safe_hold, low_power, detumble}},
            {fdir_trip, {standby, nominal_power, pointing}}
        ],
        {ground_downlink, high_power, pointing} => [
            {pass_complete, {science_ops, nominal_power, pointing}},
            {battery_low, {safe_hold, low_power, detumble}}
        ]
    },
    new_model(Init, Trans).

%%====================================================================
%% Internal Helpers
%%====================================================================

bfs_explore([], _Visited, _TransMap, Acc) ->
    lists:reverse(Acc);
bfs_explore([St | Rest], Visited, TransMap, Acc) ->
    case sets:is_element(St, Visited) of
        true ->
            bfs_explore(Rest, Visited, TransMap, Acc);
        false ->
            NewVisited = sets:add_element(St, Visited),
            OutTransitions = maps:get(St, TransMap, []),
            NextStates = [Next || {_Act, Next} <- OutTransitions],
            bfs_explore(Rest ++ NextStates, NewVisited, TransMap, [St | Acc])
    end.

find_deadlock([], _Trans) ->
    none;
find_deadlock([St | Rest], Trans) ->
    case maps:get(St, Trans, []) of
        [] -> {deadlock, St};
        _ -> find_deadlock(Rest, Trans)
    end.

search_safety([], _Visited, _Trans, _Pred) ->
    ok;
search_safety([{St, Path} | Rest], Visited, Trans, SafetyPred) ->
    case SafetyPred(St) of
        false ->
            {error, {counterexample, lists:reverse(Path)}};
        true ->
            OutTransitions = maps:get(St, Trans, []),
            NewItems = [
                {Next, [Next | Path]}
                || {_Act, Next} <- OutTransitions, not sets:is_element(Next, Visited)
            ],
            NewVisited = lists:foldl(
                fun({Next, _}, Acc) -> sets:add_element(Next, Acc) end,
                Visited,
                NewItems
            ),
            search_safety(Rest ++ NewItems, NewVisited, Trans, SafetyPred)
    end.

can_reach_target(Start, Trans, TargetPred) ->
    case TargetPred(Start) of
        true -> true;
        false ->
            check_reach_bfs([Start], sets:from_list([Start], [{version, 2}]), Trans, TargetPred)
    end.

check_reach_bfs([], _Visited, _Trans, _TargetPred) ->
    false;
check_reach_bfs([St | Rest], Visited, Trans, TargetPred) ->
    case TargetPred(St) of
        true ->
            true;
        false ->
            Out = [Next || {_Act, Next} <- maps:get(St, Trans, []), not sets:is_element(Next, Visited)],
            NewVisited = lists:foldl(fun(N, V) -> sets:add_element(N, V) end, Visited, Out),
            check_reach_bfs(Rest ++ Out, NewVisited, Trans, TargetPred)
    end.

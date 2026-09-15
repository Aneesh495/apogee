%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Metric Temporal Logic (MTL) Runtime Monitor for Avionics Telemetry.
%%% Implements dense-time temporal operators with quantitative robustness semantics:
%%% - Always / Globally within interval: G_[a, b] phi
%%% - Eventually / Future within interval: F_[a, b] phi
%%% - Propositional predicates: ge, le, eq, and, or, not, implies
%%% Evaluates spacecraft safety properties over discrete-time telemetry streams.
%%% Returns quantitative robustness degree rho:
%%% rho > 0 implies satisfied with margin rho
%%% rho < 0 implies violated with margin |rho|
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_mtl).

-export([
    eval/3,
    eval_robustness/3,
    always/3,
    eventually/3,
    predicate/2,
    conj/2,
    disj/2,
    neg/1,
    implies/2
]).

-type time_point() :: integer() | float().
-type trace() :: [{time_point(), #{atom() => float()}}].

-type mtl_expr() ::
    {pred, atom(), ge | le | eq, float()}
    | {not_expr, mtl_expr()}
    | {and_expr, mtl_expr(), mtl_expr()}
    | {or_expr, mtl_expr(), mtl_expr()}
    | {implies_expr, mtl_expr(), mtl_expr()}
    | {always_expr, float(), float(), mtl_expr()}
    | {eventually_expr, float(), float(), mtl_expr()}.

-export_type([mtl_expr/0, trace/0]).

%%====================================================================
%% DSL Constructors
%%====================================================================

-spec predicate(atom(), {ge | le | eq, float()}) -> mtl_expr().
predicate(Var, {Op, Threshold}) ->
    {pred, Var, Op, float(Threshold)}.

-spec conj(mtl_expr(), mtl_expr()) -> mtl_expr().
conj(Phi1, Phi2) ->
    {and_expr, Phi1, Phi2}.

-spec disj(mtl_expr(), mtl_expr()) -> mtl_expr().
disj(Phi1, Phi2) ->
    {or_expr, Phi1, Phi2}.

-spec neg(mtl_expr()) -> mtl_expr().
neg(Phi) ->
    {not_expr, Phi}.

-spec implies(mtl_expr(), mtl_expr()) -> mtl_expr().
implies(Phi1, Phi2) ->
    {implies_expr, Phi1, Phi2}.

-spec always(float(), float(), mtl_expr()) -> mtl_expr().
always(A, B, Phi) ->
    {always_expr, float(A), float(B), Phi}.

-spec eventually(float(), float(), mtl_expr()) -> mtl_expr().
eventually(A, B, Phi) ->
    {eventually_expr, float(A), float(B), Phi}.

%%====================================================================
%% Evaluation Engine
%%====================================================================

-spec eval(mtl_expr(), trace(), time_point()) -> boolean().
eval(Formula, Trace, CurrentTime) ->
    eval_robustness(Formula, Trace, CurrentTime) >= 0.0.

-spec eval_robustness(mtl_expr(), trace(), time_point()) -> float().
eval_robustness({pred, Var, ge, Threshold}, Trace, Time) ->
    Val = get_val(Var, Trace, Time),
    Val - Threshold;

eval_robustness({pred, Var, le, Threshold}, Trace, Time) ->
    Val = get_val(Var, Trace, Time),
    Threshold - Val;

eval_robustness({pred, Var, eq, Threshold}, Trace, Time) ->
    Val = get_val(Var, Trace, Time),
    -abs(Val - Threshold);

eval_robustness({not_expr, Phi}, Trace, Time) ->
    -eval_robustness(Phi, Trace, Time);

eval_robustness({and_expr, Phi1, Phi2}, Trace, Time) ->
    R1 = eval_robustness(Phi1, Trace, Time),
    R2 = eval_robustness(Phi2, Trace, Time),
    min(R1, R2);

eval_robustness({or_expr, Phi1, Phi2}, Trace, Time) ->
    R1 = eval_robustness(Phi1, Trace, Time),
    R2 = eval_robustness(Phi2, Trace, Time),
    max(R1, R2);

eval_robustness({implies_expr, Phi1, Phi2}, Trace, Time) ->
    % p -> q is equivalent to (not p) or q
    R1 = -eval_robustness(Phi1, Trace, Time),
    R2 = eval_robustness(Phi2, Trace, Time),
    max(R1, R2);

eval_robustness({always_expr, A, B, Phi}, Trace, Time) ->
    TStart = Time + A,
    TEnd = Time + B,
    PointsInInterval = [T || {T, _} <- Trace, T >= TStart, T =< TEnd],
    case PointsInInterval of
        [] ->
            % Default evaluation at bounds
            eval_robustness(Phi, Trace, TStart);
        _ ->
            Robustnesses = [eval_robustness(Phi, Trace, T) || T <- PointsInInterval],
            lists:min(Robustnesses)
    end;

eval_robustness({eventually_expr, A, B, Phi}, Trace, Time) ->
    TStart = Time + A,
    TEnd = Time + B,
    PointsInInterval = [T || {T, _} <- Trace, T >= TStart, T =< TEnd],
    case PointsInInterval of
        [] ->
            eval_robustness(Phi, Trace, TStart);
        _ ->
            Robustnesses = [eval_robustness(Phi, Trace, T) || T <- PointsInInterval],
            lists:max(Robustnesses)
    end.

%%====================================================================
%% Internal Helpers
%%====================================================================

get_val(Var, Trace, Time) ->
    % Find exact match or closest preceding sample
    case lists:keyfind(Time, 1, Trace) of
        {Time, Sample} ->
            maps:get(Var, Sample, 0.0);
        false ->
            Preceding = [S || {T, S} <- Trace, T =< Time],
            case Preceding of
                [] ->
                    case Trace of
                        [{_, FirstSample} | _] -> maps:get(Var, FirstSample, 0.0);
                        [] -> 0.0
                    end;
                _ ->
                    maps:get(Var, lists:last(Preceding), 0.0)
            end
    end.

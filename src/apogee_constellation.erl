%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Walker-Delta Constellation Generator and Inter-Satellite Mesh Network.
%%% Implements canonical Walker-Delta (i: T/P/F) constellation geometry,
%%% inter-satellite crosslink (ISL) line-of-sight visibility with Earth limb
%%% occultation, network graph diameter, and contact plan compilation for CGR.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_constellation).

-include("apogee.hrl").

-export([
    generate_walker_delta/1,
    generate_walker_delta/5,
    satellite_id/2,
    propagate_constellation/2,
    compute_crosslinks/2,
    compute_crosslinks/3,
    generate_contact_plan/5,
    network_metrics/2
]).

%%====================================================================
%% API Functions
%%====================================================================

-spec generate_walker_delta(#walker_config{}) -> [#tle{}].
generate_walker_delta(#walker_config{
    total_sats = T,
    planes = P,
    phasing = F,
    altitude_km = AltKm,
    inclination_deg = IncDeg
}) ->
    generate_walker_delta(T, P, F, AltKm, IncDeg).

-spec generate_walker_delta(pos_integer(), pos_integer(), non_neg_integer(), float(), float()) -> [#tle{}].
generate_walker_delta(T, P, F, AltKm, IncDeg) when T > 0, P > 0, T rem P =:= 0 ->
    SatsPerPlane = T div P,
    A = ?EARTH_RADIUS_KM + float(AltKm),
    MeanMotionRadS = math:sqrt(?EARTH_MU / (A * A * A)),
    IncRad = float(IncDeg) * ?DEG_TO_RAD,
    
    [
        build_sat_tle(PlaneIdx, SatIdx, T, P, F, IncRad, MeanMotionRadS)
        || PlaneIdx <- lists:seq(0, P - 1),
           SatIdx <- lists:seq(0, SatsPerPlane - 1)
    ].

-spec satellite_id(non_neg_integer(), non_neg_integer()) -> binary().
satellite_id(PlaneIdx, SatIdx) ->
    iolist_to_binary(io_lib:format("SAT-P~2..0B-S~2..0B", [PlaneIdx + 1, SatIdx + 1])).

-spec propagate_constellation([#tle{}], float()) -> [{binary(), #orbit_state{}}].
propagate_constellation(TleList, JD) ->
    lists:map(
        fun(#tle{} = Tle) ->
            EpochJD = apogee_tle:epoch_to_jd(Tle#tle.epoch_year, Tle#tle.epoch_day),
            Minutes = (JD - EpochJD) * 1440.0,
            State = apogee_sgp4:propagate(Tle, Minutes),
            {Tle#tle.name, State}
        end,
        TleList
    ).

-spec compute_crosslinks([{binary(), #orbit_state{}}], float()) ->
    [{binary(), binary(), float()}].
compute_crosslinks(SatStates, MaxRangeKm) ->
    compute_crosslinks(SatStates, MaxRangeKm, 100.0).

-spec compute_crosslinks([{binary(), #orbit_state{}}], float(), float()) ->
    [{binary(), binary(), float()}].
compute_crosslinks(SatStates, MaxRangeKm, MinGrazingAltKm) ->
    find_pairs(SatStates, MaxRangeKm, MinGrazingAltKm, []).

-spec generate_contact_plan([#tle{}], float(), float(), float(), float()) ->
    apogee_contact_plan:contact_plan().
generate_contact_plan(TleList, StartJD, EndJD, StepSec, MaxISLKm) ->
    TotalSpanSec = (EndJD - StartJD) * 86400.0,
    NumSteps = max(1, trunc(TotalSpanSec / max(1.0, StepSec))),
    DtDays = StepSec / 86400.0,
    CP0 = apogee_contact_plan:new(),
    build_plan_steps(0, NumSteps, StartJD, DtDays, StepSec, TleList, MaxISLKm, CP0).

-spec network_metrics([binary()], [{binary(), binary(), float()}]) ->
    #{connected := boolean(), avg_degree := float(), diameter := non_neg_integer() | infinity}.
network_metrics(Nodes, Edges) ->
    NodeCount = length(Nodes),
    case NodeCount of
        0 ->
            #{connected => true, avg_degree => 0.0, diameter => 0};
        1 ->
            #{connected => true, avg_degree => 0.0, diameter => 0};
        _ ->
            Adj = build_adjacency(Nodes, Edges),
            Degrees = [length(maps:get(N, Adj, [])) || N <- Nodes],
            AvgDegree = lists:sum(Degrees) / NodeCount,
            
            Distances = [bfs_distances(N, Adj) || N <- Nodes],
            AllReachable = lists:all(
                fun(DistMap) -> maps:size(DistMap) =:= NodeCount end,
                Distances
            ),
            MaxDist = case AllReachable of
                true ->
                    lists:max([lists:max(maps:values(DistMap)) || DistMap <- Distances]);
                false ->
                    infinity
            end,
            #{
                connected => AllReachable,
                avg_degree => AvgDegree,
                diameter => MaxDist
            }
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

build_sat_tle(PlaneIdx, SatIdx, T, P, F, IncRad, MeanMotionRadS) ->
    SatsPerPlane = T div P,
    Raan = (float(PlaneIdx) * 2.0 * ?PI) / float(P),
    MeanAnom = math:fmod(
        (float(SatIdx) * 2.0 * ?PI / float(SatsPerPlane)) +
        (float(PlaneIdx) * float(F) * 2.0 * ?PI / float(T)),
        2.0 * ?PI
    ),
    SatNum = 1000 + (PlaneIdx * 100) + SatIdx + 1,
    Name = satellite_id(PlaneIdx, SatIdx),
    #tle{
        name = Name,
        sat_num = SatNum,
        classification = $U,
        epoch_year = 2026,
        epoch_day = 1.0,
        bstar = 1.0e-5,
        inclination = IncRad,
        raan = Raan,
        eccentricity = 0.0001,
        arg_perigee = 0.0,
        mean_anomaly = MeanAnom,
        mean_motion = MeanMotionRadS,
        rev_num = 1
    }.

find_pairs([], _MaxRange, _MinAlt, Acc) ->
    lists:reverse(Acc);
find_pairs([{IdA, StateA} | Rest], MaxRange, MinAlt, Acc) ->
    NewLinks = lists:filtermap(
        fun({IdB, StateB}) ->
            PosA = StateA#orbit_state.pos,
            PosB = StateB#orbit_state.pos,
            Dist = apogee_vec3:distance(PosA, PosB),
            case Dist =< MaxRange of
                true ->
                    case apogee_los:is_los_visible(PosA, PosB, MinAlt) of
                        true -> {true, {IdA, IdB, Dist}};
                        false -> false
                    end;
                false ->
                    false
            end
        end,
        Rest
    ),
    find_pairs(Rest, MaxRange, MinAlt, NewLinks ++ Acc).

build_plan_steps(StepIdx, TotalSteps, _JD, _DtDays, _StepSec, _TleList, _MaxISLKm, CP)
  when StepIdx >= TotalSteps ->
    CP;
build_plan_steps(StepIdx, TotalSteps, JD, DtDays, StepSec, TleList, MaxISLKm, CP) ->
    States = propagate_constellation(TleList, JD),
    Links = compute_crosslinks(States, MaxISLKm),
    TStart = StepIdx * StepSec,
    TEnd = TStart + StepSec,
    
    CPUpdated = lists:foldl(
        fun({IdA, IdB, DistKm}, AccCP) ->
            DelayS = DistKm / ?SPEED_OF_LIGHT_KM_S,
            %% Add bidirectional contact for ISL
            C1 = AccCP,
            C2 = apogee_contact_plan:add_contact(C1, IdA, IdB, TStart, TEnd, 100000000, DelayS),
            apogee_contact_plan:add_contact(C2, IdB, IdA, TStart, TEnd, 100000000, DelayS)
        end,
        CP,
        Links
    ),
    build_plan_steps(StepIdx + 1, TotalSteps, JD + DtDays, DtDays, StepSec, TleList, MaxISLKm, CPUpdated).

build_adjacency(Nodes, Edges) ->
    Init = maps:from_list([{N, []} || N <- Nodes]),
    lists:foldl(
        fun({A, B, _Dist}, Acc) ->
            NeighborsA = maps:get(A, Acc, []),
            NeighborsB = maps:get(B, Acc, []),
            Acc1 = maps:put(A, lists:usort([B | NeighborsA]), Acc),
            maps:put(B, lists:usort([A | NeighborsB]), Acc1)
        end,
        Init,
        Edges
    ).

bfs_distances(StartNode, Adj) ->
    bfs_dist_queue([{StartNode, 0}], #{StartNode => 0}, Adj).

bfs_dist_queue([], DistMap, _Adj) ->
    DistMap;
bfs_dist_queue([{Curr, Dist} | Rest], DistMap, Adj) ->
    Neighbors = maps:get(Curr, Adj, []),
    Unvisited = [N || N <- Neighbors, not maps:is_key(N, DistMap)],
    NewDist = Dist + 1,
    NewDistMap = lists:foldl(fun(N, M) -> maps:put(N, NewDist, M) end, DistMap, Unvisited),
    NewEntries = [{N, NewDist} || N <- Unvisited],
    bfs_dist_queue(Rest ++ NewEntries, NewDistMap, Adj).

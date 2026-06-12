%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Contact Window Predictor for Satellite-to-Ground and Inter-Satellite Crosslinks.
%%% Employs adaptive time-step scanning and bisection root-finding
%%% to calculate Acquisition of Signal (AOS), Loss of Signal (LOS),
%%% Time of Closest Approach (TCA), and Contact Volume Capacity.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_contact_predictor).

-include("apogee.hrl").

-export([
    predict_ground_passes/5,
    predict_ground_passes/6,
    predict_crosslink_contacts/5,
    pass_to_contact_record/3
]).

-spec predict_ground_passes(#tle{}, #geodetic{}, float(), float(), number()) -> [#ground_pass{}].
predict_ground_passes(Tle, GroundStation, StartJD, EndJD, MinElevationDeg) ->
    predict_ground_passes(Tle, GroundStation, StartJD, EndJD, MinElevationDeg, 30.0). % 30s scan step

-spec predict_ground_passes(#tle{}, #geodetic{}, float(), float(), number(), number()) -> [#ground_pass{}].
predict_ground_passes(#tle{} = Tle, #geodetic{} = Station, StartJD, EndJD, MinElDeg, ScanStepSec) ->
    Model = apogee_sgp4:init_elements(Tle),
    StepDays = float(ScanStepSec) / 86400.0,
    MinEl = float(MinElDeg),
    scan_passes(Model, Station, StartJD, EndJD, StepDays, MinEl, undefined, []).

scan_passes(_Model, _Station, CurrentJD, EndJD, _StepDays, _MinEl, CurrentPass, Acc) when CurrentJD > EndJD ->
    FinalAcc = case CurrentPass of
        undefined -> Acc;
        {AosJD, TcaJD, MaxEl, MinR} ->
            %% Pass still ongoing at simulation horizon
            LosJD = EndJD,
            DurS = (LosJD - AosJD) * 86400.0,
            Pass = #ground_pass{
                aos_jd = AosJD,
                los_jd = LosJD,
                tca_jd = TcaJD,
                duration_s = DurS,
                max_elevation_deg = MaxEl,
                min_range_km = MinR,
                capacity_bytes = round(DurS * 1000000.0 / 8.0) % 1 Mbps nominal
            },
            [Pass | Acc]
    end,
    lists:reverse(FinalAcc);

scan_passes(Model, Station, CurrentJD, EndJD, StepDays, MinEl, CurrentPass, Acc) ->
    StateTeme = apogee_sgp4:propagate(Model, CurrentJD),
    StateEcef = apogee_coords:teme_to_ecef_state(StateTeme, CurrentJD),
    #{elevation_deg := El, range_km := Range} = apogee_los:ground_look_angles(Station, StateEcef#orbit_state.pos),

    IsVisible = El >= MinEl,
    case {CurrentPass, IsVisible} of
        {undefined, true} ->
            %% AOS event detected: refine with bisection
            PrevJD = CurrentJD - StepDays,
            AosJD = bisect_elevation(Model, Station, PrevJD, CurrentJD, MinEl, 0.5 / 86400.0), % 0.5s tolerance
            scan_passes(Model, Station, CurrentJD + StepDays, EndJD, StepDays, MinEl, {AosJD, CurrentJD, El, Range}, Acc);

        {{AosJD, TcaJD, MaxEl, MinR}, true} ->
            %% Update TCA
            NewMaxEl = max(MaxEl, El),
            {NewTcaJD, NewMinR} = if
                El > MaxEl -> {CurrentJD, Range};
                true -> {TcaJD, MinR}
            end,
            scan_passes(Model, Station, CurrentJD + StepDays, EndJD, StepDays, MinEl, {AosJD, NewTcaJD, NewMaxEl, NewMinR}, Acc);

        {{AosJD, TcaJD, MaxEl, MinR}, false} ->
            %% LOS event detected: refine with bisection
            PrevJD = CurrentJD - StepDays,
            LosJD = bisect_elevation(Model, Station, PrevJD, CurrentJD, MinEl, 0.5 / 86400.0),
            DurS = (LosJD - AosJD) * 86400.0,
            Pass = #ground_pass{
                aos_jd = AosJD,
                los_jd = LosJD,
                tca_jd = TcaJD,
                duration_s = DurS,
                max_elevation_deg = MaxEl,
                min_range_km = MinR,
                capacity_bytes = round(DurS * 1000000.0 / 8.0) % 1 Mbps
            },
            scan_passes(Model, Station, CurrentJD + StepDays, EndJD, StepDays, MinEl, undefined, [Pass | Acc]);

        {undefined, false} ->
            scan_passes(Model, Station, CurrentJD + StepDays, EndJD, StepDays, MinEl, undefined, Acc)
    end.

bisect_elevation(Model, Station, JD1, JD2, TargetEl, Tol) ->
    bisect_elevation_loop(Model, Station, JD1, JD2, TargetEl, Tol, 0).

bisect_elevation_loop(_Model, _Station, JD1, JD2, _TargetEl, _Tol, 20) ->
    (JD1 + JD2) * 0.5;
bisect_elevation_loop(Model, Station, JD1, JD2, TargetEl, Tol, Iter) ->
    MidJD = (JD1 + JD2) * 0.5,
    if
        (JD2 - JD1) < Tol ->
            MidJD;
        true ->
            ElMid = get_elevation(Model, Station, MidJD),
            El1 = get_elevation(Model, Station, JD1),
            case (ElMid >= TargetEl) =:= (El1 >= TargetEl) of
                true ->
                    bisect_elevation_loop(Model, Station, MidJD, JD2, TargetEl, Tol, Iter + 1);
                false ->
                    bisect_elevation_loop(Model, Station, JD1, MidJD, TargetEl, Tol, Iter + 1)
            end
    end.

get_elevation(Model, Station, JD) ->
    StateTeme = apogee_sgp4:propagate(Model, JD),
    PosEcef = apogee_coords:teme_to_ecef(StateTeme#orbit_state.pos, JD),
    #{elevation_deg := El} = apogee_los:ground_look_angles(Station, PosEcef),
    El.

-spec predict_crosslink_contacts(#tle{}, #tle{}, float(), float(), number()) -> [#contact{}].
predict_crosslink_contacts(Tle1, Tle2, StartJD, EndJD, MinGrazingAltKm) ->
    Model1 = apogee_sgp4:init_elements(Tle1),
    Model2 = apogee_sgp4:init_elements(Tle2),
    StepDays = 30.0 / 86400.0, % 30s steps
    scan_crosslinks(Model1, Model2, StartJD, EndJD, StepDays, float(MinGrazingAltKm), undefined, []).

scan_crosslinks(_M1, _M2, CurrentJD, EndJD, _StepDays, _MinAlt, CurrentContact, Acc) when CurrentJD > EndJD ->
    FinalAcc = case CurrentContact of
        undefined -> Acc;
        StartContactJD ->
            C = #contact{
                id = <<"ISL-HORIZON">>,
                start_time = StartContactJD,
                end_time = EndJD,
                data_rate_bps = 10000000 % 10 Mbps optical crosslink
            },
            [C | Acc]
    end,
    lists:reverse(FinalAcc);

scan_crosslinks(M1, M2, CurrentJD, EndJD, StepDays, MinAlt, CurrentContact, Acc) ->
    S1 = apogee_sgp4:propagate(M1, CurrentJD),
    S2 = apogee_sgp4:propagate(M2, CurrentJD),
    P1 = apogee_coords:teme_to_ecef(S1#orbit_state.pos, CurrentJD),
    P2 = apogee_coords:teme_to_ecef(S2#orbit_state.pos, CurrentJD),
    IsVisible = apogee_los:is_los_visible(P1, P2, MinAlt),

    case {CurrentContact, IsVisible} of
        {undefined, true} ->
            scan_crosslinks(M1, M2, CurrentJD + StepDays, EndJD, StepDays, MinAlt, CurrentJD, Acc);
        {StartJD, false} ->
            C = #contact{
                id = <<"ISL">>,
                start_time = StartJD,
                end_time = CurrentJD,
                data_rate_bps = 10000000,
                range_delay_s = apogee_vec3:distance(P1, P2) / ?SPEED_OF_LIGHT_KM_S
            },
            scan_crosslinks(M1, M2, CurrentJD + StepDays, EndJD, StepDays, MinAlt, undefined, [C | Acc]);
        _ ->
            scan_crosslinks(M1, M2, CurrentJD + StepDays, EndJD, StepDays, MinAlt, CurrentContact, Acc)
    end.

-spec pass_to_contact_record(#ground_pass{}, binary(), binary()) -> #contact{}.
pass_to_contact_record(#ground_pass{} = Pass, FromNode, ToNode) ->
    #contact{
        id = <<FromNode/binary, "-", ToNode/binary, "-", (integer_to_binary(round(Pass#ground_pass.aos_jd * 1000)))/binary>>,
        from_node = FromNode,
        to_node = ToNode,
        start_time = Pass#ground_pass.aos_jd,
        end_time = Pass#ground_pass.los_jd,
        data_rate_bps = 1000000,
        range_delay_s = Pass#ground_pass.min_range_km / ?SPEED_OF_LIGHT_KM_S,
        confidence = 1.0,
        total_capacity_bytes = Pass#ground_pass.capacity_bytes,
        reserved_bytes = 0
    }.

%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Terrestrial Ground Station Network and Pass Scheduler.
%%% Models tracking telemetry and telecommand ground stations, computes
%%% horizon passes (AOS/LOS/TCA), slant range, azimuth/elevation, Doppler shift,
%%% and buffers downlinked bundle/telemetry streams.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_ground_station).

-behaviour(gen_server).

-include("apogee.hrl").

%% API
-export([
    known_stations/0,
    new_station/3,
    new_station/4,
    ground_look_angles/2,
    is_satellite_in_view/3,
    predict_passes/5,
    start_link/1,
    stop/1,
    get_station/1,
    track/3,
    ingest_downlink/2,
    get_downlinked_data/1,
    get_metrics/1
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

-record(state, {
    station :: #ground_station{},
    downlink_buffer = [] :: [binary()],
    total_bytes_received = 0 :: non_neg_integer(),
    active_pass = false :: boolean(),
    completed_passes = 0 :: non_neg_integer()
}).

%%====================================================================
%% API Functions
%%====================================================================

-spec known_stations() -> [#ground_station{}].
known_stations() ->
    [
        #ground_station{
            id = <<"SGS-Svalbard">>,
            name = <<"Svalbard Satellite Station (SpiSat)">>,
            location = #geodetic{lat = 78.23, lon = 15.39, alt = 0.50},
            min_elevation_deg = 5.0,
            dish_diameter_m = 13.0,
            tx_power_dbw = 30.0,
            rf_band = s_band,
            max_bitrate_bps = 100000000.0
        },
        #ground_station{
            id = <<"KRU-Kourou">>,
            name = <<"Kourou Space Centre Tracking Station">>,
            location = #geodetic{lat = 5.25, lon = -52.81, alt = 0.05},
            min_elevation_deg = 7.0,
            dish_diameter_m = 15.0,
            tx_power_dbw = 33.0,
            rf_band = ka_band,
            max_bitrate_bps = 300000000.0
        },
        #ground_station{
            id = <<"WSS-WhiteSands">>,
            name = <<"White Sands Complex Ground Terminal">>,
            location = #geodetic{lat = 32.50, lon = -106.61, alt = 1.45},
            min_elevation_deg = 10.0,
            dish_diameter_m = 18.0,
            tx_power_dbw = 35.0,
            rf_band = ka_band,
            max_bitrate_bps = 600000000.0
        },
        #ground_station{
            id = <<"MCM-McMurdo">>,
            name = <<"McMurdo Station Antarctica Ground Terminal">>,
            location = #geodetic{lat = -77.85, lon = 166.67, alt = 0.10},
            min_elevation_deg = 5.0,
            dish_diameter_m = 10.0,
            tx_power_dbw = 28.0,
            rf_band = s_band,
            max_bitrate_bps = 50000000.0
        }
    ].

-spec new_station(binary(), #geodetic{}, float()) -> #ground_station{}.
new_station(Id, #geodetic{} = Location, MinElevationDeg) ->
    #ground_station{
        id = Id,
        name = Id,
        location = Location,
        min_elevation_deg = float(MinElevationDeg)
    }.

-spec new_station(binary(), #geodetic{}, float(), float()) -> #ground_station{}.
new_station(Id, #geodetic{} = Location, MinElevationDeg, MaxBitrateBps) ->
    #ground_station{
        id = Id,
        name = Id,
        location = Location,
        min_elevation_deg = float(MinElevationDeg),
        max_bitrate_bps = float(MaxBitrateBps)
    }.

-spec ground_look_angles(#ground_station{}, #vector3{}) ->
    #{azimuth_deg := float(), elevation_deg := float(), range_km := float()}.
ground_look_angles(#ground_station{location = Geo}, #vector3{} = TargetEcef) ->
    apogee_los:ground_look_angles(Geo, TargetEcef).

-spec is_satellite_in_view(#ground_station{}, #vector3{}, float()) -> boolean().
is_satellite_in_view(#ground_station{min_elevation_deg = MinEl} = St, #vector3{} = TargetEcef, _JD) ->
    #{elevation_deg := El} = ground_look_angles(St, TargetEcef),
    El >= MinEl.

-spec predict_passes(#ground_station{}, #tle{}, float(), float(), float()) -> [#ground_pass{}].
predict_passes(#ground_station{} = St, #tle{} = Tle, StartJD, EndJD, StepSec) ->
    TotalSpanSec = (EndJD - StartJD) * 86400.0,
    NumSteps = max(1, trunc(TotalSpanSec / max(1.0, StepSec))),
    DtDays = (StepSec / 86400.0),
    sample_trajectory(0, NumSteps, StartJD, DtDays, St, Tle, false, undefined, []).

-spec start_link(#ground_station{}) -> {ok, pid()} | {error, term()}.
start_link(#ground_station{} = Station) ->
    gen_server:start_link(?MODULE, [Station], []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-spec get_station(pid()) -> #ground_station{}.
get_station(Pid) ->
    gen_server:call(Pid, get_station).

-spec track(pid(), #vector3{}, float()) -> {in_view, map()} | not_in_view.
track(Pid, #vector3{} = SatEcef, JD) ->
    gen_server:call(Pid, {track, SatEcef, JD}).

-spec ingest_downlink(pid(), binary()) -> ok.
ingest_downlink(Pid, Data) when is_binary(Data) ->
    gen_server:call(Pid, {ingest_downlink, Data}).

-spec get_downlinked_data(pid()) -> [binary()].
get_downlinked_data(Pid) ->
    gen_server:call(Pid, get_downlinked_data).

-spec get_metrics(pid()) -> map().
get_metrics(Pid) ->
    gen_server:call(Pid, get_metrics).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([#ground_station{} = Station]) ->
    {ok, #state{
        station = Station,
        downlink_buffer = [],
        total_bytes_received = 0,
        active_pass = false,
        completed_passes = 0
    }}.

handle_call(get_station, _From, State) ->
    {reply, State#state.station, State};

handle_call({track, SatEcef, _JD}, _From, State) ->
    St = State#state.station,
    Angles = #{elevation_deg := El} = ground_look_angles(St, SatEcef),
    InView = El >= St#ground_station.min_elevation_deg,
    NewActive = InView,
    NewCompleted = case {State#state.active_pass, InView} of
        {true, false} -> State#state.completed_passes + 1;
        _ -> State#state.completed_passes
    end,
    Response = case InView of
        true -> {in_view, Angles};
        false -> not_in_view
    end,
    {reply, Response, State#state{active_pass = NewActive, completed_passes = NewCompleted}};

handle_call({ingest_downlink, Data}, _From, State) ->
    ByteSize = byte_size(Data),
    NewBuffer = [Data | State#state.downlink_buffer],
    NewTotal = State#state.total_bytes_received + ByteSize,
    {reply, ok, State#state{downlink_buffer = NewBuffer, total_bytes_received = NewTotal}};

handle_call(get_downlinked_data, _From, State) ->
    {reply, lists:reverse(State#state.downlink_buffer), State};

handle_call(get_metrics, _From, State) ->
    Metrics = #{
        downlink_bytes => State#state.total_bytes_received,
        packet_count => length(State#state.downlink_buffer),
        completed_passes => State#state.completed_passes,
        is_tracking_active => State#state.active_pass
    },
    {reply, Metrics, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal Pass Predictor
%%====================================================================

sample_trajectory(StepIdx, TotalSteps, _CurrentJD, _DtDays, _St, _Tle, _InPass, _CurrentPass, PassesAcc)
  when StepIdx > TotalSteps ->
    lists:reverse(PassesAcc);

sample_trajectory(StepIdx, TotalSteps, CurrentJD, DtDays, St, Tle, InPass, CurrentPass, PassesAcc) ->
    EpochJD = apogee_tle:epoch_to_jd(Tle#tle.epoch_year, Tle#tle.epoch_day),
    MinutesSinceEpoch = (CurrentJD - EpochJD) * 1440.0,
    SatStateTeme = apogee_sgp4:propagate(Tle, MinutesSinceEpoch),
    SatPosEcef = apogee_coords:teme_to_ecef(SatStateTeme#orbit_state.pos, CurrentJD),
    #{elevation_deg := El, range_km := Range} = ground_look_angles(St, SatPosEcef),
    AboveMask = El >= St#ground_station.min_elevation_deg,

    case {InPass, AboveMask} of
        {false, false} ->
            %% Out of pass, still out of pass
            sample_trajectory(StepIdx + 1, TotalSteps, CurrentJD + DtDays, DtDays, St, Tle, false, undefined, PassesAcc);

        {false, true} ->
            %% Pass starts (AOS)
            Pass = #ground_pass{
                station_id = St#ground_station.id,
                sat_id = integer_to_binary(Tle#tle.sat_num),
                aos_jd = CurrentJD,
                los_jd = CurrentJD,
                tca_jd = CurrentJD,
                duration_s = 0.0,
                max_elevation_deg = El,
                min_range_km = Range,
                capacity_bytes = 0
            },
            sample_trajectory(StepIdx + 1, TotalSteps, CurrentJD + DtDays, DtDays, St, Tle, true, Pass, PassesAcc);

        {true, true} ->
            %% Continuing pass: update TCA, max elevation, min range
            OldMaxEl = CurrentPass#ground_pass.max_elevation_deg,
            OldMinRange = CurrentPass#ground_pass.min_range_km,
            NewMaxEl = max(OldMaxEl, El),
            NewMinRange = min(OldMinRange, Range),
            NewTca = case El > OldMaxEl of
                true -> CurrentJD;
                false -> CurrentPass#ground_pass.tca_jd
            end,
            UpdatedPass = CurrentPass#ground_pass{
                max_elevation_deg = NewMaxEl,
                min_range_km = NewMinRange,
                tca_jd = NewTca
            },
            sample_trajectory(StepIdx + 1, TotalSteps, CurrentJD + DtDays, DtDays, St, Tle, true, UpdatedPass, PassesAcc);

        {true, false} ->
            %% Pass ends (LOS)
            DurationSec = (CurrentJD - CurrentPass#ground_pass.aos_jd) * 86400.0,
            Capacity = trunc((DurationSec * St#ground_station.max_bitrate_bps) / 8.0),
            CompletedPass = CurrentPass#ground_pass{
                los_jd = CurrentJD,
                duration_s = DurationSec,
                capacity_bytes = Capacity
            },
            sample_trajectory(StepIdx + 1, TotalSteps, CurrentJD + DtDays, DtDays, St, Tle, false, undefined, [CompletedPass | PassesAcc])
    end.

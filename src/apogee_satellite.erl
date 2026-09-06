%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Top-Level Autonomous Satellite Process and Subsystem Coordinator.
%%% Manages integrated simulation and avionics state machine:
%%% - SGP4 orbital propagation
%%% - EPS solar generation, battery charge, and load shedding
%%% - 4-node thermal balance and radiative cooling
%%% - ADCS attitude dynamics, pointing, and reaction wheel desaturation
%%% - Mode transitions: safe_hold, detumble, science_ops, downlink
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_satellite).

-behaviour(gen_server).

-include("apogee.hrl").

%% API
-export([
    start_link/2,
    start_link/3,
    step/2,
    get_telemetry/1,
    set_mode/2,
    send_telecommand/2,
    stop/1
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
    sat_id :: binary(),
    tle :: #tle{},
    current_jd = 0.0 :: float(),
    orbit_state = #orbit_state{} :: #orbit_state{},
    eps = #eps_state{} :: #eps_state{},
    thermal = #thermal_state{} :: #thermal_state{},
    adcs = #adcs_state{} :: #adcs_state{},
    mode = science_ops :: safe_hold | detumble | science_ops | ground_downlink,
    total_steps = 0 :: non_neg_integer()
}).

%%====================================================================
%% API Functions
%%====================================================================

start_link(SatId, #tle{} = TLE) ->
    start_link(SatId, TLE, []).

start_link(SatId, #tle{} = TLE, Opts) ->
    gen_server:start_link(?MODULE, {SatId, TLE, Opts}, []).

-spec step(pid(), float()) -> {ok, map()}.
step(Server, DeltaSec) ->
    gen_server:call(Server, {step, float(DeltaSec)}).

-spec get_telemetry(pid()) -> map().
get_telemetry(Server) ->
    gen_server:call(Server, get_telemetry).

-spec set_mode(pid(), atom()) -> ok.
set_mode(Server, NewMode) ->
    gen_server:call(Server, {set_mode, NewMode}).

-spec send_telecommand(pid(), #tc_frame{}) -> ok | {error, term()}.
send_telecommand(Server, #tc_frame{} = TC) ->
    gen_server:call(Server, {send_telecommand, TC}).

stop(Server) ->
    gen_server:stop(Server).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({SatId, TLE, Opts}) ->
    SatIdBin = to_bin(SatId),
    StartJD = proplists:get_value(start_jd, Opts, 2451545.0),
    Orbit0 = apogee_sgp4:propagate(TLE, StartJD),
    
    EPS0 = apogee_eps:new(proplists:get_value(eps, Opts, [])),
    Thermal0 = apogee_thermal:new(),
    ADCS0 = apogee_adcs:new(proplists:get_value(adcs, Opts, [])),

    State = #state{
        sat_id = SatIdBin,
        tle = TLE,
        current_jd = StartJD,
        orbit_state = Orbit0,
        eps = EPS0,
        thermal = Thermal0,
        adcs = ADCS0,
        mode = science_ops,
        total_steps = 0
    },
    {ok, State}.

handle_call({step, DeltaSec}, _From, State) ->
    % 1. Advance Julian Date
    DeltaDays = DeltaSec / 86400.0,
    NewJD = State#state.current_jd + DeltaDays,

    % 2. Propagate orbit
    NewOrbit = apogee_sgp4:propagate(State#state.tle, NewJD),

    % 3. Sun position and solar power
    SunPos = apogee_eps:sun_position_eci(NewJD),
    AttMatrix = apogee_quat:to_matrix(State#state.adcs#adcs_state.attitude),
    SolarPowerW = apogee_eps:solar_power_generated(State#state.eps, NewOrbit#orbit_state.pos, SunPos, AttMatrix),

    % 4. Power budget step
    ReqLoadW = case State#state.mode of
        science_ops -> 35.0; % Payload + avionics + radio
        ground_downlink -> 45.0; % High-power transmitter active
        detumble -> 15.0;
        safe_hold -> 8.0
    end,
    {NewEPS, _ActualLoad} = apogee_eps:step_power(State#state.eps, SolarPowerW, ReqLoadW, DeltaSec),

    % 5. Thermal balance step
    HeatMap = #{
        avionics => 12.0,
        payload => case State#state.mode of science_ops -> 15.0; _ -> 1.0 end,
        battery => 1.5
    },
    NewThermal = apogee_thermal:step_thermal(State#state.thermal, SolarPowerW, HeatMap, DeltaSec),

    % 6. ADCS step (reaction wheel torque / pointing)
    ZeroTorque = #vector3{x = 0.0, y = 0.0, z = 0.0},
    NewADCS = apogee_adcs:step_attitude(State#state.adcs, ZeroTorque, ZeroTorque, DeltaSec),

    % 7. Autonomous mode fallback if battery is critical
    EffectiveMode = case apogee_eps:power_mode(NewEPS) of
        critical -> safe_hold;
        _ -> State#state.mode
    end,

    NewState = State#state{
        current_jd = NewJD,
        orbit_state = NewOrbit,
        eps = NewEPS,
        thermal = NewThermal,
        adcs = NewADCS,
        mode = EffectiveMode,
        total_steps = State#state.total_steps + 1
    },

    Telem = format_telemetry(NewState),
    {reply, {ok, Telem}, NewState};

handle_call(get_telemetry, _From, State) ->
    {reply, format_telemetry(State), State};

handle_call({set_mode, NewMode}, _From, State) ->
    {reply, ok, State#state{mode = NewMode}};

handle_call({send_telecommand, #tc_frame{}}, _From, State) ->
    {reply, ok, State};

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
%% Internal Helpers
%%====================================================================

format_telemetry(#state{} = S) ->
    {TSA_C, TPL_C, TAV_C, TBT_C} = apogee_thermal:to_celsius(S#state.thermal),
    #{
        sat_id => S#state.sat_id,
        current_jd => S#state.current_jd,
        pos_km => S#state.orbit_state#orbit_state.pos,
        vel_km_s => S#state.orbit_state#orbit_state.vel,
        battery_soc => apogee_eps:battery_soc(S#state.eps),
        bus_voltage => apogee_eps:bus_voltage(S#state.eps),
        power_mode => apogee_eps:power_mode(S#state.eps),
        temp_c => #{solar_array => TSA_C, payload => TPL_C, avionics => TAV_C, battery => TBT_C},
        attitude => S#state.adcs#adcs_state.attitude,
        angular_velocity => S#state.adcs#adcs_state.angular_velocity,
        mode => S#state.mode,
        total_steps => S#state.total_steps
    }.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).

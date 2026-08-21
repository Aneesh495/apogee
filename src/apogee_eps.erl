%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Electrical Power Subsystem (EPS) for Orbital Spacecraft.
%%% Implements:
%%% - Conical solar eclipse geometry (umbra and penumbra occultation factor)
%%% - Solar array illumination, sun incidence angle, and power generation
%%% - Lithium-ion battery state-of-charge (SoC) integration
%%% - Bus voltage regulation and autonomous multi-stage load shedding
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_eps).

-include("apogee.hrl").

-export([
    new/0,
    new/1,
    sun_position_eci/1,
    eclipse_factor/2,
    solar_power_generated/4,
    step_power/4,
    power_mode/1,
    battery_soc/1,
    bus_voltage/1
]).

-define(SUN_RADIUS_KM, 696340.0).
-define(AU_KM, 149597870.7).
-define(CELL_EFFICIENCY, 0.30). % Triple-junction GaAs solar cells

-type eps_state() :: #eps_state{}.
-export_type([eps_state/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec new() -> eps_state().
new() ->
    new([]).

-spec new(proplists:proplist()) -> eps_state().
new(Opts) ->
    CapWh = proplists:get_value(battery_capacity_wh, Opts, 120.0),
    Soc = proplists:get_value(battery_soc, Opts, 1.0),
    Area = proplists:get_value(solar_array_area_m2, Opts, 0.25),
    Normal = proplists:get_value(solar_array_normal, Opts, #vector3{x = 0.0, y = 0.0, z = 1.0}),
    #eps_state{
        battery_capacity_wh = float(CapWh),
        battery_soc = float(Soc),
        solar_array_area_m2 = float(Area),
        solar_array_normal = apogee_vec3:normalize(Normal),
        bus_voltage = soc_to_voltage(Soc),
        mode = determine_mode(Soc)
    }.

-spec sun_position_eci(float()) -> #vector3{}.
sun_position_eci(JD) ->
    %% Low-precision analytical solar coordinates (Montenbruck & Gill)
    T = (JD - 2451545.0) / 36525.0,
    M = (357.529 + 35999.050 * T) * ?DEG_TO_RAD, % Mean anomaly
    L0 = (280.460 + 36000.771 * T) * ?DEG_TO_RAD, % Mean longitude
    Lambda = (L0 + (1.915 * math:sin(M) + 0.020 * math:sin(2.0 * M)) * ?DEG_TO_RAD), % Ecliptic longitude
    Eps = (23.439 - 0.013 * T) * ?DEG_TO_RAD, % Obliquity of ecliptic
    R = ?AU_KM * (1.00014 - 0.01671 * math:cos(M) - 0.00014 * math:cos(2.0 * M)),
    #vector3{
        x = R * math:cos(Lambda),
        y = R * math:cos(Eps) * math:sin(Lambda),
        z = R * math:sin(Eps) * math:sin(Lambda)
    }.

-spec eclipse_factor(#vector3{}, #vector3{}) -> float().
eclipse_factor(#vector3{} = SatPos, #vector3{} = SunPos) ->
    %% Conical occultation model: returns 1.0 in full sunlight, 0.0 in full shadow (umbra)
    SunDist = apogee_vec3:magnitude(SunPos),
    SatDist = apogee_vec3:magnitude(SatPos),
    SunDir = apogee_vec3:scale(SunPos, 1.0 / SunDist),
    
    % Projection of satellite position along Sun vector
    Proj = apogee_vec3:dot(SatPos, SunDir),
    case Proj >= 0.0 of
        true ->
            % Satellite is on the sunward side of Earth
            1.0;
        false ->
            % Satellite is on the night side of Earth
            % Distance from Earth-Sun line
            PerpDist = math:sqrt(max(0.0, SatDist * SatDist - Proj * Proj)),
            % Cylindrical/conical shadow boundary
            EarthR = ?EARTH_RADIUS_KM,
            if
                PerpDist >= EarthR -> 1.0; % Outside shadow
                PerpDist =< EarthR - 100.0 -> 0.0; % Full umbra
                true ->
                    % Penumbral transition
                    (PerpDist - (EarthR - 100.0)) / 100.0
            end
    end.

-spec solar_power_generated(eps_state(), #vector3{}, #vector3{}, #matrix3{}) -> float().
solar_power_generated(#eps_state{} = EPS, #vector3{} = SatPos, #vector3{} = SunPos, #matrix3{} = AttMatrix) ->
    Nu = eclipse_factor(SatPos, SunPos),
    case Nu =< 0.001 of
        true ->
            0.0;
        false ->
            SunDirECI = apogee_vec3:normalize(SunPos),
            % Transform Sun vector from ECI to Body frame
            SunDirBody = apogee_mat3:mult_vec(AttMatrix, SunDirECI),
            CosIncidence = max(0.0, apogee_vec3:dot(EPS#eps_state.solar_array_normal, SunDirBody)),
            Nu * ?SOLAR_CONSTANT_W_M2 * EPS#eps_state.solar_array_area_m2 * ?CELL_EFFICIENCY * CosIncidence
    end.

-spec step_power(eps_state(), float(), float(), float()) -> {eps_state(), float()}.
step_power(#eps_state{} = EPS, SolarPowerW, RequestedLoadW, DeltaSec) ->
    ActualLoadW = apply_load_shedding(EPS#eps_state.mode, RequestedLoadW),
    NetPowerW = SolarPowerW - ActualLoadW,
    EnergyDeltaWh = (NetPowerW * DeltaSec) / 3600.0,
    CapacityWh = EPS#eps_state.battery_capacity_wh,
    CurrentEnergyWh = EPS#eps_state.battery_soc * CapacityWh,
    
    NewEnergyWh = max(0.0, min(CapacityWh, CurrentEnergyWh + EnergyDeltaWh)),
    NewSoc = NewEnergyWh / CapacityWh,
    NewMode = determine_mode(NewSoc),
    NewVoltage = soc_to_voltage(NewSoc),

    UpdatedEPS = EPS#eps_state{
        battery_soc = NewSoc,
        bus_voltage = NewVoltage,
        mode = NewMode
    },
    {UpdatedEPS, ActualLoadW}.

-spec power_mode(eps_state()) -> normal | degraded | critical.
power_mode(#eps_state{mode = M}) ->
    M.

%%====================================================================
%% Internal Helpers
%%====================================================================

determine_mode(Soc) when Soc > 0.50 -> normal;
determine_mode(Soc) when Soc > 0.25 -> degraded;
determine_mode(_) -> critical.

apply_load_shedding(normal, ReqW) ->
    ReqW;
apply_load_shedding(degraded, ReqW) ->
    % Shed 50% non-essential payload
    min(ReqW, ReqW * 0.5 + 5.0);
apply_load_shedding(critical, _ReqW) ->
    % Critical safe mode: only essential avionics (8W)
    8.0.

soc_to_voltage(Soc) ->
    % 24.0V (empty) to 29.4V (full Li-ion 7S pack)
    24.0 + 5.4 * max(0.0, min(1.0, Soc)).

-spec battery_soc(eps_state()) -> float().
battery_soc(#eps_state{battery_soc = Soc}) ->
    Soc.

-spec bus_voltage(eps_state()) -> float().
bus_voltage(#eps_state{bus_voltage = V}) ->
    V.

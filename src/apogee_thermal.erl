%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc 4-Node Lumped Thermal Capacitance Radiative Equilibrium Model.
%%% Solves coupled thermal energy balance for:
%%% 1. Solar Array (direct solar flux, albedo, and deep-space radiative cooling)
%%% 2. Payload Instrument (Earth IR flux and internal sensor dissipation)
%%% 3. Avionics / Flight Computer (OBC processor dissipation and conductive coupling)
%%% 4. Battery Pack (Joule heating and strict flight qualification thermal limits)
%%% Differential Equation:
%%% C_i * (dT_i/dt) = Q_ext,i + Q_int,i + sum_j G_ij*(T_j - T_i) - eps_i * sigma * A_i * (T_i^4 - T_space^4)
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_thermal).

-include("apogee.hrl").

-export([
    new/0,
    new/4,
    step_thermal/4,
    to_celsius/1,
    is_within_limits/1,
    thermal_derivatives/3
]).

%% Physical parameters for 4-node model
%% Thermal capacitances C = m * cp (J / K)
-define(CAP_SOLAR_ARRAY, 250.0).  % Thin composite substrate
-define(CAP_PAYLOAD,     600.0).  % Optical payload housing
-define(CAP_AVIONICS,    400.0).  % Aluminum electronics enclosure
-define(CAP_BATTERY,     500.0).  % High thermal mass Li-ion pack

%% Conductive couplings G_ij (W / K)
-define(G_SA_AVIONICS,   0.5).    % Harness & standoff conduction
-define(G_AV_PAYLOAD,    1.2).    % Structural frame conduction
-define(G_AV_BATTERY,    1.5).    % Chassis mounting conduction
-define(G_PL_BATTERY,    0.3).    % Radiation / minimal conduction

%% Radiative properties: Area (m^2) * Emissivity
-define(EPS_A_SOLAR_ARRAY, 0.25 * 0.85). % Radiating front and back
-define(EPS_A_PAYLOAD,     0.10 * 0.80).
-define(EPS_A_AVIONICS,    0.05 * 0.20). % Multilayer insulation (MLI)
-define(EPS_A_BATTERY,     0.02 * 0.10). % Heavily insulated core

-type thermal_state() :: #thermal_state{}.
-export_type([thermal_state/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec new() -> thermal_state().
new() ->
    #thermal_state{
        temp_solar_array_k = 293.15,
        temp_payload_k = 293.15,
        temp_avionics_k = 293.15,
        temp_battery_k = 293.15
    }.

-spec new(number(), number(), number(), number()) -> thermal_state().
new(TSolarK, TPayloadK, TAvionicsK, TBatteryK) ->
    #thermal_state{
        temp_solar_array_k = float(TSolarK),
        temp_payload_k = float(TPayloadK),
        temp_avionics_k = float(TAvionicsK),
        temp_battery_k = float(TBatteryK)
    }.

-spec step_thermal(thermal_state(), float(), #{atom() => float()}, float()) -> thermal_state().
step_thermal(#thermal_state{} = S, SolarFluxW, InternalHeatMap, DeltaSec) ->
    %% 4th-order Runge-Kutta numerical integration
    {K1_SA, K1_PL, K1_AV, K1_BT} = thermal_derivatives(S, SolarFluxW, InternalHeatMap),

    S_K2 = S#thermal_state{
        temp_solar_array_k = S#thermal_state.temp_solar_array_k + 0.5 * DeltaSec * K1_SA,
        temp_payload_k     = S#thermal_state.temp_payload_k     + 0.5 * DeltaSec * K1_PL,
        temp_avionics_k    = S#thermal_state.temp_avionics_k    + 0.5 * DeltaSec * K1_AV,
        temp_battery_k     = S#thermal_state.temp_battery_k     + 0.5 * DeltaSec * K1_BT
    },
    {K2_SA, K2_PL, K2_AV, K2_BT} = thermal_derivatives(S_K2, SolarFluxW, InternalHeatMap),

    S_K3 = S#thermal_state{
        temp_solar_array_k = S#thermal_state.temp_solar_array_k + 0.5 * DeltaSec * K2_SA,
        temp_payload_k     = S#thermal_state.temp_payload_k     + 0.5 * DeltaSec * K2_PL,
        temp_avionics_k    = S#thermal_state.temp_avionics_k    + 0.5 * DeltaSec * K2_AV,
        temp_battery_k     = S#thermal_state.temp_battery_k     + 0.5 * DeltaSec * K2_BT
    },
    {K3_SA, K3_PL, K3_AV, K3_BT} = thermal_derivatives(S_K3, SolarFluxW, InternalHeatMap),

    S_K4 = S#thermal_state{
        temp_solar_array_k = S#thermal_state.temp_solar_array_k + DeltaSec * K3_SA,
        temp_payload_k     = S#thermal_state.temp_payload_k     + DeltaSec * K3_PL,
        temp_avionics_k    = S#thermal_state.temp_avionics_k    + DeltaSec * K3_AV,
        temp_battery_k     = S#thermal_state.temp_battery_k     + DeltaSec * K3_BT
    },
    {K4_SA, K4_PL, K4_AV, K4_BT} = thermal_derivatives(S_K4, SolarFluxW, InternalHeatMap),

    NewSA = S#thermal_state.temp_solar_array_k + (DeltaSec / 6.0) * (K1_SA + 2.0 * K2_SA + 2.0 * K3_SA + K4_SA),
    NewPL = S#thermal_state.temp_payload_k     + (DeltaSec / 6.0) * (K1_PL + 2.0 * K2_PL + 2.0 * K3_PL + K4_PL),
    NewAV = S#thermal_state.temp_avionics_k    + (DeltaSec / 6.0) * (K1_AV + 2.0 * K2_AV + 2.0 * K3_AV + K4_AV),
    NewBT = S#thermal_state.temp_battery_k     + (DeltaSec / 6.0) * (K1_BT + 2.0 * K2_BT + 2.0 * K3_BT + K4_BT),

    S#thermal_state{
        temp_solar_array_k = max(2.7, NewSA),
        temp_payload_k     = max(2.7, NewPL),
        temp_avionics_k    = max(2.7, NewAV),
        temp_battery_k     = max(2.7, NewBT)
    }.

-spec to_celsius(thermal_state()) -> {float(), float(), float(), float()}.
to_celsius(#thermal_state{} = S) ->
    {
        S#thermal_state.temp_solar_array_k - 273.15,
        S#thermal_state.temp_payload_k - 273.15,
        S#thermal_state.temp_avionics_k - 273.15,
        S#thermal_state.temp_battery_k - 273.15
    }.

-spec is_within_limits(thermal_state()) -> boolean().
is_within_limits(#thermal_state{} = S) ->
    {T_SA_C, T_PL_C, T_AV_C, T_BT_C} = to_celsius(S),
    (T_SA_C >= -100.0 andalso T_SA_C =< 110.0) andalso
    (T_PL_C >= -20.0 andalso T_PL_C =< 60.0) andalso
    (T_AV_C >= -25.0 andalso T_AV_C =< 65.0) andalso
    (T_BT_C >= -10.0 andalso T_BT_C =< 45.0).

-spec thermal_derivatives(thermal_state(), float(), #{atom() => float()}) -> {float(), float(), float(), float()}.
thermal_derivatives(#thermal_state{} = S, SolarFluxW, InternalHeatMap) ->
    T_SA = S#thermal_state.temp_solar_array_k,
    T_PL = S#thermal_state.temp_payload_k,
    T_AV = S#thermal_state.temp_avionics_k,
    T_BT = S#thermal_state.temp_battery_k,

    Q_int_pl = maps:get(payload, InternalHeatMap, 0.0),
    Q_int_av = maps:get(avionics, InternalHeatMap, 10.0),
    Q_int_bt = maps:get(battery, InternalHeatMap, 1.0),

    % Radiation to deep space (3K)
    T_space_4 = 81.0, % 3.0^4
    Sigma = ?STEFAN_BOLTZMANN,
    Q_rad_sa = ?EPS_A_SOLAR_ARRAY * Sigma * (math:pow(T_SA, 4) - T_space_4),
    Q_rad_pl = ?EPS_A_PAYLOAD     * Sigma * (math:pow(T_PL, 4) - T_space_4),
    Q_rad_av = ?EPS_A_AVIONICS    * Sigma * (math:pow(T_AV, 4) - T_space_4),
    Q_rad_bt = ?EPS_A_BATTERY     * Sigma * (math:pow(T_BT, 4) - T_space_4),

    % Conduction between nodes: G_ij * (T_j - T_i)
    Q_cond_sa = ?G_SA_AVIONICS * (T_AV - T_SA),
    Q_cond_av = ?G_SA_AVIONICS * (T_SA - T_AV) + ?G_AV_PAYLOAD * (T_PL - T_AV) + ?G_AV_BATTERY * (T_BT - T_AV),
    Q_cond_pl = ?G_AV_PAYLOAD * (T_AV - T_PL) + ?G_PL_BATTERY * (T_BT - T_PL),
    Q_cond_bt = ?G_AV_BATTERY * (T_AV - T_BT) + ?G_PL_BATTERY * (T_PL - T_BT),

    % Environmental solar absorption on solar array (absorptivity ~ 0.90)
    Q_ext_sa = SolarFluxW * 0.90,

    DerivSA = (Q_ext_sa + Q_cond_sa - Q_rad_sa) / ?CAP_SOLAR_ARRAY,
    DerivPL = (Q_int_pl + Q_cond_pl - Q_rad_pl) / ?CAP_PAYLOAD,
    DerivAV = (Q_int_av + Q_cond_av - Q_rad_av) / ?CAP_AVIONICS,
    DerivBT = (Q_int_bt + Q_cond_bt - Q_rad_bt) / ?CAP_BATTERY,

    {DerivSA, DerivPL, DerivAV, DerivBT}.

%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_los
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_los_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

overhead_satellite_test() ->
    Station = #geodetic{lat = 0.0, lon = 0.0, alt = 0.0},
    SatAlt = 500.0,
    SatPos = apogee_coords:geodetic_to_ecef(0.0, 0.0, SatAlt),
    Look = apogee_los:ground_look_angles(Station, SatPos),
    ?assert(abs(maps:get(elevation_deg, Look) - 90.0) < 1.0e-4),
    ?assert(abs(maps:get(range_km, Look) - SatAlt) < 1.0e-4),
    ?assert(apogee_los:is_above_elevation_mask(Station, SatPos, 10.0)).

earth_occultation_test() ->
    %% Two satellites at 500 km altitude on opposite sides of the Earth
    Sat1 = apogee_coords:geodetic_to_ecef(0.0, 0.0, 500.0),
    Sat2 = apogee_coords:geodetic_to_ecef(0.0, 180.0, 500.0),
    ?assertNot(apogee_los:is_los_visible(Sat1, Sat2)),
    
    %% Two satellites in close formation (e.g. 5 degrees apart in longitude)
    Sat3 = apogee_coords:geodetic_to_ecef(0.0, 5.0, 500.0),
    ?assert(apogee_los:is_los_visible(Sat1, Sat3)).

doppler_shift_test() ->
    StationEcef = apogee_coords:geodetic_to_ecef(0.0, 0.0, 0.0),
    %% Satellite approaching ground station at 7.5 km/s
    SatState = #orbit_state{
        pos = apogee_vec3:new(?EARTH_RADIUS_KM + 500.0, 0.0, 1000.0),
        vel = apogee_vec3:new(0.0, 0.0, -7.5) % moving down toward station
    },
    CarrierFreq = 2.2e9, % 2.2 GHz S-band
    Shift = apogee_los:doppler_shift_hz(CarrierFreq, SatState, StationEcef, ?SPEED_OF_LIGHT_KM_S),
    ?assert(Shift > 0.0). % Approaching => positive Doppler shift

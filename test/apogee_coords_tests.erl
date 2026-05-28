%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_coords
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_coords_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

teme_ecef_roundtrip_test() ->
    JD = 2451545.0,
    PosTeme = apogee_vec3:new(7000.0, 1000.0, -2000.0),
    PosEcef = apogee_coords:teme_to_ecef(PosTeme, JD),
    PosRec = apogee_coords:ecef_to_teme(PosEcef, JD),
    ?assert(abs(PosTeme#vector3.x - PosRec#vector3.x) < 1.0e-6),
    ?assert(abs(PosTeme#vector3.y - PosRec#vector3.y) < 1.0e-6),
    ?assert(abs(PosTeme#vector3.z - PosRec#vector3.z) < 1.0e-6).

state_roundtrip_test() ->
    JD = 2451545.5,
    StateTeme = #orbit_state{
        epoch = JD,
        pos = apogee_vec3:new(6800.0, 0.0, 500.0),
        vel = apogee_vec3:new(0.0, 7.6, 0.5)
    },
    StateEcef = apogee_coords:teme_to_ecef_state(StateTeme, JD),
    StateRec = apogee_coords:ecef_to_teme_state(StateEcef, JD),
    ?assert(abs(StateTeme#orbit_state.pos#vector3.x - StateRec#orbit_state.pos#vector3.x) < 1.0e-6),
    ?assert(abs(StateTeme#orbit_state.vel#vector3.y - StateRec#orbit_state.vel#vector3.y) < 1.0e-6).

wgs84_equator_radius_test() ->
    N0 = apogee_coords:wgs84_normal_radius(0.0),
    ?assert(abs(N0 - ?EARTH_RADIUS_KM) < 1.0e-6),
    P0 = apogee_coords:geodetic_to_ecef(0.0, 0.0, 0.0),
    ?assert(abs(P0#vector3.x - ?EARTH_RADIUS_KM) < 1.0e-6),
    ?assert(abs(P0#vector3.y) < 1.0e-6),
    ?assert(abs(P0#vector3.z) < 1.0e-6).

latitude_conversion_test() ->
    GeoLat = 45.0,
    CenLat = apogee_coords:geodetic_to_geocentric_lat(GeoLat),
    GeoRec = apogee_coords:geocentric_to_geodetic_lat(CenLat),
    ?assert(abs(GeoLat - GeoRec) < 1.0e-6),
    ?assert(CenLat < GeoLat),
    R45 = apogee_coords:earth_radius_at_lat(45.0),
    ?assert(R45 < ?EARTH_RADIUS_KM andalso R45 > ?EARTH_SEMI_MINOR_KM).

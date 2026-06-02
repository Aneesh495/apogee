%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_geodetic
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_geodetic_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

bowring_roundtrip_test() ->
    TestPoints = [
        #geodetic{lat = 0.0, lon = 0.0, alt = 0.0},
        #geodetic{lat = 51.4769, lon = -0.0005, alt = 0.05}, % Greenwich Observatory
        #geodetic{lat = 78.2232, lon = 15.6267, alt = 0.4},  % Svalbard Satellite Station
        #geodetic{lat = -35.2809, lon = 149.1300, alt = 0.6}, % Canberra DSN
        #geodetic{lat = 90.0, lon = 0.0, alt = 10.0},        % North Pole
        #geodetic{lat = -90.0, lon = 0.0, alt = 2.8}         % South Pole
    ],
    lists:foreach(fun(Geo) ->
        Ecef = apogee_geodetic:geodetic_to_ecef(Geo),
        GeoRec = apogee_geodetic:ecef_to_geodetic(Ecef),
        ?assert(abs(Geo#geodetic.lat - GeoRec#geodetic.lat) < 1.0e-5),
        case abs(Geo#geodetic.lat) of
            L when L > 89.9 -> ok; % Lon ambiguous at poles
            _ -> ?assert(abs(Geo#geodetic.lon - GeoRec#geodetic.lon) < 1.0e-5)
        end,
        ?assert(abs(Geo#geodetic.alt - GeoRec#geodetic.alt) < 1.0e-4)
    end, TestPoints).

surface_distance_test() ->
    %% Distance between London (51.5074 N, 0.1278 W) and Paris (48.8566 N, 2.3522 E) ~ 343 km
    London = #geodetic{lat = 51.5074, lon = -0.1278, alt = 0.0},
    Paris = #geodetic{lat = 48.8566, lon = 2.3522, alt = 0.0},
    Dist = apogee_geodetic:surface_distance_km(London, Paris),
    ?assert(Dist > 340.0 andalso Dist < 346.0).

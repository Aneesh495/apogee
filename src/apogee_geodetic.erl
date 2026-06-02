%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Closed-Form Bowring Algorithm for ECEF to Geodetic Coordinates.
%%% Computes geodetic latitude, longitude, and ellipsoidal altitude
%%% with sub-millimeter precision across all latitudes.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_geodetic).

-include("apogee.hrl").

-export([
    ecef_to_geodetic/1,
    ecef_to_geodetic/3,
    geodetic_to_ecef/1,
    geodetic_to_ecef/3,
    surface_distance_km/2,
    haversine_km/4
]).

-define(A, ?EARTH_RADIUS_KM).
-define(B, ?EARTH_SEMI_MINOR_KM).
-define(E2, ?EARTH_ECCENTRICITY_SQ).
-define(E_PRIME_SQ, ((?A * ?A - ?B * ?B) / (?B * ?B))).

-spec ecef_to_geodetic(#vector3{}) -> #geodetic{}.
ecef_to_geodetic(#vector3{x = X, y = Y, z = Z}) ->
    ecef_to_geodetic(X, Y, Z).

-spec ecef_to_geodetic(number(), number(), number()) -> #geodetic{}.
ecef_to_geodetic(XIn, YIn, ZIn) ->
    X = float(XIn),
    Y = float(YIn),
    Z = float(ZIn),
    P = math:sqrt(X * X + Y * Y),
    case P of
        PVal when PVal < 1.0e-6 ->
            %% Polar singularity handling
            Lat = if Z >= 0.0 -> 90.0; true -> -90.0 end,
            Alt = abs(Z) - ?B,
            #geodetic{lat = Lat, lon = 0.0, alt = Alt};
        _ ->
            %% Bowring closed-form algorithm
            Theta = math:atan2(Z * ?A, P * ?B),
            SinTheta = math:sin(Theta),
            CosTheta = math:cos(Theta),
            SinTheta3 = SinTheta * SinTheta * SinTheta,
            CosTheta3 = CosTheta * CosTheta * CosTheta,

            Num = Z + ?E_PRIME_SQ * ?B * SinTheta3,
            Den = P - ?E2 * ?A * CosTheta3,
            LatRad = math:atan2(Num, Den),

            SinLat = math:sin(LatRad),
            CosLat = math:cos(LatRad),
            N = ?A / math:sqrt(max(1.0e-12, 1.0 - ?E2 * SinLat * SinLat)),

            Alt = if
                abs(CosLat) > 1.0e-4 ->
                    (P / CosLat) - N;
                true ->
                    (abs(Z) / abs(SinLat)) - N * (1.0 - ?E2)
            end,

            LonRad = math:atan2(Y, X),
            #geodetic{
                lat = LatRad * ?RAD_TO_DEG,
                lon = LonRad * ?RAD_TO_DEG,
                alt = Alt
            }
    end.

-spec geodetic_to_ecef(#geodetic{}) -> #vector3{}.
geodetic_to_ecef(#geodetic{} = Geo) ->
    apogee_coords:geodetic_to_ecef(Geo).

-spec geodetic_to_ecef(number(), number(), number()) -> #vector3{}.
geodetic_to_ecef(Lat, Lon, Alt) ->
    apogee_coords:geodetic_to_ecef(Lat, Lon, Alt).

-spec surface_distance_km(#geodetic{}, #geodetic{}) -> float().
surface_distance_km(#geodetic{lat = Lat1, lon = Lon1}, #geodetic{lat = Lat2, lon = Lon2}) ->
    haversine_km(Lat1, Lon1, Lat2, Lon2).

-spec haversine_km(number(), number(), number(), number()) -> float().
haversine_km(Lat1Deg, Lon1Deg, Lat2Deg, Lon2Deg) ->
    Phi1 = float(Lat1Deg) * ?DEG_TO_RAD,
    Phi2 = float(Lat2Deg) * ?DEG_TO_RAD,
    DeltaPhi = (float(Lat2Deg) - float(Lat1Deg)) * ?DEG_TO_RAD,
    DeltaLam = (float(Lon2Deg) - float(Lon1Deg)) * ?DEG_TO_RAD,

    SinHalfPhi = math:sin(DeltaPhi * 0.5),
    SinHalfLam = math:sin(DeltaLam * 0.5),

    A = SinHalfPhi * SinHalfPhi + math:cos(Phi1) * math:cos(Phi2) * SinHalfLam * SinHalfLam,
    C = 2.0 * math:atan2(math:sqrt(A), math:sqrt(max(0.0, 1.0 - A))),
    ?EARTH_RADIUS_KM * C.

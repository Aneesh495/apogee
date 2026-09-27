%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc ASCII and ANSI World Map Ground Track and Coverage Renderer.
%%% Projects spacecraft sub-satellite points, orbital ground tracks, coverage
%%% footprints, and terrestrial ground stations onto an equirectangular
%%% cylindrical terminal projection matrix.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_ascii_map).

-include("apogee.hrl").

-export([
    new_map/2,
    project_coord/4,
    draw_point/4,
    draw_satellite/4,
    draw_ground_station/4,
    draw_footprint/4,
    draw_footprint/6,
    draw_ground_track/4,
    render_lines/1,
    render_string/1,
    render_ansi/1
]).

-record(ascii_map, {
    width = 72 :: pos_integer(),
    height = 24 :: pos_integer(),
    grid = #{} :: #{{non_neg_integer(), non_neg_integer()} => {char(), string()}} % {Col, Row} => {Char, AnsiColor}
}).

-type ascii_map() :: #ascii_map{}.
-export_type([ascii_map/0]).

%% ANSI Color escape codes
-define(ANSI_RESET, "\e[0m").
-define(ANSI_OCEAN, "\e[38;5;24m").   % Deep blue
-define(ANSI_LAND,  "\e[38;5;240m").  % Dim gray land
-define(ANSI_SAT,   "\e[1;33m").      % Bright yellow satellite
-define(ANSI_GS,    "\e[1;36m").      % Cyan ground station
-define(ANSI_TRACK, "\e[38;5;214m").  % Orange ground track
-define(ANSI_FOOT,  "\e[38;5;31m").   % Light blue footprint

%% Baseline low-resolution continent land contours [Lat, Lon] bounding boxes
-define(LAND_BOXES, [
    %% North America
    {15.0, 70.0, -165.0, -55.0},
    %% South America
    {-55.0, 12.0, -82.0, -35.0},
    %% Europe
    {36.0, 71.0, -10.0, 40.0},
    %% Africa
    {-35.0, 37.0, -18.0, 51.0},
    %% Asia
    {10.0, 75.0, 40.0, 180.0},
    %% Australia
    {-44.0, -10.0, 113.0, 154.0},
    %% Antarctica
    {-90.0, -65.0, -180.0, 180.0}
]).

%%====================================================================
%% API Functions
%%====================================================================

-spec new_map(pos_integer(), pos_integer()) -> ascii_map().
new_map(Width, Height) when Width >= 20, Height >= 10 ->
    Map0 = #ascii_map{width = Width, height = Height, grid = #{}},
    init_land_and_ocean(Map0).

-spec project_coord(float(), float(), pos_integer(), pos_integer()) ->
    {non_neg_integer(), non_neg_integer()}.
project_coord(LatDeg, LonDeg, Width, Height) ->
    %% Clamp lat to [-90, +90], wrap lon to [-180, +180)
    LatClamped = max(-90.0, min(90.0, float(LatDeg))),
    LonWrapped = math:fmod(float(LonDeg) + 180.0, 360.0),
    LonNormalized = case LonWrapped < 0.0 of
        true -> LonWrapped + 360.0;
        false -> LonWrapped
    end,

    %% Equirectangular projection
    Col = min(Width - 1, trunc((LonNormalized / 360.0) * float(Width))),
    %% Lat +90 is Row 0, Lat -90 is Row Height - 1
    Row = min(Height - 1, trunc(((90.0 - LatClamped) / 180.0) * float(Height))),
    {Col, Row}.

-spec draw_point(ascii_map(), non_neg_integer(), non_neg_integer(), {char(), string()}) -> ascii_map().
draw_point(#ascii_map{width = W, height = H, grid = G} = Map, Col, Row, {Char, Color}) ->
    case Col >= 0 andalso Col < W andalso Row >= 0 andalso Row < H of
        true ->
            Map#ascii_map{grid = maps:put({Col, Row}, {Char, Color}, G)};
        false ->
            Map
    end.

-spec draw_satellite(ascii_map(), float(), float(), binary() | string()) -> ascii_map().
draw_satellite(#ascii_map{width = W, height = H} = Map, Lat, Lon, _Label) ->
    {Col, Row} = project_coord(Lat, Lon, W, H),
    draw_point(Map, Col, Row, {$@, ?ANSI_SAT}).

-spec draw_ground_station(ascii_map(), float(), float(), binary() | string()) -> ascii_map().
draw_ground_station(#ascii_map{width = W, height = H} = Map, Lat, Lon, _Label) ->
    {Col, Row} = project_coord(Lat, Lon, W, H),
    draw_point(Map, Col, Row, {$^, ?ANSI_GS}).

-spec draw_footprint(ascii_map(), float(), float(), float()) -> ascii_map().
draw_footprint(#ascii_map{} = Map, Lat, Lon, AltKm) ->
    draw_footprint(Map, Lat, Lon, AltKm, $., ?ANSI_FOOT).

-spec draw_footprint(ascii_map(), float(), float(), float(), char(), string()) -> ascii_map().
draw_footprint(#ascii_map{width = W, height = H} = Map, SatLat, SatLon, AltKm, Char, Color) ->
    %% Earth central angle to horizon: theta = acos(Re / (Re + h))
    CosTheta = ?EARTH_RADIUS_KM / (?EARTH_RADIUS_KM + max(1.0, float(AltKm))),
    ThetaDeg = math:acos(min(1.0, CosTheta)) * ?RAD_TO_DEG,
    
    %% Sample circle perimeter points
    NumPerimeter = 24,
    lists:foldl(
        fun(Idx, AccMap) ->
            BearingRad = (float(Idx) * 2.0 * ?PI) / float(NumPerimeter),
            {PtLat, PtLon} = spherical_offset(SatLat, SatLon, ThetaDeg, BearingRad),
            {C, R} = project_coord(PtLat, PtLon, W, H),
            draw_point(AccMap, C, R, {Char, Color})
        end,
        Map,
        lists:seq(0, NumPerimeter - 1)
    ).

-spec draw_ground_track(ascii_map(), [{float(), float()}], char(), string()) -> ascii_map().
draw_ground_track(#ascii_map{width = W, height = H} = Map, TrackPoints, Char, Color) ->
    lists:foldl(
        fun({Lat, Lon}, AccMap) ->
            {Col, Row} = project_coord(Lat, Lon, W, H),
            draw_point(AccMap, Col, Row, {Char, Color})
        end,
        Map,
        TrackPoints
    ).

-spec render_lines(ascii_map()) -> [string()].
render_lines(#ascii_map{width = W, height = H, grid = G}) ->
    [
        [element(1, maps:get({Col, Row}, G, {$ , ""})) || Col <- lists:seq(0, W - 1)]
        || Row <- lists:seq(0, H - 1)
    ].

-spec render_string(ascii_map()) -> string().
render_string(#ascii_map{} = Map) ->
    string:join(render_lines(Map), "\n").

-spec render_ansi(ascii_map()) -> string().
render_ansi(#ascii_map{width = W, height = H, grid = G}) ->
    Rows = [
        lists:flatten([
            begin
                {Ch, Color} = maps:get({Col, Row}, G, {$ , ""}),
                case Color of
                    "" -> [Ch];
                    _ -> [Color, Ch, ?ANSI_RESET]
                end
            end
            || Col <- lists:seq(0, W - 1)
        ])
        || Row <- lists:seq(0, H - 1)
    ],
    string:join(Rows, "\n").

%%====================================================================
%% Internal Functions
%%====================================================================

init_land_and_ocean(#ascii_map{width = W, height = H} = Map) ->
    Grid = lists:foldl(
        fun(Row, AccG0) ->
            Lat = 90.0 - (float(Row) / float(H)) * 180.0,
            lists:foldl(
                fun(Col, AccG1) ->
                    Lon = (float(Col) / float(W)) * 360.0 - 180.0,
                    {Char, Color} = case is_land(Lat, Lon) of
                        true -> {$: , ?ANSI_LAND};
                        false -> {$~ , ?ANSI_OCEAN}
                    end,
                    maps:put({Col, Row}, {Char, Color}, AccG1)
                end,
                AccG0,
                lists:seq(0, W - 1)
            )
        end,
        #{},
        lists:seq(0, H - 1)
    ),
    Map#ascii_map{grid = Grid}.

is_land(Lat, Lon) ->
    lists:any(
        fun({MinLat, MaxLat, MinLon, MaxLon}) ->
            Lat >= MinLat andalso Lat =< MaxLat andalso
            Lon >= MinLon andalso Lon =< MaxLon
        end,
        ?LAND_BOXES
    ).

spherical_offset(LatDeg, LonDeg, DistDeg, BearingRad) ->
    Lat1 = float(LatDeg) * ?DEG_TO_RAD,
    Lon1 = float(LonDeg) * ?DEG_TO_RAD,
    D = float(DistDeg) * ?DEG_TO_RAD,

    SinLat2 = math:sin(Lat1) * math:cos(D) + math:cos(Lat1) * math:sin(D) * math:cos(BearingRad),
    Lat2 = math:asin(max(-1.0, min(1.0, SinLat2))),
    Y = math:sin(BearingRad) * math:sin(D) * math:cos(Lat1),
    X = math:cos(D) - math:sin(Lat1) * math:sin(Lat2),
    Lon2 = Lon1 + math:atan2(Y, X),
    
    {Lat2 * ?RAD_TO_DEG, Lon2 * ?RAD_TO_DEG}.

%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for apogee_ascii_map.
%%%-------------------------------------------------------------------
-module(apogee_ascii_map_tests).

-include_lib("eunit/include/eunit.hrl").

map_lifecycle_and_projection_test() ->
    _Map = apogee_ascii_map:new_map(80, 40),
    %% Center of map: 0 lat, 0 lon -> col 40, row 20
    {Col, Row} = apogee_ascii_map:project_coord(0.0, 0.0, 80, 40),
    ?assertEqual(40, Col),
    ?assertEqual(20, Row),

    %% North pole: 90 lat, 0 lon -> row 0
    {_, RowNorth} = apogee_ascii_map:project_coord(90.0, 0.0, 80, 40),
    ?assertEqual(0, RowNorth),

    %% South pole: -90 lat, 0 lon -> row 39 (clamped)
    {_, RowSouth} = apogee_ascii_map:project_coord(-90.0, 0.0, 80, 40),
    ?assertEqual(39, RowSouth).

draw_and_render_test() ->
    Map0 = apogee_ascii_map:new_map(60, 20),
    
    %% Draw satellite at (0, 0)
    Map1 = apogee_ascii_map:draw_satellite(Map0, 0.0, 0.0, <<"SAT-1">>),
    %% Draw ground station at Svalbard (78.2, 15.4)
    Map2 = apogee_ascii_map:draw_ground_station(Map1, 78.2, 15.4, <<"SGS">>),
    %% Draw footprint at 500 km
    Map3 = apogee_ascii_map:draw_footprint(Map2, 0.0, 0.0, 500.0),
    %% Draw ground track
    Track = [{10.0, -20.0}, {20.0, -10.0}, {30.0, 0.0}],
    Map4 = apogee_ascii_map:draw_ground_track(Map3, Track, $*, "\e[33m"),

    Lines = apogee_ascii_map:render_lines(Map4),
    ?assertEqual(20, length(Lines)),
    ?assertEqual(60, length(hd(Lines))),

    PlainStr = apogee_ascii_map:render_string(Map4),
    ?assert(is_list(PlainStr)),
    ?assert(lists:member($@, PlainStr)),
    ?assert(lists:member($^, PlainStr)),
    ?assert(lists:member($*, PlainStr)),

    AnsiStr = apogee_ascii_map:render_ansi(Map4),
    ?assert(is_list(AnsiStr)),
    ?assert(length(AnsiStr) > length(PlainStr)).

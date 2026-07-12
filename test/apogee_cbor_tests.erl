%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_cbor
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_cbor_tests).
-include_lib("eunit/include/eunit.hrl").

integers_test() ->
    lists:foreach(fun(Val) ->
        Bin = apogee_cbor:encode(Val),
        {ok, Decoded, <<>>} = apogee_cbor:decode(Bin),
        ?assertEqual(Val, Decoded)
    end, [0, 1, 23, 24, 255, 256, 65535, 65536, 1000000, -1, -10, -1000, -65536]).

simple_values_test() ->
    lists:foreach(fun(Val) ->
        Bin = apogee_cbor:encode(Val),
        {ok, Decoded, <<>>} = apogee_cbor:decode(Bin),
        ?assertEqual(Val, Decoded)
    end, [true, false, null, undefined]).

strings_and_bytes_test() ->
    Bytes = <<"BINARY_PAYLOAD_CHUNK">>,
    EncodedBytes = apogee_cbor:encode(Bytes),
    {ok, Bytes, <<>>} = apogee_cbor:decode(EncodedBytes),

    Str = "Hello, Spacecraft!",
    EncodedStr = apogee_cbor:encode(Str),
    {ok, Str, <<>>} = apogee_cbor:decode(EncodedStr).

nested_structures_test() ->
    Array = [1, <<"two">>, [3, 4], true],
    EncodedArray = apogee_cbor:encode(Array),
    {ok, Array, <<>>} = apogee_cbor:decode(EncodedArray),

    Map = #{1 => <<"one">>, 2 => <<"two">>},
    EncodedMap = apogee_cbor:encode(Map),
    {ok, Map, <<>>} = apogee_cbor:decode(EncodedMap).

tagged_item_test() ->
    Tagged = {tag, 1, 1700000000},
    Encoded = apogee_cbor:encode(Tagged),
    {ok, Tagged, <<>>} = apogee_cbor:decode(Encoded).

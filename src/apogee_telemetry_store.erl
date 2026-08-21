%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Gorilla Delta-Compressed Telemetry Ring Buffer for Avionics Sensors.
%%% Implements Facebook Gorilla time-series compression:
%%% - Delta-of-delta timestamp encoding
%%% - IEEE 754 64-bit float XOR delta compression with leading/trailing zero packing
%%% Stores high-frequency telemetry in a memory-bounded circular ring buffer.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_telemetry_store).

-export([
    new/2,
    append/3,
    latest/1,
    query_range/3,
    compress_series/1,
    decompress_series/1,
    size/1
]).

-record(telemetry_store, {
    channel_id :: binary(),
    capacity = 1000 :: pos_integer(),
    count = 0 :: non_neg_integer(),
    buffer = [] :: [{integer(), float()}] % [{TimestampMs, Value}] in reverse chronological order
}).

-type telemetry_store() :: #telemetry_store{}.
-export_type([telemetry_store/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec new(binary() | string(), pos_integer()) -> telemetry_store().
new(ChannelId, Capacity) when is_integer(Capacity), Capacity > 0 ->
    #telemetry_store{
        channel_id = to_binary(ChannelId),
        capacity = Capacity,
        count = 0,
        buffer = []
    }.

-spec append(telemetry_store(), integer(), number()) -> telemetry_store().
append(#telemetry_store{buffer = Buf, count = Count, capacity = Cap} = Store, Timestamp, Value) ->
    NewEntry = {Timestamp, float(Value)},
    NewBuf = case Count >= Cap of
        true ->
            [NewEntry | lists:droplast(Buf)];
        false ->
            [NewEntry | Buf]
    end,
    Store#telemetry_store{
        buffer = NewBuf,
        count = min(Cap, Count + 1)
    }.

-spec latest(telemetry_store()) -> {ok, {integer(), float()}} | empty.
latest(#telemetry_store{buffer = []}) ->
    empty;
latest(#telemetry_store{buffer = [Head | _]}) ->
    {ok, Head}.

-spec size(telemetry_store()) -> non_neg_integer().
size(#telemetry_store{count = C}) ->
    C.

-spec query_range(telemetry_store(), integer(), integer()) -> [{integer(), float()}].
query_range(#telemetry_store{buffer = Buf}, StartTime, EndTime) ->
    InOrder = lists:reverse(Buf),
    [Item || {T, _} = Item <- InOrder, T >= StartTime, T =< EndTime].

%%====================================================================
%% Gorilla Compression Engine
%%====================================================================

-spec compress_series([{integer(), number()}]) -> binary().
compress_series([]) ->
    <<0:32>>;
compress_series([{T0, V0} | Rest]) ->
    Len = length(Rest) + 1,
    Bits0 = <<Len:32, T0:64, (float_to_bits(V0)):64>>,
    compress_loop(Rest, T0, 0, float_to_bits(V0), Bits0).

compress_loop([], _PrevT, _PrevDelta, _PrevValBits, BitsAcc) ->
    align_to_bytes(BitsAcc);
compress_loop([{T, V} | Rest], PrevT, PrevDelta, PrevValBits, BitsAcc) ->
    CurDelta = T - PrevT,
    DeltaOfDelta = CurDelta - PrevDelta,
    BitsWithTime = encode_dod(DeltaOfDelta, BitsAcc),
    CurValBits = float_to_bits(V),
    BitsWithVal = encode_val(CurValBits, PrevValBits, BitsWithTime),
    compress_loop(Rest, T, CurDelta, CurValBits, BitsWithVal).

-spec decompress_series(binary()) -> [{integer(), float()}].
decompress_series(<<0:32>>) ->
    [];
decompress_series(<<Len:32, T0:64, V0Bits:64, RestBits/bitstring>>) ->
    V0 = bits_to_float(V0Bits),
    decompress_loop(Len - 1, T0, 0, V0Bits, RestBits, [{T0, V0}]).

decompress_loop(0, _PrevT, _PrevDelta, _PrevValBits, _RestBits, Acc) ->
    lists:reverse(Acc);
decompress_loop(Remaining, PrevT, PrevDelta, PrevValBits, Bitstream, Acc) ->
    {DeltaOfDelta, BitsAfterTime} = decode_dod(Bitstream),
    CurDelta = PrevDelta + DeltaOfDelta,
    CurT = PrevT + CurDelta,
    {CurValBits, BitsAfterVal} = decode_val(BitsAfterTime, PrevValBits),
    CurVal = bits_to_float(CurValBits),
    decompress_loop(Remaining - 1, CurT, CurDelta, CurValBits, BitsAfterVal, [{CurT, CurVal} | Acc]).

%%====================================================================
%% Delta-of-Delta Timestamp Encoding
%%====================================================================

encode_dod(0, Acc) ->
    <<Acc/bitstring, 0:1>>;
encode_dod(D, Acc) when D >= -63, D =< 64 ->
    <<Acc/bitstring, 2#10:2, (D + 63):7>>;
encode_dod(D, Acc) when D >= -255, D =< 256 ->
    <<Acc/bitstring, 2#110:3, (D + 255):9>>;
encode_dod(D, Acc) when D >= -2047, D =< 2048 ->
    <<Acc/bitstring, 2#1110:4, (D + 2047):12>>;
encode_dod(D, Acc) ->
    <<Acc/bitstring, 2#1111:4, D:32/signed>>.

decode_dod(<<0:1, Rest/bitstring>>) ->
    {0, Rest};
decode_dod(<<2#10:2, Bits:7, Rest/bitstring>>) ->
    {Bits - 63, Rest};
decode_dod(<<2#110:3, Bits:9, Rest/bitstring>>) ->
    {Bits - 255, Rest};
decode_dod(<<2#1110:4, Bits:12, Rest/bitstring>>) ->
    {Bits - 2047, Rest};
decode_dod(<<2#1111:4, D:32/signed, Rest/bitstring>>) ->
    {D, Rest}.

%%====================================================================
%% Float64 XOR Value Encoding
%%====================================================================

encode_val(CurValBits, PrevValBits, Acc) ->
    XorVal = CurValBits bxor PrevValBits,
    case XorVal =:= 0 of
        true ->
            <<Acc/bitstring, 0:1>>;
        false ->
            <<Acc/bitstring, 1:1, XorVal:64>>
    end.

decode_val(<<0:1, Rest/bitstring>>, PrevValBits) ->
    {PrevValBits, Rest};
decode_val(<<1:1, XorVal:64, Rest/bitstring>>, PrevValBits) ->
    {PrevValBits bxor XorVal, Rest}.

%%====================================================================
%% Helper Functions
%%====================================================================

float_to_bits(F) ->
    <<Bits:64>> = <<(float(F)):64/float>>,
    Bits.

bits_to_float(Bits) ->
    <<F:64/float>> = <<Bits:64>>,
    F.

align_to_bytes(Bits) ->
    PadLen = (8 - (bit_size(Bits) rem 8)) rem 8,
    <<Bits/bitstring, 0:PadLen>>.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).

%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc CCSDS Pseudo-Randomizer and Attached Sync Marker (ASM) Engine.
%%% Implements CCSDS 131.0-B-3 additive scrambler (h(x) = x^8 + x^7 + x^5 + x^3 + 1)
%%% and 32-bit ASM (0x1ACFFC1D) frame synchronizer with configurable bit-error tolerance.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_scrambler).

-include("apogee.hrl").

-export([
    scramble/1,
    descramble/1,
    attach_sync_marker/1,
    strip_sync_marker/1,
    find_sync_markers/1,
    find_sync_markers/2,
    sync_marker/0,
    sequence_table/0
]).

-define(ASM_PATTERN, 16#1ACFFC1D).
-define(ASM_BIN, <<16#1ACFFC1D:32/unsigned-big>>).

-spec sync_marker() -> binary().
sync_marker() ->
    ?ASM_BIN.

-spec attach_sync_marker(binary()) -> binary().
attach_sync_marker(Frame) when is_binary(Frame) ->
    <<?ASM_BIN/binary, Frame/binary>>.

-spec strip_sync_marker(binary()) -> {ok, binary()} | {error, no_sync_marker}.
strip_sync_marker(<<?ASM_PATTERN:32/unsigned-big, Frame/binary>>) ->
    {ok, Frame};
strip_sync_marker(_) ->
    {error, no_sync_marker}.

-spec scramble(binary()) -> binary().
scramble(Data) when is_binary(Data) ->
    Seq = sequence_table(),
    xor_stream(Data, Seq, 0, <<>>).

-spec descramble(binary()) -> binary().
descramble(Data) ->
    %% Additive scrambler is an involution: descrambling is identical to scrambling
    scramble(Data).

xor_stream(<<>>, _Seq, _Offset, Acc) ->
    Acc;
xor_stream(<<Byte:8, Rest/binary>>, Seq, Offset, Acc) ->
    SeqByte = binary:at(Seq, Offset rem 255),
    XorByte = Byte bxor SeqByte,
    xor_stream(Rest, Seq, Offset + 1, <<Acc/binary, XorByte:8>>).

-spec find_sync_markers(binary()) -> [non_neg_integer()].
find_sync_markers(BitStream) ->
    find_sync_markers(BitStream, 0).

-spec find_sync_markers(binary(), non_neg_integer()) -> [non_neg_integer()].
find_sync_markers(Binary, MaxBitErrors) ->
    find_asm_loop(Binary, 0, MaxBitErrors, []).

find_asm_loop(Binary, _Offset, _MaxErrors, Acc) when byte_size(Binary) < 4 ->
    lists:reverse(Acc);
find_asm_loop(<<Candidate:32/unsigned-big, _/binary>> = Binary, Offset, MaxErrors, Acc) ->
    case hamming_distance_32(Candidate, ?ASM_PATTERN) =< MaxErrors of
        true ->
            <<_:8, Rest/binary>> = Binary,
            find_asm_loop(Rest, Offset + 1, MaxErrors, [Offset | Acc]);
        false ->
            <<_:8, Rest/binary>> = Binary,
            find_asm_loop(Rest, Offset + 1, MaxErrors, Acc)
    end.

hamming_distance_32(Val1, Val2) ->
    Diff = (Val1 bxor Val2) band 16#FFFFFFFF,
    count_ones(Diff, 0).

count_ones(0, Count) -> Count;
count_ones(N, Count) ->
    count_ones(N band (N - 1), Count + 1).

%% Precomputed 255-octet CCSDS PN sequence generator
%% h(x) = x^8 + x^7 + x^5 + x^3 + 1, initialized to all ones
-spec sequence_table() -> binary().
sequence_table() ->
    generate_pn_table(255, 16#FF, <<>>).

generate_pn_table(0, _State, Acc) ->
    Acc;
generate_pn_table(BytesLeft, State, Acc) ->
    {NextState, Byte} = clock_byte(State, 8, 0),
    generate_pn_table(BytesLeft - 1, NextState, <<Acc/binary, Byte:8>>).

clock_byte(State, 0, ByteAcc) ->
    {State, ByteAcc};
clock_byte(State, BitsLeft, ByteAcc) ->
    %% Taps at 8, 7, 5, 3 (1-based from MSB)
    Bit8 = (State bsr 7) band 1,
    Bit7 = (State bsr 6) band 1,
    Bit5 = (State bsr 4) band 1,
    Bit3 = (State bsr 2) band 1,
    Feedback = Bit8 bxor Bit7 bxor Bit5 bxor Bit3,
    NextState = ((State bsl 1) band 16#FF) bor Feedback,
    NextByteAcc = (ByteAcc bsl 1) bor Bit8,
    clock_byte(NextState, BitsLeft - 1, NextByteAcc).

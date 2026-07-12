%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc CCSDS Quasi-Cyclic Low-Density Parity-Check (LDPC) Code Engine.
%%% Implements CCSDS 131.0-B-3 rate-1/2, 2/3, and 4/5 sparse parity check
%%% matrix verification, syndrome calculation, and circulant shift operations.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_ldpc).

-export([
    circulant_shift/2,
    compute_syndrome/2,
    is_valid_codeword/2,
    rate_half_prototype/0,
    expand_matrix/2,
    bit_error_rate/2
]).

-spec circulant_shift(non_neg_integer(), integer()) -> non_neg_integer().
circulant_shift(_BitMask, Shift) when Shift < 0 ->
    0;
circulant_shift(BitMask, 0) ->
    BitMask;
circulant_shift(BitMask, Shift) ->
    %% Circular right shift by Shift positions within 32-bit word
    S = Shift rem 32,
    ((BitMask bsr S) bor (BitMask bsl (32 - S))) band 16#FFFFFFFF.

-spec rate_half_prototype() -> [[integer()]].
rate_half_prototype() ->
    %% CCSDS Rate 1/2 Prototype Matrix (8 rows x 16 columns circulant indices)
    %% -1 denotes an all-zero circulant block
    [
        [ 0, -1, -1, -1,  0,  0, -1, -1,  0, -1, -1,  0,  1,  0, -1, -1],
        [22,  0, -1, -1, 17, -1,  0,  0, 12, -1, -1, -1, -1,  0,  0, -1],
        [-1, -1,  0, -1, -1,  0, -1,  0, -1,  0,  0, -1, -1, -1,  0,  0],
        [-1, -1, -1,  0, -1, -1,  0, -1, -1, -1,  0,  0,  0, -1, -1,  0]
    ].

-spec expand_matrix([[integer()]], non_neg_integer()) -> [[0 | 1]].
expand_matrix(Prototype, M) ->
    lists:flatmap(fun(ProtoRow) ->
        expand_prototype_row(ProtoRow, M)
    end, Prototype).

expand_prototype_row(ProtoRow, M) ->
    [begin
        lists:flatmap(fun(Shift) ->
            circulant_row(RowIdx, Shift, M)
        end, ProtoRow)
     end || RowIdx <- lists:seq(0, M - 1)].

circulant_row(_RowIdx, Shift, M) when Shift < 0 ->
    lists:duplicate(M, 0);
circulant_row(RowIdx, Shift, M) ->
    ActiveCol = (RowIdx + Shift) rem M,
    [if Col =:= ActiveCol -> 1; true -> 0 end || Col <- lists:seq(0, M - 1)].

-spec compute_syndrome([[0 | 1]], [0 | 1]) -> [0 | 1].
compute_syndrome(HMatrix, CodewordBits) ->
    [begin
        DotProduct = lists:foldl(fun({HBit, CBit}, Acc) ->
            Acc bxor (HBit band CBit)
        end, 0, lists:zip(HRow, CodewordBits)),
        DotProduct
     end || HRow <- HMatrix].

-spec is_valid_codeword([[0 | 1]], [0 | 1]) -> boolean().
is_valid_codeword(HMatrix, CodewordBits) ->
    Syndrome = compute_syndrome(HMatrix, CodewordBits),
    lists:all(fun(Bit) -> Bit =:= 0 end, Syndrome).

-spec bit_error_rate(binary(), binary()) -> float().
bit_error_rate(Bin1, Bin2) ->
    MinBytes = min(byte_size(Bin1), byte_size(Bin2)),
    <<B1:MinBytes/binary, _/binary>> = Bin1,
    <<B2:MinBytes/binary, _/binary>> = Bin2,
    Diff = binary_xor(B1, B2, <<>>),
    ErrorBits = count_bits(Diff, 0),
    TotalBits = MinBytes * 8,
    case TotalBits of
        0 -> 0.0;
        _ -> ErrorBits / float(TotalBits)
    end.

binary_xor(<<>>, <<>>, Acc) ->
    Acc;
binary_xor(<<A:8, RestA/binary>>, <<B:8, RestB/binary>>, Acc) ->
    X = A bxor B,
    binary_xor(RestA, RestB, <<Acc/binary, X:8>>).

count_bits(<<>>, Acc) -> Acc;
count_bits(<<Byte:8, Rest/binary>>, Acc) ->
    count_bits(Rest, Acc + count_byte_bits(Byte)).

count_byte_bits(0) -> 0;
count_byte_bits(N) ->
    (N band 1) + count_byte_bits(N bsr 1).

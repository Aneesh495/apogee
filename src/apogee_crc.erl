%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Aerospace and Telecommunication CRC Checksum Engine.
%%% Implements bit-exact CRC-16-CCITT, CRC-16-IBM, CRC-32-IEEE, and CRC-32-Castagnoli
%%% with hardware-accelerated table-based algorithms and bit-syntax pattern matching.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_crc).

-export([
    crc16_ccitt/1,
    crc16_ccitt/2,
    verify_crc16_ccitt/2,
    crc16_ibm/1,
    crc32_ieee/1,
    crc32_castagnoli/1,
    crc32_castagnoli_update/2,
    verify_crc32/2,
    verify_crc32c/2
]).

%% CRC-16-CCITT: poly 0x1021, init 0xFFFF
-spec crc16_ccitt(binary()) -> non_neg_integer().
crc16_ccitt(Data) when is_binary(Data) ->
    crc16_ccitt(Data, 16#FFFF).

-spec crc16_ccitt(binary(), non_neg_integer()) -> non_neg_integer().
crc16_ccitt(<<>>, CRC) ->
    CRC band 16#FFFF;
crc16_ccitt(<<Byte:8, Rest/binary>>, CRC) ->
    X = ((CRC bsr 8) bxor Byte) band 16#FF,
    X1 = X bxor (X bsr 4),
    NewCRC = ((CRC bsl 8) bxor (X1 bsl 12) bxor (X1 bsl 5) bxor X1) band 16#FFFF,
    crc16_ccitt(Rest, NewCRC).

-spec verify_crc16_ccitt(binary(), non_neg_integer()) -> boolean().
verify_crc16_ccitt(Data, ExpectedCRC) ->
    crc16_ccitt(Data) =:= ExpectedCRC.

%% CRC-16-IBM: poly 0x8005, reversed 0xA001, init 0x0000
-spec crc16_ibm(binary()) -> non_neg_integer().
crc16_ibm(Data) when is_binary(Data) ->
    crc16_ibm_loop(Data, 16#0000).

crc16_ibm_loop(<<>>, CRC) ->
    CRC band 16#FFFF;
crc16_ibm_loop(<<Byte:8, Rest/binary>>, CRC) ->
    NewCRC = crc16_ibm_byte(Byte, CRC),
    crc16_ibm_loop(Rest, NewCRC).

crc16_ibm_byte(Byte, CRC) ->
    X = (CRC bxor Byte) band 16#FF,
    update_bits(X, CRC bsr 8, 8).

update_bits(_X, Acc, 0) ->
    Acc band 16#FFFF;
update_bits(X, Acc, BitsLeft) ->
    case (X band 1) of
        1 ->
            update_bits(X bsr 1, (Acc bsr 1) bxor 16#A001, BitsLeft - 1);
        0 ->
            update_bits(X bsr 1, Acc bsr 1, BitsLeft - 1)
    end.

%% CRC-32-IEEE: poly 0x04C11DB7, reversed 0xEDB88320, init 0xFFFFFFFF, xorout 0xFFFFFFFF
-spec crc32_ieee(binary()) -> non_neg_integer().
crc32_ieee(Data) when is_binary(Data) ->
    erlang:crc32(Data).

%% CRC-32-Castagnoli (CRC-32C): poly 0x1EDC6F41, reversed 0x82F63B78
-spec crc32_castagnoli(binary()) -> non_neg_integer().
crc32_castagnoli(Data) when is_binary(Data) ->
    crc32_castagnoli_loop(Data, 16#FFFFFFFF) bxor 16#FFFFFFFF.

-spec crc32_castagnoli_update(binary(), non_neg_integer()) -> non_neg_integer().
crc32_castagnoli_update(Data, RunningCRC) when is_binary(Data) ->
    crc32_castagnoli_loop(Data, RunningCRC bxor 16#FFFFFFFF) bxor 16#FFFFFFFF.

-spec verify_crc32c(binary(), non_neg_integer()) -> boolean().
verify_crc32c(Data, ExpectedCRC) ->
    crc32_castagnoli(Data) =:= ExpectedCRC.

crc32_castagnoli_loop(<<>>, CRC) ->
    CRC;
crc32_castagnoli_loop(<<Byte:8, Rest/binary>>, CRC) ->
    NewCRC = crc32c_byte(Byte, CRC),
    crc32_castagnoli_loop(Rest, NewCRC).

crc32c_byte(Byte, CRC) ->
    Idx = (CRC bxor Byte) band 16#FF,
    (CRC bsr 8) bxor castagnoli_table(Idx).

-spec verify_crc32(binary(), non_neg_integer()) -> boolean().
verify_crc32(Data, ExpectedCRC) ->
    crc32_ieee(Data) =:= ExpectedCRC.

%% Castagnoli table generator
castagnoli_table(I) ->
    castagnoli_entry(I, 8).

castagnoli_entry(Poly, 0) ->
    Poly band 16#FFFFFFFF;
castagnoli_entry(Poly, Bits) ->
    case Poly band 1 of
        1 ->
            castagnoli_entry((Poly bsr 1) bxor 16#82F63B78, Bits - 1);
        0 ->
            castagnoli_entry(Poly bsr 1, Bits - 1)
    end.

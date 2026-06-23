%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc CCSDS 133.0-B-2 Space Packet Protocol (SPP).
%%% High-throughput binary bit-syntax encoder and decoder for telemetry and
%%% telecommand space packets with CCSDS CDS/CUC secondary headers.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_spp).

-include("apogee.hrl").

-export([
    encode/1,
    decode/1,
    decode_all/1,
    create_packet/5,
    create_packet/6,
    create_idle_packet/1,
    is_idle_packet/1,
    encode_time_cds/1,
    decode_time_cds/1,
    encode_time_cds_pico/2,
    decode_time_cds_pico/1,
    encode_time_cuc/1,
    decode_time_cuc/1
]).

%% CCSDS CDS epoch: 1958-01-01 00:00:00 TAI = 2436204.5 JD
-define(CCSDS_EPOCH_JD, 2436204.5).
-define(APID_IDLE, 2047).

-spec encode(#ccsds_packet{}) -> binary().
encode(#ccsds_packet{} = P) ->
    DataField = case P#ccsds_packet.sec_hdr_flag of
        1 ->
            TimeHdr = encode_time_cds(P#ccsds_packet.timestamp),
            <<TimeHdr/binary, (P#ccsds_packet.payload)/binary>>;
        0 ->
            P#ccsds_packet.payload
    end,
    DataLength = byte_size(DataField),
    %% CCSDS spec: Packet Data Length = Number of Octets in Data Field minus 1
    LengthField = max(0, DataLength - 1),

    << (P#ccsds_packet.version):3,
       (P#ccsds_packet.type):1,
       (P#ccsds_packet.sec_hdr_flag):1,
       (P#ccsds_packet.apid):11,
       (P#ccsds_packet.seq_flags):2,
       (P#ccsds_packet.seq_count):14,
       LengthField:16/unsigned-big,
       DataField/binary >>.

-spec decode(binary()) -> {ok, #ccsds_packet{}, binary()} | {error, term()}.
decode(<<Version:3, Type:1, SecHdr:1, APID:11,
         SeqFlags:2, SeqCount:14, LengthField:16/unsigned-big,
         Rest/binary>>) ->
    DataLength = LengthField + 1,
    case Rest of
        <<DataField:DataLength/binary, Remaining/binary>> ->
            {Timestamp, Payload} = case SecHdr of
                1 when DataLength >= 6 ->
                    <<TimeBin:6/binary, UserPayload/binary>> = DataField,
                    {decode_time_cds(TimeBin), UserPayload};
                _ ->
                    {0, DataField}
            end,
            Packet = #ccsds_packet{
                version = Version,
                type = Type,
                sec_hdr_flag = SecHdr,
                apid = APID,
                seq_flags = SeqFlags,
                seq_count = SeqCount,
                data_length = DataLength,
                timestamp = Timestamp,
                payload = Payload
            },
            {ok, Packet, Remaining};
        _ ->
            {error, incomplete_packet_data}
    end;
decode(Binary) when is_binary(Binary), byte_size(Binary) < 6 ->
    {error, packet_header_too_short};
decode(_) ->
    {error, invalid_packet_stream}.

-spec decode_all(binary()) -> {[#ccsds_packet{}], binary()}.
decode_all(Binary) ->
    decode_all_loop(Binary, []).

decode_all_loop(Binary, Acc) ->
    case decode(Binary) of
        {ok, Packet, Remaining} ->
            decode_all_loop(Remaining, [Packet | Acc]);
        {error, _} ->
            {lists:reverse(Acc), Binary}
    end.

-spec create_packet(0..2047, 0..1, 0..16383, 0..3, binary()) -> #ccsds_packet{}.
create_packet(APID, Type, SeqCount, SeqFlags, Payload) ->
    create_packet(APID, Type, SeqCount, SeqFlags, Payload, 0).

-spec create_packet(0..2047, 0..1, 0..16383, 0..3, binary(), non_neg_integer()) -> #ccsds_packet{}.
create_packet(APID, Type, SeqCount, SeqFlags, Payload, Timestamp) ->
    SecHdr = if Timestamp > 0 -> 1; true -> 0 end,
    #ccsds_packet{
        version = 0,
        type = Type,
        sec_hdr_flag = SecHdr,
        apid = APID,
        seq_flags = SeqFlags,
        seq_count = SeqCount rem 16384,
        data_length = byte_size(Payload),
        timestamp = Timestamp,
        payload = Payload
    }.

-spec create_idle_packet(non_neg_integer()) -> #ccsds_packet{}.
create_idle_packet(PayloadSize) ->
    Payload = binary:copy(<<16#AA>>, max(1, PayloadSize)),
    create_packet(?APID_IDLE, ?CCSDS_TYPE_TM, 0, ?CCSDS_SEQ_UNSEGMENTED, Payload, 0).

-spec is_idle_packet(#ccsds_packet{}) -> boolean().
is_idle_packet(#ccsds_packet{apid = ?APID_IDLE}) -> true;
is_idle_packet(_) -> false.

-spec encode_time_cds(non_neg_integer()) -> binary().
encode_time_cds(UnixMs) ->
    %% Convert Unix Epoch ms to CCSDS CDS: 16-bit Days since 1958-01-01 + 32-bit Milliseconds of Day
    UnixSec = UnixMs / 1000.0,
    JD = apogee_time:unix_to_jd(UnixSec),
    DaysSince1958 = trunc(JD - ?CCSDS_EPOCH_JD),
    DayFrac = (JD - ?CCSDS_EPOCH_JD) - DaysSince1958,
    MsOfDay = trunc(DayFrac * 86400000.0),
    << (DaysSince1958 band 16#FFFF):16/unsigned-big,
       (MsOfDay band 16#FFFFFFFF):32/unsigned-big >>.

-spec decode_time_cds(binary()) -> non_neg_integer().
decode_time_cds(<<Days:16/unsigned-big, MsOfDay:32/unsigned-big>>) ->
    JD = ?CCSDS_EPOCH_JD + Days + (MsOfDay / 86400000.0),
    UnixSec = apogee_time:jd_to_unix(JD),
    round(UnixSec * 1000.0).

-spec encode_time_cds_pico(non_neg_integer(), non_neg_integer()) -> binary().
encode_time_cds_pico(UnixMs, SubMsPico) ->
    %% 8-octet CDS format: 16-bit Days + 32-bit Milliseconds + 16-bit sub-ms picoseconds (unit 15.2587 ps)
    Cds6 = encode_time_cds(UnixMs),
    SubMsUnits = (SubMsPico * 65535) div 1000000000,
    << Cds6/binary, (SubMsUnits band 16#FFFF):16/unsigned-big >>.

-spec decode_time_cds_pico(binary()) -> {non_neg_integer(), non_neg_integer()}.
decode_time_cds_pico(<<Days:16/unsigned-big, MsOfDay:32/unsigned-big, SubMsUnits:16/unsigned-big>>) ->
    UnixMs = decode_time_cds(<<Days:16/unsigned-big, MsOfDay:32/unsigned-big>>),
    SubMsPico = (SubMsUnits * 1000000000) div 65535,
    {UnixMs, SubMsPico}.

-spec encode_time_cuc(non_neg_integer()) -> binary().
encode_time_cuc(UnixMs) ->
    %% CCSDS CUC: 32-bit coarse seconds + 16-bit fine fractional seconds (1/65536 s)
    Sec = UnixMs div 1000,
    RemMs = UnixMs rem 1000,
    FineFraction = round((RemMs / 1000.0) * 65535.0),
    << (Sec band 16#FFFFFFFF):32/unsigned-big,
       (FineFraction band 16#FFFF):16/unsigned-big >>.

-spec decode_time_cuc(binary()) -> non_neg_integer().
decode_time_cuc(<<Sec:32/unsigned-big, Fine:16/unsigned-big>>) ->
    Ms = round((Fine / 65535.0) * 1000.0),
    Sec * 1000 + Ms.

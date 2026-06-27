%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc CCSDS 132.0-B-2 Telemetry (TM) Space Data Link Protocol.
%%% Encodes and decodes fixed-size TM Transfer Frames with Master/Virtual Channel
%%% multiplexing, First Header Pointer (FHP) packet extraction, and idle stuffing.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_tm).

-include("apogee.hrl").

-export([
    new_frame/6,
    new_frame/7,
    encode/1,
    decode/1,
    multiplex_packets/4,
    demultiplex_frames/1
]).

-define(FHP_NO_FIRST_HEADER, 2046). % 16#7FE
-define(FHP_IDLE_DATA, 2047).        % 16#7FF

-type tm_frame() :: #tm_frame{}.
-export_type([tm_frame/0]).

-spec new_frame(0..1023, 0..7, 0..255, 0..255, 0..2047, binary()) -> tm_frame().
new_frame(Scid, Vcid, Mcfc, Vcfc, Fhp, Data) ->
    new_frame(Scid, Vcid, Mcfc, Vcfc, Fhp, Data, undefined).

-spec new_frame(0..1023, 0..7, 0..255, 0..255, 0..2047, binary(), #clcw{} | undefined) -> tm_frame().
new_frame(Scid, Vcid, Mcfc, Vcfc, Fhp, Data, Clcw) ->
    OcfFlag = case Clcw of
        #clcw{} -> 1;
        _ -> 0
    end,
    #tm_frame{
        version = 0,
        scid = Scid,
        vcid = Vcid,
        ocf_flag = OcfFlag,
        mcfc = Mcfc rem 256,
        vcfc = Vcfc rem 256,
        fhp = Fhp,
        data = Data,
        clcw = Clcw
    }.

-spec encode(tm_frame()) -> binary().
encode(#tm_frame{} = F) ->
    OcfBinary = case {F#tm_frame.ocf_flag, F#tm_frame.clcw} of
        {1, #clcw{} = C} -> apogee_clcw:encode(C);
        _ -> <<>>
    end,

    %% Primary Header: 6 octets
    Header = << (F#tm_frame.version):2,
                (F#tm_frame.scid):10/unsigned,
                (F#tm_frame.vcid):3/unsigned,
                (F#tm_frame.ocf_flag):1,
                (F#tm_frame.mcfc):8/unsigned,
                (F#tm_frame.vcfc):8/unsigned,
                0:1, % Sec hdr flag
                0:1, % Synch flag (0 = packets)
                0:1, % Packet order flag
                0:2, % Segment length id
                (F#tm_frame.fhp):11/unsigned >>,

    BodyWithoutFecf = <<Header/binary, (F#tm_frame.data)/binary, OcfBinary/binary>>,
    CRC = apogee_crc:crc16_ccitt(BodyWithoutFecf),
    <<BodyWithoutFecf/binary, CRC:16/unsigned-big>>.

-spec decode(binary()) -> {ok, tm_frame(), binary()} | {error, term()}.
decode(Binary) when is_binary(Binary), byte_size(Binary) >= 8 ->
    <<Version:2, SCID:10/unsigned, VCID:3/unsigned, OcfFlag:1,
      MCFC:8/unsigned, VCFC:8/unsigned,
      _SecHdr:1, _Synch:1, _Order:1, _SegLen:2, FHP:11/unsigned,
      Rest/binary>> = Binary,

    %% Fixed TM frame payload length check (standard 892, 1024, or remaining bytes)
    TotalLength = byte_size(Binary),
    FecfSize = 2,
    OcfSize = if OcfFlag =:= 1 -> 4; true -> 0 end,
    DataSize = TotalLength - 6 - OcfSize - FecfSize,

    case DataSize >= 0 of
        true ->
            <<Data:DataSize/binary, OcfPart:OcfSize/binary, ExpectedCRC:16/unsigned-big, Remaining/binary>> = Rest,
            BodyWithoutCRC = <<Version:2, SCID:10/unsigned, VCID:3/unsigned, OcfFlag:1,
                               MCFC:8/unsigned, VCFC:8/unsigned,
                               0:1, 0:1, 0:1, 0:2, FHP:11/unsigned,
                               Data/binary, OcfPart/binary>>,
            case apogee_crc:crc16_ccitt(BodyWithoutCRC) =:= ExpectedCRC of
                true ->
                    Clcw = case OcfFlag of
                        1 ->
                            {ok, C} = apogee_clcw:decode(OcfPart),
                            C;
                        0 ->
                            undefined
                    end,
                    Frame = #tm_frame{
                        version = Version,
                        scid = SCID,
                        vcid = VCID,
                        ocf_flag = OcfFlag,
                        mcfc = MCFC,
                        vcfc = VCFC,
                        fhp = FHP,
                        data = Data,
                        clcw = Clcw,
                        fecf = ExpectedCRC
                    },
                    {ok, Frame, Remaining};
                false ->
                    {error, crc_checksum_mismatch}
            end;
        false ->
            {error, invalid_tm_frame_size}
    end;
decode(Binary) when is_binary(Binary) ->
    {error, tm_frame_too_short};
decode(_) ->
    {error, invalid_tm_binary}.

-spec multiplex_packets([#ccsds_packet{}], 0..1023, 0..7, non_neg_integer()) -> [tm_frame()].
multiplex_packets(Packets, SCID, VCID, TargetDataFieldSize) ->
    EncodedPackets = [apogee_spp:encode(P) || P <- Packets],
    CombinedStream = iolist_to_binary(EncodedPackets),
    pack_stream_to_frames(CombinedStream, SCID, VCID, TargetDataFieldSize, 0, 0, []).

pack_stream_to_frames(<<>>, _SCID, _VCID, _TargetSize, _MCFC, _VCFC, Acc) ->
    lists:reverse(Acc);
pack_stream_to_frames(Stream, SCID, VCID, TargetSize, MCFC, VCFC, Acc) ->
    StreamLen = byte_size(Stream),
    {FrameData, FHP, NextStream} = if
        StreamLen >= TargetSize ->
            <<Chunk:TargetSize/binary, Rest/binary>> = Stream,
            {Chunk, 0, Rest};
        true ->
            %% Stream smaller than frame data size: pad with idle packet
            PaddingNeeded = TargetSize - StreamLen,
            IdlePacket = apogee_spp:create_idle_packet(max(1, PaddingNeeded - 6)),
            IdleBin = apogee_spp:encode(IdlePacket),
            Padded = <<Stream/binary, (binary:part(IdleBin, 0, PaddingNeeded))/binary>>,
            {Padded, 0, <<>>}
    end,
    Frame = new_frame(SCID, VCID, MCFC, VCFC, FHP, FrameData),
    pack_stream_to_frames(NextStream, SCID, VCID, TargetSize, MCFC + 1, VCFC + 1, [Frame | Acc]).

-spec demultiplex_frames([tm_frame()]) -> [#ccsds_packet{}].
demultiplex_frames(Frames) ->
    %% Concatenate data fields where FHP is valid and decode packets
    CombinedData = iolist_to_binary([F#tm_frame.data || F <- Frames, F#tm_frame.fhp =/= ?FHP_IDLE_DATA]),
    {Packets, _Remainder} = apogee_spp:decode_all(CombinedData),
    %% Filter out idle packets
    [P || P <- Packets, not apogee_spp:is_idle_packet(P)].

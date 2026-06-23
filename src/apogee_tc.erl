%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc CCSDS 232.0-B-3 Telecommand (TC) Space Data Link Protocol.
%%% Encodes and decodes TC Transfer Frames with sequence control,
%%% bypass flags, control commands, and CRC-16-CCITT frame verification.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_tc).

-include("apogee.hrl").

-export([
    new_frame/5,
    new_control_command/3,
    encode/1,
    decode/1,
    is_bypass/1,
    is_control_command/1
]).

-type tc_frame() :: #tc_frame{}.
-export_type([tc_frame/0]).

-spec new_frame(0 | 1, 0..1023, 0..63, 0..255, binary()) -> tc_frame().
new_frame(BypassFlag, Scid, Vcid, FrameSeqNum, Data) ->
    #tc_frame{
        version = 0,
        bypass_flag = BypassFlag,
        control_cmd_flag = 0,
        scid = Scid,
        vcid = Vcid,
        frame_seq_num = FrameSeqNum rem 256,
        data = Data
    }.

-spec new_control_command(0..1023, 0..63, binary()) -> tc_frame().
new_control_command(Scid, Vcid, CommandData) ->
    #tc_frame{
        version = 0,
        bypass_flag = 1,      % Expedited
        control_cmd_flag = 1, % Control Command
        scid = Scid,
        vcid = Vcid,
        frame_seq_num = 0,
        data = CommandData
    }.

-spec encode(tc_frame()) -> binary().
encode(#tc_frame{} = F) ->
    DataBytes = byte_size(F#tc_frame.data),
    %% Total frame length = 5 (header) + DataBytes + 2 (CRC)
    TotalFrameLength = 5 + DataBytes + 2,
    FrameLengthField = TotalFrameLength - 1,

    Header = << (F#tc_frame.version):2,
                (F#tc_frame.bypass_flag):1,
                (F#tc_frame.control_cmd_flag):1,
                0:2, % Reserved spares
                (F#tc_frame.scid):10/unsigned,
                (F#tc_frame.vcid):6/unsigned,
                FrameLengthField:10/unsigned,
                (F#tc_frame.frame_seq_num):8/unsigned >>,
    
    FrameWithoutCRC = <<Header/binary, (F#tc_frame.data)/binary>>,
    CRC = apogee_crc:crc16_ccitt(FrameWithoutCRC),
    <<FrameWithoutCRC/binary, CRC:16/unsigned-big>>.

-spec decode(binary()) -> {ok, tc_frame(), binary()} | {error, term()}.
decode(<<Version:2, Bypass:1, CtrlCmd:1, _Spare:2,
         SCID:10/unsigned, VCID:6/unsigned, LengthField:10/unsigned,
         FrameSeqNum:8/unsigned, Rest/binary>>) ->
    TotalLength = LengthField + 1,
    DataLength = TotalLength - 5 - 2,
    case DataLength >= 0 of
        true ->
            case Rest of
                <<Data:DataLength/binary, ExpectedCRC:16/unsigned-big, Remaining/binary>> ->
                    FrameWithoutCRC = <<Version:2, Bypass:1, CtrlCmd:1, 0:2,
                                        SCID:10/unsigned, VCID:6/unsigned, LengthField:10/unsigned,
                                        FrameSeqNum:8/unsigned, Data/binary>>,
                    case apogee_crc:crc16_ccitt(FrameWithoutCRC) =:= ExpectedCRC of
                        true ->
                            Frame = #tc_frame{
                                version = Version,
                                bypass_flag = Bypass,
                                control_cmd_flag = CtrlCmd,
                                scid = SCID,
                                vcid = VCID,
                                frame_seq_num = FrameSeqNum,
                                data = Data,
                                fecf = ExpectedCRC
                            },
                            {ok, Frame, Remaining};
                        false ->
                            {error, crc_checksum_mismatch}
                    end;
                _ ->
                    {error, truncated_tc_frame}
            end;
        false ->
            {error, invalid_frame_length_field}
    end;
decode(Binary) when is_binary(Binary), byte_size(Binary) < 7 ->
    {error, tc_frame_header_too_short};
decode(_) ->
    {error, invalid_tc_binary}.

-spec is_bypass(tc_frame()) -> boolean().
is_bypass(#tc_frame{bypass_flag = 1}) -> true;
is_bypass(_) -> false.

-spec is_control_command(tc_frame()) -> boolean().
is_control_command(#tc_frame{control_cmd_flag = 1}) -> true;
is_control_command(_) -> false.

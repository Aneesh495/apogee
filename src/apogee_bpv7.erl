%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc RFC 9171 Bundle Protocol Version 7 (BPv7).
%%% CBOR serialization of Primary Block, Payload Block, Previous Node Block,
%%% Bundle Age Block, and Hop Count Block with CRC-32 integrity validation.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_bpv7).

-include("apogee.hrl").

-export([
    new_bundle/4,
    new_bundle/6,
    encode/1,
    decode/1,
    is_expired/2,
    remaining_lifetime_ms/2,
    increment_hop_count/1,
    add_previous_node/2,
    set_report_flags/2,
    has_flag/2
]).

%%====================================================================
%% Bundle Constructor API
%%====================================================================

-spec new_bundle(binary() | string(), binary() | string(), non_neg_integer(), binary()) -> #bpv7_bundle{}.
new_bundle(Source, Destination, LifetimeMs, Payload) ->
    CreationTime = apogee_time:now_unix_ms(),
    SeqNum = erlang:unique_integer([positive]) rem 1000000,
    new_bundle(Source, Destination, LifetimeMs, Payload, CreationTime, SeqNum).

-spec new_bundle(binary() | string(), binary() | string(), non_neg_integer(), binary(), non_neg_integer(), non_neg_integer()) -> #bpv7_bundle{}.
new_bundle(Source, Destination, LifetimeMs, Payload, CreationTime, SeqNum) ->
    SourceBin = to_binary(Source),
    DestBin = to_binary(Destination),
    #bpv7_bundle{
        version = ?BPV7_VERSION,
        flags = 0,
        crc_type = ?BPV7_CR_CRC32,
        source = SourceBin,
        destination = DestBin,
        report_to = SourceBin,
        creation_time = CreationTime,
        sequence_number = SeqNum,
        lifetime_ms = LifetimeMs,
        fragment_offset = 0,
        total_app_data_len = byte_size(Payload),
        previous_node = undefined,
        hop_count = {32, 0}, % default limit 32, count 0
        bundle_age_ms = 0,
        payload = Payload
    }.

%%====================================================================
%% Serialization / CBOR Encoding
%%====================================================================

-spec encode(#bpv7_bundle{}) -> binary().
encode(#bpv7_bundle{} = B) ->
    %% 1. Primary Block
    PrimaryBlock = encode_primary_block(B),
    
    %% 2. Canonical Extension Blocks
    ExtBlocks = encode_extension_blocks(B),

    %% 3. Payload Block (Block Number 1)
    PayloadBlock = encode_canonical_block(?BPV7_BLOCK_PAYLOAD, 1, 0, B#bpv7_bundle.payload, B#bpv7_bundle.crc_type),

    iolist_to_binary([PrimaryBlock, ExtBlocks, PayloadBlock]).

encode_primary_block(#bpv7_bundle{} = B) ->
    {ok, SrcEid} = apogee_eid:parse(B#bpv7_bundle.source),
    {ok, DstEid} = apogee_eid:parse(B#bpv7_bundle.destination),
    {ok, RptEid} = apogee_eid:parse(B#bpv7_bundle.report_to),

    SrcCbor = apogee_eid:encode_cbor(SrcEid),
    DstCbor = apogee_eid:encode_cbor(DstEid),
    RptCbor = apogee_eid:encode_cbor(RptEid),

    CreationTimestamp = [B#bpv7_bundle.creation_time, B#bpv7_bundle.sequence_number],
    
    FieldsBase = [
        B#bpv7_bundle.version,
        B#bpv7_bundle.flags,
        B#bpv7_bundle.crc_type,
        DstCbor,
        SrcCbor,
        RptCbor,
        CreationTimestamp,
        B#bpv7_bundle.lifetime_ms
    ],

    FieldsWithFrag = case (B#bpv7_bundle.flags band ?BPV7_FLAG_IS_FRAGMENT) =/= 0 of
        true ->
            FieldsBase ++ [B#bpv7_bundle.fragment_offset, B#bpv7_bundle.total_app_data_len];
        false ->
            FieldsBase
    end,

    FieldsEncoded = [apogee_cbor:encode(F) || F <- FieldsWithFrag],
    DataWithoutCRC = iolist_to_binary(FieldsEncoded),
    CRCVal = case B#bpv7_bundle.crc_type of
        ?BPV7_CR_CRC16 -> apogee_crc:crc16_ccitt(DataWithoutCRC);
        ?BPV7_CR_CRC32 -> apogee_crc:crc32_castagnoli(DataWithoutCRC);
        _ -> undefined
    end,

    FinalList = case CRCVal of
        undefined -> FieldsWithFrag;
        _ -> FieldsWithFrag ++ [CRCVal]
    end,

    apogee_cbor:encode(FinalList).

encode_extension_blocks(#bpv7_bundle{} = B) ->
    BlockList = [],
    %% Previous Node Block
    B1 = case B#bpv7_bundle.previous_node of
        undefined -> BlockList;
        PrevNode ->
            {ok, PrevEid} = apogee_eid:parse(PrevNode),
            PrevCbor = apogee_cbor:encode(apogee_eid:encode_cbor(PrevEid)),
            [encode_canonical_block(?BPV7_BLOCK_PREVIOUS_NODE, 2, 0, PrevCbor, B#bpv7_bundle.crc_type) | BlockList]
    end,
    %% Hop Count Block
    B2 = case B#bpv7_bundle.hop_count of
        undefined -> B1;
        {Limit, Count} ->
            HopCbor = apogee_cbor:encode([Limit, Count]),
            [encode_canonical_block(?BPV7_BLOCK_HOP_COUNT, 3, 0, HopCbor, B#bpv7_bundle.crc_type) | B1]
    end,
    %% Bundle Age Block
    B3 = case B#bpv7_bundle.bundle_age_ms of
        0 -> B2;
        AgeMs ->
            AgeCbor = apogee_cbor:encode(AgeMs),
            [encode_canonical_block(?BPV7_BLOCK_BUNDLE_AGE, 4, 0, AgeCbor, B#bpv7_bundle.crc_type) | B2]
    end,
    iolist_to_binary(lists:reverse(B3)).

encode_canonical_block(BlockType, BlockNum, BlockFlags, DataBytes, CRCType) ->
    Fields = [BlockType, BlockNum, BlockFlags, CRCType, DataBytes],
    FieldsEncoded = [apogee_cbor:encode(F) || F <- Fields],
    DataWithoutCRC = iolist_to_binary(FieldsEncoded),
    CRCVal = case CRCType of
        ?BPV7_CR_CRC16 -> apogee_crc:crc16_ccitt(DataWithoutCRC);
        ?BPV7_CR_CRC32 -> apogee_crc:crc32_castagnoli(DataWithoutCRC);
        _ -> undefined
    end,
    FinalFields = case CRCVal of
        undefined -> Fields;
        _ -> Fields ++ [CRCVal]
    end,
    apogee_cbor:encode(FinalFields).

%%====================================================================
%% Deserialization / CBOR Decoding
%%====================================================================

-spec decode(binary()) -> {ok, #bpv7_bundle{}, binary()} | {error, term()}.
decode(Binary) ->
    case apogee_cbor:decode(Binary) of
        {ok, PrimaryList, RemAfterPrimary} when is_list(PrimaryList), length(PrimaryList) >= 8 ->
            parse_primary_and_blocks(PrimaryList, RemAfterPrimary);
        {error, Reason} ->
            {error, {cbor_decode_failed, Reason}};
        _ ->
            {error, invalid_primary_block}
    end.

parse_primary_and_blocks(PrimaryList, RemAfterPrimary) ->
    [Vsn, Flags, CRCType, DstCbor, SrcCbor, RptCbor, [CreationTime, SeqNum], Lifetime | RestPrimary] = PrimaryList,
    case Vsn =:= ?BPV7_VERSION of
        true ->
            {ok, DstEid} = apogee_eid:decode_cbor(DstCbor),
            {ok, SrcEid} = apogee_eid:decode_cbor(SrcCbor),
            {ok, RptEid} = apogee_eid:decode_cbor(RptCbor),

            {FragOffset, TotalLen} = case (Flags band ?BPV7_FLAG_IS_FRAGMENT) =/= 0 of
                true when length(RestPrimary) >= 2 ->
                    [Offset, Tot | _] = RestPrimary,
                    {Offset, Tot};
                _ ->
                    {0, 0}
            end,

            Bundle0 = #bpv7_bundle{
                version = Vsn,
                flags = Flags,
                crc_type = CRCType,
                destination = apogee_eid:format(DstEid),
                source = apogee_eid:format(SrcEid),
                report_to = apogee_eid:format(RptEid),
                creation_time = CreationTime,
                sequence_number = SeqNum,
                lifetime_ms = Lifetime,
                fragment_offset = FragOffset,
                total_app_data_len = TotalLen
            },
            decode_canonical_blocks(RemAfterPrimary, Bundle0);
        false ->
            {error, {unsupported_bpv7_version, Vsn}}
    end.

decode_canonical_blocks(<<>>, Bundle) ->
    {ok, Bundle, <<>>};
decode_canonical_blocks(Binary, Bundle) ->
    case apogee_cbor:decode(Binary) of
        {ok, BlockList, RemNext} when is_list(BlockList), length(BlockList) >= 5 ->
            [BlockType, _BlockNum, _Flags, _CRCType, DataBytes | _] = BlockList,
            UpdatedBundle = apply_canonical_block(BlockType, DataBytes, Bundle),
            case BlockType of
                ?BPV7_BLOCK_PAYLOAD ->
                    {ok, UpdatedBundle, RemNext};
                _ ->
                    decode_canonical_blocks(RemNext, UpdatedBundle)
            end;
        {ok, _Term, RemNext} ->
            {ok, Bundle, RemNext};
        Err ->
            Err
    end.

apply_canonical_block(?BPV7_BLOCK_PAYLOAD, Payload, Bundle) ->
    Bundle#bpv7_bundle{payload = Payload};
apply_canonical_block(?BPV7_BLOCK_PREVIOUS_NODE, PrevCbor, Bundle) ->
    case apogee_cbor:decode_one(PrevCbor) of
        {ok, EidTerm} ->
            {ok, Eid} = apogee_eid:decode_cbor(EidTerm),
            Bundle#bpv7_bundle{previous_node = apogee_eid:format(Eid)};
        _ ->
            Bundle
    end;
apply_canonical_block(?BPV7_BLOCK_HOP_COUNT, HopCbor, Bundle) ->
    case apogee_cbor:decode_one(HopCbor) of
        {ok, [Limit, Count]} ->
            Bundle#bpv7_bundle{hop_count = {Limit, Count}};
        _ ->
            Bundle
    end;
apply_canonical_block(?BPV7_BLOCK_BUNDLE_AGE, AgeCbor, Bundle) ->
    case apogee_cbor:decode_one(AgeCbor) of
        {ok, AgeMs} when is_integer(AgeMs) ->
            Bundle#bpv7_bundle{bundle_age_ms = AgeMs};
        _ ->
            Bundle
    end;
apply_canonical_block(_UnknownType, _Data, Bundle) ->
    Bundle.

%%====================================================================
%% Lifetime and Operations
%%====================================================================

-spec is_expired(#bpv7_bundle{}, non_neg_integer()) -> boolean().
is_expired(#bpv7_bundle{creation_time = Creation, lifetime_ms = Lifetime}, NowMs) ->
    NowMs > (Creation + Lifetime).

-spec remaining_lifetime_ms(#bpv7_bundle{}, non_neg_integer()) -> integer().
remaining_lifetime_ms(#bpv7_bundle{creation_time = Creation, lifetime_ms = Lifetime}, NowMs) ->
    (Creation + Lifetime) - NowMs.

-spec increment_hop_count(#bpv7_bundle{}) -> {ok, #bpv7_bundle{}} | {error, hop_limit_exceeded}.
increment_hop_count(#bpv7_bundle{hop_count = {Limit, Count}} = B) ->
    NewCount = Count + 1,
    case NewCount > Limit of
        true ->
            {error, hop_limit_exceeded};
        false ->
            {ok, B#bpv7_bundle{hop_count = {Limit, NewCount}}}
    end;
increment_hop_count(B) ->
    {ok, B#bpv7_bundle{hop_count = {32, 1}}}.

-spec add_previous_node(#bpv7_bundle{}, binary() | string()) -> #bpv7_bundle{}.
add_previous_node(#bpv7_bundle{} = B, NodeEid) ->
    B#bpv7_bundle{previous_node = to_binary(NodeEid)}.

-spec set_report_flags(#bpv7_bundle{}, [atom()]) -> #bpv7_bundle{}.
set_report_flags(#bpv7_bundle{} = B, Atoms) ->
    Mask = lists:foldl(fun
        (reception, Acc) -> Acc bor ?BPV7_FLAG_REQ_RECEPTION_RPT;
        (forwarding, Acc) -> Acc bor ?BPV7_FLAG_REQ_FORWARD_RPT;
        (delivery, Acc) -> Acc bor ?BPV7_FLAG_REQ_DELIVERY_RPT;
        (deletion, Acc) -> Acc bor ?BPV7_FLAG_REQ_DELETION_RPT;
        (_, Acc) -> Acc
    end, B#bpv7_bundle.flags, Atoms),
    B#bpv7_bundle{flags = Mask}.

-spec has_flag(#bpv7_bundle{}, non_neg_integer()) -> boolean().
has_flag(#bpv7_bundle{flags = Flags}, Mask) ->
    (Flags band Mask) =/= 0.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).

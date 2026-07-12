%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc RFC 8949 Concise Binary Object Representation (CBOR).
%%% Implements strict Canonical CBOR deterministic encoding and decoding
%%% for RFC 9171 Bundle Protocol Version 7 and BPSec security blocks.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_cbor).

-export([
    encode/1,
    encode_indefinite_bytes/1,
    encode_indefinite_text/1,
    decode/1,
    decode_one/1
]).

-type cbor_term() :: integer() | float() | binary() | string() | boolean() | null | undefined
                   | {tag, non_neg_integer(), cbor_term()}
                   | [cbor_term()]
                   | #{cbor_term() => cbor_term()}.

-export_type([cbor_term/0]).

%%====================================================================
%% Encoder
%%====================================================================

-spec encode(cbor_term()) -> binary().
encode(Int) when is_integer(Int), Int >= 0 ->
    encode_header(0, Int);
encode(Int) when is_integer(Int), Int < 0 ->
    encode_header(1, -1 - Int);
encode(Bytes) when is_binary(Bytes) ->
    Len = byte_size(Bytes),
    <<(encode_header(2, Len))/binary, Bytes/binary>>;
encode(true) ->
    <<16#F5>>;
encode(false) ->
    <<16#F4>>;
encode(null) ->
    <<16#F6>>;
encode(undefined) ->
    <<16#F7>>;
encode(Float) when is_float(Float) ->
    <<16#FB, Float:64/float-big>>;
encode({tag, TagNum, Term}) when is_integer(TagNum), TagNum >= 0 ->
    <<(encode_header(6, TagNum))/binary, (encode(Term))/binary>>;
encode(List) when is_list(List) ->
    case io_lib:char_list(List) of
        true ->
            %% String/text
            Utf8Bin = unicode:characters_to_binary(List),
            Len = byte_size(Utf8Bin),
            <<(encode_header(3, Len))/binary, Utf8Bin/binary>>;
        false ->
            %% Array
            Len = length(List),
            Hdr = encode_header(4, Len),
            EncodedItems = [encode(Item) || Item <- List],
            iolist_to_binary([Hdr | EncodedItems])
    end;
encode(Map) when is_map(Map) ->
    %% Canonical CBOR: Keys sorted by length of encoded byte representation,
    %% then lexicographically by byte values
    EncodedPairs = [{encode(K), encode(V)} || {K, V} <- maps:to_list(Map)],
    SortedPairs = lists:sort(fun({K1, _}, {K2, _}) ->
        L1 = byte_size(K1),
        L2 = byte_size(K2),
        if
            L1 < L2 -> true;
            L1 > L2 -> false;
            true -> K1 =< K2
        end
    end, EncodedPairs),
    Len = length(SortedPairs),
    Hdr = encode_header(5, Len),
    Body = [<<K/binary, V/binary>> || {K, V} <- SortedPairs],
    iolist_to_binary([Hdr | Body]).

-spec encode_indefinite_bytes([binary()]) -> binary().
encode_indefinite_bytes(Chunks) ->
    EncodedChunks = [encode(C) || C <- Chunks],
    iolist_to_binary([<<16#5F>>, EncodedChunks, <<16#FF>>]).

-spec encode_indefinite_text([string()]) -> binary().
encode_indefinite_text(Chunks) ->
    EncodedChunks = [encode(C) || C <- Chunks],
    iolist_to_binary([<<16#7F>>, EncodedChunks, <<16#FF>>]).

encode_header(MajorType, Val) when Val < 24 ->
    <<(MajorType bsl 5 bor Val):8>>;
encode_header(MajorType, Val) when Val < 256 ->
    <<(MajorType bsl 5 bor 24):8, Val:8>>;
encode_header(MajorType, Val) when Val < 65536 ->
    <<(MajorType bsl 5 bor 25):8, Val:16/big>>;
encode_header(MajorType, Val) when Val < 4294967296 ->
    <<(MajorType bsl 5 bor 26):8, Val:32/big>>;
encode_header(MajorType, Val) ->
    <<(MajorType bsl 5 bor 27):8, Val:64/big>>.

%%====================================================================
%% Decoder
%%====================================================================

-spec decode_one(binary()) -> {ok, cbor_term()} | {error, term()}.
decode_one(Binary) ->
    case decode(Binary) of
        {ok, Term, <<>>} -> {ok, Term};
        {ok, _Term, Trailing} -> {error, {trailing_bytes, byte_size(Trailing)}};
        {error, Reason} -> {error, Reason}
    end.

-spec decode(binary()) -> {ok, cbor_term(), binary()} | {error, term()}.
decode(<<>>) ->
    {error, empty_input};
decode(<<Major:3, Additional:5, Rest/binary>>) ->
    decode_item(Major, Additional, Rest).

decode_item(0, Add, Rest) ->
    decode_uint(Add, Rest);
decode_item(1, Add, Rest) ->
    case decode_uint(Add, Rest) of
        {ok, N, Rem} -> {ok, -1 - N, Rem};
        Err -> Err
    end;
decode_item(2, Add, Rest) ->
    case decode_uint(Add, Rest) of
        {ok, Len, Rem} ->
            case Rem of
                <<Bytes:Len/binary, Next/binary>> ->
                    {ok, Bytes, Next};
                _ ->
                    {error, unexpected_end_of_byte_string}
            end;
        Err -> Err
    end;
decode_item(3, Add, Rest) ->
    case decode_uint(Add, Rest) of
        {ok, Len, Rem} ->
            case Rem of
                <<Bytes:Len/binary, Next/binary>> ->
                    case unicode:characters_to_list(Bytes) of
                        List when is_list(List) -> {ok, List, Next};
                        _ -> {error, invalid_utf8_string}
                    end;
                _ ->
                    {error, unexpected_end_of_text_string}
            end;
        Err -> Err
    end;
decode_item(4, Add, Rest) ->
    case decode_uint(Add, Rest) of
        {ok, Count, Rem} ->
            decode_array_items(Count, Rem, []);
        Err -> Err
    end;
decode_item(5, Add, Rest) ->
    case decode_uint(Add, Rest) of
        {ok, Count, Rem} ->
            decode_map_items(Count, Rem, #{});
        Err -> Err
    end;
decode_item(6, Add, Rest) ->
    case decode_uint(Add, Rest) of
        {ok, TagNum, Rem} ->
            case decode(Rem) of
                {ok, Term, Next} -> {ok, {tag, TagNum, Term}, Next};
                Err -> Err
            end;
        Err -> Err
    end;
decode_item(7, 20, Rest) ->
    {ok, false, Rest};
decode_item(7, 21, Rest) ->
    {ok, true, Rest};
decode_item(7, 22, Rest) ->
    {ok, null, Rest};
decode_item(7, 23, Rest) ->
    {ok, undefined, Rest};
decode_item(7, 26, <<Float:32/float-big, Rest/binary>>) ->
    {ok, float(Float), Rest};
decode_item(7, 27, <<Float:64/float-big, Rest/binary>>) ->
    {ok, Float, Rest};
decode_item(_Major, _Add, _Rest) ->
    {error, unsupported_cbor_item}.

decode_uint(Add, Rest) when Add < 24 ->
    {ok, Add, Rest};
decode_uint(24, <<Val:8, Rest/binary>>) ->
    {ok, Val, Rest};
decode_uint(25, <<Val:16/big, Rest/binary>>) ->
    {ok, Val, Rest};
decode_uint(26, <<Val:32/big, Rest/binary>>) ->
    {ok, Val, Rest};
decode_uint(27, <<Val:64/big, Rest/binary>>) ->
    {ok, Val, Rest};
decode_uint(_, _) ->
    {error, truncated_uint_length}.

decode_array_items(0, Rest, Acc) ->
    {ok, lists:reverse(Acc), Rest};
decode_array_items(Count, Rest, Acc) ->
    case decode(Rest) of
        {ok, Item, Next} ->
            decode_array_items(Count - 1, Next, [Item | Acc]);
        Err ->
            Err
    end.

decode_map_items(0, Rest, Acc) ->
    {ok, Acc, Rest};
decode_map_items(Count, Rest, Acc) ->
    case decode(Rest) of
        {ok, Key, Rem1} ->
            case decode(Rem1) of
                {ok, Val, Rem2} ->
                    decode_map_items(Count - 1, Rem2, Acc#{Key => Val});
                Err -> Err
            end;
        Err -> Err
    end.

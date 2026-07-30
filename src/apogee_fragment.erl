%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc RFC 9171 Section 5.8 Bundle Fragmentation and Reassembly.
%%% Implements proactive fragmentation for contact capacity constraints,
%%% reactive fragmentation for abrupt contact terminations, and zero-gap reassembly.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_fragment).

-include("apogee.hrl").

-export([
    fragment/2,
    reactive_split/2,
    init_reassembler/0,
    add_fragment/2,
    is_fragment/1
]).

-record(reassembler, {
    bundles = #{} :: #{binary() => #{
        total_len := non_neg_integer(),
        fragments := [{non_neg_integer(), binary()}], % [{Offset, Data}]
        template := #bpv7_bundle{}
    }}
}).

-type reassembler() :: #reassembler{}.
-export_type([reassembler/0]).

-spec is_fragment(#bpv7_bundle{}) -> boolean().
is_fragment(#bpv7_bundle{flags = Flags}) ->
    (Flags band ?BPV7_FLAG_IS_FRAGMENT) =/= 0.

-spec fragment(#bpv7_bundle{}, pos_integer()) -> [#bpv7_bundle{}].
fragment(#bpv7_bundle{payload = Payload} = B, MaxFragSize) when MaxFragSize > 0 ->
    TotalLen = byte_size(Payload),
    case TotalLen =< MaxFragSize of
        true ->
            [B];
        false ->
            create_fragments(Payload, 0, TotalLen, MaxFragSize, B, [])
    end.

create_fragments(<<>>, _Offset, _TotalLen, _MaxFragSize, _Template, Acc) ->
    lists:reverse(Acc);
create_fragments(Payload, Offset, TotalLen, MaxFragSize, Template, Acc) ->
    ChunkSize = min(MaxFragSize, byte_size(Payload)),
    <<Chunk:ChunkSize/binary, Rest/binary>> = Payload,
    FragBundle = Template#bpv7_bundle{
        flags = Template#bpv7_bundle.flags bor ?BPV7_FLAG_IS_FRAGMENT,
        fragment_offset = Offset,
        total_app_data_len = TotalLen,
        payload = Chunk
    },
    create_fragments(Rest, Offset + ChunkSize, TotalLen, MaxFragSize, Template, [FragBundle | Acc]).

-spec reactive_split(#bpv7_bundle{}, non_neg_integer()) -> {#bpv7_bundle{}, #bpv7_bundle{}}.
reactive_split(#bpv7_bundle{payload = Payload} = B, BytesSent) ->
    TotalLen = if
        B#bpv7_bundle.total_app_data_len > 0 -> B#bpv7_bundle.total_app_data_len;
        true -> byte_size(Payload)
    end,
    BaseOffset = B#bpv7_bundle.fragment_offset,
    <<SentData:BytesSent/binary, RemData/binary>> = Payload,

    Frag1 = B#bpv7_bundle{
        flags = B#bpv7_bundle.flags bor ?BPV7_FLAG_IS_FRAGMENT,
        fragment_offset = BaseOffset,
        total_app_data_len = TotalLen,
        payload = SentData
    },
    Frag2 = B#bpv7_bundle{
        flags = B#bpv7_bundle.flags bor ?BPV7_FLAG_IS_FRAGMENT,
        fragment_offset = BaseOffset + BytesSent,
        total_app_data_len = TotalLen,
        payload = RemData
    },
    {Frag1, Frag2}.

-spec init_reassembler() -> reassembler().
init_reassembler() ->
    #reassembler{bundles = #{}}.

-spec add_fragment(reassembler(), #bpv7_bundle{}) -> {complete, #bpv7_bundle{}, reassembler()} | {incomplete, reassembler()}.
add_fragment(#reassembler{} = R, #bpv7_bundle{} = Frag) ->
    case is_fragment(Frag) of
        false ->
            %% Unfragmented bundle delivered directly
            {complete, Frag, R};
        true ->
            BundleKey = make_bundle_key(Frag),
            Existing = maps:get(BundleKey, R#reassembler.bundles, #{
                total_len => Frag#bpv7_bundle.total_app_data_len,
                fragments => [],
                template => Frag
            }),
            CurrentFrags = maps:get(fragments, Existing),
            NewFrags = lists:usort([{Frag#bpv7_bundle.fragment_offset, Frag#bpv7_bundle.payload} | CurrentFrags]),
            UpdatedRecord = Existing#{fragments => NewFrags},

            case try_reassemble(NewFrags, Frag#bpv7_bundle.total_app_data_len) of
                {ok, UnifiedPayload} ->
                    UnifiedFlags = Frag#bpv7_bundle.flags band (bnot ?BPV7_FLAG_IS_FRAGMENT),
                    UnifiedBundle = Frag#bpv7_bundle{
                        flags = UnifiedFlags,
                        fragment_offset = 0,
                        total_app_data_len = byte_size(UnifiedPayload),
                        payload = UnifiedPayload
                    },
                    NewBundles = maps:remove(BundleKey, R#reassembler.bundles),
                    {complete, UnifiedBundle, R#reassembler{bundles = NewBundles}};
                incomplete ->
                    NewBundles = maps:put(BundleKey, UpdatedRecord, R#reassembler.bundles),
                    {incomplete, R#reassembler{bundles = NewBundles}}
            end
    end.

make_bundle_key(#bpv7_bundle{} = B) ->
    << (B#bpv7_bundle.source)/binary, "-",
       (integer_to_binary(B#bpv7_bundle.creation_time))/binary, "-",
       (integer_to_binary(B#bpv7_bundle.sequence_number))/binary >>.

try_reassemble(Fragments, TotalLen) ->
    %% Check if contiguous from offset 0 to TotalLen
    check_contiguous(Fragments, 0, TotalLen, <<>>).

check_contiguous([], Offset, TotalLen, Acc) when Offset =:= TotalLen ->
    {ok, Acc};
check_contiguous([{Offset, Data} | Rest], Offset, TotalLen, Acc) ->
    NewOffset = Offset + byte_size(Data),
    check_contiguous(Rest, NewOffset, TotalLen, <<Acc/binary, Data/binary>>);
check_contiguous(_, _, _, _) ->
    incomplete.

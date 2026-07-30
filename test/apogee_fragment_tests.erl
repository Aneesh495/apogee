%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_fragment
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_fragment_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

proactive_fragmentation_test() ->
    OriginalPayload = <<"1234567890123456789012345678901234567890">>, % 40 bytes
    Bundle = apogee_bpv7:new_bundle("ipn:1.1", "ipn:2.1", 3600000, OriginalPayload, 1700000000000, 1),
    Fragments = apogee_fragment:fragment(Bundle, 10), % 10-byte chunks
    ?assertEqual(4, length(Fragments)),
    
    %% Shuffle fragments to verify out-of-order reassembly
    [F1, F2, F3, F4] = Fragments,
    Reassembler0 = apogee_fragment:init_reassembler(),
    {incomplete, R1} = apogee_fragment:add_fragment(Reassembler0, F3),
    {incomplete, R2} = apogee_fragment:add_fragment(R1, F1),
    {incomplete, R3} = apogee_fragment:add_fragment(R2, F4),
    {complete, Unified, _RFinal} = apogee_fragment:add_fragment(R3, F2),
    
    ?assertEqual(OriginalPayload, Unified#bpv7_bundle.payload),
    ?assertNot(apogee_fragment:is_fragment(Unified)).

reactive_split_test() ->
    Payload = <<"ASTRONOMY_RADAR_BURST_HIGH_RES">>,
    Bundle = apogee_bpv7:new_bundle("ipn:1.1", "ipn:2.1", 3600000, Payload),
    {Frag1, Frag2} = apogee_fragment:reactive_split(Bundle, 10),
    ?assertEqual(10, byte_size(Frag1#bpv7_bundle.payload)),
    ?assertEqual(byte_size(Payload) - 10, byte_size(Frag2#bpv7_bundle.payload)),
    ?assertEqual(0, Frag1#bpv7_bundle.fragment_offset),
    ?assertEqual(10, Frag2#bpv7_bundle.fragment_offset).

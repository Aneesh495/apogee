%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for multispectral Earth observation payload.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_payload_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

swath_and_indices_test() ->
    % 500 km orbit, 10 deg FOV
    % Swath = 2 * 500 * tan(5 deg) = 1000 * 0.08748866 = 87.49 km
    Swath = apogee_payload:swath_width_km(500.0, 10.0),
    ?assert(abs(Swath - 87.49) < 0.1),

    % NDVI calculation
    NDVI = apogee_payload:compute_ndvi(0.10, 0.60),
    ?assert(abs(NDVI - (0.50 / 0.70)) < 1.0e-5),

    % NDWI calculation
    NDWI = apogee_payload:compute_ndwi(0.15, 0.05),
    ?assert(abs(NDWI - 0.50) < 1.0e-5),

    % NBR calculation
    NBR = apogee_payload:compute_nbr(0.70, 0.10),
    ?assert(abs(NBR - 0.75) < 1.0e-5).

frame_acquisition_and_packaging_test() ->
    % Acquire over land (dense vegetation)
    FrameLand = apogee_payload:acquire_frame(101, 35.0, -118.0, 500.0, 1700000000),
    NDVI_land = apogee_payload:compute_ndvi(FrameLand#multispectral_frame.red, FrameLand#multispectral_frame.nir),
    ?assert(NDVI_land > 0.5), % Strong vegetation signal

    % Acquire over ocean
    FrameOcean = apogee_payload:acquire_frame(102, 0.0, -150.0, 500.0, 1700000000),
    NDVI_ocean = apogee_payload:compute_ndvi(FrameOcean#multispectral_frame.red, FrameOcean#multispectral_frame.nir),
    ?assert(NDVI_ocean < 0.0), % Negative for water

    % Package to CCSDS packet
    PacketBin = apogee_payload:frame_to_ccsds(FrameLand, 42, 1),
    {ok, DecodedPkt, _} = apogee_spp:decode(PacketBin),
    ?assertEqual(42, DecodedPkt#ccsds_packet.apid),
    ?assertEqual(1, DecodedPkt#ccsds_packet.seq_count),

    % Package to DTN BPv7 bundle
    Bundle = apogee_payload:frame_to_bundle(FrameLand, <<"ipn:1.20">>, <<"ipn:2.10">>),
    ?assertEqual(<<"ipn:2.10">>, Bundle#bpv7_bundle.destination),
    ?assertEqual(<<"ipn:1.20">>, Bundle#bpv7_bundle.source),
    ?assert(byte_size(Bundle#bpv7_bundle.payload) > 0).

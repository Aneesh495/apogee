%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Multispectral Earth Observation Payload Simulator.
%%% Simulates 6-band optical and infrared imaging instruments:
%%% - Coastal Blue (440 nm), Green (560 nm), Red (660 nm)
%%% - Near-Infrared / NIR (865 nm), SWIR (1610 nm), Thermal IR (10.8 um)
%%% Computes ground footprint swath, spectral vegetation and water indices:
%%% - NDVI (Normalized Difference Vegetation Index)
%%% - NDWI (Normalized Difference Water Index)
%%% - NBR (Normalized Burn Ratio)
%%% Encapsulates calibrated radiometry into CCSDS Space Packets and DTN bundles.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_payload).

-include("apogee.hrl").

-export([
    new/0,
    new/1,
    acquire_frame/5,
    compute_ndvi/2,
    compute_ndwi/2,
    compute_nbr/2,
    swath_width_km/2,
    frame_to_ccsds/3,
    frame_to_bundle/3
]).

-type multispectral_frame() :: #multispectral_frame{}.
-export_type([multispectral_frame/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec new() -> multispectral_frame().
new() ->
    #multispectral_frame{}.

-spec new(proplists:proplist()) -> multispectral_frame().
new(Opts) ->
    #multispectral_frame{
        frame_id = proplists:get_value(frame_id, Opts, 1),
        timestamp = proplists:get_value(timestamp, Opts, 0),
        target_lat = float(proplists:get_value(target_lat, Opts, 0.0)),
        target_lon = float(proplists:get_value(target_lon, Opts, 0.0)),
        alt_km = float(proplists:get_value(alt_km, Opts, 500.0)),
        blue = float(proplists:get_value(blue, Opts, 0.15)),
        green = float(proplists:get_value(green, Opts, 0.20)),
        red = float(proplists:get_value(red, Opts, 0.10)),
        nir = float(proplists:get_value(nir, Opts, 0.60)),
        swir = float(proplists:get_value(swir, Opts, 0.25)),
        tir_k = float(proplists:get_value(tir_k, Opts, 295.0)),
        cloud_fraction = float(proplists:get_value(cloud_fraction, Opts, 0.05))
    }.

-spec swath_width_km(float(), float()) -> float().
swath_width_km(AltKm, FovDeg) ->
    %% Swath = 2 * h * tan(FOV / 2)
    HalfFovRad = (FovDeg * 0.5) * ?DEG_TO_RAD,
    2.0 * AltKm * math:tan(HalfFovRad).

-spec acquire_frame(non_neg_integer(), float(), float(), float(), integer()) -> multispectral_frame().
acquire_frame(FrameId, LatDeg, LonDeg, AltKm, Timestamp) ->
    %% Simulate reflectance based on surface type
    IsLand = (abs(LatDeg) < 70.0 andalso (abs(LonDeg) < 60.0 orelse (LatDeg > 15.0 andalso LonDeg >= -130.0 andalso LonDeg =< -60.0))),
    {Red, Green, Blue, NIR, SWIR} = case IsLand of
        true ->
            % Dense vegetation: high NIR, low Red
            {0.08, 0.18, 0.12, 0.65, 0.22};
        false ->
            % Ocean water: very low NIR, moderate Blue/Green
            {0.05, 0.12, 0.25, 0.02, 0.01}
    end,
    #multispectral_frame{
        frame_id = FrameId,
        timestamp = Timestamp,
        target_lat = LatDeg,
        target_lon = LonDeg,
        alt_km = AltKm,
        blue = Blue,
        green = Green,
        red = Red,
        nir = NIR,
        swir = SWIR,
        tir_k = 293.15,
        cloud_fraction = 0.08
    }.

-spec compute_ndvi(float(), float()) -> float().
compute_ndvi(Red, NIR) ->
    %% NDVI = (NIR - Red) / (NIR + Red)
    Denom = NIR + Red,
    case Denom < 1.0e-9 of
        true -> 0.0;
        false -> (NIR - Red) / Denom
    end.

-spec compute_ndwi(float(), float()) -> float().
compute_ndwi(Green, NIR) ->
    %% NDWI = (Green - NIR) / (Green + NIR)
    Denom = Green + NIR,
    case Denom < 1.0e-9 of
        true -> 0.0;
        false -> (Green - NIR) / Denom
    end.

-spec compute_nbr(float(), float()) -> float().
compute_nbr(NIR, SWIR) ->
    %% NBR = (NIR - SWIR) / (NIR + SWIR)
    Denom = NIR + SWIR,
    case Denom < 1.0e-9 of
        true -> 0.0;
        false -> (NIR - SWIR) / Denom
    end.

-spec frame_to_ccsds(multispectral_frame(), non_neg_integer(), non_neg_integer()) -> binary().
frame_to_ccsds(#multispectral_frame{} = F, APID, SeqCount) ->
    %% Pack calibrated band data into telemetry space packet
    Payload = <<
        (F#multispectral_frame.frame_id):32,
        (round(F#multispectral_frame.target_lat * 10000)):32/signed,
        (round(F#multispectral_frame.target_lon * 10000)):32/signed,
        (round(F#multispectral_frame.alt_km * 10)):32,
        (round(F#multispectral_frame.blue * 10000)):16,
        (round(F#multispectral_frame.green * 10000)):16,
        (round(F#multispectral_frame.red * 10000)):16,
        (round(F#multispectral_frame.nir * 10000)):16,
        (round(F#multispectral_frame.swir * 10000)):16,
        (round(F#multispectral_frame.tir_k * 100)):16,
        (round(F#multispectral_frame.cloud_fraction * 10000)):16
    >>,
    Pkt = #ccsds_packet{
        version = 0,
        type = ?CCSDS_TYPE_TM,
        sec_hdr_flag = 1,
        apid = APID,
        seq_flags = ?CCSDS_SEQ_UNSEGMENTED,
        seq_count = SeqCount,
        data_length = byte_size(Payload) + 4 - 1,
        timestamp = F#multispectral_frame.timestamp,
        payload = Payload
    },
    apogee_spp:encode(Pkt).

-spec frame_to_bundle(multispectral_frame(), binary(), binary()) -> #bpv7_bundle{}.
frame_to_bundle(#multispectral_frame{} = F, SourceEID, DestEID) ->
    NDVI = compute_ndvi(F#multispectral_frame.red, F#multispectral_frame.nir),
    NDWI = compute_ndwi(F#multispectral_frame.green, F#multispectral_frame.nir),
    NBR = compute_nbr(F#multispectral_frame.nir, F#multispectral_frame.swir),
    
    PayloadCBOR = apogee_cbor:encode(#{
        <<"frame_id">> => F#multispectral_frame.frame_id,
        <<"lat">> => F#multispectral_frame.target_lat,
        <<"lon">> => F#multispectral_frame.target_lon,
        <<"alt_km">> => F#multispectral_frame.alt_km,
        <<"ndvi">> => NDVI,
        <<"ndwi">> => NDWI,
        <<"nbr">> => NBR,
        <<"cloud_frac">> => F#multispectral_frame.cloud_fraction
    }),

    #bpv7_bundle{
        version = ?BPV7_VERSION,
        destination = DestEID,
        source = SourceEID,
        report_to = <<"dtn:none">>,
        creation_time = F#multispectral_frame.timestamp,
        sequence_number = F#multispectral_frame.frame_id,
        lifetime_ms = 86400000, % 24 hours
        payload = PayloadCBOR
    }.

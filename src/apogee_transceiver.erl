%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Aerospace Software-Defined Radio (SDR) Transceiver Model.
%%% Simulates S-band (TT&C) and Ka-band (High-Throughput Downlink/ISL):
%%% - Free-space path loss (FSPL) and atmospheric attenuation
%%% - Full link budget calculation (EIRP, G/T, Prx, C/N0, Eb/N0, and link margin)
%%% - Theoretical Bit Error Rate (BER) for BPSK/QPSK/8PSK modulation
%%% - Adaptive Coding and Modulation (ACM) rate selection
%%% - Radio power consumption profiles
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_transceiver).

-include("apogee.hrl").

-export([
    new/0,
    new/1,
    free_space_path_loss_db/2,
    link_budget/6,
    ber_bpsk/1,
    select_acm_mode/1,
    transmit_frame/3,
    power_draw_w/2
]).

-define(BOLTZMANN_CONSTANT_DBW_K_HZ, -228.6). % 10 * log10(1.380649e-23)

-type sdr_config() :: #sdr_config{}.
-export_type([sdr_config/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec new() -> sdr_config().
new() ->
    new(s_band).

-spec new(s_band | ka_band | proplists:proplist()) -> sdr_config().
new(s_band) ->
    #sdr_config{
        rf_band = s_band,
        freq_mhz = 2200.0,
        tx_power_dbw = 10.0,        % 10 Watts
        tx_antenna_gain_dbi = 6.0,  % Patch antenna
        rx_antenna_gain_dbi = 38.0, % 11m Ground Station
        rx_system_temp_k = 150.0,
        pointing_loss_db = 0.5,
        req_eb_n0_db = 4.5
    };
new(ka_band) ->
    #sdr_config{
        rf_band = ka_band,
        freq_mhz = 26500.0,
        tx_power_dbw = 13.0,        % 20 Watts
        tx_antenna_gain_dbi = 32.0, % Steerable parabolic dish
        rx_antenna_gain_dbi = 55.0, % Deep Space Network / High Gain Ground
        rx_system_temp_k = 200.0,
        pointing_loss_db = 1.0,
        req_eb_n0_db = 6.0
    };
new(Opts) when is_list(Opts) ->
    Base = case proplists:get_value(rf_band, Opts, s_band) of
        ka_band -> new(ka_band);
        _ -> new(s_band)
    end,
    Base#sdr_config{
        freq_mhz = float(proplists:get_value(freq_mhz, Opts, Base#sdr_config.freq_mhz)),
        tx_power_dbw = float(proplists:get_value(tx_power_dbw, Opts, Base#sdr_config.tx_power_dbw)),
        tx_antenna_gain_dbi = float(proplists:get_value(tx_antenna_gain_dbi, Opts, Base#sdr_config.tx_antenna_gain_dbi)),
        rx_antenna_gain_dbi = float(proplists:get_value(rx_antenna_gain_dbi, Opts, Base#sdr_config.rx_antenna_gain_dbi))
    }.

-spec free_space_path_loss_db(float(), float()) -> float().
free_space_path_loss_db(DistanceKm, FreqMhz) ->
    %% FSPL(dB) = 20*log10(d) + 20*log10(f) + 32.44
    ClampedDist = max(1.0, DistanceKm),
    20.0 * math:log10(ClampedDist) + 20.0 * math:log10(FreqMhz) + 32.44.

-spec link_budget(sdr_config(), float(), float(), float(), float(), pos_integer()) ->
    #{atom() => float()}.
link_budget(#sdr_config{} = SDR, DistanceKm, ElevationDeg, AtmosphericLossDb, MiscLossDb, DataRateBps) ->
    FreqMhz = SDR#sdr_config.freq_mhz,
    FsplDb = free_space_path_loss_db(DistanceKm, FreqMhz),

    % Atmospheric attenuation depends on elevation
    ElevationFactor = 1.0 / math:sin(max(5.0, ElevationDeg) * ?DEG_TO_RAD),
    EffectiveAtmDb = AtmosphericLossDb * min(5.0, ElevationFactor),

    EirpDbw = SDR#sdr_config.tx_power_dbw + SDR#sdr_config.tx_antenna_gain_dbi,
    TotalLossDb = FsplDb + EffectiveAtmDb + SDR#sdr_config.pointing_loss_db + MiscLossDb,
    PrxDbw = EirpDbw + SDR#sdr_config.rx_antenna_gain_dbi - TotalLossDb,

    % Noise spectral density N0 = k * T
    N0_dbw_hz = ?BOLTZMANN_CONSTANT_DBW_K_HZ + 10.0 * math:log10(SDR#sdr_config.rx_system_temp_k),
    C_N0_db_hz = PrxDbw - N0_dbw_hz,

    % Eb/N0 = C/N0 - 10*log10(Rb)
    DataRateDb = 10.0 * math:log10(float(DataRateBps)),
    EbN0Db = C_N0_db_hz - DataRateDb,
    MarginDb = EbN0Db - SDR#sdr_config.req_eb_n0_db,

    #{
        eirp_dbw => EirpDbw,
        fspl_db => FsplDb,
        total_loss_db => TotalLossDb,
        prx_dbw => PrxDbw,
        c_n0_db_hz => C_N0_db_hz,
        eb_n0_db => EbN0Db,
        margin_db => MarginDb
    }.

-spec ber_bpsk(float()) -> float().
ber_bpsk(EbN0Db) ->
    %% BER = 0.5 * erfc(sqrt(10^(EbN0/10)))
    EbN0Linear = math:pow(10.0, EbN0Db / 10.0),
    0.5 * erfc(math:sqrt(EbN0Linear)).

-spec select_acm_mode(float()) -> {atom(), pos_integer()}.
select_acm_mode(MarginDb) ->
    %% Adaptive Coding and Modulation mode selection
    if
        MarginDb >= 12.0 -> {mod_16apsk, 100000000}; % 100 Mbps
        MarginDb >= 8.0  -> {mod_8psk,   50000000};  % 50 Mbps
        MarginDb >= 4.0  -> {mod_qpsk,   20000000};  % 20 Mbps
        MarginDb >= 1.0  -> {mod_bpsk,   5000000};   % 5 Mbps
        true             -> {mod_robust, 500000}     % 500 kbps robust fallback
    end.

-spec transmit_frame(sdr_config(), binary(), float()) -> {ok, binary()} | {error, link_loss}.
transmit_frame(#sdr_config{}, FrameData, MarginDb) ->
    case MarginDb >= 0.0 of
        true ->
            {ok, FrameData};
        false ->
            {error, link_loss}
    end.

-spec power_draw_w(s_band | ka_band, standby | rx | tx) -> float().
power_draw_w(s_band, standby) -> 1.5;
power_draw_w(s_band, rx) -> 3.5;
power_draw_w(s_band, tx) -> 18.0;
power_draw_w(ka_band, standby) -> 2.5;
power_draw_w(ka_band, rx) -> 6.0;
power_draw_w(ka_band, tx) -> 55.0.

%%====================================================================
%% Internal Helpers
%%====================================================================

erfc(X) when X < 0.0 ->
    2.0 - erfc(-X);
erfc(X) ->
    %% Numerical approximation for complementary error function (Abramowitz and Stegun)
    P = 0.3275911,
    A1 = 0.254829592,
    A2 = -0.284496736,
    A3 = 1.421413741,
    A4 = -1.453152027,
    A5 = 1.061405429,
    T = 1.0 / (1.0 + P * X),
    Poly = T * (A1 + T * (A2 + T * (A3 + T * (A4 + T * A5)))),
    Poly * math:exp(-X * X).

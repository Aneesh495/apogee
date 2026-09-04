%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for SDR transceiver model and link budget.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_transceiver_tests).

-include_lib("eunit/include/eunit.hrl").

fspl_and_link_budget_test() ->
    % S-band at 1000 km, 2200 MHz
    FSPL = apogee_transceiver:free_space_path_loss_db(1000.0, 2200.0),
    % 20*log10(1000) + 20*log10(2200) + 32.44 = 159.29 dB
    ?assert(abs(FSPL - 159.29) < 0.2),

    SDR = apogee_transceiver:new(s_band),
    Budget = apogee_transceiver:link_budget(SDR, 800.0, 45.0, 0.3, 0.5, 1000000),
    
    Margin = maps:get(margin_db, Budget),
    % At 800 km, 45 deg elevation, 1 Mbps, link margin should be comfortably positive (> 10 dB)
    ?assert(Margin > 10.0),
    ?assert(maps:get(prx_dbw, Budget) < 0.0).

ber_and_acm_selection_test() ->
    % High Eb/N0 (10 dB) -> Low BER (< 1e-4)
    BerHigh = apogee_transceiver:ber_bpsk(10.0),
    ?assert(BerHigh < 1.0e-4),

    % Low Eb/N0 (2 dB) -> Higher BER (~0.03)
    BerLow = apogee_transceiver:ber_bpsk(2.0),
    ?assert(BerLow > 0.01 andalso BerLow < 0.08),

    % ACM mode adaptation
    ?assertEqual({mod_16apsk, 100000000}, apogee_transceiver:select_acm_mode(15.0)),
    ?assertEqual({mod_8psk, 50000000}, apogee_transceiver:select_acm_mode(9.0)),
    ?assertEqual({mod_qpsk, 20000000}, apogee_transceiver:select_acm_mode(5.0)),
    ?assertEqual({mod_robust, 500000}, apogee_transceiver:select_acm_mode(-2.0)).

transceiver_power_and_frame_tx_test() ->
    SDR = apogee_transceiver:new(ka_band),
    Frame = <<"CCSDS_CADU_TELEMETRY">>,
    
    % Positive margin -> successful transmission
    ?assertEqual({ok, Frame}, apogee_transceiver:transmit_frame(SDR, Frame, 5.0)),
    % Negative margin -> link loss
    ?assertEqual({error, link_loss}, apogee_transceiver:transmit_frame(SDR, Frame, -1.0)),

    % Power draw validation
    ?assertEqual(18.0, apogee_transceiver:power_draw_w(s_band, tx)),
    ?assertEqual(55.0, apogee_transceiver:power_draw_w(ka_band, tx)),
    ?assertEqual(1.5, apogee_transceiver:power_draw_w(s_band, standby)).

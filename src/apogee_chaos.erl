%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Aerospace Chaos Engine and Radiation Fault Injector.
%%% Simulates hostile orbital space environments:
%%% - Single Event Upsets (SEU) and multi-bit radiation upsets in telemetry
%%% - Solar Particle Events (SPE / CME) solar array and RF degradation
%%% - Atmospheric density drag surges (solar cycle F10.7 flux variation)
%%% - Two-state Gilbert-Elliott Markov burst-loss channel modeling
%%% - Subsystem component faults (reaction wheel seizure, battery cell failure)
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_chaos).

-include("apogee.hrl").

-export([
    inject_seu/2,
    inject_burst_errors/3,
    new_gilbert_elliott/4,
    gilbert_elliott_filter/2,
    solar_storm/2,
    atmospheric_drag_surge/2,
    fail_reaction_wheel/2,
    fail_battery_cell/2,
    inject_gyro_bias/2
]).

-record(ge_channel, {
    state = good :: good | bad,
    p_good_to_bad = 0.01 :: float(),
    p_bad_to_good = 0.10 :: float(),
    loss_rate_good = 0.001 :: float(),
    loss_rate_bad = 0.80 :: float()
}).

-type ge_channel() :: #ge_channel{}.
-export_type([ge_channel/0]).

%%====================================================================
%% API Functions
%%====================================================================

-spec inject_seu(binary(), non_neg_integer()) -> binary().
inject_seu(Data, 0) ->
    Data;
inject_seu(Data, NumFlips) when is_binary(Data), byte_size(Data) > 0, NumFlips > 0 ->
    TotalBits = byte_size(Data) * 8,
    flip_n_bits(Data, NumFlips, TotalBits).

-spec inject_burst_errors(binary(), non_neg_integer(), non_neg_integer()) -> binary().
inject_burst_errors(Data, StartBit, BurstLengthBits) when is_binary(Data) ->
    TotalBits = byte_size(Data) * 8,
    lists:foldl(
        fun(Offset, Acc) ->
            BitIdx = (StartBit + Offset) rem TotalBits,
            flip_single_bit(Acc, BitIdx)
        end,
        Data,
        lists:seq(0, max(0, BurstLengthBits - 1))
    ).

-spec new_gilbert_elliott(float(), float(), float(), float()) -> ge_channel().
new_gilbert_elliott(P_G2B, P_B2G, LossGood, LossBad) ->
    #ge_channel{
        state = good,
        p_good_to_bad = float(P_G2B),
        p_bad_to_good = float(P_B2G),
        loss_rate_good = float(LossGood),
        loss_rate_bad = float(LossBad)
    }.

-spec gilbert_elliott_filter(ge_channel(), [term()]) -> {[term()], ge_channel()}.
gilbert_elliott_filter(#ge_channel{} = Chan, Packets) ->
    lists:foldl(
        fun(Pkt, {Delivered, CurChan}) ->
            {NextChan, Drop} = step_channel(CurChan),
            case Drop of
                true ->
                    {Delivered, NextChan};
                false ->
                    {[Pkt | Delivered], NextChan}
            end
        end,
        {[], Chan},
        Packets
    ).

-spec solar_storm(float(), #eps_state{}) -> #eps_state{}.
solar_storm(StormIntensityKIndex, #eps_state{} = Eps) ->
    %% K-index from 0 to 9. Severe storm (Kp >= 7) degrades solar cell efficiency
    DegradationFactor = max(0.5, 1.0 - (float(StormIntensityKIndex) * 0.04)),
    NewArea = Eps#eps_state.solar_array_area_m2 * DegradationFactor,
    NewTemp = Eps#eps_state.temperature_c + (float(StormIntensityKIndex) * 1.5),
    Eps#eps_state{
        solar_array_area_m2 = NewArea,
        temperature_c = NewTemp,
        mode = case StormIntensityKIndex >= 7.0 of
            true -> degraded;
            false -> Eps#eps_state.mode
        end
    }.

-spec atmospheric_drag_surge(float(), #tle{}) -> #tle{}.
atmospheric_drag_surge(F107SolarFluxRatio, #tle{} = Tle) ->
    %% Solar maximum swells upper thermosphere; increases BSTAR ballistic drag
    NewBstar = Tle#tle.bstar * max(1.0, float(F107SolarFluxRatio)),
    Tle#tle{bstar = NewBstar}.

-spec fail_reaction_wheel(x | y | z, #adcs_state{}) -> #adcs_state{}.
fail_reaction_wheel(Axis, #adcs_state{} = Adcs) ->
    #vector3{x = Wx, y = Wy, z = Wz} = Adcs#adcs_state.wheel_momentum,
    #vector3{x = Rx, y = Ry, z = Rz} = Adcs#adcs_state.wheel_speed_rpm,
    {NewMom, NewRpm} = case Axis of
        x ->
            {apogee_vec3:new(0.0, Wy, Wz), apogee_vec3:new(0.0, Ry, Rz)};
        y ->
            {apogee_vec3:new(Wx, 0.0, Wz), apogee_vec3:new(Rx, 0.0, Rz)};
        z ->
            {apogee_vec3:new(Wx, Wy, 0.0), apogee_vec3:new(Rx, Ry, 0.0)}
    end,
    Adcs#adcs_state{
        wheel_momentum = NewMom,
        wheel_speed_rpm = NewRpm,
        mode = safe_hold
    }.

-spec fail_battery_cell(float(), #eps_state{}) -> #eps_state{}.
fail_battery_cell(CapacityDropWh, #eps_state{} = Eps) ->
    NewCap = max(10.0, Eps#eps_state.battery_capacity_wh - float(CapacityDropWh)),
    NewSoc = min(1.0, Eps#eps_state.battery_soc * (NewCap / Eps#eps_state.battery_capacity_wh)),
    Eps#eps_state{
        battery_capacity_wh = NewCap,
        battery_soc = NewSoc,
        bus_voltage = min(Eps#eps_state.bus_voltage, 24.0)
    }.

-spec inject_gyro_bias(#vector3{}, #adcs_state{}) -> #adcs_state{}.
inject_gyro_bias(#vector3{} = Bias, #adcs_state{} = Adcs) ->
    NewOmega = apogee_vec3:add(Adcs#adcs_state.angular_velocity, Bias),
    Adcs#adcs_state{angular_velocity = NewOmega}.

%%====================================================================
%% Internal Functions
%%====================================================================

flip_n_bits(Data, 0, _TotalBits) ->
    Data;
flip_n_bits(Data, Count, TotalBits) ->
    BitIdx = rand:uniform(TotalBits) - 1,
    Flipped = flip_single_bit(Data, BitIdx),
    flip_n_bits(Flipped, Count - 1, TotalBits).

flip_single_bit(Data, BitIdx) ->
    ByteIdx = BitIdx div 8,
    BitPos = 7 - (BitIdx rem 8),
    <<Pre:ByteIdx/binary, Byte:8, Post/binary>> = Data,
    FlippedByte = Byte bxor (1 bsl BitPos),
    <<Pre/binary, FlippedByte:8, Post/binary>>.

step_channel(#ge_channel{state = good} = Chan) ->
    %% Check transition to bad
    NewState = case rand:uniform() < Chan#ge_channel.p_good_to_bad of
        true -> bad;
        false -> good
    end,
    Drop = rand:uniform() < Chan#ge_channel.loss_rate_good,
    {Chan#ge_channel{state = NewState}, Drop};

step_channel(#ge_channel{state = bad} = Chan) ->
    %% Check transition to good
    NewState = case rand:uniform() < Chan#ge_channel.p_bad_to_good of
        true -> good;
        false -> bad
    end,
    Drop = rand:uniform() < Chan#ge_channel.loss_rate_bad,
    {Chan#ge_channel{state = NewState}, Drop}.

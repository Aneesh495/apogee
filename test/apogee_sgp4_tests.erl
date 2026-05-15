%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_sgp4 propagator
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_sgp4_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

iss_propagation_test() ->
    L1 = "1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927",
    L2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537",
    {ok, Tle} = apogee_tle:parse_lines("ISS (ZARYA)", L1, L2),
    Model = apogee_sgp4:init_elements(Tle),

    %% Propagate at epoch (0 minutes)
    State0 = apogee_sgp4:propagate_minutes(Model, 0.0),
    R0 = apogee_vec3:norm(State0#orbit_state.pos),
    V0 = apogee_vec3:norm(State0#orbit_state.vel),
    ?assert(R0 > 6700.0 andalso R0 < 6850.0),
    ?assert(V0 > 7.5 andalso V0 < 7.8),

    %% Propagate 45 minutes (approx half orbit)
    State45 = apogee_sgp4:propagate_minutes(Model, 45.0),
    R45 = apogee_vec3:norm(State45#orbit_state.pos),
    V45 = apogee_vec3:norm(State45#orbit_state.vel),
    ?assert(R45 > 6700.0 andalso R45 < 6850.0),
    ?assert(V45 > 7.5 andalso V45 < 7.8),

    %% Dot product of R0 and R45 should be negative (opposite side of Earth)
    DotPos = apogee_vec3:dot(State0#orbit_state.pos, State45#orbit_state.pos),
    ?assert(DotPos < 0.0),

    %% Propagate 1 full orbit (~91.6 minutes)
    PeriodMin = (2.0 * ?PI / (Tle#tle.mean_motion * 60.0)),
    StateOrbit = apogee_sgp4:propagate_minutes(Model, PeriodMin),
    ROrbit = apogee_vec3:norm(StateOrbit#orbit_state.pos),
    ?assert(abs(ROrbit - R0) < 50.0).

kepler_solver_test() ->
    Eanom = apogee_sgp4:solve_kepler(0.5, 0.1),
    %% Check Kepler relation: M = E - e*sin(E)
    MCalc = Eanom - 0.1 * math:sin(Eanom),
    ?assert(abs(MCalc - 0.5) < 1.0e-9).

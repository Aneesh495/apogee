%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for apogee_cli.
%%%-------------------------------------------------------------------
-module(apogee_cli_tests).

-include_lib("eunit/include/eunit.hrl").

banner_test() ->
    Banner = apogee_cli:banner(),
    ?assert(is_list(Banner)),
    ?assert(string:find(Banner, "APOGEE") =/= nomatch).

command_parsing_test() ->
    ?assertEqual({ok, {help, []}}, apogee_cli:parse_command("help")),
    ?assertEqual({ok, {version, []}}, apogee_cli:parse_command("version\n")),
    ?assertEqual({ok, {status, []}}, apogee_cli:parse_command("  status  ")),
    ?assertEqual({ok, {send_bundle, ["ipn:2.1", "hello_earth"]}},
                 apogee_cli:parse_command("send-bundle ipn:2.1 hello_earth")),
    ?assertEqual({ok, {inject_seu, ["3"]}}, apogee_cli:parse_command("inject-seu 3")),
    ?assertEqual({ok, {exit, []}}, apogee_cli:parse_command("exit")),
    ?assertEqual({ok, {exit, []}}, apogee_cli:parse_command("quit")),
    ?assertEqual({ok, {empty, []}}, apogee_cli:parse_command("   ")),
    ?assertEqual({error, {unknown_command, "bogus"}}, apogee_cli:parse_command("bogus")).

command_eval_test() ->
    State0 = #{mode => nominal, battery_soc => 0.90, bus_voltage => 28.0},
    
    %% Status
    {{ok, StatusStr}, State0} = apogee_cli:eval_command({status, []}, State0),
    ?assert(string:find(StatusStr, "nominal") =/= nomatch),
    ?assert(string:find(StatusStr, "28.0 V") =/= nomatch),

    %% Orbit
    {{ok, OrbitStr}, State0} = apogee_cli:eval_command({orbit, []}, State0),
    ?assert(string:find(OrbitStr, "Altitude:") =/= nomatch),

    %% Send bundle
    {{ok, BundleStr}, State1} = apogee_cli:eval_command({send_bundle, ["ipn:9.1", "payload_test"]}, State0),
    ?assert(string:find(BundleStr, "Enqueued BPv7 bundle") =/= nomatch),
    ?assertEqual(1, maps:get(bundle_count, State1)),

    %% Help
    {{ok, HelpStr}, _} = apogee_cli:eval_command({help, []}, State0),
    ?assert(string:find(HelpStr, "Available Spacecraft Commands") =/= nomatch),

    %% FDIR
    {{ok, FdirStr}, _} = apogee_cli:eval_command({fdir, []}, State0),
    ?assert(string:find(FdirStr, "NOMINAL") =/= nomatch),

    %% Exit
    {{ok, exit}, _} = apogee_cli:eval_command({exit, []}, State0).

response_formatting_test() ->
    ?assertEqual("hello\n", apogee_cli:format_response({ok, "hello"})),
    ?assertEqual("ERROR: something failed\n", apogee_cli:format_response({error, "something failed"})),
    ?assert(string:find(apogee_cli:format_response({ok, exit}), "Terminating") =/= nomatch).

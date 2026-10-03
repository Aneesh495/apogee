%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Escript Command-Line Executable Entrypoint.
%%% Launcher for batch ephemeris computations, bundle encoding, constellation
%%% simulation passes, and interactive operator sessions.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_escript).

-export([main/1]).

-spec main([string()]) -> no_return().
main([]) ->
    io:format("~s\n", [apogee_cli:banner()]),
    io:format("Usage: apogee <subcommand> [args...]\n\n"),
    io:format("Subcommands:\n"),
    io:format("  orbit                          Propagate orbit state vector\n"),
    io:format("  bundle <dest> <payload>        Construct and inspect BPv7 bundle\n"),
    io:format("  dashboard                      Render mission control terminal\n"),
    io:format("  sim [duration_s]               Run accelerated constellation simulation\n"),
    io:format("  shell                          Start interactive operator shell\n"),
    io:format("  version                        Print version information\n"),
    io:format("  help                           Show operator help\n"),
    erlang:halt(0);

main(["help"]) ->
    main([]);

main(["version"]) ->
    io:format("apogee v1.0.0 (erts-17.1, Erlang/OTP 29) [64-bit]\n"),
    erlang:halt(0);

main(["orbit"]) ->
    {Res, _} = apogee_cli:eval_command({orbit, []}, #{}),
    io:format("~s", [apogee_cli:format_response(Res)]),
    erlang:halt(0);

main(["bundle", Dest, Payload]) ->
    {Res, _} = apogee_cli:eval_command({send_bundle, [Dest, Payload]}, #{}),
    io:format("~s", [apogee_cli:format_response(Res)]),
    erlang:halt(0);

main(["dashboard"]) ->
    {Res, _} = apogee_cli:eval_command({dashboard, []}, #{}),
    io:format("~s\n", [apogee_cli:format_response(Res)]),
    erlang:halt(0);

main(["sim" | _Rest]) ->
    io:format("Initializing Walker-Delta Constellation (12/3/1 @ 550 km)...\n"),
    Sats = apogee_constellation:generate_walker_delta(12, 3, 1, 550.0, 53.0),
    io:format("Generated ~B spacecraft in 3 orbital planes.\n", [length(Sats)]),
    EpochJD = apogee_tle:epoch_to_jd(2026, 1.0),
    States = apogee_constellation:propagate_constellation(Sats, EpochJD),
    Links = apogee_constellation:compute_crosslinks(States, 5000.0),
    io:format("Active Inter-Satellite Links (ISL): ~B bidirectional channels.\n", [length(Links)]),
    NodeIds = [Id || {Id, _} <- States],
    Metrics = apogee_constellation:network_metrics(NodeIds, Links),
    io:format("Constellation Network Diameter: ~p hops | Avg Degree: ~.2f\n",
              [maps:get(diameter, Metrics), maps:get(avg_degree, Metrics)]),
    io:format("Simulation step complete. Orbit ops nominal.\n"),
    erlang:halt(0);

main(["shell"]) ->
    io:format("~s\n", [apogee_cli:banner()]),
    io:format("Type 'help' for instructions, 'exit' to quit.\n\n"),
    run_shell(#{
        sat_name => "APOGEE-1",
        mode => nominal,
        battery_soc => 0.92,
        bus_voltage => 28.2
    });

main([Unknown | _]) ->
    io:format("apogee: unknown subcommand '~s'. Run 'apogee help' for usage.\n", [Unknown]),
    erlang:halt(1).

run_shell(State) ->
    case io:get_line("apogee> ") of
        eof ->
            io:format("\nSession closed.\n"),
            erlang:halt(0);
        Line ->
            case apogee_cli:parse_command(Line) of
                {ok, {exit, _}} ->
                    io:format("Terminating operator session. Orbit ops nominal.\n"),
                    erlang:halt(0);
                {ok, Cmd} ->
                    {Res, NewState} = apogee_cli:eval_command(Cmd, State),
                    io:format("~s", [apogee_cli:format_response(Res)]),
                    run_shell(NewState);
                {error, Reason} ->
                    io:format("~s", [apogee_cli:format_response({error, Reason})]),
                    run_shell(State)
            end
    end.

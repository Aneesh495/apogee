CC ?= cc
CFLAGS ?= -O3 -Wall -Wextra -std=c99 -pedantic

all: compile c_tool escript

compile:
	rebar3 compile

test: eunit

eunit:
	rebar3 eunit

escript:
	rebar3 escriptize

c_tool:
	@mkdir -p bin
	$(CC) $(CFLAGS) c_src/apogee_packet_gen.c -o bin/apogee_packet_gen

clean:
	rebar3 clean
	rm -rf bin/

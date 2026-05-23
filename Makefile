# Makefile driven by elixir_make. Builds the rnnoise NIF into priv/.
#
# elixir_make sets MIX_APP_PATH; we fall back to "." so `make` also works
# standalone for quick testing.

MIX_APP_PATH ?= .
PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_SO   = $(PRIV_DIR)/rnnoise_nif.so

CC ?= cc

# erl_nif.h lives in the ERTS include dir; derive it from the running erl.
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval \
	'io:format("~ts/erts-~ts/include/", [code:root_dir(), erlang:system_info(version)])' \
	-s init stop)

C_SRC       = c_src
RNNOISE_DIR = $(C_SRC)/rnnoise

# rnnoise builds with -ffast-math disabled (it #errors out); plain -O3 is what
# upstream uses. OPTIMIZE is overridable, e.g. OPTIMIZE="-O3 -march=native".
OPTIMIZE ?= -O3

CFLAGS += $(OPTIMIZE) -fPIC -std=c11 -DUSE_WEIGHTS_FILE \
	-I$(ERTS_INCLUDE_DIR) \
	-I$(RNNOISE_DIR)/include \
	-I$(RNNOISE_DIR)/src

SOURCES = \
	$(C_SRC)/rnnoise_nif.c \
	$(RNNOISE_DIR)/src/denoise.c \
	$(RNNOISE_DIR)/src/rnn.c \
	$(RNNOISE_DIR)/src/pitch.c \
	$(RNNOISE_DIR)/src/kiss_fft.c \
	$(RNNOISE_DIR)/src/celt_lpc.c \
	$(RNNOISE_DIR)/src/nnet.c \
	$(RNNOISE_DIR)/src/nnet_default.c \
	$(RNNOISE_DIR)/src/parse_lpcnet_weights.c \
	$(RNNOISE_DIR)/src/rnnoise_data.c \
	$(RNNOISE_DIR)/src/rnnoise_tables.c

HEADERS = $(wildcard $(RNNOISE_DIR)/src/*.h) \
	$(wildcard $(RNNOISE_DIR)/src/x86/*.h) \
	$(RNNOISE_DIR)/include/rnnoise.h

# Pick link flags by *target* OS so cross-compiled precompiler builds work too.
# cc_precompiler sets CC_PRECOMPILER_CURRENT_TARGET (a triple); fall back to uname.
TARGET := $(CC_PRECOMPILER_CURRENT_TARGET)
UNAME_S := $(shell uname -s)

ifneq (,$(findstring darwin,$(TARGET)))
	LDFLAGS += -dynamiclib -undefined dynamic_lookup
else ifneq (,$(findstring linux,$(TARGET)))
	LDFLAGS += -shared
else ifeq ($(UNAME_S),Darwin)
	LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
	LDFLAGS += -shared
endif
LDFLAGS += -lm

all: $(NIF_SO)

$(NIF_SO): $(SOURCES) $(HEADERS)
	@mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) $(SOURCES) $(LDFLAGS) -o $@

clean:
	rm -f $(NIF_SO)

.PHONY: all clean

# Builds the port programs into the app's priv directory: nano_kvm_video
# (V4L2 capture with the JPEG and H.264 encoders) and nano_kvm_audio (ALSA
# capture). elixir_make sets MIX_APP_PATH; Nerves sets CC, CFLAGS and LDFLAGS
# for the target.
#
# They need Linux headers: on other hosts (macOS) nothing is built, so that
# the Elixir code still compiles and its tests run there. nano_kvm_audio is
# also left out where the ALSA headers are missing.
#
# The library has no priv directory in its source, so priv here is a real
# directory per build (host, target) and never a link into the sources.

PREFIX = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/obj

CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -std=gnu11

PROGRAMS = $(PREFIX)/nano_kvm_video
ifeq ($(shell $(CC) $(CFLAGS) -E -include alsa/asoundlib.h -x c /dev/null >/dev/null 2>&1 && echo yes),yes)
PROGRAMS += $(PREFIX)/nano_kvm_audio
endif

ifeq ($(CROSSCOMPILE)$(shell uname -s),Darwin)
all:
	@echo "nano_kvm: skipping the port programs (they need Linux)"
else
all: $(PROGRAMS)
endif

$(PREFIX)/nano_kvm_video: $(BUILD)/nano_kvm_video.o
	@mkdir -p $(PREFIX)
	$(CC) $(LDFLAGS) -o $@ $^ -lpthread

$(PREFIX)/nano_kvm_audio: $(BUILD)/nano_kvm_audio.o
	@mkdir -p $(PREFIX)
	$(CC) $(LDFLAGS) -o $@ $^ -lasound -lm

$(BUILD)/%.o: c_src/%.c c_src/v4l2_h264_enc.h Makefile
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	$(RM) $(PREFIX)/nano_kvm_video $(PREFIX)/nano_kvm_audio $(BUILD)/*.o

.PHONY: all clean

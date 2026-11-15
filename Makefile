# Builds the programs into the app's priv directory: nano_kvm_go_video
# (V4L2 capture with the JPEG and H.264 encoders), nano_kvm_go_audio (ALSA
# capture), nano_kvm_go_playback (ALSA playback) and nano_kvm_go_edid (the
# EDID of the video input). elixir_make sets MIX_APP_PATH; Nerves sets CC,
# CFLAGS and LDFLAGS for the target.
#
# They need Linux headers: on other hosts (macOS) nothing is built, so that
# the Elixir code still compiles and its tests run there. The ALSA programs
# are also left out where the ALSA headers are missing.
#
# The library has no priv directory in its source, so priv here is a real
# directory per build (host, target) and never a link into the sources.

PREFIX = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/obj

CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -std=gnu11

PROGRAMS = $(PREFIX)/nano_kvm_go_video $(PREFIX)/nano_kvm_go_edid
ifeq ($(shell $(CC) $(CFLAGS) -E -include alsa/asoundlib.h -x c /dev/null >/dev/null 2>&1 && echo yes),yes)
PROGRAMS += $(PREFIX)/nano_kvm_go_audio $(PREFIX)/nano_kvm_go_playback
endif

ifeq ($(CROSSCOMPILE)$(shell uname -s),Darwin)
all:
	@echo "nano_kvm_go: skipping the port programs (they need Linux)"
else
all: $(PROGRAMS)
endif

$(PREFIX)/nano_kvm_go_video: $(BUILD)/nano_kvm_go_video.o
	@mkdir -p $(PREFIX)
	$(CC) $(LDFLAGS) -o $@ $^ -lpthread

$(PREFIX)/nano_kvm_go_edid: $(BUILD)/nano_kvm_go_edid.o
	@mkdir -p $(PREFIX)
	$(CC) $(LDFLAGS) -o $@ $^

$(PREFIX)/nano_kvm_go_audio: $(BUILD)/nano_kvm_go_audio.o
	@mkdir -p $(PREFIX)
	$(CC) $(LDFLAGS) -o $@ $^ -lasound -lm

$(PREFIX)/nano_kvm_go_playback: $(BUILD)/nano_kvm_go_playback.o
	@mkdir -p $(PREFIX)
	$(CC) $(LDFLAGS) -o $@ $^ -lasound -lm

$(BUILD)/%.o: c_src/%.c c_src/v4l2_h264_enc.h c_src/nano_kvm_go_alsa.h Makefile
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	$(RM) $(PROGRAMS) $(PREFIX)/nano_kvm_go_audio $(PREFIX)/nano_kvm_go_playback \
		$(BUILD)/*.o

.PHONY: all clean

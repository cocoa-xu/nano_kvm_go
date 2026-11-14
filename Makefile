# Builds the nano_kvm_video port program (V4L2 capture with the JPEG and
# H.264 encoders) into the app's priv directory. elixir_make sets
# MIX_APP_PATH; Nerves sets CC, CFLAGS and LDFLAGS for the target.
#
# The program needs the Linux V4L2 headers: on other hosts (macOS) nothing is
# built, so that the Elixir code still compiles and its tests run there.
#
# The library has no priv directory in its source, so priv here is a real
# directory per build (host, target) and never a link into the sources.

PREFIX = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/obj

CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -std=gnu11
LDLIBS += -lpthread

ifeq ($(CROSSCOMPILE)$(shell uname -s),Darwin)
all:
	@echo "nano_kvm: skipping nano_kvm_video (needs Linux)"
else
all: $(PREFIX)/nano_kvm_video
endif

$(PREFIX)/nano_kvm_video: $(BUILD)/nano_kvm_video.o
	@mkdir -p $(PREFIX)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(BUILD)/nano_kvm_video.o: c_src/nano_kvm_video.c c_src/v4l2_h264_enc.h Makefile
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	$(RM) $(PREFIX)/nano_kvm_video $(BUILD)/nano_kvm_video.o

.PHONY: all clean

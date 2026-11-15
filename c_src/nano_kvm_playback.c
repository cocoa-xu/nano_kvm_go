// SPDX-License-Identifier: Apache-2.0
/*
 * nano_kvm_playback: ALSA playback of the PCM an Erlang port sends, for the
 * microphone the target computer sees on the USB audio function.
 *
 * Usage: nano_kvm_playback <pcm> <rate> <channels> <period-frames>
 *
 * stdin carries {packet, 4} frames of interleaved signed 16-bit little
 * endian PCM. The stream keeps running: without samples the program plays
 * silence, so that the target hears a steady microphone, and it drops the
 * oldest samples when more than MAX_DELAY_MS wait, so that the sound never
 * lags behind. stdout carries {packet, 4} log lines (type 0). The end of
 * stdin stops the program.
 */
#include <alsa/asoundlib.h>
#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_DELAY_MS 200
/* Periods kept queued in the device. */
#define QUEUED_PERIODS 2

static void write_all(const void *data, size_t len)
{
	const char *p = data;

	while (len) {
		ssize_t w = write(STDOUT_FILENO, p, len);

		if (w < 0 && errno == EINTR)
			continue;
		if (w <= 0)
			exit(0);	/* the port is gone */
		p += w;
		len -= w;
	}
}

static void logline(const char *fmt, ...)
{
	char line[256];
	uint32_t size;
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(line + 1, sizeof(line) - 1, fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	if ((size_t)n > sizeof(line) - 2)
		n = sizeof(line) - 2;
	line[0] = 0;	/* type: log */
	size = htonl(n + 1);
	write_all(&size, sizeof(size));
	write_all(line, n + 1);
}

static void die(const char *what, int err)
{
	logline("%s: %s", what, snd_strerror(err));
	exit(1);
}

/* Samples waiting to be played, a ring of bytes. */
struct ring {
	uint8_t *data;
	size_t size, head, len;
};

static void ring_put(struct ring *r, const uint8_t *p, size_t n)
{
	if (n > r->size) {	/* keep the newest */
		p += n - r->size;
		n = r->size;
	}
	if (r->len + n > r->size) {	/* drop the oldest */
		size_t drop = r->len + n - r->size;

		r->head = (r->head + drop) % r->size;
		r->len -= drop;
	}
	for (size_t i = 0; i < n; i++)
		r->data[(r->head + r->len + i) % r->size] = p[i];
	r->len += n;
}

static size_t ring_get(struct ring *r, uint8_t *p, size_t n)
{
	if (n > r->len)
		n = r->len;
	for (size_t i = 0; i < n; i++)
		p[i] = r->data[(r->head + i) % r->size];
	r->head = (r->head + n) % r->size;
	r->len -= n;
	return n;
}

/* Reassembles the {packet, 4} frames read from stdin. */
struct packets {
	uint8_t header[4];
	size_t have;	/* bytes of the header, then of the payload */
	uint32_t length;
	int in_payload;
};

static void feed(struct packets *pk, struct ring *r, const uint8_t *p, size_t n)
{
	while (n) {
		if (!pk->in_payload) {
			pk->header[pk->have++] = *p++;
			n--;
			if (pk->have == 4) {
				pk->length = (uint32_t)pk->header[0] << 24 | pk->header[1] << 16 |
					     pk->header[2] << 8 | pk->header[3];
				pk->have = 0;
				pk->in_payload = pk->length > 0;
			}
		} else {
			size_t take = pk->length - pk->have;

			if (take > n)
				take = n;
			ring_put(r, p, take);
			p += take;
			n -= take;
			pk->have += take;
			if (pk->have == pk->length) {
				pk->have = 0;
				pk->in_payload = 0;
			}
		}
	}
}

static snd_pcm_t *open_playback(const char *name, unsigned int *rate, unsigned int channels,
				snd_pcm_uframes_t *period, snd_pcm_uframes_t *buffer)
{
	snd_pcm_hw_params_t *hw;
	snd_pcm_sw_params_t *sw;
	snd_pcm_t *pcm;
	int err;

	*buffer = *period * 4;
	err = snd_pcm_open(&pcm, name, SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK);
	if (err < 0)
		die("open", err);

	snd_pcm_hw_params_alloca(&hw);
	if ((err = snd_pcm_hw_params_any(pcm, hw)) < 0 ||
	    (err = snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0 ||
	    (err = snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_S16_LE)) < 0 ||
	    (err = snd_pcm_hw_params_set_channels(pcm, hw, channels)) < 0 ||
	    (err = snd_pcm_hw_params_set_rate_near(pcm, hw, rate, NULL)) < 0 ||
	    (err = snd_pcm_hw_params_set_period_size_near(pcm, hw, period, NULL)) < 0 ||
	    (err = snd_pcm_hw_params_set_buffer_size_near(pcm, hw, buffer)) < 0 ||
	    (err = snd_pcm_hw_params(pcm, hw)) < 0)
		die("hw params", err);

	snd_pcm_sw_params_alloca(&sw);
	if ((err = snd_pcm_sw_params_current(pcm, sw)) < 0 ||
	    (err = snd_pcm_sw_params_set_start_threshold(pcm, sw, *period)) < 0 ||
	    (err = snd_pcm_sw_params_set_avail_min(pcm, sw, *period)) < 0 ||
	    (err = snd_pcm_sw_params(pcm, sw)) < 0)
		die("sw params", err);

	return pcm;
}

int main(int argc, char **argv)
{
	snd_pcm_uframes_t period, buffer;
	unsigned int rate, channels;
	struct packets pk = { 0 };
	struct ring ring = { 0 };
	size_t frame_bytes;
	uint8_t *chunk;
	snd_pcm_t *pcm;

	if (argc != 5) {
		fprintf(stderr, "usage: %s <pcm> <rate> <channels> <period-frames>\n", argv[0]);
		return 2;
	}
	rate = strtoul(argv[2], NULL, 10);
	channels = strtoul(argv[3], NULL, 10);
	period = strtoul(argv[4], NULL, 10);
	if (!rate || !channels || !period)
		return 2;

	pcm = open_playback(argv[1], &rate, channels, &period, &buffer);
	frame_bytes = channels * sizeof(int16_t);
	ring.size = (size_t)rate * MAX_DELAY_MS / 1000 * frame_bytes;
	ring.data = malloc(ring.size);
	chunk = malloc(period * frame_bytes);
	if (!ring.data || !chunk)
		return 1;

	for (;;) {
		struct pollfd in = { .fd = STDIN_FILENO, .events = POLLIN };
		snd_pcm_sframes_t avail;
		int timeout = period * 1000 / rate / 2;

		if (poll(&in, 1, timeout) < 0 && errno != EINTR)
			return 1;
		if (in.revents) {
			uint8_t buf[4096];
			ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));

			if (n <= 0)
				return 0;	/* the port is gone */
			feed(&pk, &ring, buf, n);
		}

		/* Keep a couple of periods queued: samples if there are, else silence. */
		while ((avail = snd_pcm_avail_update(pcm)) >= 0 &&
		       buffer - avail < QUEUED_PERIODS * period && avail >= (snd_pcm_sframes_t)period) {
			size_t got = ring_get(&ring, chunk, (ring.len / frame_bytes < period ?
							     ring.len / frame_bytes : period) * frame_bytes);
			snd_pcm_sframes_t w;

			memset(chunk + got, 0, period * frame_bytes - got);
			w = snd_pcm_writei(pcm, chunk, period);
			if (w == -EAGAIN)
				break;
			if (w < 0) {
				logline("write: %s, recovering", snd_strerror(w));
				if (snd_pcm_recover(pcm, w, 1) < 0)
					die("recover", w);
			}
		}
		if (avail < 0) {
			logline("avail: %s, recovering", snd_strerror(avail));
			if (snd_pcm_recover(pcm, avail, 1) < 0)
				die("recover", avail);
		}
	}
}

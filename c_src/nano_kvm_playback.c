// SPDX-License-Identifier: Apache-2.0
/*
 * nano_kvm_playback: ALSA playback of the PCM an Erlang port sends, for the
 * microphone the target computer sees on the USB audio function.
 *
 * Usage: nano_kvm_playback <pcm> <period-ms>
 *
 * The program plays in the device's own format: the channels and sample
 * format the USB audio function has, at the rate the target chose. It
 * reports that format on stdout, and again when the target chooses another
 * rate (the card's "Playback Rate" control), as "<rate> <channels>
 * <format>", the format named as ALSA names it (S16_LE, S24_3LE, S32_LE).
 * The samples take the volume and mute the target sets.
 *
 * stdin carries {packet, 4} frames of interleaved PCM in that format. The
 * stream keeps running: without samples the program plays silence, so that
 * the target hears a steady microphone, and it drops the oldest samples
 * when more than MAX_DELAY_MS wait, so that the sound never lags behind.
 * stdout carries {packet, 4} frames of a type byte and a payload: 0 a log
 * line, 2 the format. The end of stdin stops the program.
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

#include "nano_kvm_alsa.h"

enum { PKT_LOG = 0, PKT_FORMAT = 2 };

#define MAX_DELAY_MS 200
/* Periods kept queued in the device. */
#define QUEUED_PERIODS 2
#define MAX_FDS 8

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

static void packet(int type, const void *data, size_t len)
{
	uint32_t size = htonl(len + 1);
	uint8_t t = type;

	write_all(&size, sizeof(size));
	write_all(&t, 1);
	write_all(data, len);
}

static void logline(const char *fmt, ...)
{
	char line[256];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	packet(PKT_LOG, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1);
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

/* The sample formats of the USB audio function: 16, 24 and 32 bits. */
static const snd_pcm_format_t formats[] = {
	SND_PCM_FORMAT_S16_LE, SND_PCM_FORMAT_S24_3LE, SND_PCM_FORMAT_S32_LE,
};

struct stream {
	snd_pcm_t *pcm;
	snd_pcm_format_t format;
	unsigned int rate, channels;
	snd_pcm_uframes_t period, buffer;
	size_t frame_bytes;
	uint8_t *chunk;
	struct ring ring;
};

/* Opens the device in its own format, the one it allows. */
static void open_stream(struct stream *s, const char *name, unsigned int period_ms)
{
	snd_pcm_hw_params_t *hw;
	snd_pcm_sw_params_t *sw;
	size_t i;
	int err;

	err = snd_pcm_open(&s->pcm, name, SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK);
	if (err < 0)
		die("open", err);

	snd_pcm_hw_params_alloca(&hw);
	if ((err = snd_pcm_hw_params_any(s->pcm, hw)) < 0 ||
	    (err = snd_pcm_hw_params_set_access(s->pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0)
		die("hw params", err);

	for (i = 0; i < sizeof(formats) / sizeof(formats[0]); i++)
		if (snd_pcm_hw_params_test_format(s->pcm, hw, formats[i]) == 0)
			break;
	if (i == sizeof(formats) / sizeof(formats[0]))
		die("format", -EINVAL);
	s->format = formats[i];

	if ((err = snd_pcm_hw_params_set_format(s->pcm, hw, s->format)) < 0 ||
	    (err = snd_pcm_hw_params_get_channels_min(hw, &s->channels)) < 0 ||
	    (err = snd_pcm_hw_params_set_channels(s->pcm, hw, s->channels)) < 0 ||
	    (err = snd_pcm_hw_params_get_rate_min(hw, &s->rate, NULL)) < 0 ||
	    (err = snd_pcm_hw_params_set_rate(s->pcm, hw, s->rate, 0)) < 0)
		die("hw params", err);

	s->period = s->rate * period_ms / 1000;
	s->buffer = s->period * 4;
	if ((err = snd_pcm_hw_params_set_period_size_near(s->pcm, hw, &s->period, NULL)) < 0 ||
	    (err = snd_pcm_hw_params_set_buffer_size_near(s->pcm, hw, &s->buffer)) < 0 ||
	    (err = snd_pcm_hw_params(s->pcm, hw)) < 0)
		die("hw params", err);

	snd_pcm_sw_params_alloca(&sw);
	if ((err = snd_pcm_sw_params_current(s->pcm, sw)) < 0 ||
	    (err = snd_pcm_sw_params_set_start_threshold(s->pcm, sw, s->period)) < 0 ||
	    (err = snd_pcm_sw_params_set_avail_min(s->pcm, sw, s->period)) < 0 ||
	    (err = snd_pcm_sw_params(s->pcm, sw)) < 0)
		die("sw params", err);

	s->frame_bytes = s->channels * snd_pcm_format_physical_width(s->format) / 8;
	s->ring.size = (size_t)s->rate * MAX_DELAY_MS / 1000 * s->frame_bytes;
	s->ring.head = s->ring.len = 0;
	s->ring.data = malloc(s->ring.size);
	s->chunk = malloc(s->period * s->frame_bytes);
	if (!s->ring.data || !s->chunk)
		exit(1);
}

static void close_stream(struct stream *s)
{
	snd_pcm_close(s->pcm);
	free(s->ring.data);
	free(s->chunk);
}

static void report_format(const struct stream *s)
{
	char format[64];
	int n = snprintf(format, sizeof(format), "%u %u %s", s->rate, s->channels,
			 snd_pcm_format_name(s->format));

	packet(PKT_FORMAT, format, n);
}

/* Keeps a couple of periods queued: samples if there are, else silence. */
static void fill(struct stream *s, const struct controls *c)
{
	snd_pcm_sframes_t avail;

	while ((avail = snd_pcm_avail_update(s->pcm)) >= 0 &&
	       s->buffer - avail < QUEUED_PERIODS * s->period &&
	       avail >= (snd_pcm_sframes_t)s->period) {
		size_t frames = s->ring.len / s->frame_bytes;
		size_t got = ring_get(&s->ring, s->chunk,
				      (frames < s->period ? frames : s->period) * s->frame_bytes);
		snd_pcm_sframes_t w;

		apply_gain(c, s->format, s->chunk,
			   got / (snd_pcm_format_physical_width(s->format) / 8));
		memset(s->chunk + got, 0, s->period * s->frame_bytes - got);
		w = snd_pcm_writei(s->pcm, s->chunk, s->period);
		if (w == -EAGAIN)
			break;
		if (w < 0) {
			logline("write: %s, recovering", snd_strerror(w));
			if (snd_pcm_recover(s->pcm, w, 1) < 0)
				die("recover", w);
		}
	}
	if (avail < 0) {
		logline("avail: %s, recovering", snd_strerror(avail));
		if (snd_pcm_recover(s->pcm, avail, 1) < 0)
			die("recover", avail);
	}
}

int main(int argc, char **argv)
{
	struct pollfd fds[MAX_FDS];
	struct packets pk = { 0 };
	struct stream s = { 0 };
	struct controls c;
	unsigned int period_ms;
	int nctl = 0;

	if (argc != 3) {
		fprintf(stderr, "usage: %s <pcm> <period-ms>\n", argv[0]);
		return 2;
	}
	period_ms = strtoul(argv[2], NULL, 10);
	if (!period_ms || period_ms > 1000)
		return 2;

	open_stream(&s, argv[1], period_ms);
	report_format(&s);
	if (open_controls(&c, s.pcm, "Playback"))
		nctl = snd_ctl_poll_descriptors(c.ctl, fds + 1, MAX_FDS - 1);

	for (;;) {
		int timeout = period_ms / 2 ? period_ms / 2 : 1;

		fds[0].fd = STDIN_FILENO;
		fds[0].events = POLLIN;
		if (poll(fds, 1 + nctl, timeout) < 0 && errno != EINTR)
			return 1;

		if (fds[0].revents) {
			uint8_t buf[4096];
			ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));

			if (n <= 0)
				return 0;	/* the port is gone */
			feed(&pk, &s.ring, buf, n);
		}

		if (nctl && fds[1].revents) {
			long rate = controls_changed(&c);

			/* The device opens at the rate the target chose. */
			if (rate > 0 && (unsigned long)rate != s.rate) {
				logline("the target takes %ld Hz", rate);
				close_stream(&s);
				open_stream(&s, argv[1], period_ms);
				report_format(&s);
			}
		}

		fill(&s, &c);
	}
}

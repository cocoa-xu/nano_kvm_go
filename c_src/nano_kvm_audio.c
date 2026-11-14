// SPDX-License-Identifier: Apache-2.0
/*
 * nano_kvm_audio: ALSA capture of the HDMI/DisplayPort audio, for an Erlang
 * port.
 *
 * Usage: nano_kvm_audio <pcm> <rate> <channels> <period-frames>
 *
 * stdout carries {packet, 4} frames of a type byte and a payload: 0 a log
 * line, 1 PCM (interleaved signed 16-bit little endian), 2 the format as
 * "<rate> <channels>". The end of stdin stops the program; nothing else
 * comes in on it.
 *
 * The LT7911EXC drives the I2S clocks at the source's own sample rate, which
 * the rate asked for here does not change: the program measures the rate the
 * samples arrive at and reports the format again when it is another one.
 * Without audio from the source no samples arrive, and the program waits.
 */
#include <alsa/asoundlib.h>
#include <arpa/inet.h>
#include <errno.h>
#include <math.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { PKT_LOG, PKT_PCM, PKT_FORMAT };

#define MAX_FDS 8
/* The arrival rate is averaged over this long... */
#define MEASURE_SECONDS 2.0
/* ...and starts over after a pause in the audio. */
#define MAX_GAP_SECONDS 0.25

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

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* The standard rate nearest to a measured one. */
static unsigned int standard_rate(double measured)
{
	static const unsigned int rates[] = {
		32000, 44100, 48000, 88200, 96000, 176400, 192000,
	};
	unsigned int best = rates[0];
	size_t i;

	for (i = 1; i < sizeof(rates) / sizeof(rates[0]); i++)
		if (fabs(measured - rates[i]) < fabs(measured - best))
			best = rates[i];
	return best;
}

struct rate_meter {
	double start;		/* of the window, 0 before the first samples */
	double last;		/* the last samples */
	unsigned long frames;	/* in the window, after its first read */
};

/*
 * Counts frames as they arrive. Returns the standard rate they arrived at
 * over the last window, 0 while a window is not complete yet.
 */
static unsigned int meter_update(struct rate_meter *m, unsigned long frames)
{
	double t = now();
	unsigned int rate = 0;

	if (!m->start || t - m->last > MAX_GAP_SECONDS) {
		m->start = t;
		m->frames = 0;
	} else {
		m->frames += frames;
		if (t - m->start >= MEASURE_SECONDS) {
			rate = standard_rate(m->frames / (t - m->start));
			m->start = t;
			m->frames = 0;
		}
	}
	m->last = t;

	return rate;
}

static void report_format(unsigned int rate, unsigned int channels)
{
	char format[32];

	snprintf(format, sizeof(format), "%u %u", rate, channels);
	packet(PKT_FORMAT, format, strlen(format));
}

static snd_pcm_t *open_capture(const char *name, unsigned int *rate, unsigned int channels,
			       snd_pcm_uframes_t *period)
{
	snd_pcm_uframes_t buffer = *period * 8;
	snd_pcm_hw_params_t *hw;
	snd_pcm_t *pcm;
	int err;

	err = snd_pcm_open(&pcm, name, SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK);
	if (err < 0)
		die("open", err);

	snd_pcm_hw_params_alloca(&hw);
	if ((err = snd_pcm_hw_params_any(pcm, hw)) < 0 ||
	    (err = snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0 ||
	    (err = snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_S16_LE)) < 0 ||
	    (err = snd_pcm_hw_params_set_channels(pcm, hw, channels)) < 0 ||
	    (err = snd_pcm_hw_params_set_rate_near(pcm, hw, rate, NULL)) < 0 ||
	    (err = snd_pcm_hw_params_set_period_size_near(pcm, hw, period, NULL)) < 0 ||
	    (err = snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buffer)) < 0 ||
	    (err = snd_pcm_hw_params(pcm, hw)) < 0)
		die("hw params", err);

	if ((err = snd_pcm_start(pcm)) < 0)
		die("start", err);

	return pcm;
}

int main(int argc, char **argv)
{
	struct pollfd fds[MAX_FDS];
	unsigned int rate, channels;
	snd_pcm_uframes_t period;
	struct rate_meter meter = { 0 };
	int16_t *samples;
	snd_pcm_t *pcm;
	int npcm, err;

	if (argc != 5) {
		fprintf(stderr, "usage: %s <pcm> <rate> <channels> <period-frames>\n", argv[0]);
		return 2;
	}
	rate = strtoul(argv[2], NULL, 10);
	channels = strtoul(argv[3], NULL, 10);
	period = strtoul(argv[4], NULL, 10);
	if (!rate || !channels || !period)
		return 2;

	pcm = open_capture(argv[1], &rate, channels, &period);
	samples = calloc(period * channels, sizeof(*samples));
	if (!samples)
		return 1;
	report_format(rate, channels);

	fds[0].fd = STDIN_FILENO;
	fds[0].events = POLLIN;
	npcm = snd_pcm_poll_descriptors(pcm, fds + 1, MAX_FDS - 1);
	if (npcm < 0)
		die("poll descriptors", npcm);

	for (;;) {
		unsigned short revents;

		if (poll(fds, 1 + npcm, -1) < 0) {
			if (errno == EINTR)
				continue;
			return 1;
		}

		if (fds[0].revents) {
			char drain[64];

			if (read(STDIN_FILENO, drain, sizeof(drain)) <= 0)
				return 0;	/* the port is gone */
		}

		err = snd_pcm_poll_descriptors_revents(pcm, fds + 1, npcm, &revents);
		if (err < 0)
			die("revents", err);
		if (!(revents & POLLIN))
			continue;

		for (;;) {
			snd_pcm_sframes_t n = snd_pcm_readi(pcm, samples, period);
			unsigned int measured;

			if (n == -EAGAIN)
				break;
			if (n < 0) {
				logline("read: %s, recovering", snd_strerror(n));
				if ((err = snd_pcm_recover(pcm, n, 1)) < 0 ||
				    (err = snd_pcm_start(pcm)) < 0)
					die("recover", err);
				break;
			}
			packet(PKT_PCM, samples, n * channels * sizeof(*samples));

			measured = meter_update(&meter, n);
			if (measured && measured != rate) {
				logline("samples arrive at %u Hz", measured);
				rate = measured;
				report_format(rate, channels);
			}
		}
	}
}

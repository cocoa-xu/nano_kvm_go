// SPDX-License-Identifier: Apache-2.0
/*
 * nano_kvm_go_audio: ALSA capture of the HDMI/DisplayPort audio, or of the USB
 * speaker, for an Erlang port.
 *
 * Usage: nano_kvm_go_audio <pcm> <rate> <channels> <period-ms> [<video-device>]
 *
 * stdout carries {packet, 4} frames of a type byte and a payload: 0 a log
 * line, 1 PCM (interleaved), 2 the format as "<rate> <channels> <format>",
 * the sample format named as ALSA names it (S16_LE, S24_3LE, S32_LE). The
 * end of stdin stops the program; nothing else comes in on it.
 *
 * The program takes signed 16-bit samples where the device has them, else
 * its own format, and the channels asked for where the device has them,
 * else its own. The USB audio function fixes its format: the channels and
 * sample size it was set up with, at the rate the target chose, which the
 * card's "Capture Rate" control tells. The program follows that control,
 * and gives the samples the volume and mute the target sets.
 *
 * The LT7911EXC drives the I2S clocks at the source's own sample rate, which
 * the rate asked for here does not change. The bridge reports that rate as
 * the "Audio sampling rate" control of the video capture device: given that
 * device, the program follows the control and reports the format again when
 * it changes. While the control has no rate, the program measures the rate
 * the samples arrive at instead. Without audio from the source no samples
 * arrive, and the program waits.
 */
#include <alsa/asoundlib.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <math.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include "nano_kvm_go_alsa.h"

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

/* In order of preference: 16 bits is what the HDMI audio has. */
static const snd_pcm_format_t formats[] = {
	SND_PCM_FORMAT_S16_LE, SND_PCM_FORMAT_S24_3LE, SND_PCM_FORMAT_S32_LE,
};

struct stream {
	snd_pcm_t *pcm;
	snd_pcm_format_t format;
	unsigned int rate, channels;
	snd_pcm_uframes_t period;
	size_t frame_bytes;
	uint8_t *samples;
};

static void report_format(const struct stream *s)
{
	char format[64];
	int n = snprintf(format, sizeof(format), "%u %u %s", s->rate, s->channels,
			 snd_pcm_format_name(s->format));

	packet(PKT_FORMAT, format, n);
}

/*
 * Opens the video device and subscribes to the bridge's rate control.
 * Returns the device, or -1 when it has no such control.
 */
static int open_rate_control(const char *device)
{
	struct v4l2_query_ext_ctrl q = { .id = V4L2_CTRL_FLAG_NEXT_CTRL };
	int fd = open(device, O_RDWR | O_NONBLOCK);

	if (fd < 0) {
		logline("%s: %s", device, strerror(errno));
		return -1;
	}

	while (ioctl(fd, VIDIOC_QUERY_EXT_CTRL, &q) == 0) {
		if (!strcmp(q.name, "Audio sampling rate")) {
			struct v4l2_event_subscription sub = {
				.type = V4L2_EVENT_CTRL,
				.id = q.id,
				.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL,
			};

			if (ioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0)
				return fd;
			break;
		}
		q.id |= V4L2_CTRL_FLAG_NEXT_CTRL;
	}

	logline("%s: no audio sampling rate control", device);
	close(fd);
	return -1;
}

/* The value in the latest control event, -1 without one. */
static int read_rate_events(int fd)
{
	struct v4l2_event ev;
	int rate = -1;

	while (ioctl(fd, VIDIOC_DQEVENT, &ev) == 0)
		if (ev.type == V4L2_EVENT_CTRL)
			rate = ev.u.ctrl.value;

	return rate;
}

static void open_capture(struct stream *s, const char *name, unsigned int rate,
			 unsigned int channels, unsigned int period_ms)
{
	snd_pcm_uframes_t buffer;
	snd_pcm_hw_params_t *hw;
	size_t i;
	int err;

	err = snd_pcm_open(&s->pcm, name, SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK);
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

	s->channels = channels;
	if (snd_pcm_hw_params_test_channels(s->pcm, hw, channels) < 0 &&
	    (err = snd_pcm_hw_params_get_channels_min(hw, &s->channels)) < 0)
		die("channels", err);

	s->rate = rate;
	if ((err = snd_pcm_hw_params_set_format(s->pcm, hw, s->format)) < 0 ||
	    (err = snd_pcm_hw_params_set_channels(s->pcm, hw, s->channels)) < 0 ||
	    (err = snd_pcm_hw_params_set_rate_near(s->pcm, hw, &s->rate, NULL)) < 0)
		die("hw params", err);

	s->period = s->rate * period_ms / 1000;
	buffer = s->period * 8;
	if ((err = snd_pcm_hw_params_set_period_size_near(s->pcm, hw, &s->period, NULL)) < 0 ||
	    (err = snd_pcm_hw_params_set_buffer_size_near(s->pcm, hw, &buffer)) < 0 ||
	    (err = snd_pcm_hw_params(s->pcm, hw)) < 0)
		die("hw params", err);

	if ((err = snd_pcm_start(s->pcm)) < 0)
		die("start", err);

	s->frame_bytes = s->channels * snd_pcm_format_physical_width(s->format) / 8;
	s->samples = malloc(s->period * s->frame_bytes);
	if (!s->samples)
		exit(1);
}

static void close_capture(struct stream *s)
{
	snd_pcm_close(s->pcm);
	free(s->samples);
}

/* stdin, the bridge's rate control, the card's controls, the PCM. */
static int poll_fds(struct pollfd *fds, int control, const struct controls *c,
		    const struct stream *s, int *nctl, int *npcm)
{
	fds[0].fd = STDIN_FILENO;
	fds[0].events = POLLIN;
	fds[1].fd = control;	/* poll() skips a negative descriptor */
	fds[1].events = POLLPRI;
	*nctl = c->ctl ? snd_ctl_poll_descriptors(c->ctl, fds + 2, MAX_FDS - 2) : 0;
	*npcm = snd_pcm_poll_descriptors(s->pcm, fds + 2 + *nctl, MAX_FDS - 2 - *nctl);
	if (*npcm < 0)
		die("poll descriptors", *npcm);
	return 2 + *nctl + *npcm;
}

int main(int argc, char **argv)
{
	struct pollfd fds[MAX_FDS];
	unsigned int rate, channels, period_ms;
	struct rate_meter meter = { 0 };
	struct stream s = { 0 };
	struct controls c;
	/* The bridge's rate control, and its rate, 0 for none. */
	int control = -1;
	unsigned int bridge_rate = 0;
	int nfds, nctl, npcm, err;

	if (argc != 5 && argc != 6) {
		fprintf(stderr, "usage: %s <pcm> <rate> <channels> <period-ms> [<video-device>]\n",
			argv[0]);
		return 2;
	}
	rate = strtoul(argv[2], NULL, 10);
	channels = strtoul(argv[3], NULL, 10);
	period_ms = strtoul(argv[4], NULL, 10);
	if (!rate || !channels || !period_ms || period_ms > 1000)
		return 2;

	if (argc == 6)
		control = open_rate_control(argv[5]);
	if (control >= 0) {
		/* The subscription sends the current value right away. */
		int reported = read_rate_events(control);

		if (reported > 0)
			rate = bridge_rate = reported;
	}

	open_capture(&s, argv[1], rate, channels, period_ms);
	report_format(&s);
	open_controls(&c, s.pcm, "Capture");
	nfds = poll_fds(fds, control, &c, &s, &nctl, &npcm);

	for (;;) {
		unsigned short revents;

		if (poll(fds, nfds, -1) < 0) {
			if (errno == EINTR)
				continue;
			return 1;
		}

		if (fds[0].revents) {
			char drain[64];

			if (read(STDIN_FILENO, drain, sizeof(drain)) <= 0)
				return 0;	/* the port is gone */
		}

		if (fds[1].revents & POLLPRI) {
			int reported = read_rate_events(control);

			if (reported >= 0)
				bridge_rate = reported;
			if (bridge_rate && bridge_rate != s.rate) {
				logline("the source sends %u Hz", bridge_rate);
				s.rate = bridge_rate;
				report_format(&s);
			}
		}

		if (nctl && fds[2].revents) {
			long chosen = controls_changed(&c);

			/* The device opens at the rate the target chose. */
			if (chosen > 0 && (unsigned long)chosen != s.rate) {
				logline("the target sends %ld Hz", chosen);
				close_capture(&s);
				open_capture(&s, argv[1], chosen, channels, period_ms);
				report_format(&s);
				nfds = poll_fds(fds, control, &c, &s, &nctl, &npcm);
				continue;
			}
		}

		err = snd_pcm_poll_descriptors_revents(s.pcm, fds + 2 + nctl, npcm, &revents);
		if (err < 0)
			die("revents", err);
		if (!(revents & POLLIN))
			continue;

		for (;;) {
			snd_pcm_sframes_t n = snd_pcm_readi(s.pcm, s.samples, s.period);
			unsigned int measured;

			if (n == -EAGAIN)
				break;
			if (n < 0) {
				logline("read: %s, recovering", snd_strerror(n));
				if ((err = snd_pcm_recover(s.pcm, n, 1)) < 0 ||
				    (err = snd_pcm_start(s.pcm)) < 0)
					die("recover", err);
				break;
			}
			apply_gain(&c, s.format, s.samples, n * s.channels);
			packet(PKT_PCM, s.samples, n * s.frame_bytes);

			if (bridge_rate || c.rate)
				continue;
			measured = meter_update(&meter, n);
			if (measured && measured != s.rate) {
				logline("samples arrive at %u Hz", measured);
				s.rate = measured;
				report_format(&s);
			}
		}
	}
}

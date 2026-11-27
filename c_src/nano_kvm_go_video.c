// SPDX-License-Identifier: Apache-2.0
/*
 * nano_kvm_go_video: V4L2 capture -> V4L2 M2M JPEG encoder -> MJPEG over
 * HTTP, and optionally -> V4L2 stateless H.264 or H.265 encoder -> stdout for
 * an Erlang port.
 *
 * Capture buffers are handed to the encoders as DMA-BUFs (no copy); encoded
 * JPEGs are sent straight from the encoder's buffers.
 *
 * Usage: nano_kvm_go_video <capture> <encoder> <port> [quality] [seconds]
 *        nano_kvm_go_video <capture> <encoder> -o <out.jpg> [quality]
 *
 * With KVM_PORT set (run as an Erlang port), stdout carries {packet, 4}
 * frames [type][payload] (type 0 log line, 1 H.264 access unit, 2 H.264
 * keyframe, 3 input: "<width>x<height>@<fps>", "none" or "unsupported",
 * 4 H.265 access unit, 5 H.265 keyframe, 6 snapshot: big-endian 16-bit width
 * and height, then RGB), stdin takes {packet, 4} commands and its end stops
 * the program: "s <x> <y> <width> <height>" asks for a snapshot of that
 * region of the next frame, in the input's pixels. With KVM_ENCODER_DEV=<video encoder
 * device> as well, the commands are "1" start the video stream, "0" stop,
 * "k" make the next frame an IDR, and "e <codec> <rate control> <bit/s> <QP>
 * <keyframe interval> <max fps> <matrix> <range>" the encoding, which
 * KVM_ENCODING gives at the start: codec "h264" or "h265"; rate control
 * "cq" (a constant QP), "cbr" (a constant bitrate) or "vbr" (the QP, more
 * where the bitrate would go over); a keyframe interval in frames; a max
 * fps of 0 for the input's; the colour, "auto", "bt601" or "bt709" and
 * "auto", "full" or "limited". Where the capture converts the colour
 * (V4L2_FMT_FLAG_CSC_*), the HDMI bridge does, "auto" keeping its own choice;
 * elsewhere the colour only labels what the bridge hands over, "auto" being
 * that, BT.709 at full range. The streams and snapshots say what the samples
 * are.
 *
 * KVM_CAPTURE_BUFFERS is how many frames the capture holds, 2 to MAX_CAP,
 * 4 without it: the encoders read them in place, so their memory and the
 * room the encoders have to finish one go together.
 *
 * The program waits for an input it can capture and streams it at its own
 * size; when the input changes it exits with status 3 (EXIT_INPUT_CHANGED),
 * to be started again.
 */
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/media.h>
#include <linux/dma-buf.h>
#include <linux/videodev2.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#include <math.h>

#include "v4l2_stateless_enc.h"

#define MAX_CAP 6
#define NJPEG 4
#define MAX_CLIENTS 8
#define EXIT_INPUT_CHANGED 3

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do
		r = ioctl(fd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

enum { PKT_LOG, PKT_FRAME, PKT_KEYFRAME, PKT_INPUT, PKT_HEVC_FRAME, PKT_HEVC_KEYFRAME, PKT_SNAPSHOT };

static int packet_mode;
static pthread_mutex_t out_lock = PTHREAD_MUTEX_INITIALIZER;

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

static void write_packet(int type, const void *data, size_t len)
{
	unsigned char hdr[5] = { (len + 1) >> 24, (len + 1) >> 16, (len + 1) >> 8, len + 1, type };

	pthread_mutex_lock(&out_lock);
	write_all(hdr, sizeof(hdr));
	write_all(data, len);
	pthread_mutex_unlock(&out_lock);
}

static void logline(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	if (n >= (int)sizeof(line))
		n = sizeof(line) - 1;
	if (packet_mode) {
		write_packet(PKT_LOG, line, n);
	} else {
		pthread_mutex_lock(&out_lock);
		fputs(line, stdout);
		fputc('\n', stdout);
		fflush(stdout);
		pthread_mutex_unlock(&out_lock);
	}
}

static void die(const char *what)
{
	logline("%s: %s", what, strerror(errno));
	exit(1);
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

struct jpeg_buf {
	void *data;
	size_t length;
	size_t used;
	unsigned long gen;	/* content generation, see repeated() */
	int run;		/* frames in a row equal to the one REPEAT back */
};

static struct jpeg_buf jpegs[NJPEG];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int ready = -1;		/* JPEG waiting for the sender */
static int clients[MAX_CLIENTS];
static int fresh[MAX_CLIENTS];	/* gets the next frame even if nothing changed */
static int nclients;
static int nsent;		/* frames sent, for the stats */
static int done_pipe[2];	/* sender -> main: JPEG index to requeue */

/*
 * Frames are sent while the picture changes. A source that dithers (macOS
 * does) repeats its pattern every REPEAT frames, so a frame equal to the one
 * REPEAT frames back shows nothing new. After REPEAT such frames in a row the
 * picture has been the same for 2 * REPEAT frames; the content generation
 * changes with every frame that is not such a repeat, so a client that got a
 * frame of the current generation shows the current picture. New clients get
 * the next frame anyway, everyone one every REFRESH seconds.
 */
#define REPEAT 4
#define REFRESH 10

/* The buffers are uncached: memcpy's burst loads beat word loads by far. */
static uint64_t hash(const void *data, size_t len)
{
	uint64_t chunk[512], h = 0xcbf29ce484222325ull ^ len;
	size_t off, i;

	for (off = 0; off < len; off += sizeof(chunk)) {
		size_t n = len - off < sizeof(chunk) ? len - off : sizeof(chunk);

		memset(chunk, 0, sizeof(chunk));
		memcpy(chunk, (const char *)data + off, n);
		for (i = 0; i < (n + 7) / 8; i++)
			h = (h ^ chunk[i]) * 0x100000001b3ull;
	}
	return h;
}

/*
 * Whether a JPEG equals the last one encoded from a captured frame with the
 * same number modulo REPEAT (the same dither phase), which is the one REPEAT
 * frames back unless frames were dropped in between. Reading a JPEG back
 * costs ~8 ms, so while the picture is quiet only one phase is compared and
 * the others count as repeats if their length is: a change of the same
 * length shows up at most REPEAT - 1 frames late.
 */
static int repeated(const struct jpeg_buf *j, unsigned long frame, int quiet)
{
	static struct {
		size_t len;
		uint64_t hash;
		int hashed;
	} seen[REPEAT];
	int k = frame % REPEAT, same = 0;

	if (seen[k].len == j->used) {
		uint64_t h;

		if (quiet && seen[k].hashed && k)
			return 1;
		h = hash(j->data, j->used);

		same = seen[k].hashed && seen[k].hash == h;
		seen[k].hash = h;
		seen[k].hashed = 1;
	} else {
		seen[k].len = j->used;
		seen[k].hashed = 0;
	}
	return same;
}

static void *sender(void *arg)
{
	static const char part[] = "Content-Type: image/jpeg\r\nContent-Length: %zu\r\n\r\n";
	/* Ends each part, so that browsers show a frame before the next arrives. */
	static const char boundary[] = "\r\n--frame\r\n";
	char hdr[128];
	double last_sent = 0;
	unsigned long sent_gen = 0;

	(void)arg;
	for (;;) {
		int idx, i, fds[MAX_CLIENTS], news[MAX_CLIENTS], n, quiet;

		pthread_mutex_lock(&lock);
		while (ready < 0)
			pthread_cond_wait(&cond, &lock);
		idx = ready;
		ready = -1;
		n = nclients;
		memcpy(fds, clients, sizeof(fds));
		memcpy(news, fresh, sizeof(news));
		memset(fresh, 0, sizeof(fresh));
		pthread_mutex_unlock(&lock);

		quiet = jpegs[idx].run >= REPEAT && jpegs[idx].gen == sent_gen &&
			now() - last_sent < REFRESH;
		if (n && !quiet) {
			last_sent = now();
			sent_gen = jpegs[idx].gen;
			__atomic_add_fetch(&nsent, 1, __ATOMIC_RELAXED);
		}

		for (i = 0; i < n; i++) {
			struct iovec iov[3] = {
				{ hdr, (size_t)snprintf(hdr, sizeof(hdr), part, jpegs[idx].used) },
				{ jpegs[idx].data, jpegs[idx].used },
				{ (void *)boundary, sizeof(boundary) - 1 },
			};
			size_t left = iov[0].iov_len + iov[1].iov_len + iov[2].iov_len;
			struct iovec *v = iov;
			int nv = 3;

			if (quiet && !news[i])
				continue;

			while (left) {
				ssize_t w = writev(fds[i], v, nv);

				if (w <= 0)
					break;
				left -= w;
				while (nv && (size_t)w >= v->iov_len) {
					w -= v->iov_len;
					v++;
					nv--;
				}
				if (nv) {
					v->iov_base = (char *)v->iov_base + w;
					v->iov_len -= w;
				}
			}
			if (left) {
				int k;

				pthread_mutex_lock(&lock);
				for (k = 0; k < nclients; k++)
					if (clients[k] == fds[i]) {
						clients[k] = clients[--nclients];
						fresh[k] = fresh[nclients];
						break;
					}
				pthread_mutex_unlock(&lock);
				close(fds[i]);
			}
		}
		if (write(done_pipe[1], &idx, sizeof(idx)) != sizeof(idx))
			die("write pipe");
	}
	return NULL;
}

/*
 * Whether a request may have the stream: with KVM_MJPEG_TOKEN set, only
 * "GET /stream.mjpg?token=<token>".
 */
static int stream_allowed(const char *req, const char *token)
{
	static const char path[] = "GET /stream.mjpg";
	static const char query[] = "GET /stream.mjpg?token=";
	size_t n = strlen(token ? token : "");

	if (!token || !*token)
		return !strncmp(req, path, sizeof(path) - 1);
	return !strncmp(req, query, sizeof(query) - 1) &&
	       !strncmp(req + sizeof(query) - 1, token, n) &&
	       (req[sizeof(query) - 1 + n] == ' ' || req[sizeof(query) - 1 + n] == '&');
}

static void *acceptor(void *arg)
{
	static const char resp[] = "HTTP/1.0 200 OK\r\nCache-Control: no-cache\r\n"
		"Content-Type: multipart/x-mixed-replace; boundary=frame\r\n\r\n--frame\r\n";
	static const char page[] = "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n"
		"<html><body style=\"margin:0;background:#000\">"
		"<img src=\"/stream.mjpg\" style=\"width:100%\"></body></html>";
	static const char forbidden[] = "HTTP/1.0 403 Forbidden\r\n\r\n";
	const char *token = getenv("KVM_MJPEG_TOKEN");
	int ls = *(int *)arg;

	for (;;) {
		char req[1024];
		int c = accept(ls, NULL, NULL);
		ssize_t n;

		if (c < 0)
			continue;
		n = read(c, req, sizeof(req) - 1);
		if (n <= 0) {
			close(c);
			continue;
		}
		req[n] = 0;
		if (!stream_allowed(req, token)) {
			/* The viewer page only where the stream is open to all. */
			const char *reply = token && *token ? forbidden : page;

			if (write(c, reply, strlen(reply)) < 0)
				logline("write: %s", strerror(errno));
			close(c);
			continue;
		}
		if (write(c, resp, sizeof(resp) - 1) < 0) {
			close(c);
			continue;
		}
		pthread_mutex_lock(&lock);
		if (nclients < MAX_CLIENTS) {
			fresh[nclients] = 1;
			clients[nclients++] = c;
		} else {
			close(c);
		}
		pthread_mutex_unlock(&lock);
	}
	return NULL;
}

/*
 * The video encoder, H.264 or H.265: one frame in flight, a media request per
 * frame (the encoder's source queue requires them). H.264's frame_num and POC
 * are 16 bits: the AX620E VENC writes them so whatever the SPS says, and the
 * kernel declares that in the SPS. The codec and the colour the stream
 * declares are the encoder's formats: changing them restarts the encoder
 * between two frames.
 */
#define NSTRM 2

enum { CODEC_H264, CODEC_H265 };

static const struct codec {
	const char *name, *label;
	__u32 fourcc;
	int pkt_frame, pkt_keyframe;
} codecs[] = {
	[CODEC_H264] = { "h264", "H.264", V4L2_PIX_FMT_H264_SLICE, PKT_FRAME, PKT_KEYFRAME },
	[CODEC_H265] = { "h265", "H.265", V4L2_PIX_FMT_HEVC_SLICE, PKT_HEVC_FRAME, PKT_HEVC_KEYFRAME },
};

/* What the samples are. */
struct colour {
	int bt601, limited;
};

static struct {
	int fd, media, request;
	int busy;		/* capture buffer in the encoder, or -1 */
	int request_busy;
	int on, force_idr, streaming;
	int codec;
	struct colour colour;
	unsigned int frame_num, poc, idr_pic_id, since_idr;
	double last;		/* when the last frame went in */
	void *strm[NSTRM];
	size_t strm_length[NSTRM];
	struct v4l2_format cfmt;	/* the capture's */
	unsigned int fps;
} venc = { .fd = -1, .media = -1, .request = -1, .busy = -1 };

/* What the encoding asks for: the encoder takes it when it next starts. */
static int want_codec = CODEC_H264;

/* The colour asked for, AUTO or 0 or 1, and what the samples are. */
#define AUTO (-1)
static int want_bt601 = AUTO, want_limited = AUTO, want_colour_changed;
static struct colour colour;

/* A snapshot asked for, of the next frame */
static struct {
	int pending;
	unsigned int x, y, width, height;
} snap;
static unsigned long venc_bytes;	/* sent since the last statistics */

/*
 * Rate control, frame by frame: a frame takes about complexity / 2^(QP/6)
 * bits, the complexity followed over the last P frames, and apart over the
 * last keyframes. A P frame gets its share of the bitrate, less a part of
 * what the frames before went over, so that dithering, every other frame
 * large, does not swing the QP, and a still picture saves no bits for later;
 * a keyframe gets half a second's.
 */
enum { RC_CQ, RC_CBR, RC_VBR };
#define QP_MIN 16
#define QP_MAX 48

static struct {
	int mode, qp_floor, qp_ceil;
	int qp, key_qp;		/* the next P frame's and keyframe's */
	int used_qp;		/* the frame in the encoder's */
	unsigned int bitrate, gop, max_fps, fps;
	double complexity;	/* bits at QP 0 of the recent P frames */
	double key_complexity;	/* and of the recent keyframes */
	double debt;		/* bits sent beyond the bitrate */
} rc = { .mode = RC_CQ, .qp = 30, .key_qp = 30, .qp_floor = 30, .qp_ceil = 30, .gop = 600,
	 .fps = 30 };

static int clamp_qp(int qp)
{
	return qp < rc.qp_floor ? rc.qp_floor : qp > rc.qp_ceil ? rc.qp_ceil : qp;
}

/*
 * "<h264|h265> <cq|cbr|vbr> <bit/s> <QP> <keyframe interval> <max fps>
 * <auto|bt601|bt709> <auto|full|limited>"; returns whether it was one.
 */
static int rc_set(const char *text)
{
	char codec[5], mode[4], matrix[6], range[8];
	unsigned int bitrate, gop, max_fps;
	int qp, c;

	if (sscanf(text, "%4s %3s %u %d %u %u %5s %7s", codec, mode, &bitrate, &qp, &gop, &max_fps,
		   matrix, range) != 8 || qp < 0 || qp > 51 || !gop ||
	    (strcmp(mode, "cq") && !bitrate) ||
	    (strcmp(matrix, "auto") && strcmp(matrix, "bt601") && strcmp(matrix, "bt709")) ||
	    (strcmp(range, "auto") && strcmp(range, "full") && strcmp(range, "limited")))
		return 0;
	for (c = 0; c < (int)(sizeof(codecs) / sizeof(codecs[0])); c++)
		if (!strcmp(codec, codecs[c].name))
			break;
	if (c == (int)(sizeof(codecs) / sizeof(codecs[0])))
		return 0;
	if (!strcmp(mode, "cq"))
		rc.mode = RC_CQ;
	else if (!strcmp(mode, "cbr"))
		rc.mode = RC_CBR;
	else if (!strcmp(mode, "vbr"))
		rc.mode = RC_VBR;
	else
		return 0;
	want_codec = c;
	want_bt601 = !strcmp(matrix, "auto") ? AUTO : !strcmp(matrix, "bt601");
	want_limited = !strcmp(range, "auto") ? AUTO : !strcmp(range, "limited");
	want_colour_changed = 1;
	rc.bitrate = bitrate;
	rc.qp_floor = rc.mode == RC_CBR ? QP_MIN : qp;
	rc.qp_ceil = rc.mode == RC_CQ ? qp : QP_MAX;
	rc.gop = gop;
	rc.max_fps = max_fps;
	rc.debt = 0;
	rc.qp = rc.mode == RC_CBR ? clamp_qp(rc.qp) : qp;
	rc.key_qp = rc.mode == RC_CBR ? clamp_qp(rc.key_qp) : qp;
	logline("%s: %s, %u bit/s, QP %d, a keyframe every %u frames, %u fps at most, colour %s %s",
		codecs[c].label, mode, bitrate, qp, gop, max_fps, matrix, range);
	return 1;
}

/*
 * Asks the capture for the colour wanted, which the HDMI bridge converts to
 * where the capture says it can, and takes what the samples are from the
 * format it gives back. Elsewhere the samples are what the bridge hands
 * over, and the colour wanted only labels them.
 */
static void capture_colour(int cap, struct v4l2_format *cfmt)
{
	const unsigned int csc = V4L2_FMT_FLAG_CSC_YCBCR_ENC | V4L2_FMT_FLAG_CSC_QUANTIZATION;
	struct v4l2_fmtdesc desc = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	struct v4l2_format f = *cfmt;
	enum v4l2_ycbcr_encoding enc;
	enum v4l2_quantization quant;

	want_colour_changed = 0;
	if (xioctl(cap, VIDIOC_ENUM_FMT, &desc) || (desc.flags & csc) != csc) {
		colour.bt601 = want_bt601 == 1;
		colour.limited = want_limited == 1;
		return;
	}
	/*
	 * The colour space stays the capture's: with the default one V4L2
	 * drops the encoding and the range asked for (v4l_sanitize_colorspace).
	 */
	f.fmt.pix.priv = V4L2_PIX_FMT_PRIV_MAGIC;
	f.fmt.pix.flags = V4L2_PIX_FMT_FLAG_SET_CSC;
	f.fmt.pix.ycbcr_enc = want_bt601 == AUTO ? V4L2_YCBCR_ENC_DEFAULT :
			      want_bt601 ? V4L2_YCBCR_ENC_601 : V4L2_YCBCR_ENC_709;
	f.fmt.pix.quantization = want_limited == AUTO ? V4L2_QUANTIZATION_DEFAULT :
				 want_limited ? V4L2_QUANTIZATION_LIM_RANGE :
						V4L2_QUANTIZATION_FULL_RANGE;
	if (xioctl(cap, VIDIOC_S_FMT, &f)) {
		logline("capture colour: %s", strerror(errno));
		f = *cfmt;
	} else {
		*cfmt = f;
	}
	enc = f.fmt.pix.ycbcr_enc ? f.fmt.pix.ycbcr_enc :
				    V4L2_MAP_YCBCR_ENC_DEFAULT(f.fmt.pix.colorspace);
	quant = f.fmt.pix.quantization ? f.fmt.pix.quantization :
					 V4L2_MAP_QUANTIZATION_DEFAULT(0, f.fmt.pix.colorspace, enc);
	colour.bt601 = enc == V4L2_YCBCR_ENC_601;
	colour.limited = quant == V4L2_QUANTIZATION_LIM_RANGE;
	logline("capture colour: %s, %s range", colour.bt601 ? "BT.601" : "BT.709",
		colour.limited ? "limited" : "full");
}

/* After each frame, from its size: the next frame's QP. */
static void rc_frame(size_t bytes, int keyframe)
{
	double bits = bytes * 8.0, share = (double)rc.bitrate / rc.fps, budget;
	int qp;

	if (rc.mode == RC_CQ)
		return;
	rc.debt += bits - share;
	if (rc.debt < -(double)rc.bitrate / 2)
		rc.debt = -(double)rc.bitrate / 2;
	if (rc.debt > 2.0 * rc.bitrate)
		rc.debt = 2.0 * rc.bitrate;
	if (keyframe) {
		double c = bits * exp2(rc.used_qp / 6.0);

		rc.key_complexity = rc.key_complexity > 0 ? 0.5 * rc.key_complexity + 0.5 * c : c;
		rc.key_qp = clamp_qp((int)lround(6 * log2(rc.key_complexity / (rc.bitrate / 2.0))));
	} else {
		double c = bits * exp2(rc.used_qp / 6.0);

		rc.complexity = rc.complexity > 0 ? 0.75 * rc.complexity + 0.25 * c : c;
	}
	if (rc.complexity <= 0)
		return;
	/* The share, paying what went over, a keyframe's mostly, back within a second. */
	budget = share - rc.debt / rc.fps;
	if (budget < share / 4)
		budget = share / 4;
	qp = (int)lround(6 * log2(rc.complexity / budget));
	if (qp > rc.qp + 3)
		qp = rc.qp + 3;
	if (qp < rc.qp - 3)
		qp = rc.qp - 3;
	rc.qp = clamp_qp(qp);
}

static unsigned int ncap = 4;

/* Encoders using each capture buffer; it goes back to capture at zero. */
static int cap_refs[MAX_CAP];

static void release_cap(int cap, int index)
{
	struct v4l2_buffer buf = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
				   .memory = V4L2_MEMORY_MMAP, .index = index };

	if (--cap_refs[index] == 0 && xioctl(cap, VIDIOC_QBUF, &buf))
		die("QBUF capture (return)");
}

/* The media device of a video device: /sys/class/video4linux/videoN/device/mediaM. */
static int open_media(const char *video)
{
	const char *name = strrchr(video, '/') ? strrchr(video, '/') + 1 : video;
	char path[512];
	struct dirent *e;
	DIR *d;
	int fd = -1;

	snprintf(path, sizeof(path), "/sys/class/video4linux/%s/device", name);
	d = opendir(path);
	if (!d)
		return -1;
	while ((e = readdir(d)))
		if (!strncmp(e->d_name, "media", 5)) {
			snprintf(path, sizeof(path), "/dev/%.32s", e->d_name);
			fd = open(path, O_RDWR);
			break;
		}
	closedir(d);
	return fd;
}

static void venc_ctrl(unsigned int id, int value)
{
	struct v4l2_ext_control c = { .id = id, .value = value };
	struct v4l2_ext_controls cs = { .which = V4L2_CTRL_WHICH_CUR_VAL, .count = 1,
					.controls = &c };

	if (xioctl(venc.fd, VIDIOC_S_EXT_CTRLS, &cs))
		die("encoder control");
}

/*
 * Sets an encoder's coded format, then its raw one (setting the coded format
 * resets the raw one) for the captured frames, with the colour the stream is
 * to declare, if any. The encoder rounds the raw size up to macroblocks;
 * cropping it back makes the stream carry the picture's size. Returns the
 * raw format: the capture buffers must hold its sizeimage.
 */
static struct v4l2_format encoder_formats(int fd, __u32 coded, const struct v4l2_format *cfmt,
					  const struct colour *colour, const char *name)
{
	struct v4l2_format c = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE };
	struct v4l2_format o = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE };
	struct v4l2_selection sel = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT,
				      .target = V4L2_SEL_TGT_CROP };
	unsigned int w = cfmt->fmt.pix.width, h = cfmt->fmt.pix.height;

	c.fmt.pix_mp.width = w;
	c.fmt.pix_mp.height = h;
	c.fmt.pix_mp.pixelformat = coded;
	c.fmt.pix_mp.num_planes = 1;
	/*
	 * Not the driver's default of two bytes a pixel, 16.6 MB a buffer at
	 * 4K: on the Go that leaves the video encoder no CMA for its
	 * references. A picture bigger than this comes back with
	 * V4L2_BUF_FLAG_ERROR, as the encoders stop at the buffer's end.
	 */
	c.fmt.pix_mp.plane_fmt[0].sizeimage = coded == V4L2_PIX_FMT_JPEG ? w * h : w * h / 2;
	if (xioctl(fd, VIDIOC_S_FMT, &c))
		die("S_FMT encoder capture");
	o.fmt.pix_mp.width = w;
	o.fmt.pix_mp.height = h;
	o.fmt.pix_mp.pixelformat = cfmt->fmt.pix.pixelformat;
	o.fmt.pix_mp.num_planes = 1;
	o.fmt.pix_mp.plane_fmt[0].bytesperline = cfmt->fmt.pix.bytesperline;
	if (colour) {
		/* The bridge changes the matrix, not the source's primaries. */
		o.fmt.pix_mp.colorspace = V4L2_COLORSPACE_REC709;
		o.fmt.pix_mp.ycbcr_enc = colour->bt601 ? V4L2_YCBCR_ENC_601 : V4L2_YCBCR_ENC_709;
		o.fmt.pix_mp.xfer_func = V4L2_XFER_FUNC_709;
		o.fmt.pix_mp.quantization = colour->limited ? V4L2_QUANTIZATION_LIM_RANGE :
							      V4L2_QUANTIZATION_FULL_RANGE;
	}
	if (xioctl(fd, VIDIOC_S_FMT, &o))
		die("S_FMT encoder output");
	if (o.fmt.pix_mp.width != w || o.fmt.pix_mp.height != h) {
		sel.r.width = w;
		sel.r.height = h;
		if (xioctl(fd, VIDIOC_S_SELECTION, &sel))
			die("crop");
	}
	logline("%s: %ux%u in %ux%u, stride %u, size %u, coded %u", name, w, h, o.fmt.pix_mp.width,
		o.fmt.pix_mp.height, o.fmt.pix_mp.plane_fmt[0].bytesperline,
		o.fmt.pix_mp.plane_fmt[0].sizeimage, c.fmt.pix_mp.plane_fmt[0].sizeimage);
	if (o.fmt.pix_mp.plane_fmt[0].bytesperline != cfmt->fmt.pix.bytesperline)
		logline("%s: stride %u differs from the capture's %u: the picture will be skewed",
			name, o.fmt.pix_mp.plane_fmt[0].bytesperline, cfmt->fmt.pix.bytesperline);
	return o;
}

static void venc_open(const char *dev)
{
	venc.fd = open(dev, O_RDWR | O_NONBLOCK);
	venc.media = open_media(dev);
	if (venc.fd < 0 || venc.media < 0 ||
	    xioctl(venc.media, MEDIA_IOC_REQUEST_ALLOC, &venc.request))
		die("video encoder");
}

/* The SPS and PPS the H.264 encoder fills in; H.265's work as they are. */
static void h264_setup(void)
{
	struct v4l2_ctrl_h264_sps sps = {
		.profile_idc = 66,	/* constrained baseline: decodable everywhere */
		.constraint_set_flags = V4L2_H264_SPS_CONSTRAINT_SET0_FLAG |
					V4L2_H264_SPS_CONSTRAINT_SET1_FLAG,
		.level_idc = 51,
		.chroma_format_idc = 1,
		.log2_max_frame_num_minus4 = 12,
		.log2_max_pic_order_cnt_lsb_minus4 = 12,
		.max_num_ref_frames = 1,
		.flags = V4L2_H264_SPS_FLAG_FRAME_MBS_ONLY |
			 V4L2_H264_SPS_FLAG_DIRECT_8X8_INFERENCE,
	};
	struct v4l2_ctrl_h264_pps pps = {
		.flags = V4L2_H264_PPS_FLAG_DEBLOCKING_FILTER_CONTROL_PRESENT,
	};
	struct v4l2_ext_control init[] = {
		{ .id = V4L2_CID_STATELESS_H264_SPS, .size = sizeof(sps), .ptr = &sps },
		{ .id = V4L2_CID_STATELESS_H264_PPS, .size = sizeof(pps), .ptr = &pps },
	};
	struct v4l2_ext_controls cs = { .which = V4L2_CTRL_WHICH_CUR_VAL, .count = 2,
					.controls = init };

	if (xioctl(venc.fd, VIDIOC_S_EXT_CTRLS, &cs))
		die("H.264 SPS/PPS");
	venc_ctrl(V4L2_CID_MPEG_VIDEO_PREPEND_SPSPPS_TO_IDR, 1);
	venc_ctrl(V4L2_CID_MPEG_VIDEO_FRAME_RC_ENABLE, 0);
}

/* Starts the encoder with the codec and colour asked for: a keyframe first. */
static void venc_start(void)
{
	enum v4l2_buf_type out_type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	enum v4l2_buf_type strm_type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	struct v4l2_streamparm parm = { .type = out_type };
	struct v4l2_requestbuffers req = { 0 };
	const struct codec *codec = &codecs[want_codec];
	int i;

	venc.codec = want_codec;
	venc.colour = colour;
	encoder_formats(venc.fd, codec->fourcc, &venc.cfmt, &venc.colour, codec->label);
	parm.parm.output.timeperframe.numerator = 1;
	parm.parm.output.timeperframe.denominator = venc.fps;
	if (xioctl(venc.fd, VIDIOC_S_PARM, &parm))
		logline("S_PARM %s: %s", codec->label, strerror(errno));
	if (venc.codec == CODEC_H264)
		h264_setup();

	req.count = ncap;
	req.type = out_type;
	req.memory = V4L2_MEMORY_DMABUF;
	if (xioctl(venc.fd, VIDIOC_REQBUFS, &req))
		die("REQBUFS encoder output");
	memset(&req, 0, sizeof(req));
	req.count = NSTRM;
	req.type = strm_type;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(venc.fd, VIDIOC_REQBUFS, &req) || req.count < NSTRM)
		die("REQBUFS encoder capture");
	for (i = 0; i < NSTRM; i++) {
		struct v4l2_plane plane = { 0 };
		struct v4l2_buffer buf = { .type = strm_type, .memory = V4L2_MEMORY_MMAP, .index = i,
					   .m.planes = &plane, .length = 1 };

		if (xioctl(venc.fd, VIDIOC_QUERYBUF, &buf))
			die("QUERYBUF encoder");
		venc.strm_length[i] = plane.length;
		venc.strm[i] = mmap(NULL, plane.length, PROT_READ, MAP_SHARED, venc.fd,
				    plane.m.mem_offset);
		if (venc.strm[i] == MAP_FAILED)
			die("mmap encoder");
		if (xioctl(venc.fd, VIDIOC_QBUF, &buf))
			die("QBUF encoder capture");
	}
	if (xioctl(venc.fd, VIDIOC_STREAMON, &out_type) ||
	    xioctl(venc.fd, VIDIOC_STREAMON, &strm_type))
		die("STREAMON encoder");
	venc.streaming = 1;
	venc.force_idr = 1;
	logline("%s: %u fps", codec->label, venc.fps);
}

/* Between two frames: nothing in the encoder. */
static void venc_stop(void)
{
	enum v4l2_buf_type out_type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	enum v4l2_buf_type strm_type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	struct v4l2_requestbuffers req = { .memory = V4L2_MEMORY_DMABUF, .type = out_type };
	int i;

	if (xioctl(venc.fd, VIDIOC_STREAMOFF, &out_type) ||
	    xioctl(venc.fd, VIDIOC_STREAMOFF, &strm_type))
		die("STREAMOFF encoder");
	for (i = 0; i < NSTRM; i++)
		munmap(venc.strm[i], venc.strm_length[i]);
	if (xioctl(venc.fd, VIDIOC_REQBUFS, &req))
		die("REQBUFS encoder output (free)");
	req.memory = V4L2_MEMORY_MMAP;
	req.type = strm_type;
	if (xioctl(venc.fd, VIDIOC_REQBUFS, &req))
		die("REQBUFS encoder capture (free)");
	venc.streaming = 0;
}

/* Whether the encoding asks for another codec, or the samples are another colour. */
static int venc_changed(void)
{
	return want_codec != venc.codec || colour.bt601 != venc.colour.bt601 ||
	       colour.limited != venc.colour.limited;
}

/* Whether a frame may go in now, at most max fps. */
static int venc_due(void)
{
	return !rc.max_fps || now() - venc.last >= 0.95 / rc.max_fps;
}

/* Each frame's QP goes in its request, with its parameters. */
static void venc_queue(const struct v4l2_buffer *cbuf, int dmabuf_fd)
{
	struct v4l2_ctrl_h264_encode_params h264 = { 0 };
	struct v4l2_ctrl_hevc_encode_params hevc = { 0 };
	struct v4l2_ext_control c[3];
	struct v4l2_ext_controls cs = { .which = V4L2_CTRL_WHICH_REQUEST_VAL,
					.request_fd = venc.request, .count = 3, .controls = c };
	struct v4l2_plane plane = { .m.fd = dmabuf_fd, .bytesused = cbuf->bytesused,
				    .length = cbuf->length };
	struct v4l2_buffer buf = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
				   .memory = V4L2_MEMORY_DMABUF, .index = cbuf->index,
				   .flags = V4L2_BUF_FLAG_REQUEST_FD,
				   .request_fd = venc.request, .m.planes = &plane, .length = 1 };
	int idr = venc.force_idr || venc.since_idr >= rc.gop;

	if (idr) {
		venc.force_idr = 0;
		venc.since_idr = 0;
		venc.frame_num = 0;
		venc.poc = 0;
		rc.used_qp = rc.key_qp;
	} else {
		venc.frame_num = (venc.frame_num + 1) & 0xffff;
		rc.used_qp = rc.qp;
	}
	venc.since_idr++;

	if (venc.codec == CODEC_H264) {
		if (!idr)
			venc.poc = (venc.poc + 2) & 0xffff;
		h264.slice_type = idr ? V4L2_H264_SLICE_TYPE_I : V4L2_H264_SLICE_TYPE_P;
		h264.flags = idr ? V4L2_H264_ENCODE_FLAG_IDR_PIC : 0;
		h264.idr_pic_id = idr ? venc.idr_pic_id++ & 0xffff : 0;
		h264.nal_ref_idc = idr ? 3 : 2;
		h264.frame_num = venc.frame_num;
		h264.pic_order_cnt_lsb = venc.poc;
		c[0] = (struct v4l2_ext_control){ .id = V4L2_CID_STATELESS_H264_ENCODE_PARAMS,
						  .size = sizeof(h264), .ptr = &h264 };
		c[1] = (struct v4l2_ext_control){ .id = V4L2_CID_MPEG_VIDEO_H264_I_FRAME_QP,
						  .value = rc.key_qp };
		c[2] = (struct v4l2_ext_control){ .id = V4L2_CID_MPEG_VIDEO_H264_P_FRAME_QP,
						  .value = rc.qp };
	} else {
		if (!idr)
			venc.poc = (venc.poc + 1) & 0xffff;
		hevc.slice_type = idr ? V4L2_HEVC_SLICE_TYPE_I : V4L2_HEVC_SLICE_TYPE_P;
		hevc.flags = idr ? V4L2_HEVC_ENCODE_FLAG_IDR_PIC : 0;
		hevc.slice_pic_order_cnt_lsb = venc.poc;
		c[0] = (struct v4l2_ext_control){ .id = V4L2_CID_STATELESS_HEVC_ENCODE_PARAMS,
						  .size = sizeof(hevc), .ptr = &hevc };
		c[1] = (struct v4l2_ext_control){ .id = V4L2_CID_MPEG_VIDEO_HEVC_I_FRAME_QP,
						  .value = rc.key_qp };
		c[2] = (struct v4l2_ext_control){ .id = V4L2_CID_MPEG_VIDEO_HEVC_P_FRAME_QP,
						  .value = rc.qp };
	}

	if (xioctl(venc.fd, VIDIOC_S_EXT_CTRLS, &cs))
		die("encode params");
	if (xioctl(venc.fd, VIDIOC_QBUF, &buf))
		die("QBUF encoder output");
	if (xioctl(venc.request, MEDIA_REQUEST_IOC_QUEUE, NULL))
		die("queue encoder request");
	venc.busy = cbuf->index;
	venc.request_busy = 1;
	venc.last = now();
}

/* Returns whether an access unit was sent. */
static int venc_send(void)
{
	const struct codec *codec = &codecs[venc.codec];
	struct v4l2_plane plane = { 0 };
	struct v4l2_buffer buf = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
				   .memory = V4L2_MEMORY_MMAP, .m.planes = &plane, .length = 1 };
	int sent = 0;

	if (xioctl(venc.fd, VIDIOC_DQBUF, &buf))
		return 0;
	if (buf.flags & V4L2_BUF_FLAG_ERROR) {
		logline("%s encode error", codec->label);
		venc.force_idr = 1;
	} else {
		size_t size = plane.bytesused - plane.data_offset;

		write_packet(buf.flags & V4L2_BUF_FLAG_KEYFRAME ? codec->pkt_keyframe :
								  codec->pkt_frame,
			     (char *)venc.strm[buf.index] + plane.data_offset, size);
		rc_frame(size, buf.flags & V4L2_BUF_FLAG_KEYFRAME);
		venc_bytes += size;
		sent = 1;
	}
	if (xioctl(venc.fd, VIDIOC_QBUF, &buf))
		die("QBUF encoder capture");
	return sent;
}

/* Kept until the encoder runs: commands can come while waiting for an input. */
static void venc_command(const char *c, size_t len)
{
	char text[96];

	if (len == 1 && c[0] == '1' && !venc.on) {
		venc.on = 1;
		venc.force_idr = 1;
	} else if (len == 1 && c[0] == '0') {
		venc.on = 0;
	} else if (len == 1 && c[0] == 'k') {
		venc.force_idr = 1;
	} else if (len > 2 && len < sizeof(text) && c[0] == 'e' && c[1] == ' ') {
		memcpy(text, c + 2, len - 2);
		text[len - 2] = 0;
		if (!rc_set(text))
			logline("not an encoding: %s", text);
	} else if (len > 2 && len < sizeof(text) && c[0] == 's' && c[1] == ' ') {
		memcpy(text, c + 2, len - 2);
		text[len - 2] = 0;
		if (sscanf(text, "%u %u %u %u", &snap.x, &snap.y, &snap.width, &snap.height) == 4)
			snap.pending = 1;
		else
			logline("not a snapshot region: %s", text);
	}
}

static uint8_t clamp8(int v)
{
	return v < 0 ? 0 : v > 255 ? 255 : v;
}

/*
 * Sends the snapshot asked for from a captured frame (YUYV or UYVY, in the
 * DMA-BUF fd) as RGB, in the colours the streams declare: an empty one when
 * the region is outside the picture.
 */
static void send_snapshot(int fd, const struct v4l2_format *f)
{
	unsigned int width = f->fmt.pix.width, height = f->fmt.pix.height;
	unsigned int stride = f->fmt.pix.bytesperline, fourcc = f->fmt.pix.pixelformat;
	unsigned int x = snap.x & ~1u, y = snap.y, w = 0, h = 0, row, col;
	/* Y'CbCr to R'G'B' in 1/256: Cr to R, Cb to G, Cr to G, Cb to B; [limited][bt601] */
	static const int k[2][2][4] = {
		{ { 403, 48, 120, 475 }, { 359, 88, 183, 454 } },
		{ { 459, 55, 136, 541 }, { 409, 100, 208, 516 } },
	};
	const int *c = k[colour.limited][colour.bt601];
	int cr_r = c[0], cb_g = c[1], cr_g = c[2], cb_b = c[3];
	int yoff = colour.limited ? 16 : 0, yscale = colour.limited ? 298 : 256;
	int luma0 = fourcc == V4L2_PIX_FMT_UYVY;
	size_t map_len = (size_t)stride * height;
	uint8_t *src = MAP_FAILED, *out = NULL, *o;
	struct dma_buf_sync sync = { DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ };

	snap.pending = 0;
	if (fourcc == V4L2_PIX_FMT_YUYV || fourcc == V4L2_PIX_FMT_UYVY) {
		if (x < width && y < height) {
			w = (snap.width < width - x ? snap.width : width - x) & ~1u;
			h = snap.height < height - y ? snap.height : height - y;
		}
	} else {
		logline("snapshot: not a YUYV or UYVY capture");
	}
	out = malloc(4 + (size_t)w * h * 3);
	if (!out)
		die("snapshot: out of memory");
	out[0] = w >> 8, out[1] = w, out[2] = h >> 8, out[3] = h;
	if (w && h) {
		src = mmap(NULL, map_len, PROT_READ, MAP_SHARED, fd, 0);
		if (src == MAP_FAILED) {
			logline("snapshot: mmap: %s", strerror(errno));
			w = h = 0;
			out[0] = out[1] = out[2] = out[3] = 0;
		} else {
			ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
		}
	}
	o = out + 4;
	for (row = 0; row < h && w; row++) {
		const uint8_t *p = src + (size_t)(y + row) * stride + (size_t)x * 2;

		for (col = 0; col < w; col += 2, p += 4) {
			int y0 = p[luma0 ? 1 : 0], y1 = p[luma0 ? 3 : 2];
			int cb = p[luma0 ? 0 : 1] - 128, cr = p[luma0 ? 2 : 3] - 128;
			int r = cr_r * cr, g = -cb_g * cb - cr_g * cr, b = cb_b * cb;
			int l0 = (y0 - yoff) * yscale, l1 = (y1 - yoff) * yscale;

			*o++ = clamp8((l0 + r) >> 8), *o++ = clamp8((l0 + g) >> 8), *o++ = clamp8((l0 + b) >> 8);
			*o++ = clamp8((l1 + r) >> 8), *o++ = clamp8((l1 + g) >> 8), *o++ = clamp8((l1 + b) >> 8);
		}
	}
	if (src != MAP_FAILED) {
		sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
		ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
		munmap(src, map_len);
	}
	write_packet(PKT_SNAPSHOT, out, 4 + (size_t)w * h * 3);
	free(out);
}

static void venc_commands(void)
{
	static char in[256];
	static size_t have;
	ssize_t n = read(STDIN_FILENO, in + have, sizeof(in) - have);
	uint32_t len;

	if (n == 0)
		exit(0);	/* the port is gone */
	if (n < 0)
		return;
	have += (size_t)n;
	while (have >= 4) {
		memcpy(&len, in, 4);
		len = ntohl(len);
		if (len > sizeof(in) - 4)
			die("a command too long");
		if (have < 4 + len)
			break;
		venc_command(in + 4, len);
		memmove(in, in + 4 + len, have - 4 - len);
		have -= 4 + len;
	}
}

static unsigned int frame_rate(const struct v4l2_bt_timings *bt)
{
	unsigned long long total = (unsigned long long)V4L2_DV_BT_FRAME_WIDTH(bt) *
				   V4L2_DV_BT_FRAME_HEIGHT(bt);

	return total ? (bt->pixelclock + total / 2) / total : 0;
}

static void report_input(const char *state)
{
	logline("input: %s", state);
	if (packet_mode)
		write_packet(PKT_INPUT, state, strlen(state));
}

/* Until the capture device reports an event, serving commands meanwhile. */
static void wait_for_event(int cap)
{
	struct v4l2_event ev;

	for (;;) {
		struct pollfd pfd[2] = {
			{ .fd = cap, .events = POLLPRI },
			{ .fd = packet_mode ? STDIN_FILENO : -1, .events = POLLIN },
		};

		if (poll(pfd, 2, -1) < 0 && errno != EINTR)
			die("poll");
		if (pfd[1].revents & (POLLIN | POLLHUP))
			venc_commands();
		if (pfd[0].revents & POLLPRI) {
			while (!xioctl(cap, VIDIOC_DQEVENT, &ev))
				;
			return;
		}
	}
}

/*
 * Waits for an input the bridge can capture and selects its timings, which
 * sets the capture format. Returns the frame rate.
 */
static unsigned int select_input(int cap)
{
	struct v4l2_event_subscription sub = { .type = V4L2_EVENT_SOURCE_CHANGE };
	struct v4l2_dv_timings t;
	const char *reported = NULL;
	char text[48];
	unsigned int fps;

	if (xioctl(cap, VIDIOC_SUBSCRIBE_EVENT, &sub))
		die("subscribe to input changes");
	for (;;) {
		const char *state;

		memset(&t, 0, sizeof(t));
		if (!xioctl(cap, VIDIOC_QUERY_DV_TIMINGS, &t))
			break;
		if (errno == ENOLINK || errno == ENOLCK)
			state = "none";
		else if (errno == ERANGE)
			state = "unsupported";
		else
			die("QUERY_DV_TIMINGS");
		if (state != reported)
			report_input(state);
		reported = state;
		wait_for_event(cap);
	}
	if (xioctl(cap, VIDIOC_S_DV_TIMINGS, &t))
		die("S_DV_TIMINGS");
	fps = frame_rate(&t.bt);
	snprintf(text, sizeof(text), "%ux%u@%u", t.bt.width, t.bt.height, fps);
	report_input(text);
	return fps;
}

int main(int argc, char **argv)
{
	enum v4l2_buf_type cap_type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	enum v4l2_buf_type out_type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	enum v4l2_buf_type jpg_type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	struct v4l2_format cfmt = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	struct v4l2_format raw;
	struct v4l2_create_buffers cb = { .memory = V4L2_MEMORY_MMAP };
	struct v4l2_requestbuffers req;
	struct v4l2_control ctrl;
	int dmabuf[MAX_CAP];
	int cap, enc, i, quality = 75, seconds = 0, port = 0, enc_busy = -1, run = 0, njpeg;
	unsigned int fps, bufsize;
	unsigned long gen = 0, captured = 0;
	const char *out = NULL, *venc_dev = NULL, *encoding;
	double t0, tstat, tq = 0, lat_sum = 0;
	unsigned long ncaptured = 0, nenc = 0, bytes = 0, nstat_enc = 0, nstat_venc = 0;
	const char *buffers;
	pthread_t th;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <capture-dev> <encoder-dev> <port> [quality] [seconds]\n"
			"       %s <capture-dev> <encoder-dev> -o <out.jpg> [quality]\n", argv[0], argv[0]);
		return 2;
	}
	signal(SIGPIPE, SIG_IGN);
	packet_mode = getenv("KVM_PORT") != NULL;
	/* Before any command: those that come while waiting for an input win. */
	encoding = getenv("KVM_ENCODING");
	if (packet_mode && encoding && !rc_set(encoding))
		logline("not an encoding: %s", encoding);
	buffers = getenv("KVM_CAPTURE_BUFFERS");
	if (buffers) {
		char *end;
		long n = strtol(buffers, &end, 10);

		if (*buffers && !*end && n >= 2 && n <= MAX_CAP)
			ncap = n;
		else
			logline("not a capture buffer count: %s", buffers);
	}
	if (!strcmp(argv[3], "-o")) {
		if (argc < 5)
			return 2;
		out = argv[4];
		if (argc > 5)
			quality = atoi(argv[5]);
	} else {
		port = atoi(argv[3]);
		if (argc > 4)
			quality = atoi(argv[4]);
		if (argc > 5)
			seconds = atoi(argv[5]);
	}

	cap = open(argv[1], O_RDWR | O_NONBLOCK);
	enc = open(argv[2], O_RDWR | O_NONBLOCK);
	if (cap < 0 || enc < 0)
		die("open");

	fps = select_input(cap);
	if (xioctl(cap, VIDIOC_G_FMT, &cfmt))
		die("G_FMT capture");
	capture_colour(cap, &cfmt);
	logline("capture %ux%u stride %u size %u", cfmt.fmt.pix.width, cfmt.fmt.pix.height,
	       cfmt.fmt.pix.bytesperline, cfmt.fmt.pix.sizeimage);
	bufsize = cfmt.fmt.pix.sizeimage;

	raw = encoder_formats(enc, V4L2_PIX_FMT_JPEG, &cfmt, NULL, "JPEG");
	if (raw.fmt.pix_mp.plane_fmt[0].sizeimage > bufsize)
		bufsize = raw.fmt.pix_mp.plane_fmt[0].sizeimage;
	ctrl.id = V4L2_CID_JPEG_COMPRESSION_QUALITY;
	ctrl.value = quality;
	if (xioctl(enc, VIDIOC_S_CTRL, &ctrl))
		logline("quality: %s", strerror(errno));

	if (packet_mode)
		venc_dev = getenv("KVM_ENCODER_DEV");
	if (venc_dev) {
		rc.fps = fps ? fps : 30;
		venc_open(venc_dev);
		/* Both codecs take the same raw format. */
		raw = encoder_formats(venc.fd, codecs[want_codec].fourcc, &cfmt, &colour,
				      codecs[want_codec].label);
		if (raw.fmt.pix_mp.plane_fmt[0].sizeimage > bufsize)
			bufsize = raw.fmt.pix_mp.plane_fmt[0].sizeimage;
	}

	/* The encoders read whole macroblock rows: the buffers hold them. */
	cb.count = ncap;
	cb.format = cfmt;
	cb.format.fmt.pix.sizeimage = bufsize;
	if (xioctl(cap, VIDIOC_CREATE_BUFS, &cb) || cb.count < ncap)
		die("CREATE_BUFS capture");
	for (i = 0; i < (int)ncap; i++) {
		struct v4l2_exportbuffer exp = { .type = cap_type, .index = i, .flags = O_RDWR };
		struct v4l2_buffer buf = { .type = cap_type, .memory = V4L2_MEMORY_MMAP, .index = i };

		if (xioctl(cap, VIDIOC_EXPBUF, &exp))
			die("EXPBUF");
		dmabuf[i] = exp.fd;
		if (xioctl(cap, VIDIOC_QBUF, &buf))
			die("QBUF capture");
	}

	memset(&req, 0, sizeof(req));
	req.count = ncap;
	req.type = out_type;
	req.memory = V4L2_MEMORY_DMABUF;
	if (xioctl(enc, VIDIOC_REQBUFS, &req))
		die("REQBUFS encoder output");

	/* JPEG buffers are sized for the worst case (16.6 MB at 4K): with the
	 * video encoder as well, two of them leave room in CMA for its references. */
	njpeg = venc_dev ? 2 : NJPEG;
	memset(&req, 0, sizeof(req));
	req.count = njpeg;
	req.type = jpg_type;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(enc, VIDIOC_REQBUFS, &req) || req.count < (unsigned int)njpeg)
		die("REQBUFS encoder capture");
	for (i = 0; i < njpeg; i++) {
		struct v4l2_plane plane = { 0 };
		struct v4l2_buffer buf = { .type = jpg_type, .memory = V4L2_MEMORY_MMAP, .index = i,
					   .m.planes = &plane, .length = 1 };

		if (xioctl(enc, VIDIOC_QUERYBUF, &buf))
			die("QUERYBUF jpeg");
		jpegs[i].length = plane.length;
		jpegs[i].data = mmap(NULL, plane.length, PROT_READ, MAP_SHARED, enc, plane.m.mem_offset);
		if (jpegs[i].data == MAP_FAILED)
			die("mmap jpeg");
		if (xioctl(enc, VIDIOC_QBUF, &buf))
			die("QBUF jpeg");
	}

	if (xioctl(enc, VIDIOC_STREAMON, &out_type) || xioctl(enc, VIDIOC_STREAMON, &jpg_type))
		die("STREAMON encoder");
	if (venc_dev) {
		venc.cfmt = cfmt;
		venc.fps = fps ? fps : 30;
		venc_start();
	}
	if (xioctl(cap, VIDIOC_STREAMON, &cap_type)) {
		/* The input changed or went away since select_input(). */
		if (errno == EPIPE || errno == ENOLINK) {
			logline("STREAMON capture: %s", strerror(errno));
			return EXIT_INPUT_CHANGED;
		}
		die("STREAMON capture");
	}

	if (!out) {
		static int ls;
		struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(port) };
		int one = 1;

		if (pipe(done_pipe))
			die("pipe");
		ls = socket(AF_INET, SOCK_STREAM, 0);
		setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		if (bind(ls, (struct sockaddr *)&sa, sizeof(sa)) || listen(ls, 4))
			die("listen");
		pthread_create(&th, NULL, sender, NULL);
		pthread_create(&th, NULL, acceptor, &ls);
		logline("serving http://<device>:%d/ (quality %d)", port, quality);
	}
	t0 = tstat = now();
	for (;;) {
		struct pollfd pfd[6] = {
			{ .fd = cap, .events = POLLIN | POLLPRI },
			{ .fd = enc, .events = POLLIN | POLLOUT },
			{ .fd = out ? -1 : done_pipe[0], .events = POLLIN },
			{ .fd = venc.fd, .events = POLLIN | POLLOUT },
			{ .fd = venc.request_busy ? venc.request : -1, .events = POLLPRI },
			{ .fd = packet_mode ? STDIN_FILENO : -1, .events = POLLIN },
		};

		if (poll(pfd, 6, 3000) <= 0) {
			logline("timeout: no frames");
			return 1;
		}

		if (pfd[0].revents & POLLPRI) {
			struct v4l2_event ev;

			if (!xioctl(cap, VIDIOC_DQEVENT, &ev) && ev.type == V4L2_EVENT_SOURCE_CHANGE) {
				logline("input changed");
				return EXIT_INPUT_CHANGED;
			}
		}

		/* Encoder first: a frame that arrives with the end of an encode
		 * would otherwise be dropped as if the encoder were busy. */

		if (pfd[1].revents & POLLOUT) {
			struct v4l2_plane plane = { 0 };
			struct v4l2_buffer ebuf = { .type = out_type, .memory = V4L2_MEMORY_DMABUF,
						    .m.planes = &plane, .length = 1 };

			if (!xioctl(enc, VIDIOC_DQBUF, &ebuf)) {
				release_cap(cap, ebuf.index);
				enc_busy = -1;
			}
		}

		if (pfd[3].revents & POLLIN)
			nstat_venc += venc_send();

		if (pfd[3].revents & POLLOUT) {
			struct v4l2_plane plane = { 0 };
			struct v4l2_buffer hbuf = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
						    .memory = V4L2_MEMORY_DMABUF,
						    .m.planes = &plane, .length = 1 };

			if (!xioctl(venc.fd, VIDIOC_DQBUF, &hbuf)) {
				release_cap(cap, hbuf.index);
				venc.busy = -1;
			}
		}

		if (pfd[4].revents & POLLPRI) {
			if (xioctl(venc.request, MEDIA_REQUEST_IOC_REINIT, NULL))
				die("reinit encoder request");
			venc.request_busy = 0;
		}

		if (pfd[5].revents & (POLLIN | POLLHUP)) {
			venc_commands();
			/* The capture streams on: the bridge changes over at once. */
			if (want_colour_changed)
				capture_colour(cap, &cfmt);
		}

		if (pfd[1].revents & POLLIN) {
			struct v4l2_plane plane = { 0 };
			struct v4l2_buffer jbuf = { .type = jpg_type, .memory = V4L2_MEMORY_MMAP,
						    .m.planes = &plane, .length = 1 };

			if (!xioctl(enc, VIDIOC_DQBUF, &jbuf)) {
				nenc++;
				nstat_enc++;
				bytes += plane.bytesused;
				lat_sum += now() - tq;
				if (jbuf.flags & V4L2_BUF_FLAG_ERROR)
					logline("encode error");
				if (out) {
					FILE *f = fopen(out, "wb");

					if (!f || fwrite(jpegs[jbuf.index].data, plane.bytesused, 1, f) != 1)
						die("write jpeg");
					fclose(f);
					logline("wrote %s: %u bytes, encode %.1f ms", out,
					       plane.bytesused, (now() - tq) * 1000);
					return 0;
				}
				jpegs[jbuf.index].used = plane.bytesused;
				if (__atomic_load_n(&nclients, __ATOMIC_RELAXED) &&
				    repeated(&jpegs[jbuf.index], jbuf.timestamp.tv_sec, run >= REPEAT)) {
					run++;
				} else {
					run = 0;
					gen++;
				}
				jpegs[jbuf.index].run = run;
				jpegs[jbuf.index].gen = gen;
				pthread_mutex_lock(&lock);
				if (ready >= 0) {
					struct v4l2_plane p2 = { 0 };
					struct v4l2_buffer old = { .type = jpg_type,
								   .memory = V4L2_MEMORY_MMAP,
								   .index = ready,
								   .m.planes = &p2, .length = 1 };

					if (xioctl(enc, VIDIOC_QBUF, &old))
						die("QBUF jpeg (drop)");
				}
				ready = jbuf.index;
				pthread_cond_signal(&cond);
				pthread_mutex_unlock(&lock);
			}
		}

		if (pfd[2].revents & POLLIN) {
			int idx;

			if (read(done_pipe[0], &idx, sizeof(idx)) == sizeof(idx)) {
				struct v4l2_plane plane = { 0 };
				struct v4l2_buffer jbuf = { .type = jpg_type, .memory = V4L2_MEMORY_MMAP,
							    .index = idx, .m.planes = &plane,
							    .length = 1 };

				if (xioctl(enc, VIDIOC_QBUF, &jbuf))
					die("QBUF jpeg (sent)");
			}
		}

		if (pfd[0].revents & POLLIN) {
			struct v4l2_buffer buf = { .type = cap_type, .memory = V4L2_MEMORY_MMAP };

			if (!xioctl(cap, VIDIOC_DQBUF, &buf)) {
				int refs = 0;

				ncaptured++;
				if (snap.pending)
					send_snapshot(dmabuf[buf.index], &cfmt);
				captured++;
				if ((out || __atomic_load_n(&nclients, __ATOMIC_RELAXED)) &&
				    enc_busy < 0) {
					struct v4l2_plane plane = { .m.fd = dmabuf[buf.index],
								    .bytesused = buf.bytesused,
								    .length = buf.length };
					/* The encoder copies the timestamp to the JPEG. */
					struct v4l2_buffer ebuf = { .type = out_type,
								    .memory = V4L2_MEMORY_DMABUF,
								    .index = buf.index,
								    .timestamp.tv_sec = captured,
								    .m.planes = &plane, .length = 1 };

					if (xioctl(enc, VIDIOC_QBUF, &ebuf))
						die("QBUF encoder output");
					enc_busy = buf.index;
					tq = now();
					refs++;
				}
				if (venc.on && venc.streaming && venc.busy < 0 &&
				    !venc.request_busy && venc_due()) {
					if (venc_changed()) {
						venc_stop();
						venc_start();
					}
					venc_queue(&buf, dmabuf[buf.index]);
					refs++;
				}
				cap_refs[buf.index] = refs;
				if (!refs && xioctl(cap, VIDIOC_QBUF, &buf))
					die("QBUF capture");
			}
		}

		if (now() - tstat >= 5) {
			double dt = now() - tstat;

			logline("capture %.1f fps, jpeg %.1f fps, sent %.1f fps, %.0f KB avg, encode+wait %.1f ms, clients %d, %s %.1f fps %.2f Mbit/s QP %d",
			       ncaptured / dt, nstat_enc / dt, __atomic_exchange_n(&nsent, 0, __ATOMIC_RELAXED) / dt,
			       nstat_enc ? bytes / 1024.0 / nstat_enc : 0,
			       nstat_enc ? lat_sum * 1000 / nstat_enc : 0, nclients,
			       codecs[venc.codec].name, nstat_venc / dt, venc_bytes * 8 / dt / 1e6, rc.qp);
			ncaptured = nstat_enc = bytes = nstat_venc = venc_bytes = 0;
			lat_sum = 0;
			tstat = now();
		}
		if (seconds && now() - t0 > seconds)
			break;
	}
	return 0;
}

// SPDX-License-Identifier: Apache-2.0
/*
 * nano_kvm_go_video: V4L2 capture -> V4L2 M2M JPEG encoder -> MJPEG over
 * HTTP, and optionally -> V4L2 stateless H.264 encoder -> stdout for an
 * Erlang port.
 *
 * Capture buffers are handed to the encoders as DMA-BUFs (no copy); encoded
 * JPEGs are sent straight from the encoder's buffers.
 *
 * Usage: nano_kvm_go_video <capture> <encoder> <port> [quality] [seconds]
 *        nano_kvm_go_video <capture> <encoder> -o <out.jpg> [quality]
 *
 * With KVM_PORT set (run as an Erlang port), stdout carries {packet, 4}
 * frames [type][payload] (type 0 log line, 1 H.264 access unit, 2 H.264
 * keyframe, 3 input: "<width>x<height>@<fps>", "none" or "unsupported"),
 * stdin takes commands and its end stops the program. With
 * KVM_H264_DEV=<H.264 encoder device> as well (KVM_H264_QP, default 30), the
 * commands are '1' start H.264, '0' stop, 'k' make the next frame an IDR.
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

#include "v4l2_h264_enc.h"

#define NCAP 4
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

enum { PKT_LOG, PKT_FRAME, PKT_KEYFRAME, PKT_INPUT };

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
 * H.264: one frame in flight, a media request per frame (the encoder's source
 * queue requires them). frame_num and POC are 16 bits: the AX620E VENC writes
 * them so whatever the SPS says, and the kernel declares that in the SPS.
 */
#define NSTRM 2
#define H264_IDR_EVERY 600

static struct {
	int fd, media, request;
	int busy;		/* capture buffer in the encoder, or -1 */
	int request_busy;
	int on, force_idr;
	unsigned int qp, frame_num, poc, idr_pic_id, since_idr;
	void *strm[NSTRM];
} h264 = { .fd = -1, .media = -1, .request = -1, .busy = -1 };

/* Encoders using each capture buffer; it goes back to capture at zero. */
static int cap_refs[NCAP];

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

static void h264_ctrl(unsigned int id, int value)
{
	struct v4l2_ext_control c = { .id = id, .value = value };
	struct v4l2_ext_controls cs = { .which = V4L2_CTRL_WHICH_CUR_VAL, .count = 1,
					.controls = &c };

	if (xioctl(h264.fd, VIDIOC_S_EXT_CTRLS, &cs))
		die("H.264 control");
}

/*
 * Sets an encoder's coded format, then its raw one (setting the coded format
 * resets the raw one) for the captured frames. The encoder rounds the raw
 * size up to macroblocks; cropping it back makes the stream carry the
 * picture's size. Returns the raw format: the capture buffers must hold its
 * sizeimage.
 */
static struct v4l2_format encoder_formats(int fd, __u32 coded, const struct v4l2_format *cfmt,
					  const char *name)
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
	if (xioctl(fd, VIDIOC_S_FMT, &c))
		die("S_FMT encoder capture");
	o.fmt.pix_mp.width = w;
	o.fmt.pix_mp.height = h;
	o.fmt.pix_mp.pixelformat = cfmt->fmt.pix.pixelformat;
	o.fmt.pix_mp.num_planes = 1;
	o.fmt.pix_mp.plane_fmt[0].bytesperline = cfmt->fmt.pix.bytesperline;
	if (xioctl(fd, VIDIOC_S_FMT, &o))
		die("S_FMT encoder output");
	if (o.fmt.pix_mp.width != w || o.fmt.pix_mp.height != h) {
		sel.r.width = w;
		sel.r.height = h;
		if (xioctl(fd, VIDIOC_S_SELECTION, &sel))
			die("crop");
	}
	logline("%s: %ux%u in %ux%u, stride %u, size %u", name, w, h, o.fmt.pix_mp.width,
		o.fmt.pix_mp.height, o.fmt.pix_mp.plane_fmt[0].bytesperline,
		o.fmt.pix_mp.plane_fmt[0].sizeimage);
	if (o.fmt.pix_mp.plane_fmt[0].bytesperline != cfmt->fmt.pix.bytesperline)
		logline("%s: stride %u differs from the capture's %u: the picture will be skewed",
			name, o.fmt.pix_mp.plane_fmt[0].bytesperline, cfmt->fmt.pix.bytesperline);
	return o;
}

static void h264_open(const char *dev)
{
	h264.fd = open(dev, O_RDWR | O_NONBLOCK);
	h264.media = open_media(dev);
	if (h264.fd < 0 || h264.media < 0 ||
	    xioctl(h264.media, MEDIA_IOC_REQUEST_ALLOC, &h264.request))
		die("H.264 encoder");
}

/* After encoder_formats(). */
static void h264_start(unsigned int fps)
{
	enum v4l2_buf_type out_type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	enum v4l2_buf_type strm_type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	struct v4l2_streamparm parm = { .type = out_type };
	struct v4l2_requestbuffers req = { 0 };
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
	const char *qp = getenv("KVM_H264_QP");
	int i;

	h264.qp = qp ? (unsigned int)atoi(qp) : 30;
	parm.parm.output.timeperframe.numerator = 1;
	parm.parm.output.timeperframe.denominator = fps ? fps : 30;
	if (xioctl(h264.fd, VIDIOC_S_PARM, &parm))
		logline("S_PARM H.264: %s", strerror(errno));
	if (xioctl(h264.fd, VIDIOC_S_EXT_CTRLS, &cs))
		die("H.264 SPS/PPS");
	h264_ctrl(V4L2_CID_MPEG_VIDEO_PREPEND_SPSPPS_TO_IDR, 1);
	h264_ctrl(V4L2_CID_MPEG_VIDEO_FRAME_RC_ENABLE, 0);
	h264_ctrl(V4L2_CID_MPEG_VIDEO_H264_I_FRAME_QP, h264.qp);
	h264_ctrl(V4L2_CID_MPEG_VIDEO_H264_P_FRAME_QP, h264.qp);

	req.count = NCAP;
	req.type = out_type;
	req.memory = V4L2_MEMORY_DMABUF;
	if (xioctl(h264.fd, VIDIOC_REQBUFS, &req))
		die("REQBUFS H.264 output");
	memset(&req, 0, sizeof(req));
	req.count = NSTRM;
	req.type = strm_type;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(h264.fd, VIDIOC_REQBUFS, &req) || req.count < NSTRM)
		die("REQBUFS H.264 capture");
	for (i = 0; i < NSTRM; i++) {
		struct v4l2_plane plane = { 0 };
		struct v4l2_buffer buf = { .type = strm_type, .memory = V4L2_MEMORY_MMAP, .index = i,
					   .m.planes = &plane, .length = 1 };

		if (xioctl(h264.fd, VIDIOC_QUERYBUF, &buf))
			die("QUERYBUF H.264");
		h264.strm[i] = mmap(NULL, plane.length, PROT_READ, MAP_SHARED, h264.fd,
				    plane.m.mem_offset);
		if (h264.strm[i] == MAP_FAILED)
			die("mmap H.264");
		if (xioctl(h264.fd, VIDIOC_QBUF, &buf))
			die("QBUF H.264 capture");
	}
	if (xioctl(h264.fd, VIDIOC_STREAMON, &out_type) ||
	    xioctl(h264.fd, VIDIOC_STREAMON, &strm_type))
		die("STREAMON H.264");
	logline("H.264: QP %u, %u fps", h264.qp, parm.parm.output.timeperframe.denominator);
}

static void h264_queue(const struct v4l2_buffer *cbuf, int dmabuf_fd)
{
	struct v4l2_ctrl_h264_encode_params ep = { 0 };
	struct v4l2_ext_control c = { .id = V4L2_CID_STATELESS_H264_ENCODE_PARAMS,
				      .size = sizeof(ep), .ptr = &ep };
	struct v4l2_ext_controls cs = { .which = V4L2_CTRL_WHICH_REQUEST_VAL,
					.request_fd = h264.request, .count = 1, .controls = &c };
	struct v4l2_plane plane = { .m.fd = dmabuf_fd, .bytesused = cbuf->bytesused,
				    .length = cbuf->length };
	struct v4l2_buffer buf = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
				   .memory = V4L2_MEMORY_DMABUF, .index = cbuf->index,
				   .flags = V4L2_BUF_FLAG_REQUEST_FD,
				   .request_fd = h264.request, .m.planes = &plane, .length = 1 };

	if (h264.force_idr || h264.since_idr >= H264_IDR_EVERY) {
		h264.force_idr = 0;
		h264.since_idr = 0;
		h264.frame_num = 0;
		h264.poc = 0;
		ep.slice_type = V4L2_H264_SLICE_TYPE_I;
		ep.flags = V4L2_H264_ENCODE_FLAG_IDR_PIC;
		ep.idr_pic_id = h264.idr_pic_id++ & 0xffff;
		ep.nal_ref_idc = 3;
	} else {
		h264.frame_num = (h264.frame_num + 1) & 0xffff;
		h264.poc = (h264.poc + 2) & 0xffff;
		ep.slice_type = V4L2_H264_SLICE_TYPE_P;
		ep.nal_ref_idc = 2;
	}
	h264.since_idr++;
	ep.frame_num = h264.frame_num;
	ep.pic_order_cnt_lsb = h264.poc;

	if (xioctl(h264.fd, VIDIOC_S_EXT_CTRLS, &cs))
		die("H.264 encode params");
	if (xioctl(h264.fd, VIDIOC_QBUF, &buf))
		die("QBUF H.264 output");
	if (xioctl(h264.request, MEDIA_REQUEST_IOC_QUEUE, NULL))
		die("queue H.264 request");
	h264.busy = cbuf->index;
	h264.request_busy = 1;
}

/* Returns whether an access unit was sent. */
static int h264_send(void)
{
	struct v4l2_plane plane = { 0 };
	struct v4l2_buffer buf = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
				   .memory = V4L2_MEMORY_MMAP, .m.planes = &plane, .length = 1 };
	int sent = 0;

	if (xioctl(h264.fd, VIDIOC_DQBUF, &buf))
		return 0;
	if (buf.flags & V4L2_BUF_FLAG_ERROR) {
		logline("H.264 encode error");
		h264.force_idr = 1;
	} else {
		write_packet(buf.flags & V4L2_BUF_FLAG_KEYFRAME ? PKT_KEYFRAME : PKT_FRAME,
			     (char *)h264.strm[buf.index] + plane.data_offset,
			     plane.bytesused - plane.data_offset);
		sent = 1;
	}
	if (xioctl(h264.fd, VIDIOC_QBUF, &buf))
		die("QBUF H.264 capture");
	return sent;
}

static void h264_commands(void)
{
	char c[16];
	ssize_t n = read(STDIN_FILENO, c, sizeof(c)), i;

	if (n == 0)
		exit(0);	/* the port is gone */
	/* Kept until the encoder runs: commands can come while waiting for an input. */
	for (i = 0; i < n; i++) {
		if (c[i] == '1' && !h264.on) {
			h264.on = 1;
			h264.force_idr = 1;
		} else if (c[i] == '0') {
			h264.on = 0;
		} else if (c[i] == 'k') {
			h264.force_idr = 1;
		}
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
			h264_commands();
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
	struct v4l2_create_buffers cb = { .count = NCAP, .memory = V4L2_MEMORY_MMAP };
	struct v4l2_requestbuffers req;
	struct v4l2_control ctrl;
	int dmabuf[NCAP];
	int cap, enc, i, quality = 75, seconds = 0, port = 0, enc_busy = -1, run = 0, njpeg;
	unsigned int fps, bufsize;
	unsigned long gen = 0, captured = 0;
	const char *out = NULL, *h264_dev = NULL;
	double t0, tstat, tq = 0, lat_sum = 0;
	unsigned long ncap = 0, nenc = 0, bytes = 0, nstat_enc = 0, nstat_h264 = 0;
	pthread_t th;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <capture-dev> <encoder-dev> <port> [quality] [seconds]\n"
			"       %s <capture-dev> <encoder-dev> -o <out.jpg> [quality]\n", argv[0], argv[0]);
		return 2;
	}
	signal(SIGPIPE, SIG_IGN);
	packet_mode = getenv("KVM_PORT") != NULL;
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
	logline("capture %ux%u stride %u size %u", cfmt.fmt.pix.width, cfmt.fmt.pix.height,
	       cfmt.fmt.pix.bytesperline, cfmt.fmt.pix.sizeimage);
	bufsize = cfmt.fmt.pix.sizeimage;

	raw = encoder_formats(enc, V4L2_PIX_FMT_JPEG, &cfmt, "JPEG");
	if (raw.fmt.pix_mp.plane_fmt[0].sizeimage > bufsize)
		bufsize = raw.fmt.pix_mp.plane_fmt[0].sizeimage;
	ctrl.id = V4L2_CID_JPEG_COMPRESSION_QUALITY;
	ctrl.value = quality;
	if (xioctl(enc, VIDIOC_S_CTRL, &ctrl))
		logline("quality: %s", strerror(errno));

	if (packet_mode)
		h264_dev = getenv("KVM_H264_DEV");
	if (h264_dev) {
		h264_open(h264_dev);
		raw = encoder_formats(h264.fd, V4L2_PIX_FMT_H264_SLICE, &cfmt, "H.264");
		if (raw.fmt.pix_mp.plane_fmt[0].sizeimage > bufsize)
			bufsize = raw.fmt.pix_mp.plane_fmt[0].sizeimage;
	}

	/* The encoders read whole macroblock rows: the buffers hold them. */
	cb.format = cfmt;
	cb.format.fmt.pix.sizeimage = bufsize;
	if (xioctl(cap, VIDIOC_CREATE_BUFS, &cb) || cb.count < NCAP)
		die("CREATE_BUFS capture");
	for (i = 0; i < NCAP; i++) {
		struct v4l2_exportbuffer exp = { .type = cap_type, .index = i, .flags = O_RDWR };
		struct v4l2_buffer buf = { .type = cap_type, .memory = V4L2_MEMORY_MMAP, .index = i };

		if (xioctl(cap, VIDIOC_EXPBUF, &exp))
			die("EXPBUF");
		dmabuf[i] = exp.fd;
		if (xioctl(cap, VIDIOC_QBUF, &buf))
			die("QBUF capture");
	}

	memset(&req, 0, sizeof(req));
	req.count = NCAP;
	req.type = out_type;
	req.memory = V4L2_MEMORY_DMABUF;
	if (xioctl(enc, VIDIOC_REQBUFS, &req))
		die("REQBUFS encoder output");

	/* JPEG buffers are sized for the worst case (16.6 MB at 4K): with H.264
	 * as well, two of them leave room in CMA for its references. */
	njpeg = h264_dev ? 2 : NJPEG;
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
	if (h264_dev)
		h264_start(fps);
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
			{ .fd = h264.fd, .events = POLLIN | POLLOUT },
			{ .fd = h264.request_busy ? h264.request : -1, .events = POLLPRI },
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
			nstat_h264 += h264_send();

		if (pfd[3].revents & POLLOUT) {
			struct v4l2_plane plane = { 0 };
			struct v4l2_buffer hbuf = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
						    .memory = V4L2_MEMORY_DMABUF,
						    .m.planes = &plane, .length = 1 };

			if (!xioctl(h264.fd, VIDIOC_DQBUF, &hbuf)) {
				release_cap(cap, hbuf.index);
				h264.busy = -1;
			}
		}

		if (pfd[4].revents & POLLPRI) {
			if (xioctl(h264.request, MEDIA_REQUEST_IOC_REINIT, NULL))
				die("reinit H.264 request");
			h264.request_busy = 0;
		}

		if (pfd[5].revents & (POLLIN | POLLHUP))
			h264_commands();

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

				ncap++;
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
				if (h264.on && h264.fd >= 0 && h264.busy < 0 && !h264.request_busy) {
					h264_queue(&buf, dmabuf[buf.index]);
					refs++;
				}
				cap_refs[buf.index] = refs;
				if (!refs && xioctl(cap, VIDIOC_QBUF, &buf))
					die("QBUF capture");
			}
		}

		if (now() - tstat >= 5) {
			double dt = now() - tstat;

			logline("capture %.1f fps, jpeg %.1f fps, sent %.1f fps, %.0f KB avg, encode+wait %.1f ms, clients %d, h264 %.1f fps",
			       ncap / dt, nstat_enc / dt, __atomic_exchange_n(&nsent, 0, __ATOMIC_RELAXED) / dt,
			       nstat_enc ? bytes / 1024.0 / nstat_enc : 0,
			       nstat_enc ? lat_sum * 1000 / nstat_enc : 0, nclients, nstat_h264 / dt);
			ncap = nstat_enc = bytes = nstat_h264 = 0;
			lat_sum = 0;
			tstat = now();
		}
		if (seconds && now() - t0 > seconds)
			break;
	}
	return 0;
}

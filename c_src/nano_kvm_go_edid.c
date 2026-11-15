// SPDX-License-Identifier: Apache-2.0
/*
 * nano_kvm_go_edid: reads or stores the EDID that the video input presents to
 * the source.
 *
 * Usage: nano_kvm_go_edid <video-device>          writes the EDID to stdout
 *        nano_kvm_go_edid <video-device> <hex>    stores the EDID given in hex
 *
 * On failure the reason goes to stderr and the exit status is 1.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BLOCK 128
#define MAX_BLOCKS 4

static int fail(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	return 1;
}

static int get_edid(int fd)
{
	unsigned char data[BLOCK * MAX_BLOCKS];
	struct v4l2_edid edid = { .blocks = MAX_BLOCKS, .edid = data };
	size_t len, off;

	if (ioctl(fd, VIDIOC_G_EDID, &edid) < 0)
		return fail("VIDIOC_G_EDID");

	len = edid.blocks * BLOCK;
	for (off = 0; off < len;) {
		ssize_t w = write(STDOUT_FILENO, data + off, len - off);

		if (w < 0 && errno == EINTR)
			continue;
		if (w <= 0)
			return fail("write");
		off += w;
	}

	return 0;
}

static int nibble(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

static int set_edid(int fd, const char *hex)
{
	unsigned char data[BLOCK * MAX_BLOCKS];
	size_t len = strlen(hex) / 2, i;
	struct v4l2_edid edid = { .edid = data };

	if (strlen(hex) % 2 || !len || len % BLOCK || len > sizeof(data)) {
		fprintf(stderr, "the EDID must be 1 to %d blocks of %d bytes\n", MAX_BLOCKS, BLOCK);
		return 1;
	}
	for (i = 0; i < len; i++) {
		int hi = nibble(hex[2 * i]), lo = nibble(hex[2 * i + 1]);

		if (hi < 0 || lo < 0) {
			fprintf(stderr, "the EDID is not in hex\n");
			return 1;
		}
		data[i] = hi << 4 | lo;
	}

	edid.blocks = len / BLOCK;
	if (ioctl(fd, VIDIOC_S_EDID, &edid) < 0)
		return fail("VIDIOC_S_EDID");

	return 0;
}

int main(int argc, char **argv)
{
	int fd;

	if (argc != 2 && argc != 3) {
		fprintf(stderr, "usage: %s <video-device> [<hex>]\n", argv[0]);
		return 2;
	}

	fd = open(argv[1], O_RDWR);
	if (fd < 0)
		return fail(argv[1]);

	return argc == 2 ? get_edid(fd) : set_edid(fd, argv[2]);
}

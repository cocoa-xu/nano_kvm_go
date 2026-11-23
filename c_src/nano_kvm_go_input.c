// SPDX-License-Identifier: Apache-2.0
/*
 * nano_kvm_go_input: reads a Linux input device for an Erlang port.
 *
 * Usage: nano_kvm_go_input <event-device>
 *
 * stdout carries {packet, 4} frames of a type byte and a payload: 0 a log
 * line, 1 the events of one read of the device, 8 bytes each, little
 * endian: the type and the code (16 bits) and the value (32 bits, signed),
 * without the time. The end of stdin stops the program; it exits with
 * status 1 when the device cannot be read, as when it goes away.
 */
#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { PKT_LOG = 0, PKT_EVENTS = 1 };

#define MAX_EVENTS 64
#define EVENT_SIZE 8

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

static int fail(const char *fmt, ...)
{
	char line[256];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	if (n >= 0)
		packet(PKT_LOG, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1);
	return 1;
}

static void send_events(const struct input_event *events, size_t count)
{
	uint8_t out[MAX_EVENTS * EVENT_SIZE];
	size_t i;

	for (i = 0; i < count; i++) {
		uint16_t type = htole16(events[i].type), code = htole16(events[i].code);
		uint32_t value = htole32((uint32_t)events[i].value);

		memcpy(out + i * EVENT_SIZE, &type, 2);
		memcpy(out + i * EVENT_SIZE + 2, &code, 2);
		memcpy(out + i * EVENT_SIZE + 4, &value, 4);
	}
	packet(PKT_EVENTS, out, count * EVENT_SIZE);
}

int main(int argc, char **argv)
{
	struct input_event events[MAX_EVENTS];
	struct pollfd fds[2] = {
		{ .fd = STDIN_FILENO, .events = POLLIN },
		{ .events = POLLIN },
	};

	if (argc != 2) {
		fprintf(stderr, "usage: %s <event-device>\n", argv[0]);
		return 2;
	}

	fds[1].fd = open(argv[1], O_RDONLY | O_CLOEXEC);
	if (fds[1].fd < 0)
		return fail("%s: %s", argv[1], strerror(errno));

	for (;;) {
		ssize_t n;

		if (poll(fds, 2, -1) < 0) {
			if (errno == EINTR)
				continue;
			return fail("poll: %s", strerror(errno));
		}
		/* Nothing comes on stdin but its end. */
		if (fds[0].revents)
			return 0;
		if (!fds[1].revents)
			continue;

		n = read(fds[1].fd, events, sizeof(events));
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0)
			return fail("%s: %s", argv[1], strerror(errno));
		if (n == 0)
			return fail("%s: end of file", argv[1]);
		send_events(events, n / sizeof(*events));
	}
}

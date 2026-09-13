// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Repack single-planar V4L2 YU12 frames with hardware line padding into
 * tightly packed YUV420p on stdout.  Intended for AtomISP userspace testing.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

struct mapped_buffer {
    void *addr;
    size_t length;
};

static volatile sig_atomic_t stop_requested;

static void on_signal(int signo)
{
    (void)signo;
    stop_requested = 1;
}

static int xioctl(int fd, unsigned long request, void *arg)
{
    int ret;

    do {
        ret = ioctl(fd, request, arg);
    } while (ret < 0 && errno == EINTR);

    return ret;
}

static void die_errno(const char *what)
{
    fprintf(stderr, "%s: %s\n", what, strerror(errno));
    exit(EXIT_FAILURE);
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [--probe] [--input N] [--buffers N] DEVICE\n"
            "       %s --selftest\n"
            "\n"
            "Select a V4L2 input, negotiate YU12, and either print the\n"
            "negotiated WIDTHxHEIGHT (--probe) or stream tightly packed\n"
            "YUV420p frames to stdout.\n",
            prog, prog);
}

static int write_all(int fd, const uint8_t *data, size_t len)
{
    while (len) {
        ssize_t n = write(fd, data, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno == EPIPE)
                return -1;
            die_errno("write");
        }
        data += (size_t)n;
        len -= (size_t)n;
    }
    return 0;
}

static void pick_initial_size(int fd, uint32_t *width, uint32_t *height)
{
    struct v4l2_frmsizeenum fsize = {
        .index = 0,
        .pixel_format = V4L2_PIX_FMT_YUV420,
    };

    if (xioctl(fd, VIDIOC_ENUM_FRAMESIZES, &fsize) == 0 &&
        fsize.type == V4L2_FRMSIZE_TYPE_DISCRETE) {
        *width = fsize.discrete.width;
        *height = fsize.discrete.height;
        return;
    }

    struct v4l2_format current = {
        .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
    };

    if (xioctl(fd, VIDIOC_G_FMT, &current) < 0)
        die_errno("VIDIOC_ENUM_FRAMESIZES and VIDIOC_G_FMT both failed");

    *width = current.fmt.pix.width;
    *height = current.fmt.pix.height;
}

static struct v4l2_format negotiate_yu12(int fd, unsigned int input)
{
    if (xioctl(fd, VIDIOC_S_INPUT, &input) < 0)
        die_errno("VIDIOC_S_INPUT");

    uint32_t width = 0, height = 0;
    pick_initial_size(fd, &width, &height);

    if (!width || !height) {
        fprintf(stderr, "driver returned an invalid initial frame size %ux%u\n",
                width, height);
        exit(EXIT_FAILURE);
    }

    struct v4l2_format fmt = {
        .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
    };
    fmt.fmt.pix.width = width;
    fmt.fmt.pix.height = height;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUV420;
    fmt.fmt.pix.field = V4L2_FIELD_ANY;

    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0)
        die_errno("VIDIOC_S_FMT(YU12)");

    if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUV420) {
        fprintf(stderr,
                "driver did not accept YU12; returned fourcc %c%c%c%c\n",
                fmt.fmt.pix.pixelformat & 0xff,
                (fmt.fmt.pix.pixelformat >> 8) & 0xff,
                (fmt.fmt.pix.pixelformat >> 16) & 0xff,
                (fmt.fmt.pix.pixelformat >> 24) & 0xff);
        exit(EXIT_FAILURE);
    }

    const uint32_t w = fmt.fmt.pix.width;
    const uint32_t h = fmt.fmt.pix.height;
    const uint32_t stride = fmt.fmt.pix.bytesperline;

    if (!w || !h || (w & 1) || (h & 1)) {
        fprintf(stderr, "YU12 needs a non-zero even size; driver returned %ux%u\n", w, h);
        exit(EXIT_FAILURE);
    }
    if (stride < w || (stride & 1)) {
        fprintf(stderr,
                "invalid YU12 bytesperline %u for width %u (must be even and >= width)\n",
                stride, w);
        exit(EXIT_FAILURE);
    }

    return fmt;
}

static size_t checked_yu12_size(uint32_t stride, uint32_t height)
{
    const uint64_t value = (uint64_t)stride * height * 3 / 2;
    if (value > SIZE_MAX) {
        fprintf(stderr, "YU12 frame size overflow\n");
        exit(EXIT_FAILURE);
    }
    return (size_t)value;
}

static void repack_yu12(uint8_t *dst, const uint8_t *src,
                        uint32_t width, uint32_t height, uint32_t y_stride)
{
    const uint32_t c_width = width / 2;
    const uint32_t c_height = height / 2;
    const uint32_t c_stride = y_stride / 2;

    const uint8_t *src_y = src;
    const uint8_t *src_u = src_y + (size_t)y_stride * height;
    const uint8_t *src_v = src_u + (size_t)c_stride * c_height;

    uint8_t *dst_y = dst;
    uint8_t *dst_u = dst_y + (size_t)width * height;
    uint8_t *dst_v = dst_u + (size_t)c_width * c_height;

    for (uint32_t row = 0; row < height; row++)
        memcpy(dst_y + (size_t)row * width,
               src_y + (size_t)row * y_stride, width);

    for (uint32_t row = 0; row < c_height; row++) {
        memcpy(dst_u + (size_t)row * c_width,
               src_u + (size_t)row * c_stride, c_width);
        memcpy(dst_v + (size_t)row * c_width,
               src_v + (size_t)row * c_stride, c_width);
    }
}

static int run_selftest(void)
{
    enum { W = 6, H = 4, STRIDE = 8 };
    uint8_t src[STRIDE * H * 3 / 2];
    uint8_t dst[W * H * 3 / 2];
    uint8_t expected[W * H * 3 / 2];
    size_t pos = 0;

    memset(src, 0xee, sizeof(src));
    memset(dst, 0, sizeof(dst));

    /* Y: four rows, six visible bytes plus two sentinel padding bytes. */
    for (unsigned int row = 0; row < H; row++)
        for (unsigned int col = 0; col < W; col++)
            src[row * STRIDE + col] = (uint8_t)(1 + row * W + col);

    /* U and V: two rows each, three visible bytes plus one padding byte. */
    const size_t u_off = STRIDE * H;
    const size_t c_stride = STRIDE / 2;
    const size_t c_height = H / 2;
    const size_t v_off = u_off + c_stride * c_height;
    for (unsigned int row = 0; row < c_height; row++) {
        for (unsigned int col = 0; col < W / 2; col++) {
            src[u_off + row * c_stride + col] = (uint8_t)(101 + row * (W / 2) + col);
            src[v_off + row * c_stride + col] = (uint8_t)(151 + row * (W / 2) + col);
        }
    }

    for (unsigned int i = 0; i < W * H; i++)
        expected[pos++] = (uint8_t)(1 + i);
    for (unsigned int i = 0; i < (W / 2) * (H / 2); i++)
        expected[pos++] = (uint8_t)(101 + i);
    for (unsigned int i = 0; i < (W / 2) * (H / 2); i++)
        expected[pos++] = (uint8_t)(151 + i);

    repack_yu12(dst, src, W, H, STRIDE);
    if (memcmp(dst, expected, sizeof(dst))) {
        fprintf(stderr, "selftest FAILED: padded YU12 repack mismatch\n");
        return EXIT_FAILURE;
    }

    fprintf(stderr, "selftest PASS: padded Y/U/V rows compacted correctly\n");
    return EXIT_SUCCESS;
}

int main(int argc, char **argv)
{
    unsigned int input = 0;
    unsigned int requested_buffers = 4;
    int probe_only = 0;
    int selftest = 0;
    const char *device = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--probe")) {
            probe_only = 1;
        } else if (!strcmp(argv[i], "--selftest")) {
            selftest = 1;
        } else if (!strcmp(argv[i], "--input")) {
            if (++i >= argc) {
                usage(argv[0]);
                return EXIT_FAILURE;
            }
            char *end = NULL;
            unsigned long v = strtoul(argv[i], &end, 0);
            if (!end || *end || v > UINT32_MAX) {
                fprintf(stderr, "invalid input index: %s\n", argv[i]);
                return EXIT_FAILURE;
            }
            input = (unsigned int)v;
        } else if (!strcmp(argv[i], "--buffers")) {
            if (++i >= argc) {
                usage(argv[0]);
                return EXIT_FAILURE;
            }
            char *end = NULL;
            unsigned long v = strtoul(argv[i], &end, 0);
            if (!end || *end || v < 2 || v > 32) {
                fprintf(stderr, "buffer count must be between 2 and 32\n");
                return EXIT_FAILURE;
            }
            requested_buffers = (unsigned int)v;
        } else if (argv[i][0] == '-') {
            usage(argv[0]);
            return EXIT_FAILURE;
        } else if (!device) {
            device = argv[i];
        } else {
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }

    if (selftest) {
        if (device || probe_only) {
            usage(argv[0]);
            return EXIT_FAILURE;
        }
        return run_selftest();
    }

    if (!device) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }

    int fd = open(device, O_RDWR | O_CLOEXEC);
    if (fd < 0)
        die_errno("open V4L2 device");

    struct v4l2_capability cap = {0};
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0)
        die_errno("VIDIOC_QUERYCAP");

    uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ?
                    cap.device_caps : cap.capabilities;
    if (!(caps & V4L2_CAP_VIDEO_CAPTURE)) {
        fprintf(stderr, "%s is not a single-planar video capture device\n", device);
        return EXIT_FAILURE;
    }
    if (!(caps & V4L2_CAP_STREAMING)) {
        fprintf(stderr, "%s does not advertise V4L2 streaming I/O\n", device);
        return EXIT_FAILURE;
    }

    struct v4l2_format fmt = negotiate_yu12(fd, input);
    const uint32_t width = fmt.fmt.pix.width;
    const uint32_t height = fmt.fmt.pix.height;
    const uint32_t y_stride = fmt.fmt.pix.bytesperline;
    const size_t padded_payload = checked_yu12_size(y_stride, height);
    const size_t tight_payload = checked_yu12_size(width, height);

    fprintf(stderr,
            "input=%u device=%s YU12=%ux%u bytesperline=%u sizeimage=%u "
            "padded-payload=%zu tight-payload=%zu\n",
            input, device, width, height, y_stride, fmt.fmt.pix.sizeimage,
            padded_payload, tight_payload);

    if (fmt.fmt.pix.sizeimage < padded_payload) {
        fprintf(stderr,
                "driver sizeimage %u is smaller than the YU12 padded payload %zu\n",
                fmt.fmt.pix.sizeimage, padded_payload);
        return EXIT_FAILURE;
    }

    if (probe_only) {
        printf("%ux%u\n", width, height);
        close(fd);
        return EXIT_SUCCESS;
    }

    struct v4l2_requestbuffers req = {
        .count = requested_buffers,
        .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
        .memory = V4L2_MEMORY_MMAP,
    };
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0)
        die_errno("VIDIOC_REQBUFS");
    if (req.count < 2) {
        fprintf(stderr, "driver allocated only %u capture buffer(s)\n", req.count);
        return EXIT_FAILURE;
    }

    struct mapped_buffer *buffers = calloc(req.count, sizeof(*buffers));
    if (!buffers)
        die_errno("calloc buffers");

    for (unsigned int i = 0; i < req.count; i++) {
        struct v4l2_buffer buf = {
            .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
            .memory = V4L2_MEMORY_MMAP,
            .index = i,
        };
        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0)
            die_errno("VIDIOC_QUERYBUF");

        buffers[i].length = buf.length;
        buffers[i].addr = mmap(NULL, buf.length, PROT_READ | PROT_WRITE,
                               MAP_SHARED, fd, buf.m.offset);
        if (buffers[i].addr == MAP_FAILED)
            die_errno("mmap V4L2 buffer");

        if (buffers[i].length < padded_payload) {
            fprintf(stderr,
                    "buffer %u length %zu is smaller than padded payload %zu\n",
                    i, buffers[i].length, padded_payload);
            return EXIT_FAILURE;
        }

        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0)
            die_errno("VIDIOC_QBUF(initial)");
    }

    uint8_t *tight = malloc(tight_payload);
    if (!tight)
        die_errno("malloc tight frame");

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0)
        die_errno("VIDIOC_STREAMON");

    struct sigaction sa = {0};
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    int status = EXIT_SUCCESS;
    while (!stop_requested) {
        struct pollfd pfd = {
            .fd = fd,
            .events = POLLIN | POLLPRI,
        };
        int pret = poll(&pfd, 1, 1000);
        if (pret < 0) {
            if (errno == EINTR)
                continue;
            die_errno("poll");
        }
        if (pret == 0)
            continue;

        struct v4l2_buffer buf = {
            .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
            .memory = V4L2_MEMORY_MMAP,
        };
        if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN)
                continue;
            die_errno("VIDIOC_DQBUF");
        }
        if (buf.index >= req.count) {
            fprintf(stderr, "driver returned invalid buffer index %u\n", buf.index);
            status = EXIT_FAILURE;
            break;
        }

        if (!(buf.flags & V4L2_BUF_FLAG_ERROR)) {
            if (buf.bytesused < padded_payload) {
                fprintf(stderr,
                        "short V4L2 payload: bytesused=%u, need at least %zu for stride layout\n",
                        buf.bytesused, padded_payload);
                status = EXIT_FAILURE;
                break;
            }

            repack_yu12(tight, buffers[buf.index].addr,
                        width, height, y_stride);
            if (write_all(STDOUT_FILENO, tight, tight_payload) < 0)
                break;
        } else {
            fprintf(stderr, "dropping V4L2 buffer %u flagged ERROR\n", buf.index);
        }

        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0)
            die_errno("VIDIOC_QBUF(requeue)");
    }

    xioctl(fd, VIDIOC_STREAMOFF, &type);
    for (unsigned int i = 0; i < req.count; i++) {
        if (buffers[i].addr && buffers[i].addr != MAP_FAILED)
            munmap(buffers[i].addr, buffers[i].length);
    }
    free(tight);
    free(buffers);
    close(fd);
    return status;
}

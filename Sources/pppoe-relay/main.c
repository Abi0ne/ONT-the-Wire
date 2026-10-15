// pppoe-relay: PPPoE client transport (RFC 2516) over an optional 802.1Q VLAN
// tag, for pppd's `pty` option.
//
// macOS' built-in PPPoE cannot run on a VLAN interface (it ends up on en<N>),
// so this program talks to the physical Ethernet interface through BPF and
// adds the VLAN tag itself. It performs discovery (PADI/PADO/PADR/PADS), then
// relays session frames between the wire and pppd, which talks async HDLC on
// stdin/stdout. Requires root (BPF).
//
// Status lines go to stderr (and to -L <file>), prefixed by "pppoe-relay:".
// Lines starting with "STATUS " are machine-readable for the app.

#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/bpf.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/time.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define ETHERTYPE_VLAN 0x8100
#define ETHERTYPE_DISC 0x8863
#define ETHERTYPE_SESS 0x8864

#define CODE_PADI 0x09
#define CODE_PADO 0x07
#define CODE_PADR 0x19
#define CODE_PADS 0x65
#define CODE_PADT 0xa7
#define CODE_SESS 0x00

#define TAG_END 0x0000
#define TAG_SERVICE_NAME 0x0101
#define TAG_AC_NAME 0x0102
#define TAG_HOST_UNIQ 0x0103
#define TAG_AC_COOKIE 0x0104
#define TAG_RELAY_ID 0x0110
#define TAG_SERVICE_NAME_ERROR 0x0201
#define TAG_AC_SYSTEM_ERROR 0x0202
#define TAG_GENERIC_ERROR 0x0203

#define MAX_FRAME 1600
#define MAX_PPP_PAYLOAD 1494 // 1500 - 6 bytes PPPoE header
#define DISCOVERY_RETRY_SECONDS 3

enum {
    EXIT_OK = 0,
    EXIT_SYSTEM = 1,
    EXIT_NO_PADO = 2,
    EXIT_NO_PADS = 3,
    EXIT_PADT = 4,
};

// MARK: Options and state

static const char *opt_ifname;
static int opt_vlan = -1; // -1: untagged
static int opt_pcp = 0;
static const char *opt_service = "";
static const char *opt_ac_name;
static int opt_timeout = 30;
static int opt_discovery_only;
static FILE *log_file;

static int bpf_fd = -1;
static size_t bpf_buf_len;
static uint8_t *bpf_buf;
static uint8_t my_mac[6];
static uint8_t ac_mac[6];
static uint16_t session_id;
static uint8_t host_uniq[4];
static uint8_t cookie[256];
static size_t cookie_len;
static uint8_t relay_id[256];
static size_t relay_id_len;
static volatile sig_atomic_t stop_requested;

static const uint8_t broadcast_mac[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};

static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    fprintf(stderr, "pppoe-relay: %s\n", line);
    if (log_file) {
        time_t now = time(NULL);
        char stamp[32];
        strftime(stamp, sizeof stamp, "%H:%M:%S", localtime(&now));
        fprintf(log_file, "%s pppoe-relay: %s\n", stamp, line);
        fflush(log_file);
    }
}

static void format_mac(const uint8_t *mac, char out[18]) {
    snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static void on_signal(int sig) {
    (void)sig;
    stop_requested = 1;
}

// MARK: Interface and BPF

static int read_mac(const char *ifname, uint8_t mac[6]) {
    struct ifaddrs *list, *ifa;
    if (getifaddrs(&list) != 0) return -1;
    int found = -1;
    for (ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_LINK) continue;
        if (strcmp(ifa->ifa_name, ifname) != 0) continue;
        struct sockaddr_dl *sdl = (struct sockaddr_dl *)ifa->ifa_addr;
        if (sdl->sdl_alen == 6) {
            memcpy(mac, LLADDR(sdl), 6);
            found = 0;
        }
        break;
    }
    freeifaddrs(list);
    return found;
}

static int open_bpf(void) {
    char path[16];
    for (int i = 0; i < 256; i++) {
        snprintf(path, sizeof path, "/dev/bpf%d", i);
        int fd = open(path, O_RDWR);
        if (fd >= 0) return fd;
        if (errno != EBUSY) break;
    }
    return -1;
}

static int setup_bpf(void) {
    bpf_fd = open_bpf();
    if (bpf_fd < 0) {
        logmsg("impossibile aprire /dev/bpf: %s (serve root)", strerror(errno));
        return -1;
    }
    // Large buffer: at gigabit rates many frames arrive per read() (the
    // kernel caps it at debug.bpf_maxbufsize, 512 KB by default).
    u_int blen = 512 * 1024;
    while (ioctl(bpf_fd, BIOCSBLEN, &blen) < 0 && blen > 32768) blen /= 2;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strlcpy(ifr.ifr_name, opt_ifname, sizeof ifr.ifr_name);
    if (ioctl(bpf_fd, BIOCSETIF, &ifr) < 0) {
        logmsg("BIOCSETIF %s: %s", opt_ifname, strerror(errno));
        return -1;
    }
    if (ioctl(bpf_fd, BIOCGBLEN, &blen) < 0) return -1;
    bpf_buf_len = blen;
    bpf_buf = malloc(bpf_buf_len);
    if (!bpf_buf) return -1;

    u_int one = 1, zero = 0;
    ioctl(bpf_fd, BIOCIMMEDIATE, &one);
    ioctl(bpf_fd, BIOCSHDRCMPLT, &one); // we supply the source MAC
    ioctl(bpf_fd, BIOCSSEESENT, &zero); // do not read back our own frames

    // Accept only PPPoE discovery/session frames, on our VLAN when tagged.
    struct bpf_insn tagged[] = {
        BPF_STMT(BPF_LD + BPF_H + BPF_ABS, 12),
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ETHERTYPE_VLAN, 0, 6),
        BPF_STMT(BPF_LD + BPF_H + BPF_ABS, 14),
        BPF_STMT(BPF_ALU + BPF_AND + BPF_K, 0x0fff),
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, (u_int)opt_vlan, 0, 3),
        BPF_STMT(BPF_LD + BPF_H + BPF_ABS, 16),
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ETHERTYPE_DISC, 2, 0),
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ETHERTYPE_SESS, 1, 0),
        BPF_STMT(BPF_RET + BPF_K, 0),
        BPF_STMT(BPF_RET + BPF_K, (u_int)-1),
    };
    struct bpf_insn untagged[] = {
        BPF_STMT(BPF_LD + BPF_H + BPF_ABS, 12),
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ETHERTYPE_DISC, 2, 0),
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ETHERTYPE_SESS, 1, 0),
        BPF_STMT(BPF_RET + BPF_K, 0),
        BPF_STMT(BPF_RET + BPF_K, (u_int)-1),
    };
    struct bpf_program prog;
    if (opt_vlan >= 0) {
        prog.bf_len = sizeof tagged / sizeof tagged[0];
        prog.bf_insns = tagged;
    } else {
        prog.bf_len = sizeof untagged / sizeof untagged[0];
        prog.bf_insns = untagged;
    }
    if (ioctl(bpf_fd, BIOCSETF, &prog) < 0) {
        logmsg("BIOCSETF: %s", strerror(errno));
        return -1;
    }
    return 0;
}

// MARK: Frames

static size_t l2_header_len(void) { return opt_vlan >= 0 ? 18 : 14; }

/// Builds Ethernet (+802.1Q) + PPPoE header into `frame`; returns the offset
/// of the PPPoE payload.
static size_t build_header(uint8_t *frame, const uint8_t *dst, uint16_t ethertype, uint8_t code,
                           uint16_t session, uint16_t payload_len) {
    size_t off = 0;
    memcpy(frame, dst, 6);
    memcpy(frame + 6, my_mac, 6);
    off = 12;
    if (opt_vlan >= 0) {
        uint16_t tci = (uint16_t)((opt_pcp & 7) << 13 | (opt_vlan & 0x0fff));
        frame[off++] = ETHERTYPE_VLAN >> 8;
        frame[off++] = ETHERTYPE_VLAN & 0xff;
        frame[off++] = tci >> 8;
        frame[off++] = tci & 0xff;
    }
    frame[off++] = ethertype >> 8;
    frame[off++] = ethertype & 0xff;
    frame[off++] = 0x11; // version 1, type 1
    frame[off++] = code;
    frame[off++] = session >> 8;
    frame[off++] = session & 0xff;
    frame[off++] = payload_len >> 8;
    frame[off++] = payload_len & 0xff;
    return off;
}

static size_t put_tag(uint8_t *p, uint16_t type, const void *value, size_t len) {
    p[0] = type >> 8;
    p[1] = type & 0xff;
    p[2] = (uint8_t)(len >> 8);
    p[3] = len & 0xff;
    if (len) memcpy(p + 4, value, len);
    return 4 + len;
}

static int send_frame(const uint8_t *frame, size_t len) {
    // Pad to the Ethernet minimum.
    uint8_t padded[MAX_FRAME];
    size_t min = 60;
    if (len < min) {
        memcpy(padded, frame, len);
        memset(padded + len, 0, min - len);
        frame = padded;
        len = min;
    }
    if (write(bpf_fd, frame, len) != (ssize_t)len) {
        logmsg("invio frame: %s", strerror(errno));
        return -1;
    }
    return 0;
}

static int send_discovery(uint8_t code, const uint8_t *dst, uint16_t session) {
    uint8_t frame[MAX_FRAME];
    uint8_t tags[512];
    size_t t = 0;
    if (code == CODE_PADI || code == CODE_PADR) {
        t += put_tag(tags + t, TAG_SERVICE_NAME, opt_service, strlen(opt_service));
        t += put_tag(tags + t, TAG_HOST_UNIQ, host_uniq, sizeof host_uniq);
    }
    if (code == CODE_PADR && cookie_len) t += put_tag(tags + t, TAG_AC_COOKIE, cookie, cookie_len);
    if (code == CODE_PADR && relay_id_len) t += put_tag(tags + t, TAG_RELAY_ID, relay_id, relay_id_len);
    size_t off = build_header(frame, dst, ETHERTYPE_DISC, code, session, (uint16_t)t);
    memcpy(frame + off, tags, t);
    return send_frame(frame, off + t);
}

/// A received PPPoE frame, already validated against the L2 header.
struct pppoe_frame {
    const uint8_t *src;
    const uint8_t *dst;
    uint16_t ethertype;
    uint8_t code;
    uint16_t session;
    const uint8_t *payload;
    uint16_t payload_len;
};

static int parse_frame(const uint8_t *data, size_t caplen, struct pppoe_frame *out) {
    size_t hl = l2_header_len();
    if (caplen < hl + 6) return -1;
    out->dst = data;
    out->src = data + 6;
    out->ethertype = (uint16_t)(data[hl - 2] << 8 | data[hl - 1]);
    const uint8_t *p = data + hl;
    if (p[0] != 0x11) return -1;
    out->code = p[1];
    out->session = (uint16_t)(p[2] << 8 | p[3]);
    uint16_t len = (uint16_t)(p[4] << 8 | p[5]);
    if (len > caplen - hl - 6) return -1;
    out->payload = p + 6;
    out->payload_len = len;
    if (memcmp(out->dst, my_mac, 6) != 0 && memcmp(out->dst, broadcast_mac, 6) != 0) return -1;
    return 0;
}

/// Iterates the tags of a discovery payload. Returns 0 at the end.
static int next_tag(const uint8_t **cursor, const uint8_t *end, uint16_t *type, const uint8_t **value, uint16_t *len) {
    if (*cursor + 4 > end) return 0;
    *type = (uint16_t)((*cursor)[0] << 8 | (*cursor)[1]);
    *len = (uint16_t)((*cursor)[2] << 8 | (*cursor)[3]);
    *value = *cursor + 4;
    if (*value + *len > end) return 0;
    *cursor = *value + *len;
    return *type != TAG_END;
}

// MARK: Discovery

typedef int (*frame_handler)(const struct pppoe_frame *frame, void *ctx);

/// Reads frames until `handler` returns non-zero, `seconds` elapse or a stop
/// is requested. Returns the handler's value, 0 on timeout, -1 on error.
static int wait_frames(double seconds, frame_handler handler, void *ctx) {
    struct timeval start, now;
    gettimeofday(&start, NULL);
    for (;;) {
        if (stop_requested) return -1;
        gettimeofday(&now, NULL);
        double elapsed = (double)(now.tv_sec - start.tv_sec) + (now.tv_usec - start.tv_usec) / 1e6;
        double left = seconds - elapsed;
        if (left <= 0) return 0;
        struct timeval tv = {(time_t)left, (int)((left - (time_t)left) * 1e6)};
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(bpf_fd, &rfds);
        int r = select(bpf_fd + 1, &rfds, NULL, NULL, &tv);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) return 0;
        ssize_t n = read(bpf_fd, bpf_buf, bpf_buf_len);
        if (n < 0) {
            if (errno == EINTR) continue;
            logmsg("lettura BPF: %s", strerror(errno));
            return -1;
        }
        for (uint8_t *p = bpf_buf; p < bpf_buf + n;) {
            struct bpf_hdr *h = (struct bpf_hdr *)p;
            struct pppoe_frame f;
            if (parse_frame(p + h->bh_hdrlen, h->bh_caplen, &f) == 0) {
                int result = handler(&f, ctx);
                if (result) return result;
            }
            p += BPF_WORDALIGN(h->bh_hdrlen + h->bh_caplen);
        }
    }
}

static void tag_string(const uint8_t *value, uint16_t len, char *out, size_t size) {
    size_t n = len < size - 1 ? len : size - 1;
    for (size_t i = 0; i < n; i++) out[i] = (value[i] >= 0x20 && value[i] < 0x7f) ? (char)value[i] : '?';
    out[n] = 0;
}

static int host_uniq_matches(const struct pppoe_frame *f) {
    const uint8_t *cursor = f->payload, *end = f->payload + f->payload_len, *value;
    uint16_t type, len;
    while (next_tag(&cursor, end, &type, &value, &len)) {
        if (type == TAG_HOST_UNIQ) return len == sizeof host_uniq && memcmp(value, host_uniq, len) == 0;
    }
    return 0;
}

/// Reports error tags; returns 1 if any was present.
static int report_errors(const struct pppoe_frame *f) {
    const uint8_t *cursor = f->payload, *end = f->payload + f->payload_len, *value;
    uint16_t type, len;
    int found = 0;
    char text[256];
    while (next_tag(&cursor, end, &type, &value, &len)) {
        const char *what = NULL;
        if (type == TAG_SERVICE_NAME_ERROR) what = "Service-Name-Error";
        if (type == TAG_AC_SYSTEM_ERROR) what = "AC-System-Error";
        if (type == TAG_GENERIC_ERROR) what = "Generic-Error";
        if (what) {
            tag_string(value, len, text, sizeof text);
            logmsg("STATUS error %s %s", what, text);
            found = 1;
        }
    }
    return found;
}

struct pado_ctx {
    int count;
};

static int handle_pado(const struct pppoe_frame *f, void *ctx) {
    struct pado_ctx *c = ctx;
    if (f->ethertype != ETHERTYPE_DISC || f->code != CODE_PADO) return 0;
    if (memcmp(f->dst, my_mac, 6) != 0 || !host_uniq_matches(f)) return 0;

    char mac[18], ac_name[128] = "", service[128] = "";
    int has_service = 0;
    size_t new_cookie_len = 0, new_relay_len = 0;
    uint8_t new_cookie[256], new_relay[256];
    const uint8_t *cursor = f->payload, *end = f->payload + f->payload_len, *value;
    uint16_t type, len;
    while (next_tag(&cursor, end, &type, &value, &len)) {
        switch (type) {
        case TAG_AC_NAME: tag_string(value, len, ac_name, sizeof ac_name); break;
        case TAG_SERVICE_NAME:
            tag_string(value, len, service, sizeof service);
            if (len == strlen(opt_service) && memcmp(value, opt_service, len) == 0) has_service = 1;
            if (opt_service[0] == 0) has_service = 1;
            break;
        case TAG_AC_COOKIE:
            if (len <= sizeof new_cookie) { memcpy(new_cookie, value, len); new_cookie_len = len; }
            break;
        case TAG_RELAY_ID:
            if (len <= sizeof new_relay) { memcpy(new_relay, value, len); new_relay_len = len; }
            break;
        }
    }
    format_mac(f->src, mac);
    if (report_errors(f)) return 0;
    logmsg("STATUS pado %s ac=\"%s\" service=\"%s\"", mac, ac_name, service);
    c->count++;
    if (opt_discovery_only) return 0; // keep collecting offers
    if (!has_service) return 0;
    if (opt_ac_name && strcmp(opt_ac_name, ac_name) != 0) return 0;

    memcpy(ac_mac, f->src, 6);
    memcpy(cookie, new_cookie, new_cookie_len);
    cookie_len = new_cookie_len;
    memcpy(relay_id, new_relay, new_relay_len);
    relay_id_len = new_relay_len;
    return 1;
}

static int handle_pads(const struct pppoe_frame *f, void *ctx) {
    (void)ctx;
    if (f->ethertype != ETHERTYPE_DISC || memcmp(f->src, ac_mac, 6) != 0) return 0;
    if (f->code == CODE_PADT) return -1;
    if (f->code != CODE_PADS || !host_uniq_matches(f)) return 0;
    if (report_errors(f) || f->session == 0) return -1;
    session_id = f->session;
    return 1;
}

static int discover(void) {
    char mac[18];
    format_mac(my_mac, mac);
    if (opt_vlan >= 0)
        logmsg("STATUS discovery %s mac=%s vlan=%d pcp=%d", opt_ifname, mac, opt_vlan, opt_pcp);
    else
        logmsg("STATUS discovery %s mac=%s untagged", opt_ifname, mac);

    struct pado_ctx ctx = {0};
    int found = 0;
    for (int waited = 0; waited < opt_timeout && !found; waited += DISCOVERY_RETRY_SECONDS) {
        if (send_discovery(CODE_PADI, broadcast_mac, 0) < 0) return EXIT_SYSTEM;
        logmsg("PADI inviato");
        int r = wait_frames(DISCOVERY_RETRY_SECONDS, handle_pado, &ctx);
        if (r < 0) return stop_requested ? EXIT_OK : EXIT_SYSTEM;
        if (r > 0) found = 1;
        if (opt_discovery_only && ctx.count) break;
    }
    if (opt_discovery_only) return ctx.count ? EXIT_OK : EXIT_NO_PADO;
    if (!found) {
        logmsg("STATUS timeout nessun PADO in %d secondi", opt_timeout);
        return EXIT_NO_PADO;
    }

    format_mac(ac_mac, mac);
    for (int attempt = 0; attempt < 3; attempt++) {
        if (send_discovery(CODE_PADR, ac_mac, 0) < 0) return EXIT_SYSTEM;
        logmsg("PADR inviato a %s", mac);
        int r = wait_frames(DISCOVERY_RETRY_SECONDS, handle_pads, NULL);
        if (r > 0) {
            logmsg("STATUS session %u ac=%s", session_id, mac);
            return EXIT_OK;
        }
        if (r < 0) {
            if (stop_requested) return EXIT_OK;
            logmsg("STATUS error PADS rifiutato dal concentratore");
            return EXIT_NO_PADS;
        }
    }
    logmsg("STATUS timeout nessun PADS");
    return EXIT_NO_PADS;
}

// MARK: Async HDLC (RFC 1662) towards pppd

static uint16_t fcs_table[256];

static void init_fcs(void) {
    for (unsigned b = 0; b < 256; b++) {
        uint16_t v = (uint16_t)b;
        for (int i = 0; i < 8; i++) v = (v & 1) ? (v >> 1) ^ 0x8408 : v >> 1;
        fcs_table[b] = v;
    }
}

static uint16_t fcs16(uint16_t fcs, const uint8_t *p, size_t len) {
    while (len--) fcs = (fcs >> 8) ^ fcs_table[(fcs ^ *p++) & 0xff];
    return fcs;
}

static int write_all(int fd, const uint8_t *p, size_t len) {
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

// Frames for pppd are encoded into one buffer and written with a single
// write() per batch of BPF frames: per-frame writes to the pty were the
// bottleneck (~300 Mbit/s with one core saturated).
static uint8_t out_buf[1 << 20];
static size_t out_len;
static uint8_t escape_table[256];

static void init_escape_table(void) {
    // pppd's receive ACCM is all control characters until LCP is up, so they
    // are always escaped; the kernel accepts escaped bytes in any state.
    for (unsigned b = 0; b < 256; b++) escape_table[b] = (b < 0x20 || b == 0x7d || b == 0x7e);
}

static int flush_to_pppd(void) {
    if (!out_len) return 0;
    int r = write_all(STDOUT_FILENO, out_buf, out_len);
    out_len = 0;
    return r;
}

static inline void put_escaped(uint8_t **o, uint8_t b) {
    if (escape_table[b]) {
        *(*o)++ = 0x7d;
        *(*o)++ = b ^ 0x20;
    } else {
        *(*o)++ = b;
    }
}

/// Appends one PPP frame (protocol + data) to the batch for pppd.
static int write_to_pppd(const uint8_t *payload, size_t len) {
    if (len > MAX_FRAME) return 0;
    // Worst case: every byte escaped, plus address/control, FCS and flags.
    if (out_len + 2 * (len + 4) + 2 > sizeof out_buf && flush_to_pppd() < 0) return -1;

    uint8_t *o = out_buf + out_len;
    *o++ = 0x7e;
    static const uint8_t header[2] = {0xff, 0x03};
    uint16_t fcs = fcs16(0xffff, header, 2);
    *o++ = 0xff;
    *o++ = 0x7d;
    *o++ = 0x03 ^ 0x20;
    for (size_t i = 0; i < len; i++) {
        uint8_t b = payload[i];
        fcs = (fcs >> 8) ^ fcs_table[(fcs ^ b) & 0xff];
        put_escaped(&o, b);
    }
    fcs ^= 0xffff;
    put_escaped(&o, fcs & 0xff);
    put_escaped(&o, fcs >> 8);
    *o++ = 0x7e;
    out_len = (size_t)(o - out_buf);
    return 0;
}

struct hdlc_decoder {
    uint8_t buf[MAX_FRAME];
    size_t len;
    int escaped;
    int overflow;
};

static int send_session(const uint8_t *payload, size_t len) {
    uint8_t frame[MAX_FRAME];
    if (len > MAX_PPP_PAYLOAD) return 0;
    size_t off = build_header(frame, ac_mac, ETHERTYPE_SESS, CODE_SESS, session_id, (uint16_t)len);
    memcpy(frame + off, payload, len);
    return send_frame(frame, off + len);
}

/// A complete HDLC frame from pppd: check FCS, strip address/control, send.
static void hdlc_frame_done(struct hdlc_decoder *d) {
    if (!d->overflow && d->len >= 4 && fcs16(0xffff, d->buf, d->len) == 0xf0b8) {
        const uint8_t *p = d->buf;
        size_t n = d->len - 2;
        if (n >= 2 && p[0] == 0xff && p[1] == 0x03) {
            p += 2;
            n -= 2;
        }
        send_session(p, n);
    }
    d->len = 0;
    d->escaped = 0;
    d->overflow = 0;
}

static void hdlc_input(struct hdlc_decoder *d, const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        // Fast path: copy a run of ordinary bytes in one go.
        if (!d->escaped) {
            size_t run = i;
            while (run < n && p[run] != 0x7e && p[run] != 0x7d) run++;
            if (run > i) {
                size_t count = run - i;
                if (d->len + count <= sizeof d->buf) {
                    memcpy(d->buf + d->len, p + i, count);
                    d->len += count;
                } else {
                    d->overflow = 1;
                }
                i = run;
                if (i == n) break;
            }
        }
        uint8_t b = p[i];
        if (b == 0x7e) {
            hdlc_frame_done(d);
            continue;
        }
        if (b == 0x7d) {
            d->escaped = 1;
            continue;
        }
        if (d->escaped) {
            b ^= 0x20;
            d->escaped = 0;
        }
        if (d->len < sizeof d->buf) d->buf[d->len++] = b;
        else d->overflow = 1;
    }
}

// MARK: Session relay

struct session_ctx {
    int padt;
};

static int handle_session(const struct pppoe_frame *f, void *ctx) {
    struct session_ctx *c = ctx;
    if (memcmp(f->src, ac_mac, 6) != 0 || f->session != session_id) return 0;
    if (f->ethertype == ETHERTYPE_DISC && f->code == CODE_PADT) {
        c->padt = 1;
        return 1;
    }
    if (f->ethertype == ETHERTYPE_SESS && f->code == CODE_SESS) {
        if (write_to_pppd(f->payload, f->payload_len) < 0) return -1;
    }
    return 0;
}

static int relay(void) {
    struct hdlc_decoder decoder = {0};
    struct session_ctx ctx = {0};
    static uint8_t in[256 * 1024];

    for (;;) {
        if (stop_requested) return EXIT_OK;
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(bpf_fd, &rfds);
        FD_SET(STDIN_FILENO, &rfds);
        int maxfd = bpf_fd > STDIN_FILENO ? bpf_fd : STDIN_FILENO;
        int r = select(maxfd + 1, &rfds, NULL, NULL, NULL);
        if (r < 0) {
            if (errno == EINTR) continue;
            return EXIT_SYSTEM;
        }
        if (FD_ISSET(STDIN_FILENO, &rfds)) {
            ssize_t n = read(STDIN_FILENO, in, sizeof in);
            if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN)) {
                logmsg("pppd ha chiuso il collegamento");
                return EXIT_OK;
            }
            if (n > 0) hdlc_input(&decoder, in, (size_t)n);
        }
        if (FD_ISSET(bpf_fd, &rfds)) {
            ssize_t n = read(bpf_fd, bpf_buf, bpf_buf_len);
            if (n < 0) {
                if (errno == EINTR) continue;
                logmsg("lettura BPF: %s", strerror(errno));
                return EXIT_SYSTEM;
            }
            for (uint8_t *p = bpf_buf; p < bpf_buf + n;) {
                struct bpf_hdr *h = (struct bpf_hdr *)p;
                struct pppoe_frame f;
                if (parse_frame(p + h->bh_hdrlen, h->bh_caplen, &f) == 0 && handle_session(&f, &ctx) < 0)
                    return EXIT_SYSTEM;
                if (ctx.padt) {
                    flush_to_pppd();
                    logmsg("STATUS padt sessione chiusa dal concentratore");
                    return EXIT_PADT;
                }
                p += BPF_WORDALIGN(h->bh_hdrlen + h->bh_caplen);
            }
            if (flush_to_pppd() < 0) return EXIT_SYSTEM;
        }
    }
}

// MARK: Main

static void usage(void) {
    fprintf(stderr,
            "uso: pppoe-relay -I <interfaccia> [-V <vlan>] [-P <pcp>] [-S <service>] [-C <ac-name>]\n"
            "                 [-T <secondi>] [-L <logfile>] [-D]\n"
            "  -V  VLAN ID 1-4094 (omesso: senza tag)\n"
            "  -D  solo discovery: mostra i concentratori che rispondono ed esce\n");
}

int main(int argc, char **argv) {
    int ch;
    while ((ch = getopt(argc, argv, "I:V:P:S:C:T:L:Dh")) != -1) {
        switch (ch) {
        case 'I': opt_ifname = optarg; break;
        case 'V': opt_vlan = atoi(optarg); break;
        case 'P': opt_pcp = atoi(optarg); break;
        case 'S': opt_service = optarg; break;
        case 'C': opt_ac_name = optarg; break;
        case 'T': opt_timeout = atoi(optarg); break;
        case 'L': log_file = fopen(optarg, "a"); break;
        case 'D': opt_discovery_only = 1; break;
        default: usage(); return EXIT_SYSTEM;
        }
    }
    if (!opt_ifname || (opt_vlan != -1 && (opt_vlan < 1 || opt_vlan > 4094)) || opt_pcp < 0 || opt_pcp > 7 ||
        opt_timeout < 1) {
        usage();
        return EXIT_SYSTEM;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal; // no SA_RESTART: select() must wake up
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    if (read_mac(opt_ifname, my_mac) != 0) {
        logmsg("STATUS error interfaccia %s non trovata", opt_ifname);
        return EXIT_SYSTEM;
    }
    if (setup_bpf() != 0) return EXIT_SYSTEM;

    uint32_t uniq = arc4random();
    memcpy(host_uniq, &uniq, sizeof host_uniq);

    int result = discover();
    if (result != EXIT_OK || opt_discovery_only || stop_requested) return result;

    if (isatty(STDIN_FILENO)) {
        struct termios tio;
        if (tcgetattr(STDIN_FILENO, &tio) == 0) {
            cfmakeraw(&tio);
            tcsetattr(STDIN_FILENO, TCSANOW, &tio);
        }
    }
    init_fcs();
    init_escape_table();
    result = relay();
    if (result != EXIT_PADT) {
        send_discovery(CODE_PADT, ac_mac, session_id);
        logmsg("STATUS padt inviato, sessione %u chiusa", session_id);
    }
    return result;
}

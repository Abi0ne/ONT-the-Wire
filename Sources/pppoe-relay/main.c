// pppoe-relay: PPPoE client (RFC 2516) over an optional 802.1Q VLAN tag.
//
// macOS' built-in PPPoE cannot run on a VLAN interface (it ends up on en<N>),
// so this program talks to the physical Ethernet interface through BPF and
// adds the VLAN tag itself. It performs discovery (PADI/PADO/PADR/PADS), then
// runs PPP itself (LCP, PAP or CHAP-MD5, IPCP with DNS) and carries IPv4 over
// a utun interface. There is no pppd and no HDLC/pty in the data path, which
// on macOS capped throughput at ~350 Mbit/s. Every packet costs one system
// call per side, so the data path is spread over several threads per
// direction, each handling its own share of the connections (see "Data
// plane"). Requires root (BPF, utun configuration).
//
// Status lines go to stderr (and to -L <file>), prefixed by "pppoe-relay:".
// Lines starting with "STATUS " are machine-readable for the app.

#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <mach/mach.h>
#include <net/bpf.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_utun.h>
#include <netinet/in.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/sys_domain.h>
#include <sys/sysctl.h>
#include <sys/time.h>
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

// Exit codes, with the values pppd(8) uses for the same outcomes.
enum {
    EXIT_OK = 0,
    EXIT_SYSTEM = 1,
    EXIT_OPTIONS = 2,
    EXIT_USER = 5,
    EXIT_NO_PADO = 8,
    EXIT_NO_PADS = 8,
    EXIT_NEGOTIATION = 10,
    EXIT_PEER_DEAD = 15,
    EXIT_HANGUP = 16,
    EXIT_AUTH = 19,
};

// MARK: Options and state

static const char *opt_ifname;
static int opt_vlan = -1; // -1: untagged
static int opt_pcp = 0;
static const char *opt_service = "";
static const char *opt_ac_name;
static int opt_timeout = 30;
static int opt_discovery_only;
static const char *opt_secret;
static int opt_threads; // data-plane threads per direction; 0: chosen from the CPU
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
    char line[1024];
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

/// Opens a BPF device on the interface, in immediate mode, with the largest
/// buffer the kernel allows. The caller sets the filter.
static int attach_bpf(size_t *buf_len) {
    int fd = open_bpf();
    if (fd < 0) {
        logmsg("impossibile aprire /dev/bpf: %s (serve root)", strerror(errno));
        return -1;
    }
    // Large buffer: at gigabit rates many frames arrive per read() (the
    // kernel caps it at debug.bpf_maxbufsize, 512 KB by default).
    u_int blen = 512 * 1024;
    while (ioctl(fd, BIOCSBLEN, &blen) < 0 && blen > 32768) blen /= 2;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strlcpy(ifr.ifr_name, opt_ifname, sizeof ifr.ifr_name);
    if (ioctl(fd, BIOCSETIF, &ifr) < 0) {
        logmsg("BIOCSETIF %s: %s", opt_ifname, strerror(errno));
        close(fd);
        return -1;
    }
    if (ioctl(fd, BIOCGBLEN, &blen) < 0) {
        close(fd);
        return -1;
    }
    *buf_len = blen;

    u_int one = 1, zero = 0;
    ioctl(fd, BIOCIMMEDIATE, &one);
    ioctl(fd, BIOCSHDRCMPLT, &one); // we supply the source MAC
    ioctl(fd, BIOCSSEESENT, &zero); // do not read back our own frames
    return fd;
}

static int setup_bpf(void) {
    bpf_fd = attach_bpf(&bpf_buf_len);
    if (bpf_fd < 0) return -1;
    bpf_buf = malloc(bpf_buf_len);
    if (!bpf_buf) return -1;

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

// MARK: Credentials

static char username[256];
static char password[256];

/// Reads a value in pppd options syntax: "quoted" with \ escapes, or a bare word.
static void read_value(const char *s, char *out, size_t size) {
    size_t n = 0;
    while (*s == ' ' || *s == '\t') s++;
    if (*s == '"') {
        for (s++; *s && *s != '"'; s++) {
            if (*s == '\\' && s[1]) s++;
            if (n + 1 < size) out[n++] = *s;
        }
    } else {
        for (; *s && *s != ' ' && *s != '\t' && *s != '\n' && *s != '\r'; s++)
            if (n + 1 < size) out[n++] = *s;
    }
    out[n] = 0;
}

/// Reads `user` and `password` lines from the secret file written by the app.
static int read_secret(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) {
        logmsg("file delle credenziali %s: %s", path, strerror(errno));
        return -1;
    }
    char line[1024];
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "user ", 5) == 0) read_value(line + 5, username, sizeof username);
        if (strncmp(line, "password ", 9) == 0) read_value(line + 9, password, sizeof password);
    }
    memset(line, 0, sizeof line);
    fclose(f);
    if (!username[0]) {
        logmsg("file delle credenziali senza username");
        return -1;
    }
    return 0;
}

// MARK: PPP framing (RFC 1661)

#define PPP_IP 0x0021
#define PPP_IPCP 0x8021
#define PPP_LCP 0xc021
#define PPP_PAP 0xc023
#define PPP_CHAP 0xc223

#define CP_CONF_REQ 1
#define CP_CONF_ACK 2
#define CP_CONF_NAK 3
#define CP_CONF_REJ 4
#define CP_TERM_REQ 5
#define CP_TERM_ACK 6
#define CP_CODE_REJ 7
#define CP_PROT_REJ 8
#define CP_ECHO_REQ 9
#define CP_ECHO_REP 10

#define OUR_MRU 1492
#define RESTART_SECONDS 3.0
#define MAX_CONFIGURE 10
#define CHAP_WAIT_SECONDS 30.0
#define ECHO_INTERVAL 10.0
#define ECHO_FAILURES 4
#define TERMINATE_SECONDS 1.5

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static int send_ppp(uint16_t protocol, const uint8_t *data, size_t len) {
    uint8_t frame[MAX_FRAME];
    if (len + 2 > MAX_PPP_PAYLOAD) return 0;
    size_t off = build_header(frame, ac_mac, ETHERTYPE_SESS, CODE_SESS, session_id, (uint16_t)(len + 2));
    frame[off++] = protocol >> 8;
    frame[off++] = protocol & 0xff;
    memcpy(frame + off, data, len);
    return send_frame(frame, off + len);
}

static int send_cp(uint16_t protocol, uint8_t code, uint8_t id, const uint8_t *data, size_t len) {
    uint8_t packet[MAX_FRAME];
    if (len + 4 > MAX_PPP_PAYLOAD - 2) return 0;
    packet[0] = code;
    packet[1] = id;
    packet[2] = (uint8_t)((len + 4) >> 8);
    packet[3] = (len + 4) & 0xff;
    if (len) memcpy(packet + 4, data, len);
    return send_ppp(protocol, packet, len + 4);
}

/// Iterates configuration options. Returns 0 at the end or on a malformed one.
static int next_option(const uint8_t **cursor, const uint8_t *end, const uint8_t **option, uint8_t *type,
                       const uint8_t **value, size_t *len) {
    if (*cursor + 2 > end) return 0;
    uint8_t total = (*cursor)[1];
    if (total < 2 || *cursor + total > end) return 0;
    *option = *cursor;
    *type = (*cursor)[0];
    *value = *cursor + 2;
    *len = total - 2u;
    *cursor += total;
    return 1;
}

static size_t put_option(uint8_t *p, uint8_t type, const void *value, size_t len) {
    p[0] = type;
    p[1] = (uint8_t)(len + 2);
    memcpy(p + 2, value, len);
    return len + 2;
}

// MARK: Control protocols (LCP, IPCP)

/// The Configure-Request/Ack/Nak/Reject exchange shared by LCP and IPCP.
struct cp {
    uint16_t protocol;
    const char *name;
    int ours_acked;   // the peer acked our Configure-Request
    int theirs_acked; // we acked the peer's Configure-Request
    uint8_t id;       // id of our last Configure-Request
    int sent;         // Configure-Requests sent so far
    double retry_at;  // 0 when no request is outstanding
    size_t (*build)(uint8_t *options);
    void (*adjust)(uint8_t code, const uint8_t *options, size_t len);
    /// Checks the peer's options; returns CP_CONF_ACK, or NAK/REJ with the
    /// options for the reply. Values are applied only on ACK.
    uint8_t (*check)(const uint8_t *options, size_t len, uint8_t *reply, size_t *reply_len);
};

static int cp_is_open(const struct cp *cp) { return cp->ours_acked && cp->theirs_acked; }

static void cp_send_request(struct cp *cp) {
    uint8_t options[64];
    size_t len = cp->build(options);
    cp->id++;
    cp->sent++;
    cp->retry_at = now_seconds() + RESTART_SECONDS;
    send_cp(cp->protocol, CP_CONF_REQ, cp->id, options, len);
}

static void cp_start(struct cp *cp) {
    cp->ours_acked = cp->theirs_acked = 0;
    cp->sent = 0;
    cp_send_request(cp);
}

enum { CP_NOTHING, CP_OPENED, CP_RENEGOTIATE, CP_TERMINATED, CP_OTHER };

/// Handles the configuration and termination codes. Returns CP_OPENED when
/// the protocol has just opened, CP_OTHER for codes left to the caller.
static int cp_input(struct cp *cp, const uint8_t *packet, size_t len) {
    if (len < 4) return CP_NOTHING;
    uint8_t code = packet[0], id = packet[1];
    size_t total = (size_t)(packet[2] << 8 | packet[3]);
    if (total < 4 || total > len) return CP_NOTHING;
    const uint8_t *data = packet + 4;
    size_t data_len = total - 4;
    int was_open = cp_is_open(cp);

    switch (code) {
    case CP_CONF_REQ: {
        uint8_t reply[MAX_FRAME];
        size_t reply_len = 0;
        uint8_t result = cp->check(data, data_len, reply, &reply_len);
        if (result == CP_CONF_ACK) {
            send_cp(cp->protocol, CP_CONF_ACK, id, data, data_len);
        } else {
            send_cp(cp->protocol, result, id, reply, reply_len);
        }
        // An open link that gets the same options again only lost our Ack;
        // anything else is a renegotiation.
        if (was_open) return result == CP_CONF_ACK ? CP_NOTHING : CP_RENEGOTIATE;
        cp->theirs_acked = result == CP_CONF_ACK;
        break;
    }
    case CP_CONF_ACK:
        if (id != cp->id || cp->ours_acked) return CP_NOTHING;
        cp->ours_acked = 1;
        cp->retry_at = 0;
        break;
    case CP_CONF_NAK:
    case CP_CONF_REJ:
        if (id != cp->id || cp->ours_acked) return CP_NOTHING;
        cp->adjust(code, data, data_len);
        cp_send_request(cp);
        break;
    case CP_TERM_REQ:
        send_cp(cp->protocol, CP_TERM_ACK, id, NULL, 0);
        return CP_TERMINATED;
    default:
        return CP_OTHER;
    }
    return !was_open && cp_is_open(cp) ? CP_OPENED : CP_NOTHING;
}

// LCP: we ask for MRU 1492 and a magic number; the peer chooses PAP or CHAP-MD5.

static int lcp_send_mru = 1, lcp_send_magic = 1;
static uint16_t lcp_mru = OUR_MRU;
static uint32_t our_magic;
static uint16_t peer_mru = 1500;
static uint16_t auth_protocol; // 0, PPP_PAP or PPP_CHAP

static size_t lcp_build(uint8_t *p) {
    size_t n = 0;
    if (lcp_send_mru) {
        uint8_t mru[2] = {lcp_mru >> 8, lcp_mru & 0xff};
        n += put_option(p + n, 1, mru, 2);
    }
    if (lcp_send_magic) {
        uint32_t magic = htonl(our_magic);
        n += put_option(p + n, 5, &magic, 4);
    }
    return n;
}

static void lcp_adjust(uint8_t code, const uint8_t *options, size_t len) {
    const uint8_t *cursor = options, *option, *value;
    uint8_t type;
    size_t vlen;
    while (next_option(&cursor, options + len, &option, &type, &value, &vlen)) {
        if (type == 1) {
            uint16_t mru = vlen == 2 ? (uint16_t)(value[0] << 8 | value[1]) : 0;
            if (code == CP_CONF_NAK && mru >= 576 && mru <= OUR_MRU) lcp_mru = mru;
            else lcp_send_mru = 0;
        } else if (type == 5) {
            if (code == CP_CONF_NAK) our_magic = arc4random();
            else lcp_send_magic = 0;
        }
    }
}

static uint8_t lcp_check(const uint8_t *options, size_t len, uint8_t *reply, size_t *reply_len) {
    uint8_t rejected[MAX_FRAME], naked[16];
    size_t rejected_len = 0, naked_len = 0;
    uint16_t mru = 1500, auth = 0;
    const uint8_t *cursor = options, *option, *value;
    uint8_t type;
    size_t vlen;
    while (next_option(&cursor, options + len, &option, &type, &value, &vlen)) {
        int ok = 0;
        if (type == 1 && vlen == 2) {
            mru = (uint16_t)(value[0] << 8 | value[1]);
            ok = 1;
        } else if (type == 3 && vlen >= 2) {
            auth = (uint16_t)(value[0] << 8 | value[1]);
            if ((auth == PPP_PAP && vlen == 2) || (auth == PPP_CHAP && vlen == 3 && value[2] == 5)) {
                ok = 1;
            } else {
                // MS-CHAP, EAP...: suggest CHAP with MD5.
                static const uint8_t chap_md5[3] = {PPP_CHAP >> 8, PPP_CHAP & 0xff, 5};
                naked_len = put_option(naked, 3, chap_md5, 3);
                continue;
            }
        } else if (type == 5 && vlen == 4) {
            ok = 1;
        }
        if (!ok) {
            memcpy(rejected + rejected_len, option, vlen + 2);
            rejected_len += vlen + 2;
        }
    }
    if (rejected_len) {
        memcpy(reply, rejected, rejected_len);
        *reply_len = rejected_len;
        return CP_CONF_REJ;
    }
    if (naked_len) {
        memcpy(reply, naked, naked_len);
        *reply_len = naked_len;
        return CP_CONF_NAK;
    }
    peer_mru = mru;
    auth_protocol = auth;
    return CP_CONF_ACK;
}

static struct cp lcp = {PPP_LCP, "LCP", 0, 0, 0, 0, 0, lcp_build, lcp_adjust, lcp_check};

// IPCP: we ask for an address and two DNS servers (RFC 1877).

static struct in_addr local_ip, remote_ip, dns_ip[2];
static int ipcp_send_dns[2] = {1, 1};
static int ipcp_address_rejected;
static const uint8_t dns_option[2] = {129, 131};

static size_t ipcp_build(uint8_t *p) {
    size_t n = put_option(p, 3, &local_ip, 4);
    for (int i = 0; i < 2; i++)
        if (ipcp_send_dns[i]) n += put_option(p + n, dns_option[i], &dns_ip[i], 4);
    return n;
}

static void ipcp_adjust(uint8_t code, const uint8_t *options, size_t len) {
    const uint8_t *cursor = options, *option, *value;
    uint8_t type;
    size_t vlen;
    while (next_option(&cursor, options + len, &option, &type, &value, &vlen)) {
        struct in_addr *target = type == 3 ? &local_ip : type == 129 ? &dns_ip[0] : type == 131 ? &dns_ip[1] : NULL;
        if (!target) continue;
        if (code == CP_CONF_NAK && vlen == 4) {
            memcpy(target, value, 4);
        } else if (code == CP_CONF_REJ) {
            if (type == 3) ipcp_address_rejected = 1;
            else ipcp_send_dns[type == 129 ? 0 : 1] = 0;
        }
    }
}

static uint8_t ipcp_check(const uint8_t *options, size_t len, uint8_t *reply, size_t *reply_len) {
    struct in_addr address = {0};
    const uint8_t *cursor = options, *option, *value;
    uint8_t type;
    size_t vlen;
    *reply_len = 0;
    while (next_option(&cursor, options + len, &option, &type, &value, &vlen)) {
        if (type == 3 && vlen == 4) {
            memcpy(&address, value, 4);
        } else {
            memcpy(reply + *reply_len, option, vlen + 2);
            *reply_len += vlen + 2;
        }
    }
    if (*reply_len) return CP_CONF_REJ;
    remote_ip = address;
    return CP_CONF_ACK;
}

static struct cp ipcp = {PPP_IPCP, "IPCP", 0, 0, 0, 0, 0, ipcp_build, ipcp_adjust, ipcp_check};

// MARK: Authentication (PAP RFC 1334, CHAP-MD5 RFC 1994)

static uint8_t pap_id;
static int pap_sent;
static double auth_retry_at;

static void pap_send(void) {
    uint8_t data[2 + sizeof username + sizeof password];
    size_t ulen = strlen(username), plen = strlen(password), n = 0;
    data[n++] = (uint8_t)ulen;
    memcpy(data + n, username, ulen);
    n += ulen;
    data[n++] = (uint8_t)plen;
    memcpy(data + n, password, plen);
    n += plen;
    send_cp(PPP_PAP, 1, ++pap_id, data, n);
    memset(data, 0, sizeof data);
    pap_sent++;
    auth_retry_at = now_seconds() + RESTART_SECONDS;
}

static void chap_respond(uint8_t id, const uint8_t *challenge, size_t len) {
    uint8_t digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5_CTX md5;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations" // MD5 is what CHAP specifies
    CC_MD5_Init(&md5);
    CC_MD5_Update(&md5, &id, 1);
    CC_MD5_Update(&md5, password, (CC_LONG)strlen(password));
    CC_MD5_Update(&md5, challenge, (CC_LONG)len);
    CC_MD5_Final(digest, &md5);
#pragma clang diagnostic pop
    uint8_t data[1 + sizeof digest + sizeof username];
    size_t ulen = strlen(username);
    data[0] = sizeof digest;
    memcpy(data + 1, digest, sizeof digest);
    memcpy(data + 1 + sizeof digest, username, ulen);
    send_cp(PPP_CHAP, 2, id, data, 1 + sizeof digest + ulen);
}

// MARK: utun

static int utun_fd = -1;
static char utun_name[IFNAMSIZ];

static int open_utun(void) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return -1;
    struct ctl_info info;
    memset(&info, 0, sizeof info);
    strlcpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof info.ctl_name);
    if (ioctl(fd, CTLIOCGINFO, &info) < 0) {
        close(fd);
        return -1;
    }
    struct sockaddr_ctl addr;
    memset(&addr, 0, sizeof addr);
    addr.sc_len = sizeof addr;
    addr.sc_family = AF_SYSTEM;
    addr.ss_sysaddr = AF_SYS_CONTROL;
    addr.sc_id = info.ctl_id;
    addr.sc_unit = 0; // first free utun<N>
    socklen_t name_len = sizeof utun_name;
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0 ||
        getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, utun_name, &name_len) < 0) {
        close(fd);
        return -1;
    }
    // Room for bursts at gigabit rates (about 8 ms at 1 Gbit/s) without
    // queueing so much that latency under load grows.
    int size = 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof size);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof size);
    return fd;
}

static void set_sin(struct sockaddr *sa, struct in_addr address) {
    struct sockaddr_in *sin = (struct sockaddr_in *)sa;
    memset(sin, 0, sizeof *sin);
    sin->sin_len = sizeof *sin;
    sin->sin_family = AF_INET;
    sin->sin_addr = address;
}

/// Point-to-point address, MTU and up, like pppd does for ppp<N>.
static int configure_utun(int mtu) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct ifaliasreq ifra;
    memset(&ifra, 0, sizeof ifra);
    strlcpy(ifra.ifra_name, utun_name, sizeof ifra.ifra_name);
    set_sin(&ifra.ifra_addr, local_ip);
    set_sin(&ifra.ifra_broadaddr, remote_ip);
    set_sin(&ifra.ifra_mask, (struct in_addr){htonl(0xffffffff)});
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strlcpy(ifr.ifr_name, utun_name, sizeof ifr.ifr_name);
    const char *step = NULL;
    if (ioctl(s, SIOCAIFADDR, &ifra) < 0) step = "indirizzo";
    ifr.ifr_mtu = mtu;
    if (!step && ioctl(s, SIOCSIFMTU, &ifr) < 0) step = "MTU";
    if (!step && ioctl(s, SIOCGIFFLAGS, &ifr) < 0) step = "stato";
    ifr.ifr_flags |= IFF_UP;
    if (!step && ioctl(s, SIOCSIFFLAGS, &ifr) < 0) step = "attivazione";
    if (step) logmsg("configurazione di %s (%s): %s", utun_name, step, strerror(errno));
    close(s);
    return step ? -1 : 0;
}

// MARK: Data plane

// Each packet costs a system call on each side (BPF hands out received frames
// in batches, but utun and BPF writes take one packet at a time), so a single
// thread per direction tops out well below 2.5 Gbit/s. The work is therefore
// split by connection: the sum of the TCP/UDP ports picks one of N buckets,
// the same for both directions of a connection, and every bucket has its own
// threads. Packets of one connection always go through the same thread, so
// they are never reordered.
//
//   wire -> utun  N BPF devices; the kernel filter of each one accepts only
//                 the IPv4 packets of its bucket, and its thread writes them
//                 to utun. The main thread keeps discovery and PPP control.
//   utun -> wire  one thread reads utun and hands each packet to the queue of
//                 its bucket; N threads write the queues to their own BPF
//                 device.
//
// With one thread per direction (-W 1, or a small CPU) the main thread
// delivers wire -> utun itself and a single thread does utun -> wire.

#define MAX_WORKERS 8
#define IP_OFFSET (l2_header_len() + 6 + 2)

/// Bucket of an IPv4 packet; `filter_bucket` builds the same computation for
/// the kernel. Fragments and protocols without ports go to bucket 0.
static unsigned ip_bucket(const uint8_t *ip, size_t len, unsigned mask) {
    if (len < 20) return 0;
    if ((ip[6] << 8 | ip[7]) & 0x3fff) return 0;
    if (ip[9] != IPPROTO_TCP && ip[9] != IPPROTO_UDP) return 0;
    size_t header = (size_t)(ip[0] & 0x0f) * 4;
    if (len < header + 4) return 0;
    const uint8_t *ports = ip + header;
    return (unsigned)((ports[0] << 8 | ports[1]) + (ports[2] << 8 | ports[3])) & mask;
}

// MARK: Kernel filters

#define TO_ACCEPT 0xfe
#define TO_REJECT 0xff

struct filter {
    struct bpf_insn insns[32];
    u_int len;
};

static void emit(struct filter *f, uint16_t code, uint8_t jt, uint8_t jf, uint32_t k) {
    f->insns[f->len++] = (struct bpf_insn){code, jt, jf, k};
}

/// Checks the VLAN tag, when used, and leaves the EtherType in A.
static void filter_begin(struct filter *f) {
    f->len = 0;
    if (opt_vlan >= 0) {
        emit(f, BPF_LD + BPF_H + BPF_ABS, 0, 0, 12);
        emit(f, BPF_JMP + BPF_JEQ + BPF_K, 0, TO_REJECT, ETHERTYPE_VLAN);
        emit(f, BPF_LD + BPF_H + BPF_ABS, 0, 0, 14);
        emit(f, BPF_ALU + BPF_AND + BPF_K, 0, 0, 0x0fff);
        emit(f, BPF_JMP + BPF_JEQ + BPF_K, 0, TO_REJECT, (uint32_t)opt_vlan);
    }
    emit(f, BPF_LD + BPF_H + BPF_ABS, 0, 0, (uint32_t)l2_header_len() - 2);
}

/// Appends the two return statements and resolves the jumps to them.
static void filter_end(struct filter *f) {
    u_int accept = f->len, reject = f->len + 1;
    for (u_int i = 0; i < f->len; i++) {
        struct bpf_insn *insn = &f->insns[i];
        if (BPF_CLASS(insn->code) != BPF_JMP) continue;
        if (insn->jt == TO_ACCEPT) insn->jt = (u_char)(accept - i - 1);
        if (insn->jt == TO_REJECT) insn->jt = (u_char)(reject - i - 1);
        if (insn->jf == TO_ACCEPT) insn->jf = (u_char)(accept - i - 1);
        if (insn->jf == TO_REJECT) insn->jf = (u_char)(reject - i - 1);
    }
    emit(f, BPF_RET + BPF_K, 0, 0, (uint32_t)-1);
    emit(f, BPF_RET + BPF_K, 0, 0, 0);
}

/// Discovery and PPP control only: what the main thread handles once the
/// data-plane threads take the IPv4 packets.
static void filter_control(struct filter *f) {
    filter_begin(f);
    emit(f, BPF_JMP + BPF_JEQ + BPF_K, TO_ACCEPT, 0, ETHERTYPE_DISC);
    emit(f, BPF_JMP + BPF_JEQ + BPF_K, 0, TO_REJECT, ETHERTYPE_SESS);
    emit(f, BPF_LD + BPF_H + BPF_ABS, 0, 0, (uint32_t)l2_header_len() + 6);
    emit(f, BPF_JMP + BPF_JEQ + BPF_K, TO_REJECT, TO_ACCEPT, PPP_IP);
    filter_end(f);
}

/// The IPv4 packets of one bucket (see `ip_bucket`).
static void filter_bucket(struct filter *f, unsigned bucket, unsigned mask) {
    uint32_t ip = (uint32_t)IP_OFFSET;
    uint8_t no_ports = bucket == 0 ? TO_ACCEPT : TO_REJECT;
    filter_begin(f);
    emit(f, BPF_JMP + BPF_JEQ + BPF_K, 0, TO_REJECT, ETHERTYPE_SESS);
    emit(f, BPF_LD + BPF_H + BPF_ABS, 0, 0, (uint32_t)l2_header_len() + 6);
    emit(f, BPF_JMP + BPF_JEQ + BPF_K, 0, TO_REJECT, PPP_IP);
    emit(f, BPF_LD + BPF_H + BPF_ABS, 0, 0, ip + 6); // flags and fragment offset
    emit(f, BPF_JMP + BPF_JSET + BPF_K, no_ports, 0, 0x3fff);
    emit(f, BPF_LD + BPF_B + BPF_ABS, 0, 0, ip + 9); // protocol
    emit(f, BPF_JMP + BPF_JEQ + BPF_K, 1, 0, IPPROTO_TCP);
    emit(f, BPF_JMP + BPF_JEQ + BPF_K, 0, no_ports, IPPROTO_UDP);
    emit(f, BPF_LDX + BPF_B + BPF_MSH, 0, 0, ip); // X = IP header length
    emit(f, BPF_LD + BPF_H + BPF_IND, 0, 0, ip); // source port
    emit(f, BPF_ST, 0, 0, 0);
    emit(f, BPF_LD + BPF_H + BPF_IND, 0, 0, ip + 2); // destination port
    emit(f, BPF_LDX + BPF_MEM, 0, 0, 0);
    emit(f, BPF_ALU + BPF_ADD + BPF_X, 0, 0, 0);
    emit(f, BPF_ALU + BPF_AND + BPF_K, 0, 0, mask);
    emit(f, BPF_JMP + BPF_JEQ + BPF_K, TO_ACCEPT, TO_REJECT, bucket);
    filter_end(f);
}

/// Nothing: for the devices that only send.
static void filter_nothing(struct filter *f) {
    f->len = 0;
    emit(f, BPF_RET + BPF_K, 0, 0, 0);
}

static int set_filter(int fd, struct filter *f) {
    struct bpf_program program = {f->len, f->insns};
    if (ioctl(fd, BIOCSETF, &program) < 0) {
        logmsg("BIOCSETF: %s", strerror(errno));
        return -1;
    }
    ioctl(fd, BIOCFLUSH); // drop what arrived before the filter was in place
    return 0;
}

// MARK: Thread load

// Highest share of a core each thread used over about a second, for the
// end-of-session statistics: a thread near 100% is where the speed is lost.
struct tracked_thread {
    const char *label;
    mach_port_t port;
    double cpu;
    double peak;
};
static struct tracked_thread tracked[2 + 2 * MAX_WORKERS];
static int tracked_count;
static double load_sampled_at;

static double thread_cpu_seconds(mach_port_t port) {
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (thread_info(port, THREAD_BASIC_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.user_time.seconds + info.system_time.seconds +
           (info.user_time.microseconds + info.system_time.microseconds) / 1e6;
}

/// Called on the main thread only.
static void track_thread(const char *label, pthread_t thread) {
    if (tracked_count >= (int)(sizeof tracked / sizeof tracked[0])) return;
    struct tracked_thread *t = &tracked[tracked_count++];
    t->label = label;
    t->port = pthread_mach_thread_np(thread);
    t->cpu = thread_cpu_seconds(t->port);
    t->peak = 0;
}

static void sample_thread_load(double now) {
    double elapsed = now - load_sampled_at;
    if (elapsed < 1) return;
    for (int i = 0; i < tracked_count; i++) {
        struct tracked_thread *t = &tracked[i];
        double cpu = thread_cpu_seconds(t->port);
        // The first sample only sets the reference.
        if (load_sampled_at > 0 && elapsed < 5 && (cpu - t->cpu) / elapsed > t->peak) t->peak = (cpu - t->cpu) / elapsed;
        t->cpu = cpu;
    }
    load_sampled_at = now;
}

// MARK: Wire -> utun

struct down_worker {
    int fd;
    uint8_t *buf;
    size_t buf_len;
    _Atomic uint64_t packets, errors;
    _Atomic uint64_t merged, merged_writes; // segments joined, and into how many packets
};
static struct down_worker main_down; // counters of the main thread, when it delivers itself
static struct down_worker down[MAX_WORKERS];
static int down_count; // 0: the main thread delivers
static _Atomic int data_plane_failed;

/// The 4 bytes before the IP header (PPPoE length and PPP protocol) are
/// overwritten in the BPF buffer with utun's address family header, so each
/// packet is a single write and no copy.
static void deliver_ip(const struct pppoe_frame *f, struct down_worker *w) {
    uint8_t *p = (uint8_t *)f->payload - 2;
    size_t len = f->payload_len - 2u + 4;
    p[0] = p[1] = p[2] = 0;
    p[3] = AF_INET;
    if (write(utun_fd, p, len) == (ssize_t)len) atomic_fetch_add_explicit(&w->packets, 1, memory_order_relaxed);
    else atomic_fetch_add_explicit(&w->errors, 1, memory_order_relaxed);
}

// MARK: Segment merging

// The kernel handles everything received on utun in a single thread, one
// packet at a time: at 2 Gbit/s that thread (dlil_input_utun<N>) is the
// busiest of the whole path. So consecutive TCP segments of a connection that
// arrive in the same BPF read are joined into one large IP packet (up to
// 64 KB) before they are written to utun, like the receive offload of a
// network card: the kernel then processes, and acknowledges, a fraction of
// the packets. Only plain data segments with valid checksums are joined,
// nothing waits for more data (what is pending is written at the end of each
// read), and the order within a connection never changes.

#define MERGE_SLOTS 16
#define MERGE_SEGMENTS 48
#define MERGE_MAX 65535
#define TCP_FLAG_PSH 0x08
#define TCP_FLAG_ACK 0x10

static _Atomic int merge_disabled; // -G, or utun refused a large packet

/// Internet checksum partial sum, in memory byte order.
static uint64_t sum_bytes(const uint8_t *p, size_t n, uint64_t sum) {
    while (n >= 4) {
        uint32_t word;
        memcpy(&word, p, 4);
        sum += word;
        p += 4;
        n -= 4;
    }
    if (n >= 2) {
        uint16_t word;
        memcpy(&word, p, 2);
        sum += word;
        p += 2;
        n -= 2;
    }
    if (n) {
        uint16_t word = 0;
        memcpy(&word, p, 1);
        sum += word;
    }
    return sum;
}

static uint16_t fold_sum(uint64_t sum) {
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)sum;
}

/// Sum of the TCP pseudo-header.
static uint64_t pseudo_sum(const uint8_t *ip, size_t tcp_len) {
    uint8_t tail[4] = {0, IPPROTO_TCP, (uint8_t)(tcp_len >> 8), (uint8_t)tcp_len};
    return sum_bytes(tail, 4, sum_bytes(ip + 12, 8, 0));
}

/// A data segment that may be joined to others.
struct segment {
    uint8_t *ip;
    size_t len; // IP total length
    size_t tcp_header;
    size_t payload;
    uint32_t seq;
    uint64_t payload_sum;
};

/// Plain IPv4 + TCP data segments only: no IP options or fragments, no flags
/// other than ACK and PSH, and both checksums valid.
static int parse_segment(uint8_t *ip, size_t available, struct segment *s) {
    if (available < 40 || ip[0] != 0x45 || ip[9] != IPPROTO_TCP) return 0;
    size_t len = (size_t)(ip[2] << 8 | ip[3]);
    if (len > available || len < 40 || ((ip[6] << 8 | ip[7]) & 0x3fff)) return 0;
    const uint8_t *tcp = ip + 20;
    size_t tcp_header = (size_t)(tcp[12] >> 4) * 4;
    if (tcp_header < 20 || 20 + tcp_header >= len) return 0;
    if ((tcp[13] & ~(TCP_FLAG_ACK | TCP_FLAG_PSH)) || !(tcp[13] & TCP_FLAG_ACK)) return 0;
    if (fold_sum(sum_bytes(ip, 20, 0)) != 0xffff) return 0;
    s->ip = ip;
    s->len = len;
    s->tcp_header = tcp_header;
    s->payload = len - 20 - tcp_header;
    s->payload_sum = sum_bytes(tcp + tcp_header, s->payload, 0);
    if (fold_sum(pseudo_sum(ip, len - 20) + sum_bytes(tcp, tcp_header, 0) + s->payload_sum) != 0xffff) return 0;
    s->seq = (uint32_t)tcp[4] << 24 | (uint32_t)tcp[5] << 16 | (uint32_t)tcp[6] << 8 | tcp[7];
    return 1;
}

/// The segments of one connection being joined.
struct merge_slot {
    int count; // 0: free
    uint8_t *segments[MERGE_SEGMENTS]; // the original packets, in the BPF buffer
    uint16_t lengths[MERGE_SEGMENTS];
    uint8_t key[12]; // addresses and ports
    uint32_t next_seq;
    size_t len; // IP total length so far
    size_t tcp_header;
    uint64_t payload_sum;
    uint8_t *packet; // utun header + joined packet, used from the second segment on
};

struct merger {
    struct merge_slot slots[MERGE_SLOTS];
    int active;
    int next_victim;
};

static void merge_key(const uint8_t *ip, uint8_t key[12]) {
    memcpy(key, ip + 12, 8);
    memcpy(key + 8, ip + 20, 4);
}

/// Writes an IP packet to utun; the 4 bytes before it are overwritten with
/// utun's address family header.
static int write_utun(uint8_t *ip, size_t len) {
    uint8_t *p = ip - 4;
    p[0] = p[1] = p[2] = 0;
    p[3] = AF_INET;
    return write(utun_fd, p, len + 4) == (ssize_t)(len + 4) ? 0 : -1;
}

static void merge_flush(struct down_worker *w, struct merger *m, struct merge_slot *slot) {
    if (slot->count == 0) return;
    int delivered = -1;
    if (slot->count > 1) {
        uint8_t *ip = slot->packet + 4, *tcp = ip + 20;
        ip[2] = (uint8_t)(slot->len >> 8);
        ip[3] = (uint8_t)slot->len;
        ip[10] = ip[11] = 0;
        uint16_t sum = (uint16_t)~fold_sum(sum_bytes(ip, 20, 0));
        memcpy(ip + 10, &sum, 2);
        tcp[16] = tcp[17] = 0;
        sum = (uint16_t)~fold_sum(pseudo_sum(ip, slot->len - 20) + sum_bytes(tcp, slot->tcp_header, 0) +
                                  slot->payload_sum);
        memcpy(tcp + 16, &sum, 2);
        delivered = write_utun(ip, slot->len);
        if (delivered == 0) {
            atomic_fetch_add_explicit(&w->packets, (uint64_t)slot->count, memory_order_relaxed);
            atomic_fetch_add_explicit(&w->merged, (uint64_t)slot->count, memory_order_relaxed);
            atomic_fetch_add_explicit(&w->merged_writes, 1, memory_order_relaxed);
        } else if (!atomic_exchange(&merge_disabled, 1)) {
            logmsg("%s non accetta pacchetti uniti (%s): consegno i segmenti uno alla volta", utun_name,
                   strerror(errno));
        }
    }
    if (delivered != 0) {
        for (int i = 0; i < slot->count; i++) {
            if (write_utun(slot->segments[i], slot->lengths[i]) == 0)
                atomic_fetch_add_explicit(&w->packets, 1, memory_order_relaxed);
            else atomic_fetch_add_explicit(&w->errors, 1, memory_order_relaxed);
        }
    }
    slot->count = 0;
    m->active--;
}

static void merge_flush_all(struct down_worker *w, struct merger *m) {
    for (int i = 0; m->active > 0 && i < MERGE_SLOTS; i++) merge_flush(w, m, &m->slots[i]);
}

static struct merge_slot *merge_find(struct merger *m, const uint8_t key[12]) {
    for (int i = 0; m->active > 0 && i < MERGE_SLOTS; i++)
        if (m->slots[i].count > 0 && memcmp(m->slots[i].key, key, 12) == 0) return &m->slots[i];
    return NULL;
}

/// Whether `s` continues the packet in `slot`: next in sequence, same TOS
/// (ECN marks must stay visible) and same TCP options, timestamps aside.
static int merge_continues(const struct merge_slot *slot, const struct segment *s) {
    const uint8_t *first = slot->segments[0];
    if (s->seq != slot->next_seq || s->tcp_header != slot->tcp_header || s->ip[1] != first[1]) return 0;
    if (slot->count >= MERGE_SEGMENTS || slot->len + s->payload > MERGE_MAX) return 0;
    // Partial sums can only be added when every segment but the last is even.
    if ((slot->len - 20 - slot->tcp_header) % 2) return 0;
    const uint8_t *a = first + 40, *b = s->ip + 40;
    size_t options = s->tcp_header - 20;
    if (options == 12 && a[0] == 1 && a[1] == 1 && a[2] == 8 && a[3] == 10) return memcmp(a, b, 4) == 0;
    return memcmp(a, b, options) == 0;
}

/// Handles one received IP packet: joins it, starts a new joined packet, or
/// writes it as it is after whatever is pending for its connection.
static void merge_input(struct down_worker *w, struct merger *m, uint8_t *ip, size_t len) {
    struct segment s;
    if (!parse_segment(ip, len, &s)) {
        // Keep the order: pending data of the same connection goes first.
        uint8_t key[12];
        struct merge_slot *slot = NULL;
        if (len >= 40 && ip[0] == 0x45 && ip[9] == IPPROTO_TCP) {
            merge_key(ip, key);
            slot = merge_find(m, key);
            if (slot) merge_flush(w, m, slot);
        } else {
            merge_flush_all(w, m);
        }
        if (write_utun(ip, len) == 0) atomic_fetch_add_explicit(&w->packets, 1, memory_order_relaxed);
        else atomic_fetch_add_explicit(&w->errors, 1, memory_order_relaxed);
        return;
    }
    uint8_t key[12];
    merge_key(ip, key);
    struct merge_slot *slot = merge_find(m, key);
    if (slot && !merge_continues(slot, &s)) merge_flush(w, m, slot), slot = NULL;
    if (!slot) {
        for (int i = 0; i < MERGE_SLOTS && !slot; i++)
            if (m->slots[i].count == 0) slot = &m->slots[i];
        if (!slot) {
            slot = &m->slots[m->next_victim++ % MERGE_SLOTS];
            merge_flush(w, m, slot);
        }
        memcpy(slot->key, key, 12);
        slot->count = 1;
        slot->segments[0] = ip;
        slot->lengths[0] = (uint16_t)s.len;
        slot->next_seq = s.seq + (uint32_t)s.payload;
        slot->len = s.len;
        slot->tcp_header = s.tcp_header;
        slot->payload_sum = s.payload_sum;
        m->active++;
    } else {
        uint8_t *packet = slot->packet + 4;
        if (slot->count == 1) memcpy(packet, slot->segments[0], slot->len);
        // The newest header carries the current acknowledgment, window and
        // timestamps; the sequence number stays that of the first segment.
        uint8_t seq[4];
        memcpy(seq, packet + 24, 4);
        uint8_t flags = packet[33];
        memcpy(packet + 20, s.ip + 20, s.tcp_header);
        memcpy(packet + 24, seq, 4);
        packet[33] |= flags;
        memcpy(packet + slot->len, s.ip + 20 + s.tcp_header, s.payload);
        slot->segments[slot->count] = ip;
        slot->lengths[slot->count++] = (uint16_t)s.len;
        slot->next_seq += (uint32_t)s.payload;
        slot->len += s.payload;
        slot->payload_sum += s.payload_sum;
    }
    // PSH: the sender wants this data delivered now.
    if (s.ip[33] & TCP_FLAG_PSH) merge_flush(w, m, slot);
}

static void *downlink(void *arg) {
    struct down_worker *w = arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    struct merger *m = calloc(1, sizeof *m);
    uint8_t *packets = malloc((size_t)MERGE_SLOTS * (MERGE_MAX + 4));
    if (!m || !packets) atomic_store(&merge_disabled, 1);
    else
        for (int i = 0; i < MERGE_SLOTS; i++) m->slots[i].packet = packets + (size_t)i * (MERGE_MAX + 4);
    for (;;) {
        ssize_t n = read(w->fd, w->buf, w->buf_len);
        if (n < 0) {
            if (errno == EINTR) continue;
            logmsg("lettura BPF (ricezione): %s", strerror(errno));
            atomic_store(&data_plane_failed, 1);
            return NULL;
        }
        int merge = !atomic_load_explicit(&merge_disabled, memory_order_relaxed);
        for (uint8_t *p = w->buf; p < w->buf + n;) {
            struct bpf_hdr *h = (struct bpf_hdr *)p;
            struct pppoe_frame f;
            if (parse_frame(p + h->bh_hdrlen, h->bh_caplen, &f) == 0 && f.ethertype == ETHERTYPE_SESS &&
                f.code == CODE_SESS && f.session == session_id && memcmp(f.src, ac_mac, 6) == 0 &&
                f.payload_len >= 2 && (f.payload[0] << 8 | f.payload[1]) == PPP_IP) {
                if (merge) merge_input(w, m, (uint8_t *)f.payload + 2, f.payload_len - 2u);
                else deliver_ip(&f, w);
            }
            p += BPF_WORDALIGN(h->bh_hdrlen + h->bh_caplen);
        }
        // The originals live in the BPF buffer: nothing stays pending across reads.
        if (merge) merge_flush_all(w, m);
    }
}

// MARK: utun -> wire

#define SEND_RETRIES 200
#define SEND_RETRY_MICROSECONDS 50
#define UP_QUEUE_SLOTS 512 // power of two; about 6 ms of packets at 1 Gbit/s
#define UP_QUEUE_SPINS 300

struct up_slot {
    uint16_t len;
    uint8_t frame[MAX_FRAME + 64];
};

/// Queue from the utun reader to one sending thread (one producer, one
/// consumer). The consumer sleeps only after finding it empty for a while.
struct up_worker {
    int fd;
    struct up_slot *slots;
    _Atomic uint32_t head, tail;
    _Atomic int sleeping;
    pthread_mutex_t lock;
    pthread_cond_t wake;
};
static struct up_worker up[MAX_WORKERS];
static int up_count; // 0: the utun reader sends by itself
static _Atomic uint64_t up_packets, up_retries, up_dropped, up_queue_full;
static _Atomic int up_last_errno;

static inline void cpu_relax(void) {
#if defined(__arm64__)
    __asm__ volatile("yield");
#elif defined(__x86_64__)
    __asm__ volatile("pause");
#endif
}

/// Writes a data frame, waiting while the interface queue is full: dropping
/// it would look like congestion loss to TCP, waiting slows the sender down
/// through utun's own queue instead.
static void send_data_frame(int fd, const uint8_t *frame, size_t len) {
    for (int attempt = 0;; attempt++) {
        if (write(fd, frame, len) == (ssize_t)len) {
            atomic_fetch_add_explicit(&up_packets, 1, memory_order_relaxed);
            return;
        }
        int error = errno;
        if ((error != ENOBUFS && error != EAGAIN && error != EINTR) || attempt >= SEND_RETRIES) {
            atomic_store_explicit(&up_last_errno, error, memory_order_relaxed);
            atomic_fetch_add_explicit(&up_dropped, 1, memory_order_relaxed);
            return;
        }
        atomic_fetch_add_explicit(&up_retries, 1, memory_order_relaxed);
        usleep(SEND_RETRY_MICROSECONDS);
    }
}

static void up_enqueue(struct up_worker *w, const uint8_t *frame, size_t len) {
    uint32_t tail = atomic_load_explicit(&w->tail, memory_order_relaxed);
    // Full: wait, so that the backlog stays in utun's queue (see send_data_frame).
    if (tail - atomic_load(&w->head) >= UP_QUEUE_SLOTS) {
        atomic_fetch_add_explicit(&up_queue_full, 1, memory_order_relaxed);
        while (tail - atomic_load(&w->head) >= UP_QUEUE_SLOTS) usleep(SEND_RETRY_MICROSECONDS);
    }
    struct up_slot *slot = &w->slots[tail % UP_QUEUE_SLOTS];
    memcpy(slot->frame, frame, len);
    slot->len = (uint16_t)len;
    atomic_store(&w->tail, tail + 1);
    if (atomic_load(&w->sleeping)) {
        pthread_mutex_lock(&w->lock);
        pthread_cond_signal(&w->wake);
        pthread_mutex_unlock(&w->lock);
    }
}

static void *up_send(void *arg) {
    struct up_worker *w = arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    uint32_t head = 0;
    for (;;) {
        for (int spin = 0; head == atomic_load(&w->tail) && spin < UP_QUEUE_SPINS; spin++) cpu_relax();
        if (head == atomic_load(&w->tail)) {
            pthread_mutex_lock(&w->lock);
            atomic_store(&w->sleeping, 1);
            while (head == atomic_load(&w->tail)) pthread_cond_wait(&w->wake, &w->lock);
            atomic_store(&w->sleeping, 0);
            pthread_mutex_unlock(&w->lock);
        }
        struct up_slot *slot = &w->slots[head % UP_QUEUE_SLOTS];
        send_data_frame(w->fd, slot->frame, slot->len);
        atomic_store(&w->head, ++head);
    }
}

/// Reads utun: the packet lands right after the room for the Ethernet, VLAN,
/// PPPoE and PPP headers, which are then written in front of it.
static void *uplink(void *arg) {
    (void)arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    size_t header = IP_OFFSET;
    unsigned mask = up_count > 0 ? (unsigned)up_count - 1 : 0;
    uint8_t frame[MAX_FRAME + 64];
    for (;;) {
        ssize_t n = read(utun_fd, frame + header - 4, MAX_FRAME);
        if (n < 0) {
            if (errno == EINTR) continue;
            logmsg("lettura da %s: %s", utun_name, strerror(errno));
            atomic_store(&data_plane_failed, 1);
            return NULL;
        }
        if (n <= 4 || frame[header - 1] != AF_INET) continue; // IPv6 is not negotiated
        size_t ip_len = (size_t)n - 4;
        if (ip_len + 2 > MAX_PPP_PAYLOAD) continue;
        build_header(frame, ac_mac, ETHERTYPE_SESS, CODE_SESS, session_id, (uint16_t)(ip_len + 2));
        frame[header - 2] = PPP_IP >> 8;
        frame[header - 1] = PPP_IP & 0xff;
        size_t len = header + ip_len;
        if (len < 60) {
            memset(frame + len, 0, 60 - len);
            len = 60;
        }
        if (up_count == 0) send_data_frame(bpf_fd, frame, len);
        else up_enqueue(&up[ip_bucket(frame + header, ip_len, mask)], frame, len);
    }
}

// MARK: Start

/// Threads per direction: enough to spread the load without taking every
/// performance core (the kernel's network threads and the applications need
/// theirs).
static int default_threads(void) {
    int cores = 0;
    size_t size = sizeof cores;
    if (sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, NULL, 0) != 0 || cores <= 0) {
        size = sizeof cores;
        if (sysctlbyname("hw.physicalcpu", &cores, &size, NULL, 0) != 0) cores = 0;
    }
    return cores >= 5 ? 4 : cores >= 3 ? 2 : 1;
}

static int start_thread(const char *label, void *(*body)(void *), void *arg) {
    pthread_t thread;
    int error = pthread_create(&thread, NULL, body, arg);
    if (error) {
        logmsg("thread del piano dati: %s", strerror(error));
        return -1;
    }
    track_thread(label, thread);
    pthread_detach(thread);
    return 0;
}

/// Opens the per-bucket BPF devices. On failure nothing is left open and the
/// single-thread path is used.
static int open_workers(int count) {
    struct filter f;
    int opened_down = 0, opened_up = 0, ok = 1;
    for (; ok && opened_down < count; opened_down++) {
        struct down_worker *w = &down[opened_down];
        w->fd = attach_bpf(&w->buf_len);
        w->buf = w->fd >= 0 ? malloc(w->buf_len) : NULL;
        filter_bucket(&f, (unsigned)opened_down, (unsigned)count - 1);
        if (w->fd < 0 || !w->buf || set_filter(w->fd, &f) != 0) ok = 0;
    }
    for (; ok && opened_up < count; opened_up++) {
        struct up_worker *w = &up[opened_up];
        size_t unused;
        w->fd = attach_bpf(&unused);
        w->slots = w->fd >= 0 ? malloc(UP_QUEUE_SLOTS * sizeof *w->slots) : NULL;
        filter_nothing(&f);
        if (w->fd < 0 || !w->slots || set_filter(w->fd, &f) != 0) ok = 0;
        pthread_mutex_init(&w->lock, NULL);
        pthread_cond_init(&w->wake, NULL);
    }
    if (ok) return 0;
    for (int i = 0; i < opened_down; i++) {
        if (down[i].fd >= 0) close(down[i].fd);
        free(down[i].buf);
    }
    for (int i = 0; i < opened_up; i++) {
        if (up[i].fd >= 0) close(up[i].fd);
        free(up[i].slots);
    }
    return -1;
}

/// Starts the threads that move packets; utun must be configured.
static int start_data_plane(void) {
    int count = opt_threads > 0 ? opt_threads : default_threads();
    if (count > MAX_WORKERS) count = MAX_WORKERS;
    if (count > 1 && open_workers(count) != 0) {
        logmsg("piano dati su più thread non disponibile, uso un thread per direzione");
        count = 1;
    }
    if (count == 1) atomic_store(&merge_disabled, 1); // the main thread delivers as it is
    // The data threads must not take the signals meant to stop the session.
    sigset_t all, old;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, &old);
    int result = 0;
    if (count > 1) {
        // From here on the main thread sees only discovery and PPP control.
        struct filter f;
        filter_control(&f);
        if (set_filter(bpf_fd, &f) != 0) result = -1;
        down_count = up_count = count;
        tracked[0].label = "controllo";
        for (int i = 0; result == 0 && i < count; i++) result = start_thread("ricezione", downlink, &down[i]);
        for (int i = 0; result == 0 && i < count; i++) result = start_thread("invio", up_send, &up[i]);
    }
    if (result == 0) result = start_thread(count > 1 ? "lettura utun" : "invio", uplink, NULL);
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    if (result == 0)
        logmsg("piano dati: %d thread per direzione, segmenti TCP ricevuti %s", count,
               atomic_load(&merge_disabled) ? "non uniti" : "uniti");
    return result;
}

// MARK: Session

enum phase { PHASE_LCP, PHASE_AUTH, PHASE_NETWORK, PHASE_RUNNING, PHASE_TERMINATE };

static enum phase phase = PHASE_LCP;
static int exit_status = -1;
static int padt_received;
static uint8_t lcp_reject_id, echo_id;
static int echo_pending;
static double next_echo, terminate_at;

static void fail(int status) {
    if (exit_status < 0) exit_status = status;
}

static void start_network(void) {
    phase = PHASE_NETWORK;
    cp_start(&ipcp);
}

static void ipcp_opened(void) {
    char local[INET_ADDRSTRLEN], remote[INET_ADDRSTRLEN], dns[2][INET_ADDRSTRLEN];
    if (ipcp_address_rejected || local_ip.s_addr == 0) {
        logmsg("il server non ha assegnato un indirizzo IPv4");
        fail(EXIT_NEGOTIATION);
        return;
    }
    // Same placeholder pppd uses when the peer does not tell its address.
    if (remote_ip.s_addr == 0) remote_ip.s_addr = htonl(0x0a404040);
    int mtu = peer_mru < OUR_MRU ? peer_mru : OUR_MRU;

    utun_fd = open_utun();
    if (utun_fd < 0) {
        logmsg("impossibile creare l'interfaccia utun: %s", strerror(errno));
        fail(EXIT_SYSTEM);
        return;
    }
    if (configure_utun(mtu) < 0) {
        fail(EXIT_SYSTEM);
        return;
    }

    if (start_data_plane() != 0) {
        fail(EXIT_SYSTEM);
        return;
    }

    inet_ntop(AF_INET, &local_ip, local, sizeof local);
    inet_ntop(AF_INET, &remote_ip, remote, sizeof remote);
    logmsg("STATUS interface %s mtu=%d", utun_name, mtu);
    logmsg("STATUS local %s", local);
    logmsg("STATUS remote %s", remote);
    char dns_list[2 * INET_ADDRSTRLEN + 1] = "";
    for (int i = 0; i < 2; i++) {
        if (!ipcp_send_dns[i] || dns_ip[i].s_addr == 0) continue;
        inet_ntop(AF_INET, &dns_ip[i], dns[i], sizeof dns[i]);
        logmsg("STATUS dns %s", dns[i]);
        if (dns_list[0]) strlcat(dns_list, ",", sizeof dns_list);
        strlcat(dns_list, dns[i], sizeof dns_list);
    }
    // One line with everything, for the root supervisor.
    logmsg("STATUS up %s local=%s remote=%s dns=%s", utun_name, local, remote, dns_list);
    phase = PHASE_RUNNING;
    next_echo = now_seconds() + ECHO_INTERVAL;
}

static void lcp_opened(void) {
    logmsg("LCP aperto: MRU del server %u, autenticazione %s", peer_mru,
           auth_protocol == PPP_PAP ? "PAP" : auth_protocol == PPP_CHAP ? "CHAP" : "nessuna");
    if (auth_protocol == PPP_PAP) {
        logmsg("STATUS auth PAP");
        phase = PHASE_AUTH;
        pap_send();
    } else if (auth_protocol == PPP_CHAP) {
        logmsg("STATUS auth CHAP");
        phase = PHASE_AUTH;
        auth_retry_at = now_seconds() + CHAP_WAIT_SECONDS;
    } else {
        start_network();
    }
}

static void authenticated(void) {
    logmsg("STATUS auth-ok");
    start_network();
}

static void auth_failed(const uint8_t *message, size_t len) {
    char text[256];
    tag_string(message, (uint16_t)(len < 255 ? len : 255), text, sizeof text);
    logmsg("STATUS auth-failed %s", text);
    fail(EXIT_AUTH);
}

static void begin_terminate(void) {
    phase = PHASE_TERMINATE;
    terminate_at = now_seconds() + TERMINATE_SECONDS;
    if (cp_is_open(&lcp)) {
        static const char reason[] = "User request";
        send_cp(PPP_LCP, CP_TERM_REQ, ++lcp_reject_id, (const uint8_t *)reason, sizeof reason - 1);
    } else {
        fail(EXIT_USER);
    }
}

static void lcp_input(const uint8_t *packet, size_t len) {
    switch (cp_input(&lcp, packet, len)) {
    case CP_OPENED:
        lcp_opened();
        return;
    case CP_RENEGOTIATE:
        logmsg("il server ha rinegoziato LCP: sessione chiusa");
        fail(EXIT_HANGUP);
        return;
    case CP_TERMINATED:
        if (phase == PHASE_TERMINATE) {
            fail(EXIT_USER);
        } else {
            logmsg("STATUS lcp-terminated dal server");
            fail(EXIT_HANGUP);
        }
        return;
    case CP_OTHER:
        break;
    default:
        return;
    }
    uint8_t code = packet[0], id = packet[1];
    size_t total = (size_t)(packet[2] << 8 | packet[3]);
    const uint8_t *data = packet + 4;
    size_t data_len = total - 4;
    switch (code) {
    case CP_TERM_ACK:
        if (phase == PHASE_TERMINATE) fail(EXIT_USER);
        break;
    case CP_ECHO_REQ:
        if (cp_is_open(&lcp) && data_len >= 4) {
            uint8_t reply[MAX_FRAME];
            uint32_t magic = htonl(our_magic);
            memcpy(reply, &magic, 4);
            memcpy(reply + 4, data + 4, data_len - 4);
            send_cp(PPP_LCP, CP_ECHO_REP, id, reply, data_len);
        }
        break;
    case CP_ECHO_REP:
        echo_pending = 0;
        break;
    case CP_PROT_REJ:
        if (data_len >= 2 && (data[0] << 8 | data[1]) == PPP_IPCP) {
            logmsg("il server ha rifiutato IPCP");
            fail(EXIT_NEGOTIATION);
        }
        break;
    case CP_CODE_REJ:
        logmsg("il server ha rifiutato un codice LCP");
        break;
    }
}

static void auth_input(uint16_t protocol, const uint8_t *packet, size_t len) {
    if (len < 4 || phase < PHASE_AUTH || phase == PHASE_TERMINATE) return;
    uint8_t code = packet[0], id = packet[1];
    size_t total = (size_t)(packet[2] << 8 | packet[3]);
    if (total < 4 || total > len) return;
    const uint8_t *data = packet + 4;
    size_t data_len = total - 4;

    if (protocol == PPP_PAP) {
        if (phase != PHASE_AUTH || id != pap_id) return;
        const uint8_t *message = data_len ? data + 1 : data;
        size_t message_len = data_len ? (data[0] < data_len ? data[0] : data_len - 1) : 0;
        if (code == 2) authenticated();
        if (code == 3) auth_failed(message, message_len);
        return;
    }
    // CHAP: the server may challenge again at any time.
    if (code == 1 && data_len >= 1 && data[0] <= data_len - 1) {
        chap_respond(id, data + 1, data[0]);
    } else if (code == 3 && phase == PHASE_AUTH) {
        authenticated();
    } else if (code == 4) {
        auth_failed(data, data_len);
    }
}

static void protocol_reject(uint16_t protocol, const uint8_t *packet, size_t len) {
    if (!cp_is_open(&lcp)) return;
    uint8_t data[MAX_FRAME];
    size_t n = len < MAX_PPP_PAYLOAD - 2 - 4 - 2 ? len : MAX_PPP_PAYLOAD - 2 - 4 - 2;
    data[0] = protocol >> 8;
    data[1] = protocol & 0xff;
    memcpy(data + 2, packet, n);
    send_cp(PPP_LCP, CP_PROT_REJ, ++lcp_reject_id, data, n + 2);
}

static void session_frame(const struct pppoe_frame *f) {
    if (memcmp(f->src, ac_mac, 6) != 0 || f->session != session_id) return;
    if (f->ethertype == ETHERTYPE_DISC) {
        if (f->code == CODE_PADT) {
            padt_received = 1;
            logmsg("STATUS padt sessione chiusa dal concentratore");
            fail(EXIT_HANGUP);
        }
        return;
    }
    if (f->code != CODE_SESS || f->payload_len < 2) return;
    uint16_t protocol = (uint16_t)(f->payload[0] << 8 | f->payload[1]);
    if (protocol == PPP_IP) {
        if (phase == PHASE_RUNNING && down_count == 0) deliver_ip(f, &main_down);
        return;
    }
    const uint8_t *packet = f->payload + 2;
    size_t len = f->payload_len - 2u;
    switch (protocol) {
    case PPP_LCP: lcp_input(packet, len); break;
    case PPP_PAP:
    case PPP_CHAP: auth_input(protocol, packet, len); break;
    case PPP_IPCP:
        if (phase == PHASE_NETWORK || phase == PHASE_RUNNING) {
            int r = cp_input(&ipcp, packet, len);
            if (r == CP_OPENED) ipcp_opened();
            if (r == CP_RENEGOTIATE || r == CP_TERMINATED) {
                logmsg("il server ha chiuso o rinegoziato IPCP");
                fail(EXIT_HANGUP);
            }
        }
        break;
    default: protocol_reject(protocol, packet, len); break; // IPv6CP, CCP...
    }
}

static void run_timers(double now) {
    if (phase == PHASE_TERMINATE) {
        if (now >= terminate_at) fail(EXIT_USER);
        return;
    }
    struct cp *cp = phase == PHASE_LCP ? &lcp : phase == PHASE_NETWORK ? &ipcp : NULL;
    if (cp && cp->retry_at && now >= cp->retry_at) {
        if (cp->sent >= MAX_CONFIGURE) {
            logmsg("nessuna risposta alle richieste %s", cp->name);
            fail(EXIT_NEGOTIATION);
            return;
        }
        cp_send_request(cp);
    }
    if (phase == PHASE_AUTH && now >= auth_retry_at) {
        if (auth_protocol == PPP_CHAP || pap_sent >= MAX_CONFIGURE) {
            logmsg("STATUS auth-failed nessuna risposta dal server");
            fail(EXIT_AUTH);
            return;
        }
        pap_send();
    }
    if (phase == PHASE_RUNNING && now >= next_echo) {
        if (echo_pending >= ECHO_FAILURES) {
            logmsg("STATUS echo-timeout nessuna risposta a %d LCP echo", ECHO_FAILURES);
            fail(EXIT_PEER_DEAD);
            return;
        }
        uint32_t magic = htonl(our_magic);
        send_cp(PPP_LCP, CP_ECHO_REQ, ++echo_id, (const uint8_t *)&magic, 4);
        echo_pending++;
        next_echo = now + ECHO_INTERVAL;
    }
}

static int run_session(void) {
    our_magic = arc4random();
    cp_start(&lcp);
    while (exit_status < 0) {
        if (stop_requested && phase != PHASE_TERMINATE) begin_terminate();
        double now = now_seconds();
        run_timers(now);
        sample_thread_load(now);
        if (atomic_load(&data_plane_failed)) fail(EXIT_SYSTEM);
        if (exit_status >= 0) break;

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(bpf_fd, &rfds);
        struct timeval tv = {0, 200000};
        int r = select(bpf_fd + 1, &rfds, NULL, NULL, &tv);
        if (r < 0) {
            if (errno == EINTR) continue;
            return EXIT_SYSTEM;
        }
        if (r == 0) continue;
        ssize_t n = read(bpf_fd, bpf_buf, bpf_buf_len);
        if (n < 0) {
            if (errno == EINTR) continue;
            logmsg("lettura BPF: %s", strerror(errno));
            return EXIT_SYSTEM;
        }
        for (uint8_t *p = bpf_buf; p < bpf_buf + n && exit_status < 0;) {
            struct bpf_hdr *h = (struct bpf_hdr *)p;
            struct pppoe_frame f;
            if (parse_frame(p + h->bh_hdrlen, h->bh_caplen, &f) == 0) session_frame(&f);
            p += BPF_WORDALIGN(h->bh_hdrlen + h->bh_caplen);
        }
    }
    return exit_status;
}

// MARK: Statistics

struct link_counters {
    uint32_t output_errors;
    uint32_t input_drops;
};

static int read_link_counters(const char *ifname, struct link_counters *out) {
    struct ifaddrs *list, *ifa;
    if (getifaddrs(&list) != 0) return -1;
    int found = -1;
    for (ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_LINK || !ifa->ifa_data) continue;
        if (strcmp(ifa->ifa_name, ifname) != 0) continue;
        const struct if_data *data = ifa->ifa_data;
        out->output_errors = data->ifi_oerrors;
        out->input_drops = data->ifi_iqdrops;
        found = 0;
        break;
    }
    freeifaddrs(list);
    return found;
}

static struct link_counters wire_at_start;
static int wire_at_start_valid;

/// One STATUS line the app shows in its log: where packets were lost, if any,
/// and how busy each thread got.
static void log_statistics(void) {
    char line[1024];
    size_t size = sizeof line;
    uint64_t received = atomic_load(&main_down.packets), undelivered = atomic_load(&main_down.errors);
    uint64_t merged = 0, merged_writes = 0;
    struct bpf_stat bpf;
    unsigned bpf_dropped = 0;
    int bpf_known = ioctl(bpf_fd, BIOCGSTATS, &bpf) == 0;
    if (bpf_known) bpf_dropped = bpf.bs_drop;
    for (int i = 0; i < down_count; i++) {
        received += atomic_load(&down[i].packets);
        undelivered += atomic_load(&down[i].errors);
        merged += atomic_load(&down[i].merged);
        merged_writes += atomic_load(&down[i].merged_writes);
        if (ioctl(down[i].fd, BIOCGSTATS, &bpf) == 0) bpf_dropped += bpf.bs_drop;
    }
    int n = snprintf(line, size, "STATUS stats ricevuti %llu, inviati %llu", (unsigned long long)received,
                     (unsigned long long)atomic_load(&up_packets));
    if (merged)
        n += snprintf(line + n, size - (size_t)n, " (%llu uniti in %llu)", (unsigned long long)merged,
                      (unsigned long long)merged_writes);
    if (undelivered)
        n += snprintf(line + n, size - (size_t)n, ", consegna a %s fallita %llu", utun_name,
                      (unsigned long long)undelivered);
    n += snprintf(line + n, size - (size_t)n, "; invio: coda piena %llu volte, scartati %llu",
                  (unsigned long long)atomic_load(&up_retries), (unsigned long long)atomic_load(&up_dropped));
    int error = atomic_load(&up_last_errno);
    if (error) n += snprintf(line + n, size - (size_t)n, " (%s)", strerror(error));
    if (up_count > 0)
        n += snprintf(line + n, size - (size_t)n, ", code interne piene %llu volte",
                      (unsigned long long)atomic_load(&up_queue_full));
    if (bpf_known) n += snprintf(line + n, size - (size_t)n, "; BPF persi %u", bpf_dropped);
    struct link_counters wire, tun;
    if (wire_at_start_valid && read_link_counters(opt_ifname, &wire) == 0)
        n += snprintf(line + n, size - (size_t)n, "; %s errori in uscita %u, scarti in ingresso %u", opt_ifname,
                      wire.output_errors - wire_at_start.output_errors, wire.input_drops - wire_at_start.input_drops);
    if (utun_fd >= 0 && read_link_counters(utun_name, &tun) == 0)
        n += snprintf(line + n, size - (size_t)n, "; %s errori in uscita %u", utun_name, tun.output_errors);
    // "carico massimo dei thread: ricezione 97% 91%, invio 60% 58%, ..."
    const char *label = NULL;
    for (int i = 0; i < tracked_count && (size_t)n < size; i++) {
        if (!label) n += snprintf(line + n, size - (size_t)n, "; carico massimo dei thread:");
        if (!label || strcmp(label, tracked[i].label) != 0) {
            n += snprintf(line + n, size - (size_t)n, "%s %s", label ? "," : "", tracked[i].label);
            label = tracked[i].label;
        }
        n += snprintf(line + n, size - (size_t)n, " %.0f%%", tracked[i].peak * 100);
    }
    logmsg("%s", line);
}

// MARK: Main

static void usage(void) {
    fprintf(stderr,
            "uso: pppoe-relay -I <interfaccia> -A <credenziali> [-V <vlan>] [-P <pcp>] [-S <service>]\n"
            "                 [-C <ac-name>] [-T <secondi>] [-L <logfile>] [-W <thread>] [-G]\n"
            "     pppoe-relay -I <interfaccia> -D [-V <vlan>] ...\n"
            "  -A  file con le righe: user \"nome\" / password \"segreto\"\n"
            "  -V  VLAN ID 1-4094 (omesso: senza tag)\n"
            "  -D  solo discovery: mostra i concentratori che rispondono ed esce\n"
            "  -W  thread del piano dati per direzione: 1, 2, 4 o 8 (omesso: in base alla CPU)\n"
            "  -G  non unire i segmenti TCP ricevuti in pacchetti grandi\n");
}

int main(int argc, char **argv) {
    int ch;
    while ((ch = getopt(argc, argv, "I:A:V:P:S:C:T:L:W:DGh")) != -1) {
        switch (ch) {
        case 'I': opt_ifname = optarg; break;
        case 'A': opt_secret = optarg; break;
        case 'V': opt_vlan = atoi(optarg); break;
        case 'P': opt_pcp = atoi(optarg); break;
        case 'S': opt_service = optarg; break;
        case 'C': opt_ac_name = optarg; break;
        case 'T': opt_timeout = atoi(optarg); break;
        case 'L': log_file = fopen(optarg, "a"); break;
        case 'D': opt_discovery_only = 1; break;
        case 'W': opt_threads = atoi(optarg); break;
        case 'G': atomic_store(&merge_disabled, 1); break;
        default: usage(); return EXIT_OPTIONS;
        }
    }
    if (!opt_ifname || (!opt_secret && !opt_discovery_only) || (opt_vlan != -1 && (opt_vlan < 1 || opt_vlan > 4094)) ||
        opt_pcp < 0 || opt_pcp > 7 || opt_timeout < 1 ||
        (opt_threads != 0 && opt_threads != 1 && opt_threads != 2 && opt_threads != 4 && opt_threads != 8)) {
        usage();
        return EXIT_OPTIONS;
    }
    if (opt_secret && read_secret(opt_secret) != 0) return EXIT_OPTIONS;

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

    // Keep the data path on the performance cores.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    track_thread("ricezione", pthread_self());

    int result = discover();
    if (result != EXIT_OK || opt_discovery_only || session_id == 0) return result;
    wire_at_start_valid = read_link_counters(opt_ifname, &wire_at_start) == 0;
    if (!stop_requested) result = run_session();
    else result = EXIT_USER;

    if (!padt_received) {
        send_discovery(CODE_PADT, ac_mac, session_id);
        logmsg("STATUS padt inviato, sessione %u chiusa", session_id);
    }
    log_statistics();
    return result;
}

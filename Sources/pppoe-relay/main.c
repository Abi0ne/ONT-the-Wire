// pppoe-relay: PPPoE client (RFC 2516) over an optional 802.1Q VLAN tag.
//
// macOS' built-in PPPoE cannot run on a VLAN interface (it ends up on en<N>),
// so this program talks to the physical Ethernet interface through BPF and
// adds the VLAN tag itself. It performs discovery (PADI/PADO/PADR/PADS), then
// runs PPP itself (LCP, PAP or CHAP-MD5, IPCP with DNS) and carries IPv4 over
// a utun interface: one thread moves wire -> utun, another utun -> wire.
// There is no pppd and no HDLC/pty in the data path, which on macOS capped
// throughput at ~350 Mbit/s. Requires root (BPF, utun configuration).
//
// Status lines go to stderr (and to -L <file>), prefixed by "pppoe-relay:".
// Lines starting with "STATUS " are machine-readable for the app.

#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
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

// Counters for the end-of-session statistics. The uplink ones are written by
// the uplink thread.
static uint64_t down_packets, down_errors;
static _Atomic uint64_t up_packets, up_retries, up_dropped;
static _Atomic int up_last_errno;

#define SEND_RETRIES 200
#define SEND_RETRY_MICROSECONDS 50

/// Writes a data frame, waiting while the interface queue is full: dropping
/// it would look like congestion loss to TCP, waiting slows the sender down
/// through utun's own queue instead.
static void send_data_frame(const uint8_t *frame, size_t len) {
    for (int attempt = 0;; attempt++) {
        if (write(bpf_fd, frame, len) == (ssize_t)len) {
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

/// Wire -> utun, on the main thread: the 4 bytes before the IP header (PPPoE
/// length and PPP protocol) are overwritten in the BPF buffer with utun's
/// address family header, so each packet is a single write and no copy.
static void deliver_ip(const struct pppoe_frame *f) {
    uint8_t *p = (uint8_t *)f->payload - 2;
    size_t len = f->payload_len - 2u + 4;
    p[0] = p[1] = p[2] = 0;
    p[3] = AF_INET;
    if (write(utun_fd, p, len) == (ssize_t)len) down_packets++;
    else down_errors++;
}

/// utun -> wire: the packet is read right after the room for the Ethernet,
/// VLAN, PPPoE and PPP headers, which are then written in front of it.
static void *uplink(void *arg) {
    (void)arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    size_t header = l2_header_len() + 6 + 2;
    uint8_t frame[MAX_FRAME + 64];
    for (;;) {
        ssize_t n = read(utun_fd, frame + header - 4, MAX_FRAME);
        if (n < 0) {
            if (errno == EINTR) continue;
            logmsg("lettura da %s: %s", utun_name, strerror(errno));
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
        send_data_frame(frame, len);
    }
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

    // The uplink thread must not take the signals meant to stop the session.
    sigset_t all, old;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, &old);
    pthread_t thread;
    int error = pthread_create(&thread, NULL, uplink, NULL);
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    if (error) {
        logmsg("thread di invio: %s", strerror(error));
        fail(EXIT_SYSTEM);
        return;
    }
    pthread_detach(thread);

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
        if (phase == PHASE_RUNNING) deliver_ip(f);
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
        run_timers(now_seconds());
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

/// One STATUS line the app shows in its log: where packets were lost, if any.
static void log_statistics(void) {
    char line[512];
    int n = snprintf(line, sizeof line, "STATUS stats ricevuti %llu, inviati %llu",
                     (unsigned long long)down_packets,
                     (unsigned long long)atomic_load(&up_packets));
    if (down_errors) n += snprintf(line + n, sizeof line - (size_t)n, ", consegna a %s fallita %llu", utun_name,
                                   (unsigned long long)down_errors);
    n += snprintf(line + n, sizeof line - (size_t)n, "; invio: coda piena %llu volte, scartati %llu",
                  (unsigned long long)atomic_load(&up_retries), (unsigned long long)atomic_load(&up_dropped));
    int error = atomic_load(&up_last_errno);
    if (error) n += snprintf(line + n, sizeof line - (size_t)n, " (%s)", strerror(error));
    struct bpf_stat bpf;
    if (ioctl(bpf_fd, BIOCGSTATS, &bpf) == 0)
        n += snprintf(line + n, sizeof line - (size_t)n, "; BPF persi %u", bpf.bs_drop);
    struct link_counters wire, tun;
    if (wire_at_start_valid && read_link_counters(opt_ifname, &wire) == 0)
        n += snprintf(line + n, sizeof line - (size_t)n, "; %s errori in uscita %u, scarti in ingresso %u", opt_ifname,
                      wire.output_errors - wire_at_start.output_errors, wire.input_drops - wire_at_start.input_drops);
    if (utun_fd >= 0 && read_link_counters(utun_name, &tun) == 0)
        snprintf(line + n, sizeof line - (size_t)n, "; %s errori in uscita %u", utun_name, tun.output_errors);
    logmsg("%s", line);
}

// MARK: Main

static void usage(void) {
    fprintf(stderr,
            "uso: pppoe-relay -I <interfaccia> -A <credenziali> [-V <vlan>] [-P <pcp>] [-S <service>]\n"
            "                 [-C <ac-name>] [-T <secondi>] [-L <logfile>]\n"
            "     pppoe-relay -I <interfaccia> -D [-V <vlan>] ...\n"
            "  -A  file con le righe: user \"nome\" / password \"segreto\"\n"
            "  -V  VLAN ID 1-4094 (omesso: senza tag)\n"
            "  -D  solo discovery: mostra i concentratori che rispondono ed esce\n");
}

int main(int argc, char **argv) {
    int ch;
    while ((ch = getopt(argc, argv, "I:A:V:P:S:C:T:L:Dh")) != -1) {
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
        default: usage(); return EXIT_OPTIONS;
        }
    }
    if (!opt_ifname || (!opt_secret && !opt_discovery_only) || (opt_vlan != -1 && (opt_vlan < 1 || opt_vlan > 4094)) ||
        opt_pcp < 0 || opt_pcp > 7 || opt_timeout < 1) {
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

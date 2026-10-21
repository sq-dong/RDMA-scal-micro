/*
 * scale_bench.c - RDMA scalability microbenchmark.
 *
 * Asymmetric mesh: server processes and client processes need not be equal.
 *   -q PEERS : number of remote peers (connected QPs, or UD AH destinations)
 *   -I ID    : local process id
 *
 * Modes: out-write|in-write|out-read|in-read|out-send|in-send
 * Transport: --rc|--uc|--ud (UD only valid for send)
 */

#include "common.h"

#include <arpa/inet.h>
#include <getopt.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

enum scale_mode {
  MODE_OUT_WRITE = 0,
  MODE_IN_WRITE,
  MODE_OUT_READ,
  MODE_IN_READ,
  MODE_OUT_SEND,
  MODE_IN_SEND,
};

enum transport {
  XPORT_RC = 0,
  XPORT_UC,
  XPORT_UD,
};

struct cfg {
  int is_server;
  char *dev;
  char *ip;
  uint16_t port;
  int gid_index;
  int size;
  int n_peer;
  int proc_id;
  int unsig;
  int postlist;
  int duration;
  int use_inline;
  enum transport xport;
  enum scale_mode mode;
  int pin_cpu;
  size_t buf_bytes; /* 0 => VT_BUF_SIZE; -B sets this (LLC footprint) */
};

static void usage(const char *a) {
  fprintf(stderr,
          "Usage: %s -s|-c -d DEV -a IP -I ID -q PEERS [-p PORT] [-x GID]\n"
          "  -M out-write|in-write|out-read|in-read|out-send|in-send\n"
          "  [-t POSTLIST] [-l SIZE] [-Q UNSIG] [-D SEC] [-C CPU]\n"
          "  [-B BUF_MB] [--no-inline] [--rc|--uc|--ud]\n"
          "  -q PEERS : remote peer count (QPs or UD destinations)\n"
          "  -I       : process id (>= 0)\n"
          "  -a       : server RoCE IPv4 (TCP bind/connect target)\n"
          "  -B       : registered buf size in MiB (spread remote addrs; "
          "PCM LLC test)\n",
          a);
  exit(1);
}

static enum scale_mode parse_mode(const char *s) {
  if (!strcmp(s, "out-write"))
    return MODE_OUT_WRITE;
  if (!strcmp(s, "in-write"))
    return MODE_IN_WRITE;
  if (!strcmp(s, "out-read"))
    return MODE_OUT_READ;
  if (!strcmp(s, "in-read"))
    return MODE_IN_READ;
  if (!strcmp(s, "out-send") || !strcmp(s, "out-send-ud"))
    return MODE_OUT_SEND;
  if (!strcmp(s, "in-send") || !strcmp(s, "in-send-ud"))
    return MODE_IN_SEND;
  fprintf(stderr, "unknown mode %s\n", s);
  usage("scale_bench");
  return MODE_OUT_WRITE;
}

static const char *mode_name(const struct cfg *c) {
  static char buf[64];
  const char *verb = "WRITE";
  const char *dir = "Out";
  switch (c->mode) {
  case MODE_OUT_WRITE:
    dir = "Out";
    verb = "WRITE";
    break;
  case MODE_IN_WRITE:
    dir = "In";
    verb = "WRITE";
    break;
  case MODE_OUT_READ:
    dir = "Out";
    verb = "READ";
    break;
  case MODE_IN_READ:
    dir = "In";
    verb = "READ";
    break;
  case MODE_OUT_SEND:
    dir = "Out";
    verb = "SEND";
    break;
  case MODE_IN_SEND:
    dir = "In";
    verb = "SEND";
    break;
  }
  const char *xp = (c->xport == XPORT_UD) ? "UD" : (c->xport == XPORT_UC) ? "UC" : "RC";
  const char *inl = c->use_inline ? "inl" : "dma";
  if (c->mode == MODE_OUT_READ || c->mode == MODE_IN_READ)
    snprintf(buf, sizeof(buf), "%s-%s-%s-%s", dir, verb, "RC", inl);
  else if (c->mode == MODE_OUT_SEND || c->mode == MODE_IN_SEND)
    snprintf(buf, sizeof(buf), "%s-%s-%s-%s", dir, verb, xp, inl);
  else
    snprintf(buf, sizeof(buf), "%s-%s-%s-%s", dir, verb, xp, inl);
  return buf;
}

static int is_send_mode(enum scale_mode m) {
  return m == MODE_OUT_SEND || m == MODE_IN_SEND;
}

static int is_read_mode(enum scale_mode m) {
  return m == MODE_OUT_READ || m == MODE_IN_READ;
}

static int i_am_requester(const struct cfg *c) {
  switch (c->mode) {
  case MODE_OUT_WRITE:
  case MODE_OUT_READ:
  case MODE_OUT_SEND:
    return c->is_server;
  case MODE_IN_WRITE:
  case MODE_IN_READ:
  case MODE_IN_SEND:
    return !c->is_server;
  }
  return 0;
}

static void parse(int argc, char **argv, struct cfg *c) {
  memset(c, 0, sizeof(*c));
  c->port = 18640;
  c->gid_index = 3;
  c->size = 32;
  c->n_peer = 1;
  c->proc_id = 0;
  c->unsig = 4;
  c->postlist = 1;
  c->duration = 5;
  c->use_inline = 1;
  c->xport = XPORT_UC;
  c->is_server = -1;
  c->mode = MODE_OUT_WRITE;
  c->pin_cpu = -1;
  c->buf_bytes = 0;
  static struct option longopts[] = {{"no-inline", no_argument, 0, 1001},
                                     {"rc", no_argument, 0, 1002},
                                     {"uc", no_argument, 0, 1003},
                                     {"ud", no_argument, 0, 1004},
                                     {0, 0, 0, 0}};
  int opt;
  while ((opt = getopt_long(argc, argv, "scd:a:p:x:l:q:I:t:Q:D:M:C:B:h",
                            longopts, NULL)) != -1) {
    switch (opt) {
    case 's':
      c->is_server = 1;
      break;
    case 'c':
      c->is_server = 0;
      break;
    case 'd':
      c->dev = optarg;
      break;
    case 'a':
      c->ip = optarg;
      break;
    case 'p':
      c->port = (uint16_t)atoi(optarg);
      break;
    case 'x':
      c->gid_index = atoi(optarg);
      break;
    case 'l':
      c->size = atoi(optarg);
      break;
    case 'q':
      c->n_peer = atoi(optarg);
      break;
    case 'I':
      c->proc_id = atoi(optarg);
      break;
    case 't':
      c->postlist = atoi(optarg);
      break;
    case 'Q':
      c->unsig = atoi(optarg);
      break;
    case 'D':
      c->duration = atoi(optarg);
      break;
    case 'M':
      if (!strcmp(optarg, "out-send-ud") || !strcmp(optarg, "in-send-ud"))
        c->xport = XPORT_UD;
      c->mode = parse_mode(optarg);
      break;
    case 'C':
      c->pin_cpu = atoi(optarg);
      break;
    case 'B': {
      int mb = atoi(optarg);
      if (mb < 1)
        mb = 1;
      c->buf_bytes = (size_t)mb * 1024ull * 1024ull;
      break;
    }
    case 1001:
      c->use_inline = 0;
      break;
    case 1002:
      c->xport = XPORT_RC;
      break;
    case 1003:
      c->xport = XPORT_UC;
      break;
    case 1004:
      c->xport = XPORT_UD;
      break;
    default:
      usage(argv[0]);
    }
  }
  if (c->is_server < 0 || !c->dev || !c->ip)
    usage(argv[0]);
  if (c->n_peer < 1 || c->n_peer > VT_MAX_QPS) {
    fprintf(stderr, "-q PEERS must be 1..%d\n", VT_MAX_QPS);
    exit(1);
  }
  if (c->n_peer > 255) {
    fprintf(stderr, "-q PEERS must be <= 255 (TCP peer id is 1 byte)\n");
    exit(1);
  }
  if (c->proc_id < 0) {
    fprintf(stderr, "-I id must be >= 0\n");
    exit(1);
  }
  if (is_read_mode(c->mode)) {
    if (c->xport != XPORT_RC)
      c->xport = XPORT_RC;
  }
  if (!is_send_mode(c->mode) && c->xport == XPORT_UD) {
    fprintf(stderr, "UD is only valid for out-send/in-send\n");
    exit(1);
  }
  if (c->unsig < 1)
    c->unsig = 1;
  if (c->postlist < 1)
    c->postlist = 1;
  if (c->postlist > 64)
    c->postlist = 64;
}

static struct ibv_qp *create_qp(struct vt_ctx *v, struct ibv_cq *scq,
                                struct ibv_cq *rcq, enum ibv_qp_type type,
                                int max_inline, int sq_depth, int rq_depth) {
  struct ibv_qp_init_attr attr;
  memset(&attr, 0, sizeof(attr));
  attr.send_cq = scq;
  attr.recv_cq = rcq;
  attr.qp_type = type;
  attr.cap.max_send_wr = (uint32_t)sq_depth;
  attr.cap.max_recv_wr = (uint32_t)rq_depth;
  attr.cap.max_send_sge = 1;
  attr.cap.max_recv_sge = 1;
  if (type == IBV_QPT_UD) {
    if (max_inline > VT_MAX_INLINE_UD)
      max_inline = VT_MAX_INLINE_UD;
  } else if (max_inline > VT_MAX_INLINE) {
    max_inline = VT_MAX_INLINE;
  }
  attr.cap.max_inline_data = (uint32_t)max_inline;
  struct ibv_qp *qp = ibv_create_qp(v->pd, &attr);
  VT_CHECK(qp, "ibv_create_qp");
  return qp;
}

static void post_recv(struct ibv_qp *qp, struct vt_ctx *v, uint64_t id,
                      int is_ud) {
  struct ibv_sge sge = {.addr = (uintptr_t)v->buf,
                        .length = (uint32_t)v->buf_size,
                        .lkey = v->mr->lkey};
  (void)is_ud;
  struct ibv_recv_wr wr = {.wr_id = id, .sg_list = &sge, .num_sge = 1};
  struct ibv_recv_wr *bad = NULL;
  VT_CHECK(ibv_post_recv(qp, &wr, &bad) == 0, "post_recv");
}

/* Wait for one WC. Returns 0 on success, -1 if deadline_ns is reached with no
 * completion (avoids infinite spin when the peer has already exited). */
static int poll_one_until(struct ibv_cq *cq, uint64_t deadline_ns) {
  struct ibv_wc wc;
  uint64_t spins = 0;
  for (;;) {
    int n = ibv_poll_cq(cq, 1, &wc);
    if (n > 0)
      break;
    if (n < 0) {
      fprintf(stderr, "poll_cq failed\n");
      exit(1);
    }
    if ((++spins & 1023) == 0 && vt_ns() >= deadline_ns)
      return -1;
  }
  if (wc.status != IBV_WC_SUCCESS) {
    fprintf(stderr, "wc %s\n", ibv_wc_status_str(wc.status));
    exit(1);
  }
  return 0;
}

static struct ibv_ah *make_ah(struct vt_ctx *v,
                              const struct vt_endpoint *remote) {
  struct ibv_ah_attr ah_attr;
  memset(&ah_attr, 0, sizeof(ah_attr));
  ah_attr.port_num = (uint8_t)v->port;
  if (v->is_roce || remote->is_roce) {
    ah_attr.is_global = 1;
    ah_attr.dlid = 0;
    memcpy(ah_attr.grh.dgid.raw, remote->gid, 16);
    ah_attr.grh.sgid_index = (uint8_t)v->gid_index;
    ah_attr.grh.hop_limit = 1;
  } else {
    ah_attr.is_global = 0;
    ah_attr.dlid = (uint16_t)remote->lid;
  }
  struct ibv_ah *ah = ibv_create_ah(v->pd, &ah_attr);
  VT_CHECK(ah, "ibv_create_ah");
  return ah;
}

static int tcp_listen_only(const char *ip, uint16_t port, int backlog) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  VT_CHECK(fd >= 0, "socket");
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  VT_CHECK(inet_pton(AF_INET, ip, &addr.sin_addr) == 1, "inet_pton");
  VT_CHECK(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0, "bind");
  VT_CHECK(listen(fd, backlog) == 0, "listen");
  return fd;
}

static void mesh_listen_exchange(struct cfg *c, struct vt_endpoint *locals,
                                 struct vt_endpoint *remotes, int n_peer,
                                 int n_local_qp) {
  int lfd = tcp_listen_only(c->ip, (uint16_t)(c->port + c->proc_id),
                            n_peer + 4);
  int got = 0;
  while (got < n_peer) {
    struct sockaddr_in addr;
    socklen_t alen = sizeof(addr);
    int fd = accept(lfd, (struct sockaddr *)&addr, &alen);
    VT_CHECK(fd >= 0, "accept");
    uint8_t peer = 0xff;
    VT_CHECK(read(fd, &peer, 1) == 1, "peer id");
    VT_CHECK(peer < (uint8_t)n_peer, "peer id range");
    int li = (n_local_qp == 1) ? 0 : (int)peer;
    vt_tcp_exchange(fd, &locals[li], &remotes[peer]);
    close(fd);
    got++;
  }
  close(lfd);
}

static void mesh_connect_exchange(struct cfg *c, struct vt_endpoint *locals,
                                  struct vt_endpoint *remotes, int n_peer,
                                  int n_local_qp) {
  for (int peer = 0; peer < n_peer; peer++) {
    int fd = -1;
    for (int try = 0; try < 600; try++) {
      fd = socket(AF_INET, SOCK_STREAM, 0);
      VT_CHECK(fd >= 0, "socket");
      struct sockaddr_in addr;
      memset(&addr, 0, sizeof(addr));
      addr.sin_family = AF_INET;
      addr.sin_port = htons((uint16_t)(c->port + peer));
      VT_CHECK(inet_pton(AF_INET, c->ip, &addr.sin_addr) == 1, "inet_pton");
      if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0)
        break;
      close(fd);
      fd = -1;
      usleep(50000);
    }
    VT_CHECK(fd >= 0, "connect peers");
    uint8_t me = (uint8_t)c->proc_id;
    VT_CHECK(write(fd, &me, 1) == 1, "send id");
    int li = (n_local_qp == 1) ? 0 : peer;
    vt_tcp_exchange(fd, &locals[li], &remotes[peer]);
    close(fd);
  }
}

int main(int argc, char **argv) {
  struct cfg c;
  parse(argc, argv, &c);
  setvbuf(stdout, NULL, _IONBF, 0);
  if (c.pin_cpu >= 0)
    vt_pin_cpu(c.pin_cpu);

  const int is_ud = (c.xport == XPORT_UD);
  const int requester = i_am_requester(&c);
  const int n_peer = c.n_peer;

  /* UD: one local QP. Connected: one QP per remote peer. */
  int n_local = is_ud ? 1 : n_peer;

  enum ibv_qp_type qpt =
      is_ud ? IBV_QPT_UD : (c.xport == XPORT_UC ? IBV_QPT_UC : IBV_QPT_RC);
  const int inl_cap = vt_inline_grant(c.size, c.use_inline, is_ud);
  const int sq_depth = 128;
  const int rq_depth = is_send_mode(c.mode) ? 512 : (is_ud ? 512 : 16);

  int unsig = c.unsig;
  if (unsig > 1 && unsig < 2 * c.postlist)
    unsig = 2 * c.postlist;
  if (unsig > sq_depth / 2)
    unsig = sq_depth / 2;

  struct vt_ctx v;
  vt_open_device(&v, c.dev, 1, c.gid_index);
  /* -B: enlarge MR so remote WRITEs hit a larger LLC footprint (PCM). */
  size_t buf_bytes = c.buf_bytes ? c.buf_bytes : (size_t)VT_BUF_SIZE;
  size_t addr_stride = 4096;
  if (n_local > 0 && buf_bytes / (size_t)n_local > addr_stride)
    addr_stride = buf_bytes / (size_t)n_local;
  addr_stride &= ~(size_t)63; /* cacheline align */
  if (addr_stride < 4096)
    addr_stride = 4096;
  if (addr_stride * (size_t)n_local > buf_bytes)
    buf_bytes = addr_stride * (size_t)n_local;
  vt_alloc_buf(&v, buf_bytes,
               IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
                   IBV_ACCESS_REMOTE_READ);

  struct ibv_cq *scqs[VT_MAX_QPS];
  struct ibv_cq *rcqs[VT_MAX_QPS];
  struct ibv_qp *qps[VT_MAX_QPS];
  struct vt_endpoint locals[VT_MAX_QPS], remotes[VT_MAX_QPS];
  struct ibv_ah *ahs[VT_MAX_QPS];
  uint32_t psns[VT_MAX_QPS];
  memset(ahs, 0, sizeof(ahs));
  memset(scqs, 0, sizeof(scqs));
  memset(rcqs, 0, sizeof(rcqs));

  for (int i = 0; i < n_local; i++) {
    scqs[i] = ibv_create_cq(v.ctx, 512, NULL, NULL, 0);
    VT_CHECK(scqs[i], "scq");
    if (is_ud || is_send_mode(c.mode)) {
      rcqs[i] = ibv_create_cq(v.ctx, 512, NULL, NULL, 0);
      VT_CHECK(rcqs[i], "rcq");
    } else {
      rcqs[i] = scqs[i];
    }
    qps[i] = create_qp(&v, scqs[i], rcqs[i], qpt, inl_cap, sq_depth, rq_depth);
    psns[i] = (uint32_t)((vt_ns() + (uint64_t)i * 9973 +
                          (uint64_t)c.proc_id * 7919) &
                         0xffffff);
    vt_fill_local_ep(&v, qps[i], psns[i], &locals[i]);
    locals[i].addr = (uint64_t)(uintptr_t)(v.buf + (size_t)i * addr_stride);
    vt_qp_to_init(qps[i], v.port);
  }

  if (c.is_server) {
    mesh_listen_exchange(&c, locals, remotes, n_peer, n_local);
  } else {
    /* In-SEND-UD uses the same full mesh as Out-SEND-UD (roles flipped). */
    mesh_connect_exchange(&c, locals, remotes, n_peer, n_local);
  }

  if (is_ud) {
    vt_qp_to_rtr(&v, qps[0], &remotes[0], qpt);
    vt_qp_to_rts(qps[0], psns[0]);
    if (requester) {
      for (int i = 0; i < n_peer; i++)
        ahs[i] = make_ah(&v, &remotes[i]);
    }
  } else {
    for (int i = 0; i < n_local; i++) {
      vt_qp_to_rtr(&v, qps[i], &remotes[i], qpt);
      vt_qp_to_rts(qps[i], psns[i]);
    }
  }

  const char *tag = mode_name(&c);

  /* Responder / passive path */
  if (!requester) {
    const int need_recv = is_send_mode(c.mode);
    printf("scale passive %s peers=%d id=%d nqp=%d\n", tag, n_peer, c.proc_id,
           n_local);
    fflush(stdout);

    if (!need_recv) {
      /* WRITE/READ target: no per-op notification; idle. */
      if (c.duration > 0)
        sleep((unsigned)c.duration + 5);
      else
        pause();
      return 0;
    }

    /* SEND target: post RECVs; optionally count for remote-side metering. */
    for (int qi = 0; qi < n_local; qi++) {
      for (int r = 0; r < rq_depth / 2; r++)
        post_recv(qps[qi], &v, (uint64_t)r + (uint64_t)qi * 1000003ull, is_ud);
    }

    uint64_t ops = 0;
    uint64_t t0 = vt_ns();
    uint64_t deadline =
        t0 + (uint64_t)(c.duration > 0 ? c.duration : 3600) * 1000000000ull;
    const uint64_t check_every = 65536;
    uint64_t poll_iters = 0;

    while (1) {
      /* Check time on idle polls too — peer may stop posting before ops hits
       * the next check_every boundary (otherwise we busy-spin forever). */
      int got = 0;
      for (int qi = 0; qi < n_local; qi++) {
        struct ibv_wc wc[16];
        int n = ibv_poll_cq(rcqs[qi], 16, wc);
        for (int i = 0; i < n; i++) {
          if (wc[i].status != IBV_WC_SUCCESS) {
            fprintf(stderr, "wc %s\n", ibv_wc_status_str(wc[i].status));
            exit(1);
          }
          if (wc[i].opcode & IBV_WC_RECV) {
            post_recv(qps[qi], &v, wc[i].wr_id, is_ud);
            ops++;
            got++;
          }
        }
      }
      poll_iters++;
      if (c.duration > 0 &&
          (got == 0 || (ops & (check_every - 1)) == 0 ||
           (poll_iters & 1023) == 0) &&
          vt_ns() >= deadline)
        break;
    }

    double sec = (vt_ns() - t0) / 1e9;
    if (sec < 1e-6)
      sec = 1e-6;
    double mops = ops / sec / 1e6;
    printf("scale %s: %.2f Mops  peers=%d id=%d Q=%d size=%d postlist=%d "
           "(recv)\n",
           tag, mops, n_peer, c.proc_id, is_ud ? 1 : n_peer, c.size,
           c.postlist);
    fflush(stdout);
    return 0;
  }

  /* Requester hot path */
  memset(v.buf, 1, v.buf_size);
  const int pl = c.postlist;
  struct ibv_send_wr wr[64], *bad;
  struct ibv_sge sge[64];
  uint64_t nb_tx_qp[VT_MAX_QPS];
  memset(nb_tx_qp, 0, sizeof(nb_tx_qp));
  uint64_t ops = 0;
  uint64_t seed = 0x12345678abcdefull ^ ((uint64_t)c.proc_id << 17);

  printf("scale sender %s peers=%d id=%d nqp=%d size=%d inl=%d postlist=%d "
         "unsig=%d\n",
         tag, n_peer, c.proc_id, n_local, c.size, inl_cap, pl, unsig);
  fflush(stdout);

  const uint64_t check_every = 65536;
  uint64_t t0 = vt_ns();
  uint64_t deadline = t0 + (uint64_t)c.duration * 1000000000ull;
  uint64_t loop_iters = 0;

  while (1) {
    loop_iters++;
    if (c.duration > 0 &&
        ((ops & (check_every - 1)) == 0 || (loop_iters & 1023) == 0) &&
        vt_ns() >= deadline)
      break;

    if (is_ud && is_send_mode(c.mode)) {
      /* Out-SEND-UD and In-SEND-UD: one local QP, AH per peer, random dest. */
      int stop = 0;
      for (int w = 0; w < pl; w++) {
        int dest = (int)(seed % (uint64_t)n_peer);
        seed = seed * 6364136223846793005ull + 1;
        memset(&wr[w], 0, sizeof(wr[w]));
        memset(&sge[w], 0, sizeof(sge[w]));
        wr[w].opcode = IBV_WR_SEND;
        wr[w].num_sge = 1;
        wr[w].sg_list = &sge[w];
        wr[w].next = (w == pl - 1) ? NULL : &wr[w + 1];
        wr[w].send_flags =
            vt_should_signal(nb_tx_qp[0], unsig) ? IBV_SEND_SIGNALED : 0;
        if (vt_should_signal(nb_tx_qp[0], unsig) && nb_tx_qp[0] > 0) {
          if (poll_one_until(scqs[0], deadline) != 0) {
            stop = 1;
            break;
          }
        }
        if (c.use_inline && c.size <= inl_cap)
          wr[w].send_flags |= IBV_SEND_INLINE;
        sge[w].addr = (uintptr_t)v.buf;
        sge[w].length = (uint32_t)c.size;
        sge[w].lkey = v.mr->lkey;
        wr[w].wr.ud.ah = ahs[dest];
        wr[w].wr.ud.remote_qpn = remotes[dest].qpn;
        wr[w].wr.ud.remote_qkey = 0x11111111;
        nb_tx_qp[0]++;
      }
      if (stop)
        break;
      VT_CHECK(ibv_post_send(qps[0], &wr[0], &bad) == 0, "post");
      ops += (uint64_t)pl;
    } else {
      int qi = (int)(seed % (uint64_t)n_local);
      seed = seed * 6364136223846793005ull + 1;
      enum ibv_wr_opcode opc;
      int stop = 0;
      if (is_read_mode(c.mode))
        opc = IBV_WR_RDMA_READ;
      else if (is_send_mode(c.mode))
        opc = IBV_WR_SEND;
      else
        opc = IBV_WR_RDMA_WRITE;

      for (int w = 0; w < pl; w++) {
        memset(&wr[w], 0, sizeof(wr[w]));
        memset(&sge[w], 0, sizeof(sge[w]));
        wr[w].opcode = opc;
        wr[w].num_sge = 1;
        wr[w].sg_list = &sge[w];
        wr[w].next = (w == pl - 1) ? NULL : &wr[w + 1];
        wr[w].send_flags =
            vt_should_signal(nb_tx_qp[qi], unsig) ? IBV_SEND_SIGNALED : 0;
        if (vt_should_signal(nb_tx_qp[qi], unsig) && nb_tx_qp[qi] > 0) {
          if (poll_one_until(scqs[qi], deadline) != 0) {
            stop = 1;
            break;
          }
        }
        if (!is_read_mode(c.mode) && c.use_inline && c.size <= inl_cap)
          wr[w].send_flags |= IBV_SEND_INLINE;
        sge[w].addr = (uintptr_t)(v.buf + (size_t)qi * 64);
        sge[w].length = (uint32_t)c.size;
        sge[w].lkey = v.mr->lkey;
        if (!is_send_mode(c.mode)) {
          wr[w].wr.rdma.remote_addr = remotes[qi].addr;
          wr[w].wr.rdma.rkey = remotes[qi].rkey;
        }
        nb_tx_qp[qi]++;
      }
      if (stop)
        break;
      VT_CHECK(ibv_post_send(qps[qi], &wr[0], &bad) == 0, "post");
      ops += (uint64_t)pl;
    }
  }

  double sec = (vt_ns() - t0) / 1e9;
  if (sec < 1e-6)
    sec = 1e-6;
  double mops = ops / sec / 1e6;
  int q_report = n_peer;
  printf("scale %s: %.2f Mops  peers=%d id=%d Q=%d size=%d postlist=%d\n", tag,
         mops, n_peer, c.proc_id, q_report, c.size, pl);
  fflush(stdout);

  for (int i = 0; i < n_peer; i++) {
    if (ahs[i])
      ibv_destroy_ah(ahs[i]);
  }
  for (int i = 0; i < n_local; i++) {
    ibv_destroy_qp(qps[i]);
    if (rcqs[i] && rcqs[i] != scqs[i])
      ibv_destroy_cq(rcqs[i]);
    ibv_destroy_cq(scqs[i]);
  }
  vt_close_device(&v);
  return 0;
}

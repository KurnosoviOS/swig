/* transport_adapter_nack.c */

#include <pjmedia/vid_stream.h>
#include <pjmedia/stream.h>
#include <pj/pj_assert.h>
#include <pj/pool.h>
#include <pj/log.h>
#include "transport_adapter_nack.h"
#include <pjmedia/rtp.h>
#include <pj/lock.h>

#if defined (__ANDROID__) //|| defined (TARGET_OS_IOS) || defined (TARGET_OS_IPHONE)

#include <signal.h>
#include <time.h>

#endif // __ANDROID__

typedef struct nack_stat
{
    pj_uint32_t rcv;                                /* Total recieved packets with duplicated */
    pj_uint32_t rtr;                                /* Total retransmitted packets */
    pj_uint32_t snd;                                /* Total sent packets without retransmitted */
    pj_uint32_t req;                                /* Total requested packets */
    pj_uint32_t dup;                                /* Total recieved duplicate packets */
    pj_uint32_t rx_ts_local;                        /* Local side last completely recieved block timestamp */
    pj_uint32_t tx_ts_local;                        /* Local side last sent block timestamp */
    pj_uint32_t rx_ts_remote;                        /* Remote side last recieved block timestamp */
    pj_uint32_t rx_ts_timer;
    pj_uint32_t tx_ts_timer;
    pj_uint16_t tx_size_timer;
} nack_stat;

enum
{
    RTP_NACK_PT = 127
};



#define SYMBOL_SIZE_MAX    PJMEDIA_MAX_MTU                            /* Max packet size, in bytes. */
#define RETR_TABLE_SIZE 100                                        /* Retransmission packets table size for ACK/NACK */
#define BURST_LOSS_SIZE 3                                        /* Packets sequence numbers max diff */
#define BURST_CHECK_DELAY 50                                    /* Burst loss check timer timeout, msec */

enum
{
    RTCP_SR = 200,                                                /* RTCP sender report payload type */
    RTCP_RR = 201,                                                /* RTCP reciever report payload type */
    RTCP_FIR = 206,                                                /* RTCP full intra request payload type */
    RTCP_NACK = 205,                                            /* RTCP feedback negative acknowlegment request payload type */
    RTCP_ACK = 204                                                /* RTCP feedback positive acknowlegment request payload type */
};

/* Timers ids */
enum
{
    ACK_TIMER = 2
};

static char *this_file_tmpl = "tp_nack_%s";

/* Transport functions prototypes */
static pj_status_t    transport_get_info        (pjmedia_transport *tp, pjmedia_transport_info *info);
/* transport_attach for Android pjsip 2.4 compatibility */
static pj_status_t    transport_attach        (pjmedia_transport *tp,    void *user_data, const pj_sockaddr_t *rem_addr,    const pj_sockaddr_t *rem_rtcp, unsigned addr_len, void(*rtp_cb)(void*, void*, pj_ssize_t), void(*rtcp_cb)(void*, void*, pj_ssize_t));
#if defined(PJ_VERSION_NUM_MAJOR) && (PJ_VERSION_NUM_MAJOR == 2) && defined(PJ_VERSION_NUM_MINOR) && (PJ_VERSION_NUM_MINOR >= 6)
static pj_status_t    transport_attach2        (pjmedia_transport *tp, pjmedia_transport_attach_param *att_prm);
#endif
static void            transport_detach        (pjmedia_transport *tp, void *strm);
static pj_status_t    transport_send_rtp        (pjmedia_transport *tp, const void *pkt, pj_size_t size);
static pj_status_t    transport_send_rtcp        (pjmedia_transport *tp, const void *pkt, pj_size_t size);
static pj_status_t    transport_send_rtcp2    (pjmedia_transport *tp, const pj_sockaddr_t *addr, unsigned addr_len, const void *pkt, pj_size_t size);
static pj_status_t    transport_media_create    (pjmedia_transport *tp, pj_pool_t *sdp_pool, unsigned options, const pjmedia_sdp_session *rem_sdp, unsigned media_index);
static pj_status_t    transport_encode_sdp    (pjmedia_transport *tp, pj_pool_t *sdp_pool, pjmedia_sdp_session *local_sdp, const pjmedia_sdp_session *rem_sdp, unsigned media_index);
static pj_status_t    transport_media_start    (pjmedia_transport *tp, pj_pool_t *pool, const pjmedia_sdp_session *local_sdp, const pjmedia_sdp_session *rem_sdp, unsigned media_index);
static pj_status_t    transport_media_stop    (pjmedia_transport *tp);
static pj_status_t    transport_simulate_lost    (pjmedia_transport *tp, pjmedia_dir dir, unsigned pct_lost);
static pj_status_t    transport_destroy        (pjmedia_transport *tp);

static void            transport_retransmit_rtp(void *user_data /* TP adapter */, const pj_uint32_t ts, pj_uint32_t skew);

/* RTCP functions prototypes */
static pj_status_t transport_send_rtcp_ack(pjmedia_transport *tp, pj_uint32_t ts);

/* The transport operations */
static struct pjmedia_transport_op nack_adapter_op =
{
    &transport_get_info,
#if defined(PJ_VERSION_NUM_MAJOR) && (PJ_VERSION_NUM_MAJOR == 2) && defined(PJ_VERSION_NUM_MINOR) && (PJ_VERSION_NUM_MINOR <= 6)
    &transport_attach,
#else
    NULL,
#endif
    &transport_detach,
    &transport_send_rtp,
    &transport_send_rtcp,
    &transport_send_rtcp2,
    &transport_media_create,
    &transport_encode_sdp,
    &transport_media_start,
    &transport_media_stop,
    &transport_simulate_lost,
    &transport_destroy,
#if defined(PJ_VERSION_NUM_MAJOR) && (PJ_VERSION_NUM_MAJOR == 2) && defined(PJ_VERSION_NUM_MINOR) && (PJ_VERSION_NUM_MINOR >= 6)
    &transport_attach2,
#endif
};

typedef struct retr_entry
{
    PJ_DECL_LIST_MEMBER(struct retr_entry);
    pj_uint8_t pkt[SYMBOL_SIZE_MAX];
    pj_uint32_t ts;
    pj_uint16_t size;
} retr_entry;

/* Compare callback must return zero for success found result */
static int retr_list_comp(void *value, const pj_list_type *node)
{
    /* Find first entry with 'seq' equal requested value */
    return !(((retr_entry *)node)->ts == *((pj_uint32_t *)value));
}

static void retr_list_init(retr_entry *list, retr_entry *arr, const pj_uint16_t size)
{
    pj_uint16_t i;
    
    pj_list_init(list);
    
    /* Init list entries */
    for (i = 0; i < size; i++)
        pj_list_push_back(list, &arr[i]);
}

static void retr_list_push_back(retr_entry *list, const void *pkt, const pj_uint16_t size, const pj_uint32_t ts)
{
    retr_entry *e = list->next;
    
    /* Remove entry from head */
    pj_list_erase(e);
    
    /* Change entry data */
    e->ts = ts;
    e->size = size;
    if (pkt && size)
        memcpy(e->pkt, pkt, size);
    
    /* Push entry back */
    pj_list_push_back(list, e);
}

static retr_entry *retr_list_search(retr_entry *list, pj_uint32_t ts)
{
    return (retr_entry *)pj_list_search(list, &ts, &retr_list_comp);
}

static retr_entry *retr_list_next(retr_entry *list, retr_entry *e)
{
    /* If next is a head this is the end of list */
    if (e->next == list)
        return NULL;
    
    return e->next;
}

static retr_entry *retr_list_first(retr_entry *list)
{
    if (list->next == list)
        return NULL;
    
    return list->next;
}

static void retr_list_reset(retr_entry *list)
{
    retr_entry *e = retr_list_first(list);
    for (; e; e = retr_list_next(list, e))
        e->ts = 0;
}

/* The transport adapter instance */
struct nack_adapter
{
    pjmedia_transport    base;
    pj_bool_t            del_base;
    pj_pool_t            *pool;
    pjsip_endpoint        *sip_endpt;
    
    /* Stream information. */
    void                *stream_user_data;
    void                *stream_ref;
    void                (*stream_rtp_cb)(void *user_data, void *pkt, pj_ssize_t);
    void                (*stream_rtcp_cb)(void *user_data, void *pkt, pj_ssize_t);
    
    /* Timer members */
    
    pj_time_val                delay;                        /* Max buffering delay, msec */
    pj_timer_entry            timer_entry;
    
    pj_bool_t                rtp_flag;                    /* Incoming RTP packets detection flag */
    
    pj_lock_t                *timer_lock;                /* Synchronization object for timer/rtp callbacks */
    pj_lock_t                *rtp_lock;                    /* RTP send/retransmit lock */
    
    char                    this_file[15];                /* For logging purposes */
    
    
    pjmedia_transport        *slave_tp;                    /* Base transport pointer */
    
    pjmedia_rtcp_session    *rtcp_ses;                    /* Pointer to encoding RTCP session for statistics update purpose */
    pjmedia_rtp_session        *rtp_tx_ses;                /* Pointer to encoding RTP session */
    pjmedia_rtp_session        *rtp_rx_ses;                /* Pointer to decoding RTP session */
    
    unsigned                ts_delay;
    unsigned                ts_step;
    
    /* Retransmission buffer and list for ACK/NACK */
    retr_entry                retr_arr[RETR_TABLE_SIZE], retr_list;
    
    /* Statistics */
    nack_stat                stat;
    
#if defined (__ANDROID__) //|| defined (TARGET_OS_IOS) || defined (TARGET_OS_IPHONE)
    timer_t                    posix_timer_id;
#endif // __ANDROID__
    
};

#if defined (__ANDROID__) //|| defined (TARGET_OS_IOS) || defined (TARGET_OS_IPHONE)

#define CLOCKID CLOCK_REALTIME
#define SIG SIGRTMIN

static void posix_timer_cb(int sig, siginfo_t *si, void *uc)
{
    struct nack_adapter *a = (struct nack_adapter *)si->si_value.sival_ptr;
    pj_status_t status;
    
    /* Prevent data racing with 'transport_rtp_cb' calls from pjsip */
    pj_lock_acquire(a->timer_lock);
    
    PJ_LOG(5, (a->this_file, "NACK timer callback rx_ts_local=%lu rx_ts_timer=%lu", a->stat.rx_ts_local, a->stat.rx_ts_timer));
    
    /* Send positive acknowlegement if last recieved packet sequence number not changed */
    if (a->stat.rx_ts_local && a->rtp_flag == PJ_FALSE)
    {
        status = transport_send_rtcp_ack(si->si_value.sival_ptr, a->stat.rx_ts_local);
        pj_assert(status == PJ_SUCCESS);
    }
    
    /* Update last recieved sequence number for timer future compare */
    a->stat.rx_ts_timer = a->stat.rx_ts_local;
    
    a->rtp_flag = PJ_FALSE;
    
    pj_lock_release(a->timer_lock);
}

static void posix_timer_schedule(void *user_data /* TP adapter */, long sec, long msec)
{
    struct sigevent sev;
    struct itimerspec its;
    struct sigaction sa;
    struct nack_adapter *a = (struct nack_adapter *)user_data;
    
    /* Establish handler for timer signal */
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = posix_timer_cb;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIG, &sa, NULL) == -1)
    {
        PJ_LOG(4, (a->this_file, "NACK Establish handler for timer signal failed"));
        return;
    }
    
    /* Create the timer */
    sev.sigev_notify = SIGEV_SIGNAL;
    sev.sigev_signo = SIG;
    sev.sigev_value.sival_ptr = user_data;
    if (timer_create(CLOCKID, &sev, &a->posix_timer_id) == -1)
    {
        PJ_LOG(4, (a->this_file, "NACK Create the timer failed"));
        return;
    }
    
    /* Start the timer */
    its.it_value.tv_sec = sec;
    its.it_value.tv_nsec = msec * 1000000;
    its.it_interval.tv_sec = its.it_value.tv_sec;
    its.it_interval.tv_nsec = its.it_value.tv_nsec;
    if (timer_settime(a->posix_timer_id, 0, &its, NULL) == -1)
    {
        PJ_LOG(4, (a->this_file, "NACK Start the timer id=0x%lx failed", (long)a->posix_timer_id));
        return;
    }
    
    PJ_LOG(4, (a->this_file, "NACK Timer id=0x%lx started sec=%ld msec=%ld", (long)a->posix_timer_id, sec, msec));
}

static void posix_timer_cancel(void *user_data /* TP adapter */)
{
    struct nack_adapter *a = (struct nack_adapter *)user_data;
    
    if (a->posix_timer_id == -1)
        return;
    
    if (!timer_delete(a->posix_timer_id))
    {
        PJ_LOG(4, (a->this_file, "NACK Timer id=0x%lx stopped", (long)a->posix_timer_id));
    }
    else
    {
        PJ_LOG(4, (a->this_file, "NACK Timer id=0x%lx stop failed", (long)a->posix_timer_id));
    }
    
    a->posix_timer_id = -1;
}
#endif // __ANDROID__

/**
 * Dumps a buffer (typically a symbol).
 */
static void dump_pkt(const void * const buf, const pj_uint16_t size, pj_uint16_t esi, const char *type)
{
    char    *ptr;
    pj_uint16_t    n = size;
    char str[SYMBOL_SIZE_MAX * 3] = { '\0' }, *p = str;
    
    //p += sprintf(p, "%s_%03u size=%u: ", type, esi, size);
    PJ_UNUSED_ARG(esi);
    PJ_UNUSED_ARG(type);
    p += sprintf(p, "size=%u: ", size);
    p += sprintf(p, "0x");
    for (ptr = (char *)buf; n > 0; n--, ptr++)
    {
        //p += sprintf(p, "%hhX", *ptr);
        p += sprintf(p, "%02X", (unsigned char)*ptr);
    }
    p += sprintf(p, "\n");
    
    PJ_LOG(5, ("dump_pkt", str));
}

static void timer_cb(pj_timer_heap_t *timer_heap, struct pj_timer_entry *entry)
{
    PJ_UNUSED_ARG(timer_heap);
    struct nack_adapter *a = (struct nack_adapter *)entry->user_data;
    pj_status_t status;
    
    /* Prevent data racing with 'transport_rtp_cb' calls from pjsip */
    pj_lock_acquire(a->timer_lock);
    
    PJ_LOG(5, (a->this_file, "NACK timer callback rx_ts_local=%lu rx_ts_timer=%lu", a->stat.rx_ts_local, a->stat.rx_ts_timer));
    
    /* Send positive acknowlegement if last recieved packet sequence number not changed */
    if (a->stat.rx_ts_local && a->rtp_flag == PJ_FALSE)
    {
        status = transport_send_rtcp_ack(entry->user_data, a->stat.rx_ts_local);
        pj_assert(status == PJ_SUCCESS);
    }
    
    /* Update last recieved sequence number for timer future compare */
    a->stat.rx_ts_timer = a->stat.rx_ts_local;
    
    a->rtp_flag = PJ_FALSE;
    
    pj_lock_release(a->timer_lock);
    
    /* Restart timer */
    //if (a->timer_entry.id > 0)
    //    pjsip_endpt_cancel_timer(a->sip_endpt, &a->timer_entry);
    
    a->timer_entry.id = ACK_TIMER;
    
    pjsip_endpt_schedule_timer(a->sip_endpt, &a->timer_entry, &a->delay);
}

/*
 * Create the adapter.
 */
PJ_DEF(pj_status_t) pjmedia_nack_adapter_create(pjsip_endpoint *sip_endpt, pjmedia_endpt *endpt, const char *name, pjmedia_transport *transport, pj_bool_t del_base, pjmedia_transport **p_tp)
{
    pj_pool_t *pool;
    struct nack_adapter *a;
    
    if (name == NULL)
        name = "tpad%p";
    
    /* Create the pool and initialize the adapter structure */
    pool = pjmedia_endpt_create_pool(endpt, name, 512, 512);
    a = PJ_POOL_ZALLOC_T(pool, struct nack_adapter);
    a->pool = pool;
    pj_ansi_strncpy(a->base.name, pool->obj_name, sizeof(a->base.name));
    a->base.type = (pjmedia_transport_type)(PJMEDIA_TRANSPORT_TYPE_USER + 2);
    a->base.op = &nack_adapter_op;
    
    /* Save the transport as the slave transport */
    a->slave_tp = transport;
    a->del_base = del_base;
    
    a->sip_endpt = sip_endpt;
    
    /* Timer thread and lock init */
    a->timer_lock = NULL;
    a->timer_entry.cb = &timer_cb;
    a->timer_entry.user_data = a;
    a->timer_entry.id = -1;
    
#if defined (__ANDROID__) //|| defined(TARGET_OS_IOS) || defined(TARGET_OS_IPHONE)
    a->posix_timer_id = -1;
#endif // __ANDROID__
    
    retr_list_init(&a->retr_list, a->retr_arr, RETR_TABLE_SIZE);
    
    /* Done */
    *p_tp = &a->base;
    return PJ_SUCCESS;
}


/*
 * get_info() is called to get the transport addresses to be put
 * in SDP c= line and a=rtcp line.
 */
static pj_status_t transport_get_info(pjmedia_transport *tp, pjmedia_transport_info *info)
{
    struct nack_adapter *a = (struct nack_adapter*)tp;
    
    /* Since we don't have our own connection here, we just pass
     * this function to the slave transport.
     */
    return pjmedia_transport_get_info(a->slave_tp, info);
}

/* This is our RTP callback, that is called by the slave transport when it
 * receives RTP packet.
 */
static void transport_rtp_cb(void *user_data, void *pkt, pj_ssize_t size)
{
    struct nack_adapter *a = (struct nack_adapter*)user_data;
    pjmedia_rtp_hdr *hdr = (pjmedia_rtp_hdr *)pkt;
    pj_uint32_t ts = pj_ntohl(hdr->ts);
    
    /* Prevent data racing with 'timer_cb' */
    pj_lock_acquire(a->timer_lock);
    
    /* Reset timer loss detection flag */
    a->rtp_flag = PJ_TRUE;
    
    /* Retransmitted packet */
    if (hdr->pt == RTP_NACK_PT)
    {
        /* Statistics */
        a->stat.dup++;
        
        /* Restore payload type before transfer */
        hdr->pt = a->rtp_rx_ses->out_pt;
    }
    
    /* Statistics */
    a->stat.rcv++;
    
    /* Update last recieved packet sequence number */
    if (ts > a->stat.rx_ts_local)
        a->stat.rx_ts_local = ts;
    
    pj_lock_release(a->timer_lock);
    
    a->stream_rtp_cb(a->stream_user_data, pkt, size);
    return;
}

/* This is our RTCP callback, that is called by the slave transport when it
 * receives RTCP packet.
 */
static void transport_rtcp_cb(void *user_data, void *pkt, pj_ssize_t size)
{
    struct nack_adapter *a = (struct nack_adapter*)user_data;
    pjmedia_rtcp_common *hdr = (pjmedia_rtcp_common*)pkt;
    
    
    if (hdr->pt == RTCP_ACK)
    {
        a->stat.rx_ts_remote = pj_ntohl(hdr->ssrc);
        
        transport_retransmit_rtp(a, a->stat.rx_ts_remote, a->stat.tx_ts_local);
        
        return;
    }
    
    pj_assert(a->stream_rtcp_cb != NULL);
    
    /* Call stream's callback */
    a->stream_rtcp_cb(a->stream_user_data, pkt, size);
}

#if defined(PJ_VERSION_NUM_MAJOR) && (PJ_VERSION_NUM_MAJOR == 2) && defined(PJ_VERSION_NUM_MINOR) && (PJ_VERSION_NUM_MINOR < 6)
/*
 * attach() needed only for old pjsip transport interfaces compatibility used in android client
 */
static pj_status_t transport_attach(pjmedia_transport *tp,
                                    void *user_data,
                                    const pj_sockaddr_t *rem_addr,
                                    const pj_sockaddr_t *rem_rtcp,
                                    unsigned addr_len,
                                    void(*rtp_cb)(void*, void*, pj_ssize_t),
                                    void(*rtcp_cb)(void*, void*, pj_ssize_t))
{
    struct nack_adapter *a = (struct nack_adapter*)tp;
    pj_status_t status;
    
    pj_assert(a->stream_user_data == NULL);
    a->stream_user_data = user_data;
    a->stream_rtp_cb = rtp_cb;
    a->stream_rtcp_cb = rtcp_cb;
    /* pjsip assign stream pointer to user_data  */
    a->stream_ref = user_data;
    
    /* Get pointer RTP session information of the media stream */
    if (a->stream_type == PJMEDIA_TYPE_VIDEO)
        pjmedia_vid_stream_get_rtp_session_tx(a->stream_ref, &a->rtp_tx_ses);
    /* Not implemented */
    else
        return PJ_EINVALIDOP;
    
    
    /* Not implemented */
    a->rtcp_ses = NULL;
    
    rtp_cb = &transport_rtp_cb;
    rtcp_cb = &transport_rtcp_cb;
    user_data = a;
    
    status = pjmedia_transport_attach(a->slave_tp, user_data, rem_addr, rem_rtcp, addr_len, rtp_cb, rtcp_cb);
    if (status != PJ_SUCCESS)
    {
        a->stream_user_data = NULL;
        a->stream_rtp_cb = NULL;
        a->stream_rtcp_cb = NULL;
        a->stream_ref = NULL;
        return status;
    }
    
    return PJ_SUCCESS;
}
#endif

#if defined(PJ_VERSION_NUM_MAJOR) && (PJ_VERSION_NUM_MAJOR == 2) && defined(PJ_VERSION_NUM_MINOR) && (PJ_VERSION_NUM_MINOR >= 6)
/*
 * attach2() is called by stream to register callbacks that we should
 * call on receipt of RTP and RTCP packets.
 */
static pj_status_t transport_attach2(pjmedia_transport *tp, pjmedia_transport_attach_param *att_param)
{
    struct nack_adapter *a = (struct nack_adapter *)tp;
    pj_status_t status;
    pjmedia_transport_attach_param param;
    pjmedia_port *port;
    
    
    /* In this example, we will save the stream information and callbacks
     * to our structure, and we will register different RTP/RTCP callbacks
     * instead.
     */
    pj_assert(a->stream_user_data == NULL);
    a->stream_user_data = att_param->user_data;
    a->stream_rtp_cb = att_param->rtp_cb;
    a->stream_rtcp_cb = att_param->rtcp_cb;
    a->stream_ref = att_param->stream;
    
    /* Get pointer RTP session information of the media stream */
    pjmedia_stream_rtp_sess_info session_info;
    
    switch (att_param->media_type)
    {
        case PJMEDIA_TYPE_AUDIO:
        {
            sprintf(a->this_file, this_file_tmpl, "aud");
            
            pjmedia_stream_get_rtp_session_info(a->stream_ref, &session_info);
            
            status = pjmedia_stream_get_port(a->stream_ref, &port);
            if (status == PJ_SUCCESS)
            {
                a->ts_delay = BURST_CHECK_DELAY * (port->info.fmt.det.aud.clock_rate / 1000);
                a->ts_step = (port->info.fmt.det.aud.frame_time_usec / 1000) * (port->info.fmt.det.aud.clock_rate / 1000);
            }
            else
            {
                PJ_LOG(4, (a->this_file, "NACK get media stream params failed"));
                return PJ_EINVALIDOP;
            }
            
            break;
        }
        default:
        {
            PJ_LOG(4, (a->this_file, "NACK unsupported media type. Attach to media stream failed"));
            return PJ_EINVALIDOP;
        }
    }
    
    a->delay.sec = 0;
    a->delay.msec = BURST_CHECK_DELAY;
    
    a->rtp_tx_ses = (pjmedia_rtp_session *)session_info.tx_rtp;
    a->rtp_rx_ses = (pjmedia_rtp_session *)session_info.rx_rtp;
    a->rtcp_ses = (pjmedia_rtcp_session *)session_info.rtcp;
    
    //att_param->rtp_cb = &transport_rtp_cb;
    //att_param->rtcp_cb = &transport_rtcp_cb;
    //att_param->user_data = a;
    
    /* Create timer callback lock  */
    status = pj_lock_create_simple_mutex(a->pool, "timer_lock", &a->timer_lock);
    if (status != PJ_SUCCESS)
    {
        PJ_LOG(4, (a->this_file, "NACK timer callback lock creation failed"));
        return PJ_EUNKNOWN;
    }
    
    /* Create rtp send lock  */
    status = pj_lock_create_simple_mutex(a->pool, "rtp_lock", &a->rtp_lock);
    if (status != PJ_SUCCESS)
    {
        PJ_LOG(4, (a->this_file, "NACK rtp send lock creation failed"));
        return PJ_EUNKNOWN;
    }
    
    retr_list_reset(&a->retr_list);
    
    a->rtp_flag = PJ_FALSE;
    
    //a->timer_entry.id = ACK_TIMER;
    //pjsip_endpt_schedule_timer(a->sip_endpt, &a->timer_entry, &a->delay);
    
#if defined (__ANDROID__) //|| defined (TARGET_OS_IOS) || defined (TARGET_OS_IPHONE)
    posix_timer_schedule(a, a->delay.sec, a->delay.msec);
#else
    a->timer_entry.id = ACK_TIMER;
    pjsip_endpt_schedule_timer(a->sip_endpt, &a->timer_entry, &a->delay);
#endif // __ANDROID__
    
    
    /* Stat structure total zeroing */
    memset(&a->stat, 0, sizeof(a->stat));
    
    /* Attach self to member transport */
    param = *att_param;
    param.user_data = a;
    param.rtp_cb = &transport_rtp_cb;
    param.rtcp_cb = &transport_rtcp_cb;
    
    status = pjmedia_transport_attach2(a->slave_tp, &param);
    if (status != PJ_SUCCESS)
    {
        a->stream_user_data = NULL;
        a->stream_rtp_cb = NULL;
        a->stream_rtcp_cb = NULL;
        a->stream_ref = NULL;
        return status;
    }
    
    return PJ_SUCCESS;
}
#endif

/*
 * detach() is called when the media is terminated, and the stream is
 * to be disconnected from us.
 */
static void transport_detach(pjmedia_transport *tp, void *strm)
{
    struct nack_adapter *a = (struct nack_adapter*)tp;
    
    PJ_UNUSED_ARG(strm);
    
#if defined (__ANDROID__) //|| defined (TARGET_OS_IOS) || defined (TARGET_OS_IPHONE)
    posix_timer_cancel(a);
    a->posix_timer_id = -1;
#else
    if (a->timer_entry.id > 0)
        pjsip_endpt_cancel_timer(a->sip_endpt, &a->timer_entry);
#endif // __ANDROID__
    
    PJ_LOG(4, (a->this_file, "NACK statistics: sent=%lu retransmit=%lu recieve=%lu requested=%lu duplicated=%lu", a->stat.snd, a->stat.rtr, a->stat.rcv, a->stat.req, a->stat.dup));
    
    if (a->stream_user_data != NULL)
    {
        pjmedia_transport_detach(a->slave_tp, a);
        a->stream_user_data = NULL;
        a->stream_rtp_cb = NULL;
        a->stream_rtcp_cb = NULL;
        a->stream_ref = NULL;
    }
}

static void transport_retransmit_rtp(void *user_data, const pj_uint32_t ts_from, pj_uint32_t ts_to)
{
    struct nack_adapter *a = (struct nack_adapter *)user_data;
    pj_status_t status;
    retr_entry *e = NULL;
    pjmedia_rtp_hdr *hdr;
    int len;
    pj_uint16_t rtr = 0;
    pj_uint32_t ts;
    
    if (!ts_from || !ts_to)
        return;
    
    pj_lock_acquire(a->rtp_lock);
    
    /* Search success sent item */
    e = retr_list_search(&a->retr_list, ts_from);
    
    /* Calculate transmit window */
    ts = ts_to - ts_from;
    
    /* Check transmit window */
    if (ts < a->ts_delay)
        e = NULL;
    else if (e)
    /* Go to the untransmitted item */
        e = retr_list_next(&a->retr_list, e);
    
    PJ_LOG(5, (a->this_file, "NACK retransmit request ts_from=%lu ts_to=%lu last_tx=%lu", ts_from, ts_to, a->stat.tx_ts_local));
    
    /* Determine transmit window high border timestamp */
    // TODO do it more
    ts = ts_from + a->ts_delay + a->ts_step;
    
    /* Send required sequence */
    while (e && e->ts < ts)
    {
        /* Update session */
        status = pjmedia_rtp_encode_rtp(a->rtp_tx_ses, -1, -1, -1, 0, (const void **)&hdr, &len);
        pj_assert(status == PJ_SUCCESS);
        
        //PJ_LOG(5, (a->this_file, "NACK retransmit packet for seq=%u found_seq=%u new_seq=%u seq_size=%u", seq, pj_ntohs(((pjmedia_rtp_hdr *)e->pkt)->seq), pj_ntohs(hdr->seq), seq_size));
        //PJ_LOG(5, (a->this_file, "NACK retransmit packet for ts=%lu found_ts=%lu new_seq=%u seq_size=%u", seq, e->seq, pj_ntohs(hdr->seq), seq_size));
        
        /* Update sequence number for SRTP */
        ((pjmedia_rtp_hdr *)e->pkt)->seq = hdr->seq;
        /* Change payload type for statistics on remote side */
        ((pjmedia_rtp_hdr *)e->pkt)->pt = RTP_NACK_PT;
        
        status = pjmedia_transport_send_rtp(a->slave_tp, e->pkt, e->size);
        pj_assert(status == PJ_SUCCESS);
        
        /* Local logging purpose */
        rtr++;
        
        /* Statistics */
        a->stat.rtr++;
        
        e = retr_list_next(&a->retr_list, e);
    }
    
    pj_lock_release(a->rtp_lock);
    
    PJ_LOG(5, (a->this_file, "NACK retransmitted ts_from=%lu ts_to=%lu ts_wnd=%lu count=%u", ts_from, ts_to, ts, rtr));
}

/*
 * send_rtp() is called to send RTP packet. The "pkt" and "size" argument
 * contain both the RTP header and the payload.
 */

static pj_status_t transport_send_rtp(pjmedia_transport *tp, const void *pkt, pj_size_t size)
{
    struct nack_adapter *a = (struct nack_adapter *)tp;
    pj_status_t status;
    
    pj_lock_acquire(a->rtp_lock);
    
    /* Update last sent packet sequence number */
    a->stat.tx_ts_local = pj_ntohl(((pjmedia_rtp_hdr *)pkt)->ts);
    
    /* Statistics */
    a->stat.snd++;
    
    
    /* Store sent packets for ACK/NACK requests retransmit */
    retr_list_push_back(&a->retr_list, pkt, (pj_uint16_t)size, a->stat.tx_ts_local);
    
    status = pjmedia_transport_send_rtp(a->slave_tp, pkt, size);
    pj_assert(status == PJ_SUCCESS);
    
    //PJ_LOG(5, (a->this_file, "NACK sent RTP packet seq=%u", a->stat.tx_seq_local));
    
    a->stat.tx_size_timer++;
    
    pj_lock_release(a->rtp_lock);
    
    return status;
}

/* Send a RTCP NACK/ACK */
static pj_status_t transport_send_rtcp_ack(pjmedia_transport *tp, pj_uint32_t ts)
{
    struct nack_adapter *a = (struct nack_adapter*)tp;
    pj_uint8_t buf[64];
    pjmedia_rtcp_common *hdr = (pjmedia_rtcp_common*)buf;
    pj_size_t len = sizeof(*hdr);
    pj_uint8_t *p;
    //nack_rtcp_hdr *nack = (nack_rtcp_hdr *)&hdr->ssrc;
    
    /* Not implemented for 2.4 */
    if (!a->rtcp_ses)
        return PJ_EINVALIDOP;
    
    /* Build RTCP packet */
    pj_memcpy(hdr, &a->rtcp_ses->rtcp_sr_pkt.common, len);
    hdr->pt = RTCP_ACK;
    p = (pj_uint8_t *)hdr + len;
    
    /* In place of the SSRC value of the media sender */
    hdr->ssrc = pj_htonl(ts);
    
    
    /* The length of RTCP packet in 32 bit words minus one, including the header and any padding. */
    hdr->length = pj_htons((pj_uint16_t)(len / sizeof(pj_uint32_t) - 1));
    
    pj_assert((int)len == p - (pj_uint8_t *)buf);
    
    /* Statistics */
    a->stat.req++;
    
    PJ_LOG(5, (a->this_file, "NACK sending positive request for ts=%lu", ts));
    
    return transport_send_rtcp(tp, (void *)buf, len);
}

/*
 * send_rtcp() is called to send RTCP packet. The "pkt" and "size" argument
 * contain the RTCP packet.
 */
static pj_status_t transport_send_rtcp(pjmedia_transport *tp, const void *pkt, pj_size_t size)
{
    struct nack_adapter *a = (struct nack_adapter *)tp;
    
    /* You may do some processing to the RTCP packet here if you want. */
    
    /* Send the packet using the slave transport */
    return pjmedia_transport_send_rtcp(a->slave_tp, pkt, size);
}


/*
 * This is another variant of send_rtcp(), with the alternate destination
 * address in the argument.
 */
static pj_status_t transport_send_rtcp2(pjmedia_transport *tp, const pj_sockaddr_t *addr, unsigned addr_len, const void *pkt, pj_size_t size)
{
    struct nack_adapter *a = (struct nack_adapter *)tp;
    
    /* You may do some processing to the RTCP packet here if you want. */
    return pjmedia_transport_send_rtcp2(a->slave_tp, addr, addr_len, pkt, size);
}

/*
 * The media_create() is called when the transport is about to be used for
 * a new call.
 */
static pj_status_t transport_media_create(pjmedia_transport *tp, pj_pool_t *sdp_pool, unsigned options, const pjmedia_sdp_session *rem_sdp, unsigned media_index)
{
    struct nack_adapter *a = (struct nack_adapter *)tp;
    
    /* if "rem_sdp" is not NULL, it means we are UAS. You may do some
     * inspections on the incoming SDP to verify that the SDP is acceptable
     * for us. If the SDP is not acceptable, we can reject the SDP by
     * returning non-PJ_SUCCESS.
     */
    if (rem_sdp)
    {
        
    }
    
    /* Once we're done with our initialization, pass the call to the
     * slave transports to let it do it's own initialization too.
     */
    return pjmedia_transport_media_create(a->slave_tp, sdp_pool, options, rem_sdp, media_index);
}

/*
 * The encode_sdp() is called when we're about to send SDP to remote party,
 * either as SDP offer or as SDP answer.
 */
static pj_status_t transport_encode_sdp(pjmedia_transport *tp, pj_pool_t *sdp_pool, pjmedia_sdp_session *local_sdp, const pjmedia_sdp_session *rem_sdp, unsigned media_index)
{
    struct nack_adapter *a = (struct nack_adapter *)tp;
    
    /* If "rem_sdp" is not NULL, it means we're encoding SDP answer.
     * We can check remote side support level before we send SDP.
     */
    if (rem_sdp)
    {
        
    }
    /* Set our params in local SDP if we are sending offer */
    else
    {
        
    }
    
    /* And then pass the call to slave transport to let it encode its
     * information in the SDP. You may choose to call encode_sdp() to slave
     * first before adding your custom attributes if you want.
     */
    return pjmedia_transport_encode_sdp(a->slave_tp, sdp_pool, local_sdp, rem_sdp, media_index);
}

/*
 * The media_start() is called once both local and remote SDP have been
 * negotiated successfully, and the media is ready to start. Here we can start
 * committing our processing.
 */
static pj_status_t transport_media_start(pjmedia_transport *tp, pj_pool_t *pool, const pjmedia_sdp_session *local_sdp, const pjmedia_sdp_session *rem_sdp, unsigned media_index)
{
    struct nack_adapter *a = (struct nack_adapter *)tp;
    
    /* Check support by remote side */
    if (rem_sdp)
    {
        
    }
    
    /* And pass the call to the slave transport */
    return pjmedia_transport_media_start(a->slave_tp, pool, local_sdp, rem_sdp, media_index);
}

/*
 * The media_stop() is called when media has been stopped.
 */
static pj_status_t transport_media_stop(pjmedia_transport *tp)
{
    struct nack_adapter *a = (struct nack_adapter *)tp;
    
    /* And pass the call to the slave transport */
    return pjmedia_transport_media_stop(a->slave_tp);
}

/*
 * simulate_lost() is called to simulate packet lost
 */
static pj_status_t transport_simulate_lost(pjmedia_transport *tp, pjmedia_dir dir, unsigned pct_lost)
{
    struct nack_adapter *a = (struct nack_adapter *)tp;
    
    return pjmedia_transport_simulate_lost(a->slave_tp, dir, pct_lost);
}

/*
 * destroy() is called when the transport is no longer needed.
 */
static pj_status_t transport_destroy(pjmedia_transport *tp)
{
    struct nack_adapter *a = (struct nack_adapter *)tp;
    
    /* Close the slave transport */
    if (a->del_base)
        pjmedia_transport_close(a->slave_tp);
    
    /* Self destruct */
    pj_pool_release(a->pool);
    
    return PJ_SUCCESS;
}

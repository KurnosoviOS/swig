/* $Id: transport_adapter_sample.c 5478 2016-11-03 09:39:20Z riza $ */
/*
 * Copyright (C) 2008-2011 Teluu Inc. (http://www.teluu.com)
 * Copyright (C) 2003-2008 Benny Prijono <benny@prijono.org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include <pjmedia/vid_stream.h>
#include <pjmedia/stream.h>
#include <pj/assert.h>
#include <pj/pool.h>
#include <pj/log.h>
#include "transport_adapter_fec.h"
#include <time.h>
#include <pjmedia/rtp.h>

//#pragma comment(lib, "openfec.lib")

/* Fast floor/ceiling macro-functions
 * https://www.codeproject.com/Tips/700780/Fast-floor-ceiling-functions
 */
#define shift_floor(arg)    ((int)(arg + 32768.) - 32768)
#define shift_ceil(arg)        (32768 - (int)(32768. - arg))

/*
 * Size must be multiple 32bit
 */
typedef struct fec_ext_hdr
{
    pj_uint32_t                sn;                        /* Symbol sequence number (ecnoding block number) */
    pj_uint16_t                esi;                    /* Encoding symbol ID */
    pj_uint16_t                k;                        /* Source symbols in block */
    pj_uint16_t                n;                        /* Source+repair symbols in block */
    pj_uint16_t                esl;                    /* Encoding (max) symbol size in block */
    pj_uint16_t                s;                        /* Encoded by FEC coder symbol size for repair */
    pj_uint16_t                rsrv;                    /* Reserve */
} fec_ext_hdr;

/*
 * FEC SDP attributes by
 * 3GPP TS 26.346 version 12.3.0 Release 12
 */

const char *fec_sdp_attrs [] =
{
    "FEC-declaration",
    "FEC-redundancy-level",
    "FEC",
    "FEC-OTI-extension",
    //"FEC-OTI-FEC-Encoding-ID",
    //"FEC-OTI-Maximum-Source-Block-Length",
    //"FEC-OTI-Encoding-Symbol-Length",
    //"FEC-OTI-Max-Number-of-Encoding-Symbols",
    //"FEC-OTI-FEC-Instance-ID",
    //"FEC-OTI-Scheme-Specific-Info",
    NULL
};

/*
 * Redundancy parameters K_MAX, N_MAX, CODE_RATE_MAX
 * for buffer's arrays max sizes definitions
 * Change if required
 */
#define K_MIN                4                                    /* Source symbols min count in sequence */
#define K_MAX                20                                    /* Source symbols max count in sequence */
#define CODE_RATE_MAX        .667                                /* k/n = 2/3 means we add max 50% of repair symbols */
#define N_MAX                shift_ceil(K_MAX / CODE_RATE_MAX)    /* n value = k/code_rate means we add 50% of repair symbols */

#if defined(K_MIN) && defined(K_MAX) && (K_MIN >= K_MAX)
#error Check redundancy parameters K_MAX, K_MIN
#endif

/*
 * Max symbol buffer size, in bytes.
 * NOTE: PJMEDIA_MAX_VID_PAYLOAD_SIZE redefinition must be made in confgi_site.h to reserve place for RTP Extension and FEC headers for video
 */
#define SYMBOL_SIZE_MAX    PJMEDIA_MAX_MTU

/* RTP and RTCP decoding specific macros */
#define RTP_VERSION    2                                            /* RTP version */
#define RTCP_SR        200                                            /* RTCP sender report payload type */
#define RTCP_RR        201                                            /* RTCP reciever report payload type */
#define RTCP_FIR    206                                            /* RTCP FIR request payload type */
#define RTP_EXT_PT  127                                            /* RTP extension header profile data for FEC header */

/* For logging purposes */
#define THIS_FILE   "tp_adap_fec"

/* Transport functions prototypes */
static pj_status_t    transport_get_info        (pjmedia_transport *tp, pjmedia_transport_info *info);
static void            transport_rtp_cb        (void * user_data, void * pkt, pj_ssize_t size);
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

/* FEC functions prototypes */

/* openfec.org FEC framework decoder callback for source and repair restored symbols */
static void*        fec_dec_cb                (void *context /* TP adapter */, pj_uint32_t size, pj_uint32_t esi);
/* Decode from RTP packet FEC extension header */
static void*        fec_dec_hdr                (const void *pkt, fec_ext_hdr *fec_hdr);
/* Decode source and repair symbols and copy to decoding buffer */
static pj_uint16_t    fec_dec_pkt                (void * const dst, void *pkt, pj_ssize_t size, pj_bool_t rtp);
/* Clear adapter decoding buffers and init decoder instance with new params */
static pj_status_t    fec_dec_reset            (void *user_data /* TP adapter */, pj_uint16_t k, pj_uint16_t n, pj_uint16_t len);
/* Decode packets length */
static pj_status_t    fec_dec_len                (void *user_data /* TP adapter */);

/* Add packets to encoding buffer and call encoder */
static pj_status_t    fec_enc_pkt                (void *user_data /* TP adapter */, const void *pkt, pj_size_t size);
/* Add FEC extension header to sources packets and copy to encoding buffer */
static pj_uint16_t    fec_enc_src                (void *dst, const void *pkt, pj_uint16_t size, const fec_ext_hdr *fec_hdr, const pjmedia_rtp_ext_hdr *ext_hdr);
/* Add RTP and FEC extension headers to repair packets and copy to encoding buffer */
static pj_uint16_t  fec_enc_rpr                (void *dst, pjmedia_rtp_session *ses, int ts_len, const void *payload, pj_uint16_t payload_len, const fec_ext_hdr *fec_hdr, const pjmedia_rtp_ext_hdr *ext_hdr);
/* Clear adapter encoding buffers */
static pj_status_t    fec_enc_reset            (void *user_data /* TP adapter */, pj_uint16_t n, pj_uint16_t len);
/* Encode packets length */
static pj_status_t    fec_enc_len                (void *user_data /* TP adapter */);

/* RTCP functions prototypes */
static pj_status_t    transport_send_rtcp_fir(pjmedia_transport *tp);

/* The transport operations */
static struct pjmedia_transport_op tp_adapter_op =
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

/* The transport adapter instance */
struct tp_adapter
{
    pjmedia_transport    base;
    pj_bool_t            del_base;
    pj_pool_t            *pool;
    
    /* Stream information. */
    void                *stream_user_data;
    void                *stream_ref;
    void                (*stream_rtp_cb)(void *user_data, void *pkt, pj_ssize_t);
    void                (*stream_rtcp_cb)(void *user_data, void *pkt, pj_ssize_t);
    
    pjmedia_type        stream_type;
    
    
    pjmedia_transport        *slave_tp;                    /* Base transport pointer */
    
    /* FEC specific encoding/decoding members */
    of_codec_id_t            codec_id;                    /* Identifier of the codec to use */
    
    of_session_t            *dec_ses;                    /* Current decoder instance pointer */
    
    of_parameters_t            *enc_params;                /* Pointer to common encoding params */
    of_parameters_t            *dec_params;                /* Pointer to common decoding params */
    
    of_rs_2_m_parameters_t    enc_rs_params;                /* Structure used to store Reed-Solomon codes over GF(2^m) params */
    of_ldpc_parameters_t    enc_ldps_params;            /* Structure used to store LDPC-Staircase large block FEC codes params */
    
    of_rs_2_m_parameters_t    dec_rs_params;                /* Structure used to store Reed-Solomon codes over GF(2^m) params */
    of_ldpc_parameters_t    dec_ldps_params;            /* Structure used to store LDPC-Staircase large block FEC codes params */
    
    pjmedia_rtp_session        *rtp_tx_ses;                /* Pointer to encoding RTP session */
    pjmedia_rtcp_session    *rtcp_ses;                    /* Pointer to encoding RTCP session for statistics update purpose */
    
    pjmedia_rtp_hdr            rtp_hdr;                    /* RTP header with common default values for encoding repair symbols */
    pjmedia_rtp_ext_hdr        ext_hdr;                    /* RTP Extension header with common default values for encoding purpose */
    fec_ext_hdr                fec_hdr;                    /* RTP Extension header data with common FEC encoding session values */
    
    /* FEC specific runtime values */
    pj_uint16_t                snd_k_max;                    /* Max count of source symbols in the block, depends on stream type */
    pj_uint16_t                snd_k;                        /* Current count of ready to send source symbols in the block */
    pj_uint32_t                snd_sn;                        /* Current number of encoding symbol's sequence */
    pj_uint16_t                snd_len;                    /* Current max packet length of encoding symbol's sequence */
    pj_bool_t                snd_ready;
    
    pj_uint16_t                rcv_k;                        /* Current count of recieved source/repair symbols of decoding block */
    pj_uint32_t                rcv_sn;                        /* Current number of decoding symbol's sequence */
    
    pj_uint8_t                rtcp_fir_sn;                /* Full Intra Request number */
    
    double                    tx_loss;                    /* Current TX packets lost fraction based on RTCP fraction lost field, updates by each incoming RTCP packet callback */
    double                    tx_code_rate;                /* Current TX code rate */
    
    /* Encoding buffers. We'll update it progressively without reallocation */
    void*        enc_symbols_ptr[N_MAX];                        /* Table containing pointers to the encoding (i.e. source + repair) symbols buffers */
    pj_uint8_t    enc_symbols_buf[SYMBOL_SIZE_MAX * N_MAX];    /* Buffer containing encoding (i.e. source + repair) symbols */
    pj_uint16_t    enc_symbols_size[N_MAX];                    /* Table containing network(real) sizes of the encoding symbols(packets) (i.e. source + repair) */
    pj_uint8_t    enc_symbol_buf[SYMBOL_SIZE_MAX];            /* Runtime buffer for single encoding packet */
    
    /* Decoding buffers. We'll update it progressively without reallocation */
    void*        dec_symbols_ptr[N_MAX];                        /* Table containing pointers to the decoding (i.e. source + repair) symbols buffers */
    pj_uint8_t    dec_symbols_buf[SYMBOL_SIZE_MAX * N_MAX];    /* Buffer containing decoding (i.e. source + repair) symbols */
    pj_uint16_t    dec_symbols_size[N_MAX];                    /* Table containing network(real) sizes of the decoding symbols(packets) (i.e. source + repair) */
    
#if 1
    pj_bool_t    old_client;
#endif // 1
    
};

/**
 * Dumps len32 32-bit words of a buffer (typically a symbol).
 */
static void dump_pkt(const void *buf, const pj_uint32_t size, pj_uint16_t esi, const char *type)
{
    char    *ptr;
    pj_uint16_t    n = size;
    char str[SYMBOL_SIZE_MAX * 3] = { '\0' }, *p = str;
    
    p += sprintf(p, "%s_%03u size=%u: ", type, esi, size);
    p += sprintf(p, "0x");
    for (ptr = (char *)buf; n > 0; n--, ptr++)
    {
        p += sprintf(p, "%hhX", *ptr);
    }
    p += sprintf(p, "\n");
    
    PJ_LOG(4, (THIS_FILE, str));
}

/* Clear runtime params and encoding buffer */
static pj_status_t fec_enc_reset(void *user_data, pj_uint16_t n, pj_uint16_t len)
{
    struct tp_adapter *a = (struct tp_adapter *)user_data;
    pj_uint16_t esi;
    
    if (!a)
        return PJ_EINVAL;
    
    /* Clear buffer */
    for (esi = 0; esi < n; esi++)
    {
        memset(a->enc_symbols_ptr[esi], 0, len);
        //memset(a->enc_symbols_ptr[esi], 0, SYMBOL_SIZE_MAX);
        a->enc_symbols_size[esi] = 0;
    }
    
    /* Reset runtime params */
    a->snd_k = 0;
    a->snd_len = 0;
    a->snd_ready = PJ_FALSE;
    
    return PJ_SUCCESS;
}

/* New decoder creation for adaptive decoding */
static pj_status_t fec_dec_reset(void *user_data, pj_uint16_t k, pj_uint16_t n, pj_uint16_t len)
{
    struct tp_adapter *a = (struct tp_adapter *)user_data;
    pj_status_t status = PJ_SUCCESS;
    pj_uint16_t esi;
    
    if (!a)
        return PJ_EINVAL;
    
    /* Decoder reinit */
    if (a->dec_ses)
        of_release_codec_instance(a->dec_ses);
    
    //for (esi = 0; esi < n; esi++)
    esi = a->dec_params->nb_source_symbols + a->dec_params->nb_repair_symbols;
    while (esi--)
    {
        memset(a->dec_symbols_ptr[esi], 0, a->dec_params->encoding_symbol_length);
        //memset(a->dec_symbols_ptr[esi], 0, SYMBOL_SIZE_MAX);
        a->dec_symbols_size[esi] = 0;
    }
    
    a->rcv_k = 0;
    a->dec_params->nb_source_symbols = k;
    a->dec_params->nb_repair_symbols = n - k;
    a->dec_params->encoding_symbol_length = len;
    
    /* Open and initialize the openfec session */
    if (of_create_codec_instance(&a->dec_ses, a->codec_id, OF_DECODER, 2 /* Verbosity */) != OF_STATUS_OK)
    {
        status = PJ_EINVAL;
        PJ_LOG(4, (THIS_FILE, "Create decoder instance failed"));
    }
    /* Set session parameters */
    if (status == PJ_SUCCESS && of_set_fec_parameters(a->dec_ses, a->dec_params) != OF_STATUS_OK)
    {
        status = PJ_EINVAL;
        PJ_LOG(4, (THIS_FILE, "Set parameters failed for decoder codec_id=%d", a->codec_id));
    }
    
    /* Setup callbacks for decoding */
    if (of_set_callback_functions(a->dec_ses, &fec_dec_cb, NULL, a) != OF_STATUS_OK)
    {
        status = PJ_EINVAL;
        PJ_LOG(4, (THIS_FILE, "Set callback functions failed for decoder with codec_id=%d", a->codec_id));
    }
    
    
    /* Cleanup session on fail */
    if (status != PJ_SUCCESS && a->dec_ses)
        of_release_codec_instance(a->dec_ses);
    
    return status;
}

static void* fec_dec_len_cb(void *context, unsigned size, unsigned esi)
{
    pj_uint16_t *dec_len_tab = (pj_uint16_t *)context;
    
    return &dec_len_tab[esi];
}

static pj_status_t    fec_dec_len(void *user_data)
{
    struct tp_adapter        *a = (struct tp_adapter *)user_data;
    of_session_t            *dec_ses;
    pj_uint16_t                esi, k, n;
    of_rs_2_m_parameters_t    dec_params;
    
    if (of_create_codec_instance(&dec_ses, OF_CODEC_REED_SOLOMON_GF_2_M_STABLE, OF_DECODER, 2) != OF_STATUS_OK)
        return PJ_EINVAL;
    
    dec_params.nb_source_symbols = a->dec_params->nb_source_symbols;
    dec_params.nb_repair_symbols = a->dec_params->nb_repair_symbols;
    dec_params.encoding_symbol_length = sizeof(pj_uint16_t);
    dec_params.m = 8;
    
    if (of_set_fec_parameters(dec_ses, (of_parameters_t *)&dec_params) != OF_STATUS_OK
        || of_set_callback_functions(dec_ses, &fec_dec_len_cb, NULL, (void *)a->dec_symbols_size) != OF_STATUS_OK)
    {
        PJ_LOG(4, (THIS_FILE, "Set parameters failed for length decoder codec_id=%d", a->codec_id));
        
        of_release_codec_instance(dec_ses);
        
        return PJ_EINVAL;
    }
    
    k = dec_params.nb_source_symbols;
    n = dec_params.nb_source_symbols + dec_params.nb_repair_symbols;
    
    for (esi = 0; esi < n; esi++)
    {
        if(a->dec_symbols_size[esi])
            of_decode_with_new_symbol(dec_ses, (void *)&a->dec_symbols_size[esi], esi);
        
        if (of_is_decoding_complete(dec_ses))
            break;
    }
    
    of_release_codec_instance(dec_ses);
    
    return PJ_SUCCESS;
}

static pj_status_t    fec_enc_len(void *user_data)
{
    struct tp_adapter        *a = (struct tp_adapter *)user_data;
    of_session_t            *enc_ses;
    pj_uint16_t                esi, n, k;
    of_rs_2_m_parameters_t    enc_params;
    void*                    enc_symbols_tab[N_MAX];
    
    if (of_create_codec_instance(&enc_ses, OF_CODEC_REED_SOLOMON_GF_2_M_STABLE, OF_ENCODER, 2) != OF_STATUS_OK)
        return PJ_EINVAL;
    
    enc_params.nb_source_symbols = a->enc_params->nb_source_symbols;
    enc_params.nb_repair_symbols = a->enc_params->nb_repair_symbols;
    enc_params.encoding_symbol_length = sizeof(pj_uint16_t);
    enc_params.m = 8;
    
    
    if (of_set_fec_parameters(enc_ses, (of_parameters_t *)&enc_params) != OF_STATUS_OK)
    {
        PJ_LOG(4, (THIS_FILE, "Set parameters failed for length encoder codec_id=%d", a->codec_id));
        
        of_release_codec_instance(enc_ses);
        
        return PJ_EINVAL;
    }
    
    k = enc_params.nb_source_symbols;
    n = enc_params.nb_source_symbols + enc_params.nb_repair_symbols;
    
    for (esi = 0; esi < n; esi++)
        enc_symbols_tab[esi] = (void *)&a->enc_symbols_size[esi];
    
    for (esi = k; esi < n; esi++)
        of_build_repair_symbol(enc_ses, enc_symbols_tab, esi);
    
    of_release_codec_instance(enc_ses);
    
    return PJ_SUCCESS;
}

static pj_status_t fec_enc_pkt(void *user_data, const void *pkt, pj_size_t size)
{
    struct tp_adapter    *a = (struct tp_adapter *)user_data;
    pj_status_t            status = PJ_SUCCESS;
    pj_uint16_t            esi, n, k, len;
    of_session_t        *enc_ses;
    
    /* Put to table only if current count of symbols less than k */
    //if (a->snd_k < K_MAX) // TODO replace by param depending on stream type
    if (a->snd_k < a->snd_k_max)
    {
        /* Copy source symbol to buffer */
        memcpy(a->enc_symbols_ptr[a->snd_k], pkt, size);
        
        /* Remember real size for source symbols */
        a->enc_symbols_size[a->snd_k] = (pj_uint16_t)size;
        
        a->snd_k++;
        
        /* Update max packet length in sequence */
        if (size > a->snd_len)
            a->snd_len = (pj_uint16_t)size;
    }
    
    pjmedia_rtp_hdr *rtp_hdr = (pjmedia_rtp_hdr *)pkt;
    
    /*
     * If symbol is mark packet (end of frame packets sequence)
     * and collected count over min value
     * or collected count equal max value,
     * stop collect source symbols, build repair symbols
     */
    //if ((a->snd_k < K_MAX && !rtp_hdr->m) || (rtp_hdr->m && a->snd_k < K_MIN)) // TODO replace by param depending on stream type
    if ((a->snd_k < a->snd_k_max && !rtp_hdr->m) || (rtp_hdr->m && a->snd_k < K_MIN))
        return PJ_SUCCESS;
    
    k = a->snd_k;
    /* For dynamic reduancy use variable with packet loss info from RTCP callback */
    n = shift_ceil(k / a->tx_code_rate);
    len = a->snd_len;
    
    /* Sequence counter for new symbols block */
    a->snd_sn++;
    
    /* Setup current encoder params */
    a->enc_params->nb_source_symbols = k;
    a->enc_params->nb_repair_symbols = n - k;
    a->enc_params->encoding_symbol_length = len;
    
    /* Open and initialize the new openfec session */
    if (of_create_codec_instance(&enc_ses, a->codec_id, OF_ENCODER, 2 /* Verbosity */) != OF_STATUS_OK)
    {
        PJ_LOG(4, (THIS_FILE, "Create encoder instance failed"));
        
        return PJ_EINVAL;
    }
    
    /* Set session parameters */
    if (of_set_fec_parameters(enc_ses, a->enc_params) != OF_STATUS_OK)
    {
        PJ_LOG(4, (THIS_FILE, "Set parameters failed for encoder codec_id=%d", a->codec_id));
        
        /* Cleanup session on fail before return */
        of_release_codec_instance(enc_ses);
        
        return PJ_EINVAL;
    }
    
    /* Build the n-k repair symbols if count of symbols is enough */
    for (esi = k; esi < n; esi++)
    {
        if (of_build_repair_symbol(enc_ses, a->enc_symbols_ptr, esi) != OF_STATUS_OK)
        {
            PJ_LOG(4, (THIS_FILE, "Build repair symbol failed for esi=%u", esi));
        }
        else
        {
            /* Set repair symbol length to max value */
            a->enc_symbols_size[esi] = len;
        }
    }
    
    a->snd_ready = PJ_TRUE;
    
    /* Cleanup session on fail or success */
    of_release_codec_instance(enc_ses);
    
    return status;
}

/* Unified restore callback for source and repair packets */
static void* fec_dec_cb(void *context, pj_uint32_t size, pj_uint32_t esi)
{
    struct tp_adapter *a = (struct tp_adapter *)context;
    
    /* Must return buffer pointer for decoder to save restored source packet in adapter buffer */
    return a->dec_symbols_ptr[esi];
}

/* Construct in destination buffer packet with Extension header and data based on original RTP source symbol */
static pj_uint16_t fec_enc_src(void *dst, const void *pkt, pj_uint16_t size, const fec_ext_hdr *fec_hdr, const pjmedia_rtp_ext_hdr *ext_hdr)
{
    unsigned num;
    pj_uint8_t *ptr = (pj_uint8_t *)dst;
    
    /* Assume RTP header at begin of packet */
    pjmedia_rtp_hdr *rtp_hdr = (pjmedia_rtp_hdr *)pkt;
    
    /* Sanity check */
    if (rtp_hdr->v != RTP_VERSION || rtp_hdr->x)
    {
        PJ_LOG(4, (THIS_FILE, "RTP packet header decode failed esi=%u, sn=%u", fec_hdr->esi, fec_hdr->sn));
        return 0;
    }
    
    /* Set Extension header flag in original RTP packet */
    rtp_hdr->x = 1;
    
    /* Payload is located right after header plus CSRC */
    /* Copy modified header plus CSRCs until payload */
    num = sizeof(pjmedia_rtp_hdr) + rtp_hdr->cc * sizeof(pj_uint32_t);
    memcpy(ptr, pkt, num);
    ptr += num;
    
    /* Remember payload offset in original packet and decrease copy left size */
    pkt = (pj_uint8_t *)pkt + num;
    size -= num;
    
    /* Insert RTP Extension header */
    num = sizeof(pjmedia_rtp_ext_hdr);
    memcpy(ptr, ext_hdr, num);
    ptr += num;
    
    /* Insert FEC header as Extension header data */
    //num = sizeof(fec_ext_hdr);
    num = pj_ntohs(ext_hdr->length) * sizeof(pj_uint32_t);
    memcpy(ptr, fec_hdr, num);
    ptr += num;
    
    /* Copy payload */
    memcpy(ptr, pkt, size);
    ptr += size;
    
    return (ptr - (pj_uint8_t *)dst);
}

/* Construct in destination buffer RTP packet with Extension header and data based on FEC repair symbol */
static pj_uint16_t fec_enc_rpr(void *dst, pjmedia_rtp_session *ses, int ts_len, const void *payload, pj_uint16_t payload_len, const fec_ext_hdr *fec_hdr, const pjmedia_rtp_ext_hdr *ext_hdr)
{
    int num;
    pj_uint8_t *ptr = (pj_uint8_t *)dst;
    pjmedia_rtp_hdr *hdr;
    
    /* Get RTP header */
    pjmedia_rtp_encode_rtp(ses, ses->out_pt, 0, payload_len, ts_len, &hdr, &num);
    
    /* Copy RTP header */
    memcpy(ptr, hdr, num);
    ((pjmedia_rtp_hdr *)dst)->x = 1;
    ptr += num;
    
    /* Copy RTP Extension header */
    num = sizeof(pjmedia_rtp_ext_hdr);
    memcpy(ptr, ext_hdr, num);
    ptr += num;
    
    /* Copy FEC header as Extension header data */
    //num = sizeof(fec_ext_hdr);
    num = pj_ntohs(ext_hdr->length) * sizeof(pj_uint32_t);
    memcpy(ptr, fec_hdr, num);
    ptr += num;
    
    /* Copy repair symbol */
    memcpy(ptr, payload, payload_len);
    ptr += payload_len;
    
    return (ptr - (pj_uint8_t *)dst);
}

static void* fec_dec_hdr(const void *pkt, fec_ext_hdr *fec_hdr)
{
    unsigned num;
    pj_uint8_t *ptr = (pj_uint8_t *)pkt;
    
    /* Assume RTP header at begin of packet */
    pjmedia_rtp_hdr *rtp_hdr = (pjmedia_rtp_hdr *)pkt;
    
    pj_assert(rtp_hdr->v == RTP_VERSION);
    
    /* Sanity check */
    if (rtp_hdr->v != RTP_VERSION || !rtp_hdr->x)
    {
        PJ_LOG(4, (THIS_FILE, "FEC header in RTP packet decode failed"));
        return 0;
    }
    
    /* FEC header is located right after RTP header + CSRCs + Extension header */
    num = sizeof(pjmedia_rtp_hdr) + rtp_hdr->cc * sizeof(pj_uint32_t) + sizeof(pjmedia_rtp_ext_hdr);
    ptr += num;
    
    fec_hdr->sn = pj_ntohl(*(pj_uint32_t *)ptr);
    ptr += sizeof(pj_uint32_t);
    fec_hdr->esi = pj_ntohs(*(pj_uint16_t *)ptr);
    ptr += sizeof(pj_uint16_t);
    fec_hdr->k = pj_ntohs(*(pj_uint16_t *)ptr);
    ptr += sizeof(pj_uint16_t);
    fec_hdr->n = pj_ntohs(*(pj_uint16_t *)ptr);
    ptr += sizeof(pj_uint16_t);
    fec_hdr->esl = pj_ntohs(*(pj_uint16_t *)ptr);
    ptr += sizeof(pj_uint16_t);
    fec_hdr->s = pj_ntohs(*(pj_uint16_t *)ptr);
    ptr += sizeof(pj_uint16_t);
    fec_hdr->rsrv = pj_ntohs(*(pj_uint16_t *)ptr);
    ptr += sizeof(pj_uint16_t);
    
    return ptr;
}

static pj_uint16_t fec_dec_pkt(void * const dst, void *pkt, pj_ssize_t size, pj_bool_t rtp)
{
    unsigned num;
    pj_uint8_t *ptr = (pj_uint8_t *)dst;
    pjmedia_rtp_hdr *rtp_hdr = (pjmedia_rtp_hdr *)pkt;
    
    pj_assert(rtp_hdr->v == RTP_VERSION);
    
    /* Size of RTP header plus CSRCs until Extension header */
    num = sizeof(pjmedia_rtp_hdr) + rtp_hdr->cc * sizeof(pj_uint32_t);
    
    /* Copy RTP header if source symbol */
    if (rtp)
    {
        rtp_hdr->x = 0;
        
        memcpy(ptr, pkt, num);
        ptr += num;
    }
    
    /* Skip Extension header and data */
    num += sizeof(pjmedia_rtp_ext_hdr);
    //    num += sizeof(fec_ext_hdr);
    num += pj_ntohs(((pjmedia_rtp_ext_hdr *)((pj_uint8_t *)pkt + sizeof(pjmedia_rtp_hdr)))->length) * sizeof(pj_uint32_t);
    
    /* Set payload offset in original packet and decrease copy left size */
    pkt = (pj_uint8_t *)pkt + num;
    size -= num;
    
    memcpy(ptr, pkt, size);
    ptr += size;
    
    return (ptr - (pj_uint8_t *)dst);
}

/*
 * Create the adapter.
 */
PJ_DEF(pj_status_t) pjmedia_fec_adapter_create(pjmedia_endpt *endpt, const char *name, pjmedia_transport *transport, pj_bool_t del_base, pjmedia_transport **p_tp)
{
    pj_pool_t *pool;
    struct tp_adapter *a;
    
    if (name == NULL)
        name = "tpad%p";
    
    /* Create the pool and initialize the adapter structure */
    pool = pjmedia_endpt_create_pool(endpt, name, 512, 512);
    a = PJ_POOL_ZALLOC_T(pool, struct tp_adapter);
    a->pool = pool;
    pj_ansi_strncpy(a->base.name, pool->obj_name, sizeof(a->base.name));
    a->base.type = (pjmedia_transport_type)(PJMEDIA_TRANSPORT_TYPE_USER + 1);
    a->base.op = &tp_adapter_op;
    
    /* Save the transport as the slave transport */
    a->slave_tp = transport;
    a->del_base = del_base;
    
    a->tx_code_rate = CODE_RATE_MAX;
    a->snd_k_max = K_MAX;
    a->old_client = 0;
    
    /* Choose codec before SDP negotiation
     * Fill default in the code specific part of the of_..._parameters_t structure
     * Currently choose codec on n value
     */
    if (N_MAX <= 255)
    {
        a->codec_id = OF_CODEC_REED_SOLOMON_GF_2_M_STABLE;
        
        a->enc_rs_params.m = 8;
        a->enc_params = (of_parameters_t *)&a->enc_rs_params;
        
        a->dec_rs_params.m = 8;
        a->dec_params = (of_parameters_t *)&a->dec_rs_params;
    }
    else
    {
        a->codec_id = OF_CODEC_LDPC_STAIRCASE_STABLE;
        
        a->enc_ldps_params.prng_seed = rand();
        a->enc_ldps_params.N1 = 7;
        a->enc_params = (of_parameters_t *)&a->enc_ldps_params;
        
        a->dec_ldps_params.prng_seed = rand();
        a->dec_ldps_params.N1 = 7;
        a->dec_params = (of_parameters_t *)&a->dec_ldps_params;
    }
    
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
    struct tp_adapter *a = (struct tp_adapter*)tp;
    
    /* Since we don't have our own connection here, we just pass
     * this function to the slave transport.
     */
    return pjmedia_transport_get_info(a->slave_tp, info);
}

#if 1 /* Old clients support (w/o SDP) */
/* Currently get packet real size, because openfec encode repair packet using size padding */
static pj_uint16_t fec_symbol_size_old(const void * const pkt, const pj_uint32_t symbol_size)
{
    /* Pointer to end of packet buffer */
    pj_uint8_t *ptr = (pj_uint8_t *)pkt + symbol_size - 1;
    pj_uint16_t size = symbol_size;
    
    while (!*ptr-- && size)
        --size;
    
    return size;
}
#endif

// DEBUG
//pj_time_val t1, t2;

/* This is our RTP callback, that is called by the slave transport when it
 * receives RTP packet.
 */
static void transport_rtp_cb(void *user_data, void *pkt, pj_ssize_t size)
{
    struct tp_adapter *a = (struct tp_adapter*)user_data;
    pj_uint16_t esi, k, n, len;
    fec_ext_hdr fec_hdr;
    pjmedia_rtp_hdr *rtp_hdr = (pjmedia_rtp_hdr *)pkt;
    
    if (a->codec_id == OF_CODEC_NIL)
    {
        a->stream_rtp_cb(a->stream_user_data, pkt, size);
        return;
    }
    
    a->rcv_k++;
    
    /* Decode FEC header before FEC decoding */
    fec_dec_hdr(pkt, &fec_hdr);
    
    //PJ_LOG(4, (THIS_FILE, "DEBUG recieved packet sn=%u k=%u n=%u len=%u esi=%u, decoder sn=%u k=%u",
    //    fec_hdr.sn,
    //    fec_hdr.k,
    //    fec_hdr.n,
    //    fec_hdr.len,
    //    fec_hdr.esi,
    //    a->rcv_sn,
    //    a->rcv_k));
    
    /* Check packet FEC sequence number */
    if (fec_hdr.sn < a->rcv_sn)
    {
        PJ_LOG(5, (THIS_FILE, "Too late sn=%u received in a packet while decoder sn=%u, drop packet", fec_hdr.sn, a->rcv_sn));
        return;
    }
    /* New FEC sequence packet */
    else if (fec_hdr.sn > a->rcv_sn)
    {
        if (a->dec_ses && !of_is_decoding_complete(a->dec_ses))
        {
            k = a->dec_params->nb_source_symbols;
            n = a->dec_params->nb_source_symbols + a->dec_params->nb_repair_symbols;
            
            PJ_LOG(5, (THIS_FILE, "Decoding incomplete for sn=%u k=%u n=%u len=%u rcv=%u, reset for new sn=%u",
                       a->rcv_sn,
                       k,
                       n,
                       a->dec_params->encoding_symbol_length,
                       a->rcv_k,
                       fec_hdr.sn));
            
            /* Request key frame if video stream */
            if (a->stream_type == PJMEDIA_TYPE_VIDEO)
                transport_send_rtcp_fir(user_data);
            
            if (a->stream_type == PJMEDIA_TYPE_AUDIO)
            {
                /* Call stream's callback for all source symbols in buffer */
                for (esi = 0; esi < k; esi++)
                {
                    if (a->dec_symbols_size[esi])
                        a->stream_rtp_cb(a->stream_user_data, a->dec_symbols_ptr[esi], a->dec_symbols_size[esi]);
                }
            }
        }
        
        // DEBUG
        //pj_gettickcount(&t1);
        
        a->rcv_sn = fec_hdr.sn;
        /* Create new decoder session for new FEC sequence */
        if (fec_dec_reset(a, fec_hdr.k, fec_hdr.n, fec_hdr.esl) != PJ_SUCCESS)
        {
            PJ_LOG(4, (THIS_FILE, "Decoder instance creation failed for sn=%u k=%u n=%u len=%u",
                       fec_hdr.sn,
                       fec_hdr.k,
                       fec_hdr.n,
                       fec_hdr.esl));
        }
    }
    /* Drop packet if sequence already decoded */
    else if (of_is_decoding_complete(a->dec_ses))
    {
        pj_assert(fec_hdr.sn == a->rcv_sn);
        
        if (fec_hdr.sn != a->rcv_sn)
            PJ_LOG(5, (THIS_FILE, "Decoding already complete for sn=%u, but decoder sn=%u, drop packet", fec_hdr.sn, a->rcv_sn));
        
        return;
    }
    
    /* Decode packet */
    len = fec_dec_pkt(a->dec_symbols_ptr[fec_hdr.esi], pkt, size, fec_hdr.esi < fec_hdr.k ? PJ_TRUE : PJ_FALSE);
    
    /* Fill length table using FEC encoded size-value for future decoding */
#if 1
    a->dec_symbols_size[fec_hdr.esi] = a->old_client ? len : fec_hdr.s;
#else
    a->dec_symbols_size[fec_hdr.esi] = fec_hdr.s;
#endif
    
    pj_assert(len > 0);
    
    /*
     * Submit each fresh symbol to the library, upon reception
     * using the standard of_decode_with_new_symbol() function.
     */
    if (of_decode_with_new_symbol(a->dec_ses, a->dec_symbols_ptr[fec_hdr.esi], fec_hdr.esi) == OF_STATUS_ERROR)
        PJ_LOG(4, (THIS_FILE, "Decode with new symbol failed esi=%u, len=%u", fec_hdr.esi, a->dec_params->encoding_symbol_length));
    
    /* Exit if decoding not complete */
    if (!of_is_decoding_complete(a->dec_ses))
        return;
    
    //PJ_LOG(4, (THIS_FILE, "DEBUG Decoded sequence sn=%u k=%u n=%u len=%u", fec_hdr.sn, fec_hdr.k, fec_hdr.n, fec_hdr.len));
    
    k = a->dec_params->nb_source_symbols;
    n = a->dec_params->nb_source_symbols + a->dec_params->nb_repair_symbols;
    
    /* Decode lengths */
#if 1
    if(!a->old_client)
        fec_dec_len(a);
#else
    fec_dec_len(a);
#endif
    
    /* Call stream's callback for all source symbols in buffer */
    for (esi = 0; esi < k; esi++)
    {
#if 1 /* Old clients support (w/o SDP) */
        /* Get repaired packet unpadded size */
        if (!a->dec_symbols_size[esi])
            a->dec_symbols_size[esi] = fec_symbol_size_old(a->dec_symbols_ptr[esi], a->dec_params->encoding_symbol_length);
#endif
        
        a->stream_rtp_cb(a->stream_user_data, a->dec_symbols_ptr[esi], a->dec_symbols_size[esi]);
    }
    
    // DEBUG
    //pj_gettickcount(&t2);
    //PJ_LOG(4, (THIS_FILE, "Decoding FEC buffering  delay=%dms k=%u n=%u", (t2.sec * 1000 + t2.msec) - (t1.sec * 1000 + t1.msec), k, n));
}

/* This is our RTCP callback, that is called by the slave transport when it
 * receives RTCP packet.
 */
static void transport_rtcp_cb(void *user_data, void *pkt, pj_ssize_t size)
{
    struct tp_adapter *a = (struct tp_adapter*)user_data;
    pjmedia_rtcp_common *common = (pjmedia_rtcp_common*)pkt;
    const pjmedia_rtcp_rr *rr = NULL;
    const pjmedia_rtcp_sr *sr = NULL;
    
    if (a->codec_id == OF_CODEC_NIL)
    {
        a->stream_rtcp_cb(a->stream_user_data, pkt, size);
        return;
    }
    
    /* RTCP key frame request */
    if (common->pt == RTCP_FIR && a->stream_type == PJMEDIA_TYPE_VIDEO /* not necessary, FIR not send for audio */)
    {
        pjmedia_vid_stream_send_keyframe(a->stream_ref);
        return;
    }
    
    /* Parse RTCP from rtcp.c */
    if (common->pt == RTCP_SR)
    {
        sr = (pjmedia_rtcp_sr*)(((char*)pkt) + sizeof(pjmedia_rtcp_common));
        if (common->count > 0 && size >= (sizeof(pjmedia_rtcp_sr_pkt)))
            rr = (pjmedia_rtcp_rr*)(((char*)pkt) + (sizeof(pjmedia_rtcp_common) + sizeof(pjmedia_rtcp_sr)));
    }
    else if (common->pt == RTCP_RR && common->count > 0)
    {
        rr = (pjmedia_rtcp_rr*)(((char*)pkt) + sizeof(pjmedia_rtcp_common));
    }
    
    /* Nothing to do if there's no RR packet */
    if (rr)
    {
        /* Get packet fraction loss */
        /* Percents with reduancy */
        //rr_loss = (rr->fract_lost * 100) >> 8;
        /* Fraction without reduancy */
        a->tx_loss = a->tx_code_rate + rr->fract_lost / 256.0 - 1;
        // TODO update code_rate
        //if (a->tx_loss < .1)
        //{
        //    a->tx_code_rate = .9; // 10%
        //    pj_assert(11, shift_ceil(10 / a->tx_code_rate));
        //}
        //else if (a->tx_loss > .1 && a->tx_loss < .33)
        //{
        //    a->tx_code_rate = .75; // 33%
        //    pj_assert(13, shift_ceil(10 / a->tx_code_rate));
        //}
        //else if (a->tx_loss > .33 && a->tx_loss < .5)
        //{
        //    a->tx_code_rate = .667; // 50%
        //    pj_assert(15, shift_ceil(10 / a->tx_code_rate));
        //}
        //else if (a->tx_loss > .5)
        //{
        //    a->tx_code_rate = .5; // 100%
        //    pj_assert(20, shift_ceil(10 / a->tx_code_rate));
        //}
        
        PJ_LOG(5, (THIS_FILE, "Current TX tx_loss=%3.3f -> code_rate=%1.3f", a->tx_loss, a->tx_code_rate));
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
    struct tp_adapter *a = (struct tp_adapter*)tp;
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
    struct tp_adapter *a = (struct tp_adapter*)tp;
    pj_status_t status;
    
    /* In this example, we will save the stream information and callbacks
     * to our structure, and we will register different RTP/RTCP callbacks
     * instead.
     */
    pj_assert(a->stream_user_data == NULL);
    a->stream_user_data = att_param->user_data;
    a->stream_rtp_cb = att_param->rtp_cb;
    a->stream_rtcp_cb = att_param->rtcp_cb;
    a->stream_ref = att_param->stream;
    a->stream_type = att_param->media_type;
    
    /* Get pointer RTP session information of the media stream */
    pjmedia_stream_rtp_sess_info session_info;
    
    switch (att_param->media_type)
    {
        case PJMEDIA_TYPE_VIDEO:
        {
#if 1 /* Old clients support (w/o SDP) */
            if (a->codec_id == OF_CODEC_NIL)
            {
                /*
                 * Old client use OF_CODEC_REED_SOLOMON_GF_2_M_STABLE and k_max 10
                 * Header size is less on 32bit word
                 */
                a->old_client = 1;
                a->codec_id = OF_CODEC_REED_SOLOMON_GF_2_M_STABLE;
                a->snd_k_max = 10;
                a->ext_hdr.length = pj_htons(sizeof(fec_ext_hdr) / sizeof(pj_uint32_t) - 1);
            }
            else
                a->snd_k_max = 20;
#else
            a->snd_k_max = 20;
#endif
            pjmedia_vid_stream_get_rtp_session_info(a->stream_ref, &session_info);
            break;
        }
        case PJMEDIA_TYPE_AUDIO:
        {
            a->snd_k_max = 10;
            pjmedia_stream_get_rtp_session_info(a->stream_ref, &session_info);
            break;
        }
        default:
            return PJ_EINVALIDOP;
    }
    
    pj_assert(a->snd_k_max <= K_MAX);
    
    a->rtp_tx_ses = session_info.tx_rtp;
    a->rtcp_ses = session_info.rtcp;
    
    att_param->rtp_cb = &transport_rtp_cb;
    att_param->rtcp_cb = &transport_rtcp_cb;
    att_param->user_data = a;
    
    status = pjmedia_transport_attach2(a->slave_tp, att_param);
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
    struct tp_adapter *a = (struct tp_adapter*)tp;
    
    PJ_UNUSED_ARG(strm);
    
    if (a->stream_user_data != NULL)
    {
        pjmedia_transport_detach(a->slave_tp, a);
        a->stream_user_data = NULL;
        a->stream_rtp_cb = NULL;
        a->stream_rtcp_cb = NULL;
        a->stream_ref = NULL;
    }
}


/*
 * send_rtp() is called to send RTP packet. The "pkt" and "size" argument
 * contain both the RTP header and the payload.
 */

// DEBUG
//pj_time_val snd_t1, snd_t2;

static pj_status_t transport_send_rtp(pjmedia_transport *tp, const void *pkt, pj_size_t size)
{
    struct tp_adapter *a = (struct tp_adapter *)tp;
    pj_uint16_t esi, len, n, k;
    fec_ext_hdr fec_hdr;
    
    if (a->codec_id == OF_CODEC_NIL)
        return pjmedia_transport_send_rtp(a->slave_tp, pkt, size);
    
    // DEBUG
    //if (!adapter->snd_k)
    //    pj_gettickcount(&snd_t1);
    
    /* Encode the RTP packet with FEC Framework */
    pj_status_t status = fec_enc_pkt(a, pkt, size);
    
    
    if (status != PJ_SUCCESS)
    {
        PJ_LOG(4, (THIS_FILE, "Encode for send rtp failed with packet size=%u", size));
        return status;
    }
    
    /* Send the packet using the UDP transport if symbols block encoding complete */
    if (a->snd_ready == PJ_FALSE)
        return status;
    
    k = a->enc_params->nb_source_symbols;
    n = a->enc_params->nb_repair_symbols + a->enc_params->nb_source_symbols;
    
    /* Setup FEC header fields */
    fec_hdr.sn = pj_htonl(a->snd_sn);
    fec_hdr.k = pj_htons(k);
    fec_hdr.n = pj_htons(n);
    fec_hdr.esl = pj_htons(a->enc_params->encoding_symbol_length);
    
    /* Encode lengths */
#if 1
    if (!a->old_client)
        fec_enc_len(a);
#else
    fec_enc_len(a);
#endif
    
    //PJ_LOG(4, (THIS_FILE, "DEBUG Encoded sequence sn=%u k=%u n=%u len=%u",
    //    a->snd_sn,
    //    k,
    //    n,
    //    a->enc_params->encoding_symbol_length));
    
    for (esi = 0; esi < k; esi++)
    {
        /* Setup FEC header encoding symbol ID */
        fec_hdr.esi = pj_htons(esi);
        fec_hdr.s = pj_htons(a->enc_symbols_size[esi]);
        len = fec_enc_src((void *)a->enc_symbol_buf, a->enc_symbols_ptr[esi], a->enc_symbols_size[esi], &fec_hdr, &a->ext_hdr);
        
        if (len)
            status = pjmedia_transport_send_rtp(a->slave_tp, (void *)a->enc_symbol_buf, len);
        
        if (status != PJ_SUCCESS || !len)
            PJ_LOG(4, (THIS_FILE, "Send RTP packet failed sn=%u k=%u n=%u esi=%u len=%u pkt_len=%u", a->snd_sn, k, n, esi, a->enc_params->encoding_symbol_length, len));
        //else
        //    PJ_LOG(4, (THIS_FILE, "DEBUG Sended RTP packet sn=%u k=%u n=%u esi=%u len=%u pkt_len=%u", a->snd_sn, k, n, esi, a->enc_params->encoding_symbol_length, len));
    }
    
    for (; esi < n; esi++)
    {
        /* Setup FEC header encoding symbol ID */
        fec_hdr.esi = pj_htons(esi);
        fec_hdr.s = pj_htons(a->enc_symbols_size[esi]);
        //len = fec_enc_rpr((void *)a->enc_symbol_buf, a->rtp_tx_ses, 0, a->enc_symbols_ptr[esi], a->enc_symbols_size[esi], &fec_hdr, &a->ext_hdr);
        len = fec_enc_rpr((void *)a->enc_symbol_buf, a->rtp_tx_ses, 0, a->enc_symbols_ptr[esi], a->snd_len, &fec_hdr, &a->ext_hdr);
        
        if (len)
            status = pjmedia_transport_send_rtp(a->slave_tp, (void *)a->enc_symbol_buf, len);
        
        if (status != PJ_SUCCESS || !len)
            PJ_LOG(4, (THIS_FILE, "Send RTP packet failed sn=%u k=%u n=%u esi=%u len=%u pkt_len=%u", a->snd_sn, k, n, esi, a->enc_params->encoding_symbol_length, len));
        //else
        //    PJ_LOG(4, (THIS_FILE, "DEBUG Sended RTP packet sn=%u k=%u n=%u esi=%u len=%u pkt_len=%u", a->snd_sn, k, n, esi, a->enc_params->encoding_symbol_length, len));
    }
    
    // DEBUG
    //pj_gettickcount(&snd_t2);
    //PJ_LOG(4, (THIS_FILE, "Encoding FEC buffering  delay=%dms k=%u n=%u", (snd_t2.sec * 1000 + snd_t2.msec) - (snd_t1.sec * 1000 + snd_t1.msec), k, n));
    
    /* Reset runtime encoding params */
    fec_enc_reset(a, n, a->enc_params->encoding_symbol_length);
    
    return status;
}

/* Request to send a RTCP Full Intra Request */
static pj_status_t transport_send_rtcp_fir(pjmedia_transport *tp)
{
    struct tp_adapter *a = (struct tp_adapter*)tp;
    pj_uint8_t buf[256];
    pjmedia_rtcp_common *hdr = (pjmedia_rtcp_common*)buf;
    pj_uint8_t *p;
    pj_size_t len;
    pj_uint32_t ssrc;
    
    /* Not implemented for 2.4 */
    if (!a->rtcp_ses)
        return PJ_EINVALIDOP;
    
    /* Build RTCP packet */
    len = sizeof(*hdr);
    pj_memcpy(hdr, &a->rtcp_ses->rtcp_sr_pkt.common, sizeof(*hdr));
    hdr->pt = RTCP_FIR;
    p = (pj_uint8_t*)hdr + sizeof(*hdr);
    
    /* Write RTCP Feedback Control Information
     * https://tools.ietf.org/html/rfc5104#section-4.3.1
     */
    
    /* The SSRC value of the media sender */
    ssrc = pj_htonl(a->rtcp_ses->peer_ssrc);
    pj_memcpy(p, &ssrc, sizeof(ssrc));
    len += sizeof(ssrc);
    p += sizeof(ssrc);
    
    /* FIR command sequence number */
    *p++ = ++a->rtcp_fir_sn;
    len++;
    
    /* Pad to 32bit */
    while ((p - (pj_uint8_t*)buf) % 4)
    {
        *p++ = 0;
        len++;
    }
    
    hdr->length = len;
    
    pj_assert((int)len == p - (pj_uint8_t*)buf);
    
    return transport_send_rtcp(tp, (void *)buf, len);
}

/*
 * send_rtcp() is called to send RTCP packet. The "pkt" and "size" argument
 * contain the RTCP packet.
 */
static pj_status_t transport_send_rtcp(pjmedia_transport *tp, const void *pkt, pj_size_t size)
{
    struct tp_adapter *a = (struct tp_adapter*)tp;
    
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
    struct tp_adapter *a = (struct tp_adapter*)tp;
    
    return pjmedia_transport_send_rtcp2(a->slave_tp, addr, addr_len, pkt, size);
}

/*
 * The media_create() is called when the transport is about to be used for
 * a new call.
 */
static pj_status_t transport_media_create(pjmedia_transport *tp, pj_pool_t *sdp_pool, unsigned options, const pjmedia_sdp_session *rem_sdp, unsigned media_index)
{
    struct tp_adapter *a = (struct tp_adapter*)tp;
    
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

/* Create FEC declaration */
static pjmedia_sdp_attr *fec_sdp_decl_create(pj_pool_t *pool, unsigned ref, unsigned enc_id)
{
    pj_str_t value;
    pjmedia_sdp_attr *attr = PJ_POOL_ALLOC_T(pool, pjmedia_sdp_attr);
    char buf[128];
    
    value.ptr = buf;
    
    /* fec-ref */
    value.slen = 0;
    value.slen += pj_utoa(ref, buf);
    
    /* fec-enc-id */
    pj_strcat2(&value, " encoding-id=");
    value.slen += pj_utoa(enc_id, buf + value.slen);
    
    pj_strdup2(pool, &attr->name, "FEC-declaration");
    pj_strdup(pool, &attr->value, &value);
    
    return attr;
}

/* Create FEC OTI extension attribute for max params (dont use base64) */
static pjmedia_sdp_attr *fec_sdp_oti_create(pj_pool_t *pool, unsigned ref, unsigned block_len, unsigned symbol_len)
{
    pj_str_t value;
    pjmedia_sdp_attr *attr = PJ_POOL_ALLOC_T(pool, pjmedia_sdp_attr);
    char buf[128];
    
    value.ptr = buf;
    
    /* fec-ref */
    value.slen = 0;
    value.slen += pj_utoa(ref, buf);
    
    /* Max block length */
    pj_strcat2(&value, " max-block-len=");
    value.slen += pj_utoa(block_len, buf + value.slen);
    
    /* Max symbol length */
    pj_strcat2(&value, " max-symbol-len=");
    value.slen += pj_utoa(symbol_len, buf + value.slen);
    
    pj_strdup2(pool, &attr->name, "FEC-OTI-extension");
    pj_strdup(pool, &attr->value, &value);
    
    return attr;
}

static of_codec_id_t fec_sdp_check(unsigned attr_count, pjmedia_sdp_attr * const *attr_array, unsigned media_index)
{
    pjmedia_sdp_attr *attr;
    unsigned ref, enc_id, block_len, symbol_len;
    
    /* Check FEC declaration */
    attr = pjmedia_sdp_attr_find2(attr_count, attr_array, "FEC-declaration", NULL);
    
    if (attr && sscanf(attr->value.ptr, "%u encoding-id=%u", &ref, &enc_id) == 2
        && enc_id < OF_CODEC_LDPC_FROM_FILE_ADVANCED)
    {
        pj_assert(media_index == ref);
        
        /* Check FEC OTI params */
        attr = pjmedia_sdp_attr_find2(attr_count, attr_array, "FEC-OTI-extension", NULL);
        
        if (attr && sscanf(attr->value.ptr, "%u max-block-len=%u max-symbol-len=%u", &ref, &block_len, &symbol_len) == 3
            && block_len <= N_MAX && symbol_len <= SYMBOL_SIZE_MAX)
        {
            pj_assert(media_index == ref);
            
            return (of_codec_id_t)enc_id;
        }
    }
    
    return OF_CODEC_NIL;
}

/*
 * The encode_sdp() is called when we're about to send SDP to remote party,
 * either as SDP offer or as SDP answer.
 */
static pj_status_t transport_encode_sdp(pjmedia_transport *tp, pj_pool_t *sdp_pool, pjmedia_sdp_session *local_sdp, const pjmedia_sdp_session *rem_sdp, unsigned media_index)
{
    struct tp_adapter *a = (struct tp_adapter*)tp;
    pjmedia_sdp_attr *fec_attr;
    pj_status_t status = PJ_EINVAL;
    unsigned i;
    
    /* If "rem_sdp" is not NULL, it means we're encoding SDP answer.
     * We can check remote side FEC support level before we send SDP.
     */
    if (rem_sdp)
    {
        /* Check FEC support from remote SDP */
        a->codec_id = fec_sdp_check(rem_sdp->media[media_index]->attr_count, rem_sdp->media[media_index]->attr, media_index);
        
        /* Copy all FEC attributes from remote SDP excluding declaration */
        if (a->codec_id != OF_CODEC_NIL)
        {
            /* Add FEC declaration */
            status = pjmedia_sdp_attr_add(&local_sdp->media[media_index]->attr_count, local_sdp->media[media_index]->attr, fec_sdp_decl_create(sdp_pool, media_index, a->codec_id));
            
            for (i = 1; fec_sdp_attrs[i]; i++)
            {
                fec_attr = pjmedia_sdp_attr_find2(rem_sdp->media[media_index]->attr_count, rem_sdp->media[media_index]->attr, fec_sdp_attrs[i], NULL);
                
                if (fec_attr)
                    status = pjmedia_sdp_attr_add(&local_sdp->media[media_index]->attr_count, local_sdp->media[media_index]->attr, pjmedia_sdp_attr_clone(sdp_pool, fec_attr));
            }
        }
    }
    /* Set our FEC params in local SDP if we are sending offer */
    else
    {
        
        /* Format target attribute string as "a=FEC-declaration:0 encoding-id=1"
         * according to ETSI TS 126 346 V12.3.0 (2014-10)
         * where in 'FEC-declaration' instead of "FEC:0" value we use stream media index value
         * and 'encoding-id' is openfec.org codec id from 'of_codec_id_t' enum
         */
        
        /* Add FEC declaration */
        status = pjmedia_sdp_attr_add(&local_sdp->media[media_index]->attr_count, local_sdp->media[media_index]->attr, fec_sdp_decl_create(sdp_pool, media_index, a->codec_id));
        
        /* Add FEC OTI max values information */
        status = pjmedia_sdp_attr_add(&local_sdp->media[media_index]->attr_count, local_sdp->media[media_index]->attr, fec_sdp_oti_create(sdp_pool, media_index, N_MAX, SYMBOL_SIZE_MAX));
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
    struct tp_adapter *a = (struct tp_adapter*)tp;
    pjmedia_sdp_attr *fec_attr = NULL;
    pj_status_t status = PJ_EINVAL;
    pj_uint16_t esi;
    
    /* Check FEC support by remote side */
    if (rem_sdp)
        a->codec_id = fec_sdp_check(rem_sdp->media[media_index]->attr_count, rem_sdp->media[media_index]->attr, media_index);
    
    //    if (a->codec_id != OF_CODEC_NIL)
    {
        a->dec_ses = NULL;
        a->tx_loss = .0;
        //a->tx_code_rate = CODE_RATE_MAX;
        
        /* Init Extension headers with default values */
        a->ext_hdr.profile_data = pj_htons(RTP_EXT_PT);
        a->ext_hdr.length = pj_htons(sizeof(fec_ext_hdr) / sizeof(pj_uint32_t));
        
        a->rcv_sn = 0;
        
        a->rtcp_fir_sn = 0;
        
        /* Init all pointers to symbol's buffers */
        for (esi = 0; esi < N_MAX; esi++)
        {
            a->enc_symbols_ptr[esi] = (void *)&a->enc_symbols_buf[esi * SYMBOL_SIZE_MAX];
            a->dec_symbols_ptr[esi] = (void *)&a->dec_symbols_buf[esi * SYMBOL_SIZE_MAX];
        }
        
        PJ_LOG(5, (THIS_FILE, "FEC adapter init for media_index=%u succeed with max values: k=%u n=%u len=%u",
                   media_index,
                   K_MAX,
                   N_MAX,
                   SYMBOL_SIZE_MAX));
    }
    
    /* And pass the call to the slave transport */
    return pjmedia_transport_media_start(a->slave_tp, pool, local_sdp, rem_sdp, media_index);
}

/*
 * The media_stop() is called when media has been stopped.
 */
static pj_status_t transport_media_stop(pjmedia_transport *tp)
{
    struct tp_adapter *a = (struct tp_adapter*)tp;
    
    /* Destroy FEC codecs */
    if (a->dec_ses)
        of_release_codec_instance(a->dec_ses);
    
    /* And pass the call to the slave transport */
    return pjmedia_transport_media_stop(a->slave_tp);
}

/*
 * simulate_lost() is called to simulate packet lost
 */
static pj_status_t transport_simulate_lost(pjmedia_transport *tp, pjmedia_dir dir, unsigned pct_lost)
{
    struct tp_adapter *a = (struct tp_adapter*)tp;
    
    return pjmedia_transport_simulate_lost(a->slave_tp, dir, pct_lost);
}

/*
 * destroy() is called when the transport is no longer needed.
 */
static pj_status_t transport_destroy(pjmedia_transport *tp)
{
    struct tp_adapter *a = (struct tp_adapter*)tp;
    
    /* Close the slave transport */
    if (a->del_base)
        pjmedia_transport_close(a->slave_tp);
    
    /* Self destruct.. */
    pj_pool_release(a->pool);
    
    return PJ_SUCCESS;
}


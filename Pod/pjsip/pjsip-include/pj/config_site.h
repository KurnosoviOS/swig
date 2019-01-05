/*
 * PJLIB settings.
 */

#define PJ_IPHONE_OS_HAS_MULTITASKING_SUPPORT	0

/* Both armv6 and armv7 has FP hardware support.
 * See https://trac.pjsip.org/repos/ticket/1589 for more info
 */
#define PJ_HAS_FLOATING_POINT		1

#define PJ_HAS_IPV6 1

/*
 * PJMEDIA settings
 */

/* We have our own native CoreAudio backend */
#define PJMEDIA_AUDIO_DEV_HAS_PORTAUDIO	0
#define PJMEDIA_AUDIO_DEV_HAS_WMME		0
#define PJMEDIA_AUDIO_DEV_HAS_COREAUDIO	1

/* The CoreAudio backend has built-in echo canceller! */
#define PJMEDIA_HAS_SPEEX_AEC    0

/* Disable some codecs */
#define PJMEDIA_HAS_L16_CODEC		0
#define PJMEDIA_HAS_G722_CODEC		0

/* Use the built-in CoreAudio's iLBC codec (yay!) */
#define PJMEDIA_HAS_ILBC_CODEC		1
#define PJMEDIA_ILBC_CODEC_USE_COREAUDIO	1

/* Fine tune Speex's default settings for best performance/quality */
#define PJMEDIA_CODEC_SPEEX_DEFAULT_QUALITY	5

/* Video */
#define PJMEDIA_HAS_VIDEO			1
#define PJMEDIA_HAS_OPENH264_CODEC		1

/*
 * PJSIP settings.
 */

/* Increase allowable packet size, just in case */
//#define PJSIP_MAX_PKT_LEN			2000

/*
 * PJSUA settings.
 */

/* Default codec quality, previously was set to 5, however it is now
 * set to 4 to make sure pjsua instantiates resampler with small filter.
 */
#define PJSUA_DEFAULT_CODEC_QUALITY		4

/* Set maximum number of dialog/transaction/calls to minimum */
#define PJSIP_MAX_TSX_COUNT 		31
#define PJSIP_MAX_DIALOG_COUNT 		31
#define PJSUA_MAX_CALLS			32

/* Other pjsua settings */
#define PJSUA_MAX_ACC			4
#define PJSUA_MAX_PLAYERS			4
#define PJSUA_MAX_RECORDERS			4
#define PJSUA_MAX_CONF_PORTS		(PJSUA_MAX_CALLS+2*PJSUA_MAX_PLAYERS)
#define PJSUA_MAX_BUDDIES			32

// Для поддержки FEC необходимо уменьшить размер PJMEDIA_MAX_VID_PAYLOAD_SIZE на размеры RTP Extension header (4 октета) и FEC header (12 октетов)
// Размер заголовка FEC опеределяется размером структуры fec_ext_hdr в transport_adapter_fec.c или иной реализацией FEC
// По умолчанию PJMEDIA_MAX_VID_PAYLOAD_SIZE определяется в config.h pjmedia
#define PJMEDIA_HAS_SRTP 1

#ifndef PJMEDIA_MAX_VID_PAYLOAD_SIZE
#  if PJMEDIA_HAS_SRTP
#     define PJMEDIA_MAX_VID_PAYLOAD_SIZE     (PJMEDIA_MAX_MTU - 20 - (128+16) - (4+12))
#  else
#     define PJMEDIA_MAX_VID_PAYLOAD_SIZE     (PJMEDIA_MAX_MTU - 20 - (4+12))
#  endif
#endif

//
//  SWUriFormatter.m
//  swig
//
//  Created by Pierre-Marc Airoldi on 2014-08-21.
//  Copyright (c) 2014 PeteAppDesigns. All rights reserved.
//

#import "SWUriFormatter.h"
#import "Swig.h"
#import "SWContact.h"
#import "SWAccount.h"
#import "SWAccountConfiguration.h"
#import "NSString+PJString.h"

@implementation SWUriFormatter

+(NSString *)sipUri:(NSString *)uri {
    
    NSString *sipUri = uri;
    
    pjsua_transport_info transport_info;
    pjsua_transport_get_info(0, &transport_info);

    NSString *urlSchema = @"sip";
    if (transport_info.type == PJSIP_TRANSPORT_TLS || transport_info.type == PJSIP_TRANSPORT_TLS6) {
        urlSchema = @"sips";
    }
    
    if (![sipUri hasPrefix:@"sip:"] && ![sipUri hasPrefix:@"sips:"] && ![sipUri hasPrefix:@"tel:"]) {
        sipUri = [NSString stringWithFormat:@"%@:%@", urlSchema, sipUri];
    }
    
    return sipUri;
}

+(NSString *)sipUri:(NSString *)uri fromAccount:(SWAccount *)account {
    
    NSString *sipUri = [SWUriFormatter sipUri:uri];
    
    if ([sipUri rangeOfString:@"@"].location == NSNotFound) {
        sipUri = [NSString stringWithFormat:@"%@@%@", sipUri, account.accountConfiguration.domain];
    }
    
    if (![sipUri hasSuffix:account.accountConfiguration.domain]) {
        
        sipUri = [sipUri stringByPaddingToLength:[sipUri rangeOfString:@"@"].location withString:@"" startingAtIndex:0];
        sipUri = [NSString stringWithFormat:@"%@@%@", sipUri, account.accountConfiguration.domain];
    }
    
    return sipUri;
}

+(NSString *)sipUriWithPhone:(NSString *)uri fromAccount:(SWAccount *)account toGSM: (BOOL) toGSM {
    
    pj_pool_t *tempPool = pjsua_pool_create("swig-pjsua-temp", 512, 512);

    pjsua_acc_info acc_info = [account getInfo];
    
    /*
     @synchronized ([SWAccount getLocker]) {
     pjsua_acc_get_info(acc_id, &acc_info);
     }
     */
    
    pjsip_uri* local_uri = pjsip_parse_uri(tempPool, acc_info.acc_uri.ptr, acc_info.acc_uri.slen, NULL);
    pjsip_sip_uri *local_sip_uri = (pjsip_sip_uri *)pjsip_uri_get_uri(local_uri);

    
    local_sip_uri->user = [uri pjString];
    
    if (toGSM) {
        local_sip_uri->user_param = pj_str((char *)"phone");
    }
    
    char contact_buf[512];
    pj_str_t new_contact;
    new_contact.ptr = contact_buf;
    
    new_contact.slen = pjsip_uri_print(PJSIP_URI_IN_FROMTO_HDR, local_sip_uri, contact_buf, 512);

    pj_pool_release(tempPool);
    
    return [NSString stringWithFormat:@"<%@:%d>", [NSString stringWithPJString:new_contact], local_sip_uri->port];
}



+(NSString *)sipUri:(NSString *)uri withDisplayName:(NSString *)displayName {
    
    NSString *sipUri = uri;
    
    pjsua_transport_info transport_info;
    pjsua_transport_get_info(0, &transport_info);

    NSString *urlSchema = @"sip";
    if (transport_info.type == PJSIP_TRANSPORT_TLS || transport_info.type == PJSIP_TRANSPORT_TLS6) {
        urlSchema = @"sips";
    }
    
    if (![sipUri hasPrefix:@"sip:"] && ![sipUri hasPrefix:@"sips:"] && ![sipUri hasPrefix:@"tel:"]) {
        sipUri = [NSString stringWithFormat:@"%@:%@", urlSchema, sipUri];
    }
    
    if (displayName) {
        sipUri = [NSString stringWithFormat:@"\"%@\" <%@>", displayName, sipUri];
    }
    
    return sipUri;
}

+(SWContact *)contactFromURI:(NSString *)uri {
    
    //TODO rewrite this. it is overly complex
    
    if ([uri length] == 0) {
        return [[SWContact alloc] initWithName:nil host:nil user:nil];
    }
    
    pj_pool_t *tempPool = pjsua_pool_create("swig-pjsua-temp", 512, 512);
    
    pj_str_t localURI = [uri pjString];
    
    pjsip_uri* local_uri = pjsip_parse_uri(tempPool, localURI.ptr, localURI.slen, PJSIP_PARSE_URI_AS_NAMEADDR);
    pjsip_sip_uri *local_sip_uri = (pjsip_sip_uri *)pjsip_uri_get_uri(local_uri);
    
    NSString *username = [NSString stringWithPJString:local_sip_uri->user];
    NSString *host = [NSString stringWithPJString:local_sip_uri->host];
    NSString *user = [NSString stringWithPJString:local_sip_uri->user_param];
    
    pj_pool_release(tempPool);
    return [[SWContact alloc] initWithName:username host:host user:user];
}

+ (NSString *) usernameFromURI: (NSString *) URI {
    
    pj_pool_t *tempPool = pjsua_pool_create("swig-pjsua-temp", 512, 512);
    
    pj_str_t localURI = [URI pjString];
    
    pjsip_uri* local_uri = pjsip_parse_uri(tempPool, localURI.ptr, localURI.slen, PJSIP_PARSE_URI_AS_NAMEADDR);
    pjsip_sip_uri *local_sip_uri = (pjsip_sip_uri *)pjsip_uri_get_uri(local_uri);
    
    NSString *username = [NSString stringWithPJString:local_sip_uri->user];
    
    pj_pool_release(tempPool);
    return username;
}

@end

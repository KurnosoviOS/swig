//
//  EWFileLogger.m
//  Swig
//
//  Created by EastWind on 13.02.2018.
//

#import "EWFileLogger.h"

#import "SWAccount.h"
#import "SWEndpoint.h"
#import "SWEndpointConfiguration.h"

@implementation EWFileLogger

static BOOL _EWNoLogging = YES;
static NSDateFormatter *ewLogDateFormat;

static unsigned long long _logFileSize = 1024*1024*100;

void _Log(NSString *prefix, const char *file, int lineNumber, const char *funcName, NSString *format,...) {
    va_list ap;
    va_start (ap, format);
    
    format = [format stringByAppendingString:@"\n"];
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end (ap);
    
    if ([SWEndpoint sharedEndpoint].endpointConfiguration.logBlock != nil) {
        [SWEndpoint sharedEndpoint].endpointConfiguration.logBlock(prefix, file, lineNumber, funcName, msg);
    }
}

void _OldLog(NSString *prefix, const char *file, int lineNumber, const char *funcName, NSString *msg) {
    if (EWFileLogger.noLogging) {
        return;
    }
    
    fprintf(stderr,"%s%50s:%3d - %s",[prefix UTF8String], funcName, lineNumber, [msg UTF8String]);
    
    if(EWFileLogger.loggingToFile) {
        [EWFileLogger append: msg];
    }
}

+(void) append: (NSString *) msg{
    
    BOOL filenameGenerated = NO;
    
    if (!EWFileLogger.logFileName) {
        EWFileLogger.logFileName = [EWFileLogger generateFilename];
        filenameGenerated = YES;
    }
    
    // get path to Application Support/somefile.txt
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *path = [documentsDirectory stringByAppendingPathComponent:EWFileLogger.logFileName];
    // create if needed
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]){
        [self createFileAt:path withReason:filenameGenerated ? @"newFileName" : @"fileNotExists"];
    }
    else {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        unsigned long long fileSize = [attributes fileSize];
        
        //Если новый файл разросся больше предельного размера, удаляем старый файл, а новый делаем старым
        if (fileSize > EWFileLogger.logFileSize) {
            [self deleteFileAt:[documentsDirectory stringByAppendingPathComponent:EWFileLogger.logFileNameOld]];
            
            EWFileLogger.logFileNameOld = EWFileLogger.logFileName;
            EWFileLogger.logFileName = [EWFileLogger generateFilename];
            path = [documentsDirectory stringByAppendingPathComponent:EWFileLogger.logFileName];
            [self createFileAt:path withReason:@"logfileSizeTooMuch"];
        }
    }
    
    // append
    [self append_lowlevelMsg:msg toFile:path];
}
    
+ (void) append_lowlevelMsg: (NSString *) msg toFile: (NSString *) path {
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle truncateFileAtOffset:[handle seekToEndOfFile]];
    [handle writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

+ (void) createFileAt: (NSString *) path withReason: (NSString *) reason {
    fprintf(stderr,"Creating file at %s",[path UTF8String]);
    [[NSData data] writeToFile:path atomically:YES];
    [self append_lowlevelMsg:[NSString stringWithFormat:@"<--logfile--> logfile created with Reason:%@", reason] toFile:path];
}

+ (void) deleteFileAt: (NSString *) path {
    fprintf(stderr,"Deleting file at %s",[path UTF8String]);
    NSError *error;
    if ([[NSFileManager defaultManager] isDeletableFileAtPath:path]) {
        BOOL success = [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        if (!success) {
            //NSLog(@"Error removing file at path: %@", error.localizedDescription);
        }
    }
}

+ (NSString *) generateFilename {
    return [NSString stringWithFormat:@"logfile%@.txt", [[NSUUID UUID] UUIDString]];
}

#pragma mark getters/setters

+(NSString *)logFileNameOld {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"EWLogFileNameOld"];
}

+(NSString *)logFileName {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"EWLogFileName"];
}

+(unsigned long long)logFileSize {
    NSNumber *size = [[NSUserDefaults standardUserDefaults] objectForKey:@"EWLogFileSize"];
    
    return [size unsignedLongLongValue];
}

+(BOOL) loggingToFile {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"EWLoggingToFile"];
}

+(BOOL) noLogging {
    return _EWNoLogging;
}

+ (void)setLogFileName:(NSString *)logFileName {
    [[NSUserDefaults standardUserDefaults] setObject:logFileName forKey:@"EWLogFileName"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+(void)setLogFileNameOld:(NSString *)logFileNameOld {
    [[NSUserDefaults standardUserDefaults] setObject:logFileNameOld forKey:@"EWLogFileNameOld"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+(void)setLogFileSize:(unsigned long long)logFileSize {
    NSNumber *size = [NSNumber numberWithUnsignedLongLong:logFileSize];
    [[NSUserDefaults standardUserDefaults] setObject:size forKey:@"EWLogFileSize"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+(void)setLoggingToFile:(BOOL)loggingToFile {
    [[NSUserDefaults standardUserDefaults] setBool:loggingToFile forKey:@"EWLoggingToFile"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+(void)setNoLogging:(BOOL)noLogging {
    _EWNoLogging = noLogging;
}

@end

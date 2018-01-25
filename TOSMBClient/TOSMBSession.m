//
// TOSMBSession.m
// Copyright 2015-2017 Timothy Oliver
//
// This file is dual-licensed under both the MIT License, and the LGPL v2.1 License.
//
// -------------------------------------------------------------------------------
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
// -------------------------------------------------------------------------------

#import <arpa/inet.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import "TOSMBSessionPrivate.h"
#import "TOSMBSessionFile.h"
#import "TOSMBSessionFilePrivate.h"
#import "TONetBIOSNameService.h"
#import "TOSMBSessionDownloadTaskPrivate.h"
#import "TOSMBSessionUploadTaskPrivate.h"

#import "smb_session.h"
#import "smb_share.h"
#import "smb_stat.h"

@interface TOSMBSession ()

/* The session pointer responsible for this object. */
@property (nonatomic, assign) smb_session *session;

/* 1 == Guest, 0 == Logged in, -1 == Logged out */
@property (nonatomic, assign, readwrite) NSInteger guest;

@property (nonatomic, strong, null_resettable) NSOperationQueue *dataQueue; /* Operation queue for asynchronous data requests. */
@property (nonatomic, strong, null_resettable) NSOperationQueue *taskQueue; /* Operation queue for task. */

@property (nonatomic, strong) NSArray <TOSMBSessionDownloadTask *> *downloadTasks;
@property (nonatomic, strong) NSArray <TOSMBSessionUploadTask *> *uploadTasks;

@property (nonatomic, strong) NSDate *lastRequestDate;

@property (nonatomic, assign, readwrite) BOOL connected;

@property (nonatomic, readwrite) dispatch_queue_t serialQueue;

/* Connection/Authentication handling */
- (BOOL)deviceIsOnWiFi;
- (NSError *)attemptConnection; //Attempt connection for ourselves
- (NSError *)attemptConnectionWithSessionPointer:(smb_session *)session; //Attempt connection on behalf of concurrent download sessions

/* File path parsing */
- (NSString *)shareNameFromPath:(NSString *)path;
- (NSString *)filePathExcludingSharePathFromPath:(NSString *)path;

@end

@implementation TOSMBSession

#pragma mark - Class Creation -
- (instancetype)init
{
    if (self = [super init]) {
        _maxTaskOperationCount = NSOperationQueueDefaultMaxConcurrentOperationCount;
        _session = smb_session_new();
        _serialQueue = dispatch_queue_create(nil, DISPATCH_QUEUE_SERIAL);
        if (_session == NULL) {
            return nil;
        }
    }
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"hostName:%@ ipAddress:%@ user:%@", _hostName, _ipAddress, _userName]]);
    return self;
}

- (instancetype)initWithHostName:(NSString *)name
{
    if (self = [self init]) {
        _hostName = name;
    }
    
    return self;
}

- (instancetype)initWithIPAddress:(NSString *)address
{
    if (self = [self init]) {
        _ipAddress = address;
    }
    
    return self;
}

- (instancetype)initWithHostName:(NSString *)name ipAddress:(NSString *)ipAddress
{
    if (self = [self init]) {
        _hostName = name;
        _ipAddress = ipAddress;
    }
    
    return self;
}

- (void)dealloc
{
    if (self.session) {
        smb_session_destroy(self.session);
    }
}

#pragma mark - Authorization -
- (void)setLoginCredentialsWithUserName:(NSString *)userName password:(NSString *)password
{
    self.userName = userName;
    self.password = password;
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"user:%@ pass:%@", _userName, _password.length?@"<redacted>": @"<no password provided>"]]);
}

#pragma mark - Connections/Authentication -
- (BOOL)deviceIsOnWiFi
{
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, "8.8.8.8");
    SCNetworkReachabilityFlags flags;
    BOOL success = SCNetworkReachabilityGetFlags(reachability, &flags);
    CFRelease(reachability);
    if (!success) {
        return NO;
    }
    BOOL isReachable = ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    BOOL needsConnection = ((flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0);
    BOOL isNetworkReachable = (isReachable && !needsConnection);
    
    if (!isNetworkReachable) {
        return NO;
    } else if ((flags & kSCNetworkReachabilityFlagsIsWWAN) != 0) {
        return NO;
    }
    
    return YES;
}

- (NSError *)attemptConnection
{
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 @"entered"]);
    __block NSError *error = nil;
    dispatch_sync(self.serialQueue, ^{
        error = [self attemptConnectionWithSessionPointer:self.session];
    });
        
    if (error) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     [NSString stringWithFormat:@"%@", error]]);
        return error;
    }
    
    self.guest = smb_session_is_guest(self.session);
    return nil;
}

- (NSError *)attemptConnectionWithSessionPointer:(smb_session *)session
{
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 @"entered"]);
    //There's no point in attempting a potentially costly TCP attempt if we're not even on a local network.
    if ([self deviceIsOnWiFi] == NO) {
        return errorForErrorCode(TOSMBSessionErrorNotOnWiFi);
    }
    
    // If we're connecting from a download task, and the sessions match, make sure to
    // refresh them periodically
    if (self.session == session) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"Found an existing session"]);
        if (self.lastRequestDate && [[NSDate date] timeIntervalSinceDate:self.lastRequestDate] > 60) {
            [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                         @"Existing session expired; create a new one"]);
            [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                         @"attempt to delete session"]);
            smb_session_destroy(self.session);
            [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                         @"attempt to create session"]);
            self.session = smb_session_new();
            session = self.session;
            
            self.connected = NO;
        }
        
        self.lastRequestDate = [NSDate date];
    }
    
    //Don't attempt another connection if we already made it through
    if (smb_session_is_guest(session) >= 0) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"already connected"]);
        
        self.connected = YES;
        return nil;
    }
    
    //Ensure at least one piece of connection information was supplied
    if (self.ipAddress.length == 0 && self.hostName.length == 0) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"no hostname and/or ipAddress provided"]);
        return errorForErrorCode(TOSMBSessionErrorCodeUnableToResolveAddress);
    }
    
    //If only one piece of information was supplied, use NetBIOS to resolve the other
    if (self.ipAddress.length == 0 || self.hostName.length == 0) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     [NSString stringWithFormat:@"using netbios to resolve either ipAddress: %@ or hostName: %@", self.ipAddress, self.hostName]]);
        TONetBIOSNameService *nameService = [[TONetBIOSNameService alloc] init];
        
        if ((self.ipAddress == nil || self.ipAddress.length <= 1) && self.hostName.length > 0) {
            self.ipAddress = [nameService resolveIPAddressWithName:self.hostName type:TONetBIOSNameServiceTypeFileServer];
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     [NSString stringWithFormat:@"ipAddress was nil; resolved address: %@", self.ipAddress]]);
        } else if(self.ipAddress.length > 1) {
            self.hostName = [nameService lookupNetworkNameForIPAddress:self.ipAddress];
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     [NSString stringWithFormat:@"hostName was nil; resolved hostname to: %@", self.hostName]]);
        }
    }
    
    //If there is STILL no IP address after the resolution, there's no chance of a successful connection
    if (self.ipAddress == nil) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"still no ipAddress provided; aborting"]);
        return errorForErrorCode(TOSMBSessionErrorCodeUnableToResolveAddress);
    }
    
    //Convert the IP Address and hostname values to their C equivalents
    if(!self.hostName.length) {
        NSLog(@"HOST NAME WAS NULL! -3 !");
    }
    
    struct in_addr addr;
    inet_aton([self.ipAddress cStringUsingEncoding:NSASCIIStringEncoding], &addr);
    const char *hostName = [self.hostName cStringUsingEncoding:NSUTF8StringEncoding];
    if(!hostName || *hostName != '\0') {
        NSString *host = [NSString stringWithCString:hostName encoding:NSUTF8StringEncoding];
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     [NSString stringWithFormat:@"Attempt connection with session with HostName:'%@' ipAddress : %@", host, self.ipAddress]]);
    }
    
    //Attempt a connection
    NSInteger result = smb_session_connect(session, hostName, addr.s_addr, SMB_TRANSPORT_TCP);
    if (result != 0) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"Could not connect session; aborting"]);
        return errorForErrorCode(TOSMBSessionErrorCodeUnableToConnect);
    }
    
    //If the username or password wasn't supplied, a non-NULL string must still be supplied
    //to avoid NULL input assertions.
    const char *userName = (self.userName ? [self.userName cStringUsingEncoding:NSUTF8StringEncoding] : " ");
    const char *password = (self.password ? [self.password cStringUsingEncoding:NSUTF8StringEncoding] : " ");
    
    //Attempt a login. Even if we're downgraded to guest, the login call will succeed
    smb_session_set_creds(session, hostName, userName, password);
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"attemping session logon with user: %@, password: %@", self.userName, @"<redacted>"]]);
    if (smb_session_login(session) != 0) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"authentication failed"]);
        return errorForErrorCode(TOSMBSessionErrorCodeAuthenticationFailed);
    }
    
    if (session == self.session) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"session up and running"]);
        self.connected = YES;
    }
    return nil;
}

#pragma mark - Data Requests -
- (NSArray *)requestContentsOfDirectoryAtFilePath:(NSString *)path error:(NSError **)error
{
    //Attempt a connection attempt (If it has not already been done)
    NSError *resultError = [self attemptConnection];
    if (error && resultError)
        *error = resultError;
    
    if (resultError)
        return nil;
    
    //-----------------------------------------------------------------------------
    
    //If the path is nil, or '/', we'll be specifically requesting the
    //parent network share names as opposed to the actual file lists
    if (path.length == 0 || [path isEqualToString:@"/"]) {
        smb_share_list list;
        size_t shareCount = 0;
        smb_share_get_list(self.session, &list, &shareCount);
        if (shareCount == 0)
            return nil;
        
        NSMutableArray *shareList = [NSMutableArray array];
        for (NSInteger i = 0; i < shareCount; i++) {
            const char *shareName = smb_share_list_at(list, i);
            
            //Skip system shares suffixed by '$'
            if (shareName[strlen(shareName)-1] == '$')
                continue;
            
            //Null check
            if(shareName != NULL && shareName[0] != '\0') {
                NSString *shareNameString = [NSString stringWithCString:shareName encoding:NSUTF8StringEncoding];
                TOSMBSessionFile *share = [[TOSMBSessionFile alloc] initWithShareName:shareNameString session:self];
                [shareList addObject:share];
            }
            else {
                NSLog(@"SHARENAME WAS NULL!");
            }
        }
        
        smb_share_list_destroy(list);
        
        return [NSArray arrayWithArray:shareList];
    }
    
    //-----------------------------------------------------------------------------
    
    //Replace any backslashes with forward slashes
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [self shareNameFromPath:path];
    
    //Connect to that share
    //If not, make a new connection
    const char *cStringName = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    smb_tid shareID = -1;
    if (smb_tree_connect(self.session, cStringName, &shareID) != 0) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed);
            *error = resultError;
        }
        
        return nil;
    }
    
    //work out the remainder of the file path and create the search query
    NSString *relativePath = [self filePathExcludingSharePathFromPath:path];
    //prepend double backslashes
    relativePath = [NSString stringWithFormat:@"\\%@",relativePath];
    //replace any additional forward slashes with backslashes
    relativePath = [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]; //replace forward slashes with backslashes
    //append double backslash if we don't have one
    if (![[relativePath substringFromIndex:relativePath.length-1] isEqualToString:@"\\"])
        relativePath = [relativePath stringByAppendingString:@"\\"];
    
    //Add the wildcard symbol for everything in this folder
    relativePath = [relativePath stringByAppendingString:@"*"]; //wildcard to search for all files
    
    //Query for a list of files in this directory
    smb_stat_list statList = smb_find(self.session, shareID, relativePath.UTF8String);
    size_t listCount = smb_stat_list_count(statList);
    if (listCount == 0)
        return nil;
    
    NSMutableArray *fileList = [NSMutableArray array];
    
    for (NSInteger i = 0; i < listCount; i++) {
        smb_stat item = smb_stat_list_at(statList, i);
        const char* name = smb_stat_name(item);
        if (name[0] == '.') { //skip hidden files
            continue;
        }
        
        TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:item session:self parentDirectoryFilePath:path];
        [fileList addObject:file];
    }
    smb_stat_list_destroy(statList);
    smb_tree_disconnect(self.session, shareID);
    
    if (fileList.count == 0)
        return nil;
    
    return [fileList sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
}

- (void)requestContentsOfDirectoryAtFilePath:(NSString *)path success:(void (^)(NSArray *))successHandler error:(void (^)(NSError *))errorHandler
{
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof(self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id operationBlock = ^{
        if (weakOperation.cancelled) { return; }
        
        NSError *error = nil;
        NSArray *files = [weakSelf requestContentsOfDirectoryAtFilePath:path error:&error];
        
        if (weakOperation.cancelled) { return; }
        
        if (error) {
            if (errorHandler) {
                [[NSOperationQueue mainQueue] addOperationWithBlock:^{ errorHandler(error); }];
            }
        }
        else {
            if (successHandler) {
                [[NSOperationQueue mainQueue] addOperationWithBlock:^{ successHandler(files); }];
            }
        }
    };
    [operation addExecutionBlock:operationBlock];
    [self.dataQueue addOperation:operation];
}

- (void)cancelAllRequests
{
    [self.dataQueue cancelAllOperations];
    [self.taskQueue cancelAllOperations];
}

#pragma mark - Download Tasks -
- (TOSMBSessionDownloadTask *)downloadTaskForFileAtPath:(NSString *)path destinationPath:(NSString *)destinationPath delegate:(id<TOSMBSessionDownloadTaskDelegate>)delegate
{
    TOSMBSessionDownloadTask *task = [[TOSMBSessionDownloadTask alloc] initWithSession:self filePath:path destinationPath:destinationPath delegate:delegate];
    self.downloadTasks = [self.downloadTasks ? : @[] arrayByAddingObjectsFromArray:@[task]];
    return task;
}

- (TOSMBSessionDownloadTask *)downloadTaskForFileAtPath:(NSString *)path
                                        destinationPath:(NSString *)destinationPath
                                        progressHandler:(void (^)(uint64_t totalBytesWritten, uint64_t totalBytesExpected))progressHandler
                                      completionHandler:(void (^)(NSString *filePath))completionHandler
                                            failHandler:(void (^)(NSError *error))failHandler
{
    TOSMBSessionDownloadTask *task = [[TOSMBSessionDownloadTask alloc] initWithSession:self filePath:path destinationPath:destinationPath progressHandler:progressHandler successHandler:completionHandler failHandler:failHandler];
    self.downloadTasks = [self.downloadTasks ? : @[] arrayByAddingObjectsFromArray:@[task]];
    return task;
}

#pragma mark - Upload Tasks -
- (TOSMBSessionUploadTask *)uploadTaskForFileAtPath:(NSString *)path data:(NSData *)data progressHandler:(void (^)(uint64_t, uint64_t))progressHandler completionHandler:(void (^)(void))completionHandler failHandler:(void (^)(NSError *))failHandler {
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"session:%@ path:%@ data:%@ progressHandler:%@% completionHandler:%@ failHandler:%@", self?@"true":@"false",
                                  path.length?@"true":@"false",
                                  data.length?@"true":@"false",
                                  progressHandler?@"true":@"false",
                                  completionHandler?@"true":@"false",
                                  failHandler?@"true":@"false"]]);
    TOSMBSessionUploadTask *task = [[TOSMBSessionUploadTask alloc] initWithSession:self
                                                                              path:path
                                                                              data:data
                                                                   progressHandler:progressHandler
                                                                    successHandler:completionHandler
                                                                       failHandler:failHandler];
    
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"task created: %@", task?@"true":@"false"]]);
    
    self.uploadTasks = [self.uploadTasks ?: @[] arrayByAddingObject:task];
    
    return task;
}

#pragma mark - String Parsing -
- (NSString *)shareNameFromPath:(NSString *)path
{
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"path: %@", path]]);
    path = [path copy];
    
    //Remove any potential slashes at the start
    if ([[path substringToIndex:2] isEqualToString:@"//"]) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"removed appended //"]);
        path = [path substringFromIndex:2];
    }
    else if ([[path substringToIndex:1] isEqualToString:@"/"]) {
        path = [path substringFromIndex:1];
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"removed appended /"]);
    }
    
    NSRange range = [path rangeOfString:@"/"];
    
    if (range.location != NSNotFound) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"taken substring from first /"]);
        path = [path substringWithRange:NSMakeRange(0, range.location)];
    }
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"final path: %@", path]]);
    return path;
}

- (NSString *)filePathExcludingSharePathFromPath:(NSString *)path
{
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"path: %@", path]]);
    path = [path copy];
    
    //Remove any potential slashes at the start
    if ([[path substringToIndex:2] isEqualToString:@"//"] || [[path substringToIndex:2] isEqualToString:@"\\\\"]) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"removed appended // or \\\\ "]);
        path = [path substringFromIndex:2];
    }
    else if ([[path substringToIndex:1] isEqualToString:@"/"] || [[path substringToIndex:1] isEqualToString:@"\\"]) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"removed appended / or \\ "]);
        path = [path substringFromIndex:1];
    }
    
    NSRange range = [path rangeOfString:@"/"];
    if (range.location == NSNotFound) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"looking for \\ "]);
        range = [path rangeOfString:@"\\"];
    }
    
    if (range.location != NSNotFound) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"taken substring from first / or \\ "]);
        path = [path substringFromIndex:range.location+1];
    }
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"final path : %@", path]]);
    return path;
}

#pragma mark - Accessors -
- (NSInteger)guest
{
    if (self.session == NULL)
        return -1;
    
    return smb_session_is_guest(self.session);
}

- (NSOperationQueue *)dataQueue
{
    if (!_dataQueue) {
        _dataQueue = [[NSOperationQueue alloc] init];
        _dataQueue.maxConcurrentOperationCount = 1;
    }
    
    return _dataQueue;
}

- (NSOperationQueue *)taskQueue
{
    if (!_taskQueue) {
        _taskQueue = [[NSOperationQueue alloc] init];
        _taskQueue.maxConcurrentOperationCount = self.maxTaskOperationCount;
    }
    
    return _taskQueue;
}

- (void)setMaxTaskOperationCount:(NSInteger)maxTaskOperationCount {
    _maxTaskOperationCount = maxTaskOperationCount;
    
    self.taskQueue.maxConcurrentOperationCount = maxTaskOperationCount;
}

#pragma mark Logging

static toSMBGlobalLogger _globalLogger;

+(toSMBGlobalLogger)globalLogger
{
    return _globalLogger;
}

+(void)setGlobalLogger:(toSMBGlobalLogger)globalLogger
{
    _globalLogger = globalLogger;
}

@end

@implementation TOSMBSession (Deprecated)

- (NSInteger)maxDownloadOperationCount {
    return self.maxTaskOperationCount;
}

- (void)setMaxDownloadOperationCount:(NSInteger)maxDownloadOperationCount
{
    self.maxTaskOperationCount = maxDownloadOperationCount;
}

@end

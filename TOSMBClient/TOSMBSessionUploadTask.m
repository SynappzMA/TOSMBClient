//
// TOSMBSessionUploadTake.m
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

#import "TOSMBSessionUploadTaskPrivate.h"
#import "TOSMBSessionPrivate.h"

@interface TOSMBSessionUploadTask ()

@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSData *data;
@property(nonatomic) smb_tid treeID;
@property(nonatomic) smb_tid fileID;

@property (nonatomic, strong) TOSMBSessionFile *file;

@property (nonatomic, weak) id <TOSMBSessionUploadTaskDelegate> delegate;
@property (nonatomic, copy) void (^successHandler)(void);

@end

@implementation TOSMBSessionUploadTask

@dynamic delegate;

- (instancetype)initWithSession:(TOSMBSession *)session
                           path:(NSString *)path
                           data:(NSData *)data {
    if ((self = [super initWithSession:session])) {
        self.path = path;
        self.data = data;
    }
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"path: %@, data:%@", path, data.length?@"true":@"false"]]);
    return self;
}

- (instancetype)initWithSession:(TOSMBSession *)session
                           path:(NSString *)path
                           data:(NSData *)data
                       delegate:(id<TOSMBSessionUploadTaskDelegate>)delegate {
    if ((self = [self initWithSession:session path:path data:data])) {
        self.delegate = delegate;
    }
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"delegate: %@", delegate]]);
    
    return self;
}

- (instancetype)initWithSession:(TOSMBSession *)session
                           path:(NSString *)path
                           data:(NSData *)data
                progressHandler:(id)progressHandler
                 successHandler:(id)successHandler
                    failHandler:(id)failHandler {
    if ((self = [self initWithSession:session path:path data:data])) {
        self.progressHandler = progressHandler;
        self.successHandler = successHandler;
        self.failHandler = failHandler;
    }
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"progressHandler:%@ successhandler:%@ failhandler:%@", self.progressHandler?@"true":@"false", self.successHandler?@"true":@"false", self.failHandler?@"true":@"false"]]);
    return self;
}

#pragma mark - delegate helpers

- (void)didSendBytes:(NSInteger)recentCount bytesSent:(NSInteger)totalCount {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([weakSelf.delegate respondsToSelector:@selector(uploadTask:didSendBytes:totalBytesSent:totalBytesExpectedToSend:)]) {
            [weakSelf.delegate uploadTask:self didSendBytes:recentCount totalBytesSent:totalCount totalBytesExpectedToSend:weakSelf.data.length];
        }
        if (weakSelf.progressHandler) {
            weakSelf.progressHandler(totalCount, weakSelf.data.length);
        }
    });
}

- (void)didFinish {
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__, @"entered"]);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([weakSelf.delegate respondsToSelector:@selector(uploadTaskDidFinishUploading:)]) {
            [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                         @"uploadTaskDidFinishUploading called on delegate"]);
            [weakSelf.delegate uploadTaskDidFinishUploading:self];
        } else {
            [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                         @"delegate does not respond to uploadTaskDidFinishUploading"]);
        }
        if (weakSelf.successHandler) {
            [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                         @"successhandler called"]);
            weakSelf.successHandler();
        } else {
            [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                         @"no delegate or successhandler found"]);
        }
        self.cleanupBlock(self.treeID, self.fileID);
    });
}

#pragma mark - task

- (void)performTaskWithOperation:(NSBlockOperation * _Nonnull __weak)weakOperation {
    if (weakOperation.isCancelled) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"task was already cancelled"]);
        return;
    }
    
    smb_tid treeID = 0;
    smb_fd fileID = 0;
    
    //---------------------------------------------------------------------------------------
    //Connect to SMB device
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 @"try connect to smb device"]);
    self.smbSession = smb_session_new();
    
    //First, check to make sure the server is there, and to acquire its attributes
    __block NSError *error = nil;
    dispatch_sync(self.session.serialQueue, ^{
        error = [self.session attemptConnectionWithSessionPointer:self.smbSession];
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     [NSString stringWithFormat:@"%@", error]]);
    });
    if (error) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     [NSString stringWithFormat:@"%@", error]]);
        [self didFailWithError:error];
        self.cleanupBlock(treeID, fileID);
        return;
    }
    
    if (weakOperation.isCancelled) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"cancelled"]);
        self.cleanupBlock(treeID, fileID);
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Connect to share
    
    //Next attach to the share we'll be using
    NSLog(@"Performing upload task with operation");
    NSString *shareName = [self.session shareNameFromPath:self.path];
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"connecting to shareName %@", shareName]]);
    const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    
    if (smb_tree_connect(self.smbSession, shareCString, &treeID) != 0) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__, @"failed to connect to share"]);
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed)];
        self.cleanupBlock(treeID, fileID);
        return;
    }
    
    self.treeID = treeID;
    self.fileID = fileID;
    NSLog(@"Connected successfully: %d, %d", self.treeID, self.fileID);
    if (weakOperation.isCancelled) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"cancelled"]);
        self.cleanupBlock(treeID, fileID);
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Find the target file
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"attempt to find file at %@", self.path]]);
    NSString *formattedPath = [self.session filePathExcludingSharePathFromPath:self.path];
    formattedPath = [NSString stringWithFormat:@"\\%@",formattedPath];
    formattedPath = [formattedPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\\\"];
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"formatted path: %@", formattedPath]]);
    
    //Get the file info we'll be working off
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"requesting file for path: %@ inTree: %u", formattedPath, treeID]]);
    self.file = [self requestFileForItemAtPath:formattedPath inTree:treeID];
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 [NSString stringWithFormat:@"file: %@", self.file]]);
    if (weakOperation.isCancelled) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"cancelled"]);
        self.cleanupBlock(treeID, fileID);
        return;
    }
    
    if (self.file.directory) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"file is directory"]);
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeDirectoryDownloaded)];
        self.cleanupBlock(treeID, fileID);
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Open the file handle
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 @"attempt to open fileHandle"]);
    smb_fopen(self.smbSession, treeID, [formattedPath cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RW, &fileID);
    if (!fileID) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"no file found"]);
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        self.cleanupBlock(treeID, fileID);
        return;
    }
    
    if (weakOperation.isCancelled) {
        [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                     @"cancelled"]);
        self.cleanupBlock(treeID, fileID);
        return;
    }
    
    NSUInteger bufferSize = self.data.length;
    void *buffer = malloc(bufferSize);
    [self.data getBytes:buffer length:bufferSize];
    // change the limit size to 63488(62KB)
    // (if still crash, change the limit size < 63488)
    size_t uploadBufferLimit = MIN(bufferSize, 63488);
    
    ssize_t bytesWritten = 0;
    ssize_t totalBytesWritten = 0;
    [TOSMBSession globalLogger]([NSString stringWithFormat:@"%s:%d - %@", __PRETTY_FUNCTION__ , __LINE__,
                                 @"start uploading"]);
    do {
        // change the the size of last part
        if (bufferSize - totalBytesWritten < uploadBufferLimit) {
            uploadBufferLimit = bufferSize - totalBytesWritten;
        }
        bytesWritten = smb_fwrite(self.smbSession, fileID, buffer+totalBytesWritten, uploadBufferLimit);
        if (bytesWritten < 0) {
            [self fail];
            [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileDownloadFailed)];
            break;
        }
        totalBytesWritten += bytesWritten;
        [self didSendBytes:bytesWritten bytesSent:totalBytesWritten];
    } while (totalBytesWritten < bufferSize);
    
    free(buffer);
    
    [self didFinish];
}


@end

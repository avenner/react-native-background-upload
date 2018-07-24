#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import <Photos/Photos.h>

@interface VydiaRNFileUploader : RCTEventEmitter <RCTBridgeModule, NSURLSessionTaskDelegate>
{
    NSMutableDictionary *_responsesData;
}
@end

@implementation VydiaRNFileUploader

RCT_EXPORT_MODULE();

@synthesize bridge = _bridge;
static int uploadId = 0;
static RCTEventEmitter* staticEventEmitter = nil;
static NSString *BACKGROUND_SESSION_ID = @"ReactNativeBackgroundUpload";
NSURLSession *_urlSession = nil;

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

-(id) init {
    self = [super init];
    if (self) {
        staticEventEmitter = self;
        _responsesData = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)_sendEventWithName:(NSString *)eventName body:(id)body {
    if (staticEventEmitter == nil)
        return;
    [staticEventEmitter sendEventWithName:eventName body:body];
}

- (NSArray<NSString *> *)supportedEvents {
    return @[
             @"RNFileUploader-progress",
             @"RNFileUploader-error",
             @"RNFileUploader-cancelled",
             @"RNFileUploader-completed"
             ];
}

/*
 * Starts a file upload.
 * Options are passed in as the first argument as a js hash:
 * {
 *   url: string.  url to post to.
 *   path: string.  path to the file on the device
 *   headers: hash of name/value header pairs
 * }
 *
 * Returns a promise with the string ID of the upload.
 */
RCT_EXPORT_METHOD(startUpload:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
{
    int thisUploadId;
    @synchronized(self.class)
    {
        thisUploadId = uploadId++;
    }
    
    NSString *uploadUrl = options[@"url"];
    NSString *method = options[@"method"] ?: @"POST";
    NSString *customUploadId = options[@"customUploadId"];
    NSDictionary *headers = options[@"headers"];
    NSDictionary *parameters = options[@"parameters"];
    
    @try {
        NSURL *requestUrl;
        
        if([method isEqualToString:@"POST"] || [method isEqualToString:@"PUT"]){
            requestUrl = [NSURL URLWithString: uploadUrl];
        } else {
            NSURLComponents *components = [NSURLComponents componentsWithString:uploadUrl];
            NSMutableArray *queryItems = [NSMutableArray array];
            for (NSString *key in parameters) {
                [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:parameters[key]]];
            }
            components.queryItems = queryItems;
            requestUrl = components.URL;
        }
        
        if (requestUrl == nil) {
          @throw @"Request cannot be nil";
        }
        
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestUrl];
        [request setHTTPMethod: method];
        
        [headers enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull val, BOOL * _Nonnull stop) {
            if ([val respondsToSelector:@selector(stringValue)]) {
                val = [val stringValue];
            }
            if ([val isKindOfClass:[NSString class]]) {
                [request setValue:val forHTTPHeaderField:key];
            }
        }];
        
        NSURLSessionDownloadTask *uploadTask;
        
        if([method isEqualToString:@"POST"] || [method isEqualToString:@"PUT"]){
            NSString *uuidStr = [[NSUUID UUID] UUIDString];
            [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", uuidStr] forHTTPHeaderField:@"Content-Type"];
            
            NSMutableData *httpBody = [NSMutableData data];
            
            [parameters enumerateKeysAndObjectsUsingBlock:^(NSString *parameterKey, NSString *parameterValue, BOOL *stop) {
                [httpBody appendData:[[NSString stringWithFormat:@"--%@\r\n", uuidStr] dataUsingEncoding:NSUTF8StringEncoding]];
                [httpBody appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", parameterKey] dataUsingEncoding:NSUTF8StringEncoding]];
                [httpBody appendData:[[NSString stringWithFormat:@"%@\r\n", parameterValue] dataUsingEncoding:NSUTF8StringEncoding]];
            }];
            
            [httpBody appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
            
            [httpBody appendData:[[NSString stringWithFormat:@"--%@--\r\n", uuidStr] dataUsingEncoding:NSUTF8StringEncoding]];

            [request setHTTPBody: httpBody];
        }
            
        uploadTask = [[self urlSession] downloadTaskWithRequest:request];
        
        uploadTask.taskDescription = customUploadId ? customUploadId : [NSString stringWithFormat:@"%i", thisUploadId];
        
        [uploadTask resume];
        resolve(uploadTask.taskDescription);
    }
    @catch (NSException *exception) {
        reject(@"RN Uploader", exception.name, nil);
    }
}

/*
 * Cancels file upload
 * Accepts upload ID as a first argument, this upload will be cancelled
 * Event "cancelled" will be fired when upload is cancelled.
 */
RCT_EXPORT_METHOD(cancelUpload: (NSString *)cancelUploadId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    [_urlSession getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        for (NSURLSessionTask *uploadTask in uploadTasks) {
            if (uploadTask.taskDescription == cancelUploadId) {
                [uploadTask cancel];
            }
        }
    }];
    resolve([NSNumber numberWithBool:YES]);
}

- (NSURLSession *)urlSession {
    if (_urlSession == nil) {
        NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:BACKGROUND_SESSION_ID];
        sessionConfiguration.waitsForConnectivity = YES;
        _urlSession = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:self delegateQueue:nil];
    }
    
    return _urlSession;
}

#pragma NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObjectsAndKeys:task.taskDescription, @"id", nil];
    NSURLSessionDataTask *uploadTask = (NSURLSessionDataTask *)task;
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)uploadTask.response;
    if (response != nil)
    {
        [data setObject:[NSNumber numberWithInteger:response.statusCode] forKey:@"responseCode"];
    }
    //Add data that was collected earlier by the didReceiveData method
    NSMutableData *responseData = _responsesData[@(task.taskIdentifier)];
    if (responseData) {
        [_responsesData removeObjectForKey:@(task.taskIdentifier)];
        NSString *response = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        [data setObject:response forKey:@"responseBody"];
    } else {
        [data setObject:[NSNull null] forKey:@"responseBody"];
    }
    
    if (error == nil)
    {
        [self _sendEventWithName:@"RNFileUploader-completed" body:data];
    }
    else
    {
        [data setObject:error.localizedDescription forKey:@"error"];
        if (error.code == NSURLErrorCancelled) {
            [self _sendEventWithName:@"RNFileUploader-cancelled" body:data];
        } else {
            [self _sendEventWithName:@"RNFileUploader-error" body:data];
        }
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    float progress = -1;
    if (totalBytesExpectedToSend > 0) //see documentation.  For unknown size it's -1 (NSURLSessionTransferSizeUnknown)
    {
        progress = 100.0 * (float)totalBytesSent / (float)totalBytesExpectedToSend;
    }
    [self _sendEventWithName:@"RNFileUploader-progress" body:@{ @"id": task.taskDescription, @"progress": [NSNumber numberWithFloat:progress] }];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!data.length) {
        return;
    }
    //Hold returned data so it can be picked up by the didCompleteWithError method later
    NSMutableData *responseData = _responsesData[@(dataTask.taskIdentifier)];
    if (!responseData) {
        responseData = [NSMutableData dataWithData:data];
        _responsesData[@(dataTask.taskIdentifier)] = responseData;
    } else {
        [responseData appendData:data];
    }
}

@end

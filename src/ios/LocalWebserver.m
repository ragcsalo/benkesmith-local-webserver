#import "LocalWebserver.h"
#import <ifaddrs.h>
#import <arpa/inet.h>

// Helper wrapper for request state
@interface RequestWrapper : NSObject
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, strong) NSDictionary* response;
@end

@implementation RequestWrapper
@end

@implementation LocalWebserver

- (void)pluginInitialize {
    pendingRequests = [NSMutableDictionary dictionary];
}

- (void)start:(CDVInvokedUrlCommand*)command {
    NSInteger port = [command.arguments[0] integerValue];
    webServer = [[GCDWebServer alloc] init];
    __weak __typeof__(self) weakSelf = self;

    for (NSString* method in @[@"GET", @"POST", @"OPTIONS"]) {
        [webServer addDefaultHandlerForMethod:method
                                 requestClass:[GCDWebServerDataRequest class]
                                  processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return nil;

            // Create and store wrapper
            NSString* reqId = [[NSUUID UUID] UUIDString];
            RequestWrapper* rw = [RequestWrapper new];
            rw.semaphore = dispatch_semaphore_create(0);
            rw.response = nil;
            strongSelf->pendingRequests[reqId] = rw;

            // Extract request details
            NSString* httpMethod = request.method;
            NSString* path = request.URL.path ?: @"";
            NSString* query = request.URL.query ?: @"";
            NSString* remoteAddr = @"";
            NSData* addrData = [request respondsToSelector:@selector(remoteAddressData)] ? request.remoteAddressData : nil;
            if (addrData) {
                struct sockaddr *addr = (struct sockaddr*)addrData.bytes;
                char buffer[INET6_ADDRSTRLEN];
                const void* src = (addr->sa_family == AF_INET) ?
                    (void*)&((struct sockaddr_in*)addr)->sin_addr :
                    (void*)&((struct sockaddr_in6*)addr)->sin6_addr;
                if (inet_ntop(addr->sa_family, src, buffer, sizeof(buffer))) {
                    remoteAddr = [NSString stringWithUTF8String:buffer];
                }
            }
            NSDictionary* headers = [request respondsToSelector:@selector(headers)] ? request.headers : @{};
            NSString* bodyString = @"";
            if (([httpMethod isEqualToString:@"POST"] || [httpMethod isEqualToString:@"PUT"]) &&
                            [request isKindOfClass:[GCDWebServerDataRequest class]]) {
                            GCDWebServerDataRequest* dataReq = (GCDWebServerDataRequest*)request;
                            bodyString = [[NSString alloc] initWithData:dataReq.data encoding:NSUTF8StringEncoding] ?: @"";
                        }

            // Send request info to JS
            NSDictionary* jsReq = @{ @"requestId": reqId,
                                     @"method": httpMethod,
                                     @"path": path,
                                     @"query": query,
                                     @"headers": headers,
                                     @"body": bodyString,
                                     @"remoteAddress": remoteAddr };
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:jsReq];
            [pluginResult setKeepCallbackAsBool:YES];
            [strongSelf.commandDelegate sendPluginResult:pluginResult callbackId:strongSelf->requestCallbackId];

            // Wait for JS response or timeout
            dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC);
            long wait = dispatch_semaphore_wait(rw.semaphore, timeout);

            NSDictionary* respDict = rw.response;
            GCDWebServerDataResponse* respObj;
            if (wait != 0 || !respDict) {
                respObj = [GCDWebServerDataResponse responseWithText:@"Timeout waiting for response"];
                respObj.statusCode = 500;
            } else {
                NSInteger status = [respDict[@"status"] integerValue];
                NSString* respBody = respDict[@"body"] ?: @"";
                respObj = [GCDWebServerDataResponse responseWithText:respBody];
                respObj.statusCode = status;
                NSDictionary* respHeaders = respDict[@"headers"] ?: @{};
                [respHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                    [respObj setValue:value forAdditionalHeader:key];
                }];
            }

            // Clean up
            [strongSelf->pendingRequests removeObjectForKey:reqId];
            return respObj;
        }];
    }

    [webServer startWithOptions:@{ GCDWebServerOption_Port: @(port),
                                  GCDWebServerOption_BindToLocalhost: @NO,
                                  GCDWebServerOption_AutomaticallySuspendInBackground: @NO } error:nil];

    NSString* ip = [self getWiFiAddress];
    NSString* resultString = [NSString stringWithFormat:@"%@:%ld", ip, (long)port];
    CDVPluginResult* res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:resultString];
    [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
}

- (void)stop:(CDVInvokedUrlCommand*)command {
    [webServer stop];
    [pendingRequests removeAllObjects];
    CDVPluginResult* res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Server stopped"];
    [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
}

- (void)onRequest:(CDVInvokedUrlCommand*)command {
    requestCallbackId = command.callbackId;
    CDVPluginResult* res = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [res setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
}

- (void)sendResponse:(CDVInvokedUrlCommand*)command {
    NSString* reqId = command.arguments[0];
    NSDictionary* respDict = command.arguments[1];
    RequestWrapper* rw = pendingRequests[reqId];
    if (rw) {
        rw.response = respDict;
        dispatch_semaphore_signal(rw.semaphore);
        CDVPluginResult* res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Response sent"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
    } else {
        CDVPluginResult* err = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid requestId"];
        [self.commandDelegate sendPluginResult:err callbackId:command.callbackId];
    }
}

- (NSString*)getWiFiAddress {
    NSString *address = @"127.0.0.1";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString* ifaName = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([ifaName isEqualToString:@"en0"] || [ifaName hasPrefix:@"bridge"] || [ifaName hasPrefix:@"pdp_ip"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    break;
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    freeifaddrs(interfaces);
    return address;
}

@end


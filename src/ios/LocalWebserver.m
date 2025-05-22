#import "LocalWebserver.h"
#import <ifaddrs.h>
#import <arpa/inet.h>


@implementation LocalWebserver

- (void)pluginInitialize {
    pendingRequests = [NSMutableDictionary dictionary];
}

- (void)start:(CDVInvokedUrlCommand*)command {
    NSInteger port = [command.arguments[0] integerValue];
    webServer = [[GCDWebServer alloc] init];
    __weak __typeof(self) weakSelf = self;

    [webServer addDefaultHandlerForMethod:@"GET"
                              requestClass:[GCDWebServerDataRequest class]
                              processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
        NSString* reqId = [[NSUUID UUID] UUIDString];
        NSMutableDictionary* wrapper = [NSMutableDictionary dictionary];
        wrapper[@"request"] = request;
        wrapper[@"semaphore"] = dispatch_semaphore_create(0);
        pendingRequests[reqId] = wrapper;
        // Notify JS
        NSDictionary* jsReq = @{
            @"requestId": reqId,
            @"method": request.method,
            @"path": request.path,
            @"query": request.query
        };
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:jsReq];
        [pluginResult setKeepCallbackAsBool:YES];
        [weakSelf.commandDelegate sendPluginResult:pluginResult callbackId:requestCallbackId];
        // Wait for JS response (timeout 30s)
        dispatch_semaphore_t sem = wrapper[@"semaphore"];
        long result = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
        if (result != 0) {
            GCDWebServerDataResponse* timeoutResp = [GCDWebServerDataResponse responseWithText:@"Timeout waiting for response"];
            timeoutResp.statusCode = 500;
            return timeoutResp;
        }
        NSDictionary* resp = wrapper[@"response"];
        NSInteger status = [resp[@"status"] integerValue];
        NSDictionary* headers = resp[@"headers"];
        NSString* body = resp[@"body"];
        GCDWebServerDataResponse* responseObj = [GCDWebServerDataResponse responseWithText:body];
        responseObj.statusCode = status;
        [headers enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL* stop) {
            [responseObj setValue:value forAdditionalHeader:key];
        }];
        return responseObj;
    }];
    [self->webServer startWithOptions:@{
      GCDWebServerOption_Port: @(port),
      GCDWebServerOption_BindToLocalhost: @NO,
      GCDWebServerOption_AutomaticallySuspendInBackground: @NO
    } error:nil];

    NSString* ip = [self getWiFiAddress];
    NSString* resultString = [NSString stringWithFormat:@"%@:%ld", ip, (long)port];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:resultString];

    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (NSString *)getWiFiAddress {
    NSString *address = @"127.0.0.1";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = getifaddrs(&interfaces);
    if (success == 0) {
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

- (void)stop:(CDVInvokedUrlCommand*)command {
    if (webServer) {
        [webServer stop];
        [pendingRequests removeAllObjects];
        CDVPluginResult* res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Server stopped"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
    } else {
        CDVPluginResult* err = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Server not running"];
        [self.commandDelegate sendPluginResult:err callbackId:command.callbackId];
    }
}

- (void)onRequest:(CDVInvokedUrlCommand*)command {
    requestCallbackId = command.callbackId;
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:requestCallbackId];
}

- (void)sendResponse:(CDVInvokedUrlCommand*)command {
    NSString* reqId = command.arguments[0];
    NSDictionary* resp = command.arguments[1];
    NSMutableDictionary* wrapper = pendingRequests[reqId];
    if (wrapper) {
        wrapper[@"response"] = resp;
        dispatch_semaphore_signal(wrapper[@"semaphore"]);
        [pendingRequests removeObjectForKey:reqId];
        CDVPluginResult* res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Response sent"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
    } else {
        CDVPluginResult* err = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid requestId"];
        [self.commandDelegate sendPluginResult:err callbackId:command.callbackId];
    }
}

@end

#import "LocalWebserver.h"

@implementation LocalWebserver

- (void)pluginInitialize {
    pendingRequests = [NSMutableDictionary dictionary];
}

- (void)start:(CDVInvokedUrlCommand*)command {
    NSInteger port = [command.arguments[0] integerValue];
    webServer = [[GCDWebServer alloc] init];
    __weak typeof(self) weakSelf = self;
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
            return [GCDWebServerDataResponse responseWithStatusCode:500 text:@"Timeout waiting for response"];
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
    [webServer startWithPort:port bonjourName:nil];
    CDVPluginResult* res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[NSString stringWithFormat:@"Server started on port %ld", (long)port]];
    [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
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

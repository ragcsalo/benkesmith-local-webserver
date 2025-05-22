#import <Cordova/CDVPlugin.h>
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"

@interface LocalWebserver : CDVPlugin {
    GCDWebServer* webServer;
    NSString* requestCallbackId;
    NSMutableDictionary<NSString*, NSMutableDictionary*>* pendingRequests;
}

- (void)start:(CDVInvokedUrlCommand*)command;
- (void)stop:(CDVInvokedUrlCommand*)command;
- (void)onRequest:(CDVInvokedUrlCommand*)command;
- (void)sendResponse:(CDVInvokedUrlCommand*)command;

@end


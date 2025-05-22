#import <Cordova/CDVPlugin.h>
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"

@class RequestWrapper;

@interface LocalWebserver : CDVPlugin {
    GCDWebServer* webServer;
    NSString* requestCallbackId;
    NSMutableDictionary<NSString*, RequestWrapper*>* pendingRequests;
}

- (void)start:(CDVInvokedUrlCommand*)command;
- (void)stop:(CDVInvokedUrlCommand*)command;
- (void)onRequest:(CDVInvokedUrlCommand*)command;
- (void)sendResponse:(CDVInvokedUrlCommand*)command;

@end

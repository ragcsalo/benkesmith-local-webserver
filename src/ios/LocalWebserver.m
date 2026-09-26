#import "LocalWebserver.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <net/if.h>

#define REALBOARD_DISCOVERY_PORT 8889

// Helper wrapper for request state
@interface RequestWrapper : NSObject
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, strong) NSDictionary* response;
@end

@implementation RequestWrapper
@end

// Which network interface the server's address comes from: en0 (Wi-Fi) first, then bridge* (the
// Personal Hotspot this phone shares - the other phones join it over Wi-Fi). NEVER pdp_ip* (cellular):
// other phones can't reach that address. -1 = not a candidate (also: not IPv4, down, loopback, or a
// 169.254.x.x "no address yet" one). No candidate -> getWiFiAddress() gives 127.0.0.1, and the app
// shows "please connect to a Wi-Fi network" instead of an address (websocket.js).
// getifaddrs() often lists pdp_ip0 BEFORE en0, so simply taking the first match returned the cellular
// address (e.g. 10.126.x.x) while the phone was on Wi-Fi (192.168.1.x) - unreachable for the others.
static int ms_interface_priority(struct ifaddrs* ifa) {
    if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_INET) {
        return -1;
    }
    if ((ifa->ifa_flags & IFF_UP) == 0 || (ifa->ifa_flags & IFF_LOOPBACK) != 0) {
        return -1;
    }
    struct in_addr addr = ((struct sockaddr_in *)ifa->ifa_addr)->sin_addr;
    if ((ntohl(addr.s_addr) & 0xFFFF0000) == 0xA9FE0000) {
        return -1;
    }
    const char* name = ifa->ifa_name;
    if (strcmp(name, "en0") == 0) {
        return 0;
    }
    if (strncmp(name, "bridge", 6) == 0) {
        return 1;
    }
    return -1;
}

// the best interface of a getifaddrs() list (see above), or NULL
static struct ifaddrs* ms_best_interface(struct ifaddrs* interfaces) {
    struct ifaddrs* best = NULL;
    int bestPriority = 99;
    for (struct ifaddrs* temp_addr = interfaces; temp_addr != NULL; temp_addr = temp_addr->ifa_next) {
        int priority = ms_interface_priority(temp_addr);
        if (priority >= 0 && priority < bestPriority) {
            best = temp_addr;
            bestPriority = priority;
        }
    }
    return best;
}

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

// UDP discovery of a RealBoard on the local network - broadcasts "DRAWING_APP_DISCOVERY" on port
// 8889 and waits (2s) for a unicast "DRAWING_APP_SERVER:<tcpPort>" reply. See
// docs/RealBoard_WiFi_Protocol.md §3. Mirrors the Android discoverBoard implementation. Known to
// be unreliable on some phone hotspots (broadcast doesn't always propagate) - callers should fall
// back to a manually-entered IP on failure.
- (void)discoverBoard:(CDVInvokedUrlCommand*)command {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performDiscoverBoard:command];
    });
}

- (void)performDiscoverBoard:(CDVInvokedUrlCommand*)command {
    NSLog(@"**RealBoard** [iOS] discoverBoard: starting");

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        [self sendTcpError:[NSString stringWithFormat:@"Failed to create UDP socket: %s", strerror(errno)] command:command];
        return;
    }

    int broadcastEnable = 1;
    if (setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, sizeof(broadcastEnable)) < 0) {
        NSLog(@"**RealBoard** [iOS] setsockopt SO_BROADCAST failed: %s (continuing anyway)", strerror(errno));
    }
    int reuseEnable = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseEnable, sizeof(reuseEnable));

    struct timeval readTv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &readTv, sizeof(readTv));

    // On iOS/macOS, sending to the limited broadcast address (255.255.255.255) from an unbound
    // socket has no route unless the socket is first bound to the WiFi interface's own local
    // address - unlike Android, where an unbound DatagramSocket resolves this on its own.
    NSString* localIp = [self getWiFiAddress];
    NSLog(@"**RealBoard** [iOS] getWiFiAddress() -> %@", localIp);
    if (!localIp || [localIp isEqualToString:@"127.0.0.1"]) {
        close(sock);
        [self sendTcpError:@"No WiFi network detected - can't broadcast for discovery" command:command];
        return;
    }

    struct sockaddr_in bindAddr;
    memset(&bindAddr, 0, sizeof(bindAddr));
    bindAddr.sin_family = AF_INET;
    bindAddr.sin_port = htons(0);
    bindAddr.sin_addr.s_addr = inet_addr([localIp UTF8String]);

    if (bind(sock, (struct sockaddr*)&bindAddr, sizeof(bindAddr)) < 0) {
        NSString* errMsg = [NSString stringWithFormat:@"Failed to bind discovery socket to %@: %s", localIp, strerror(errno)];
        NSLog(@"**RealBoard** [iOS] %@", errMsg);
        close(sock);
        [self sendTcpError:errMsg command:command];
        return;
    }
    NSLog(@"**RealBoard** [iOS] bound discovery socket to %@", localIp);

    // Prefer the WiFi interface's subnet-directed broadcast address (e.g. 192.168.1.255) over the
    // limited broadcast address 255.255.255.255 - iOS/macOS frequently has no route for the latter
    // at all, even from a bound socket, while the directed broadcast corresponds to a real local
    // route through the interface. Falls back to 255.255.255.255 only if the netmask couldn't be
    // read (shouldn't normally happen once getWiFiAddress() above already found an interface).
    NSString* targetAddress = [self getWiFiBroadcastAddress];
    if (!targetAddress) {
        NSLog(@"**RealBoard** [iOS] could not compute directed broadcast address, falling back to 255.255.255.255");
        targetAddress = @"255.255.255.255";
    }

    struct sockaddr_in broadcastAddr;
    memset(&broadcastAddr, 0, sizeof(broadcastAddr));
    broadcastAddr.sin_family = AF_INET;
    broadcastAddr.sin_port = htons(REALBOARD_DISCOVERY_PORT);
    broadcastAddr.sin_addr.s_addr = inet_addr([targetAddress UTF8String]);

    NSLog(@"**RealBoard** [iOS] sending discovery broadcast to %@:%d from bound socket %@", targetAddress, REALBOARD_DISCOVERY_PORT, localIp);

    const char* message = "DRAWING_APP_DISCOVERY";
    if (sendto(sock, message, strlen(message), 0, (struct sockaddr*)&broadcastAddr, sizeof(broadcastAddr)) < 0) {
        NSString* errMsg = [NSString stringWithFormat:@"Failed to send discovery broadcast to %@:%d (bound to %@): %s (errno %d)",
                             targetAddress, REALBOARD_DISCOVERY_PORT, localIp, strerror(errno), errno];
        NSLog(@"**RealBoard** [iOS] %@", errMsg);
        close(sock);
        [self sendTcpError:errMsg command:command];
        return;
    }
    NSLog(@"**RealBoard** [iOS] broadcast sent OK, waiting up to 2s for a reply...");

    char recvBuf[1024];
    struct sockaddr_in fromAddr;
    socklen_t fromLen = sizeof(fromAddr);
    ssize_t n = recvfrom(sock, recvBuf, sizeof(recvBuf) - 1, 0, (struct sockaddr*)&fromAddr, &fromLen);
    close(sock);

    if (n <= 0) {
        NSLog(@"**RealBoard** [iOS] recvfrom timed out/failed: %s", strerror(errno));
        [self sendTcpError:@"Discovery timed out - no board responded" command:command];
        return;
    }

    recvBuf[n] = '\0';
    NSString* reply = [NSString stringWithUTF8String:recvBuf];
    NSLog(@"**RealBoard** [iOS] reply from %s: %@", inet_ntoa(fromAddr.sin_addr), reply);
    NSArray* parts = [reply componentsSeparatedByString:@":"];
    if (parts.count == 2 && [parts[0] isEqualToString:@"DRAWING_APP_SERVER"]) {
        NSString* ip = [NSString stringWithUTF8String:inet_ntoa(fromAddr.sin_addr)];
        NSInteger port = [[parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] integerValue];

        NSDictionary* result = @{ @"ip": ip, @"port": @(port) };
        CDVPluginResult* res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
    } else {
        [self sendTcpError:[NSString stringWithFormat:@"Unexpected discovery reply: %@", reply] command:command];
    }
}

// Outbound raw TCP client (not the GCDWebServer above): connects out to a device speaking
// the RealBoard wire protocol - 4-byte big-endian length header, then the raw JPEG bytes,
// then a single ACK text line ("IMAGE_RECEIVED\n") read back on the same socket. See
// docs/RealBoard_WiFi_Protocol.md. Mirrors the Android sendTcpImage implementation in
// LocalWebserver.java (same timeouts, same wire format). Runs off the Cordova command
// queue thread since it's blocking network I/O.
- (void)sendTcpImage:(CDVInvokedUrlCommand*)command {
    NSString* ip = command.arguments[0];
    NSInteger port = [command.arguments[1] integerValue];
    NSString* base64Image = command.arguments[2];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performTcpImageSend:ip port:port base64Image:base64Image command:command];
    });
}

- (void)sendTcpError:(NSString*)message command:(CDVInvokedUrlCommand*)command {
    CDVPluginResult* err = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
    [self.commandDelegate sendPluginResult:err callbackId:command.callbackId];
}

- (void)performTcpImageSend:(NSString*)ip port:(NSInteger)port base64Image:(NSString*)base64Image command:(CDVInvokedUrlCommand*)command {
    NSData* imageData = [[NSData alloc] initWithBase64EncodedString:base64Image options:0];
    if (!imageData) {
        [self sendTcpError:@"Invalid base64 image data" command:command];
        return;
    }

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        [self sendTcpError:@"Failed to create socket" command:command];
        return;
    }

    struct hostent* server = gethostbyname([ip UTF8String]);
    if (!server) {
        close(sock);
        [self sendTcpError:@"Unknown host" command:command];
        return;
    }

    struct sockaddr_in serverAddr;
    memset(&serverAddr, 0, sizeof(serverAddr));
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_port = htons((uint16_t)port);
    memcpy(&serverAddr.sin_addr.s_addr, server->h_addr, server->h_length);

    // Non-blocking connect with a 5s timeout (matches Socket.connect(..., 5000) on Android)
    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    int connectResult = connect(sock, (struct sockaddr*)&serverAddr, sizeof(serverAddr));
    if (connectResult < 0 && errno != EINPROGRESS) {
        close(sock);
        [self sendTcpError:[NSString stringWithFormat:@"Connect failed: %s", strerror(errno)] command:command];
        return;
    }

    struct timeval connectTv = { .tv_sec = 5, .tv_usec = 0 };
    fd_set writeSet;
    FD_ZERO(&writeSet);
    FD_SET(sock, &writeSet);

    int selResult = select(sock + 1, NULL, &writeSet, NULL, &connectTv);
    if (selResult <= 0) {
        close(sock);
        [self sendTcpError:@"Connect timed out" command:command];
        return;
    }

    int soError = 0;
    socklen_t soErrorLen = sizeof(soError);
    getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen);
    if (soError != 0) {
        close(sock);
        [self sendTcpError:[NSString stringWithFormat:@"Connect failed: %s", strerror(soError)] command:command];
        return;
    }

    // Back to blocking mode for the write/read, with a 15s read timeout (matches
    // socket.setSoTimeout(15000) on Android)
    fcntl(sock, F_SETFL, flags);
    struct timeval readTv = { .tv_sec = 15, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &readTv, sizeof(readTv));

    // 4-byte big-endian length header
    uint32_t imgLen = (uint32_t)imageData.length;
    uint8_t header[4] = {
        (uint8_t)((imgLen >> 24) & 0xFF),
        (uint8_t)((imgLen >> 16) & 0xFF),
        (uint8_t)((imgLen >> 8) & 0xFF),
        (uint8_t)(imgLen & 0xFF)
    };

    if (write(sock, header, 4) != 4) {
        close(sock);
        [self sendTcpError:@"Failed to write length header" command:command];
        return;
    }

    const uint8_t* bytes = (const uint8_t*)imageData.bytes;
    size_t totalSent = 0;
    while (totalSent < imgLen) {
        ssize_t sent = write(sock, bytes + totalSent, imgLen - totalSent);
        if (sent <= 0) {
            close(sock);
            [self sendTcpError:[NSString stringWithFormat:@"Failed to write image bytes: %s", strerror(errno)] command:command];
            return;
        }
        totalSent += sent;
    }

    // Read the ACK line ("IMAGE_RECEIVED\n")
    NSMutableData* ackData = [NSMutableData data];
    char buf[256];
    BOOL gotNewline = NO;
    while (!gotNewline) {
        ssize_t n = read(sock, buf, sizeof(buf));
        if (n <= 0) {
            break;
        }
        for (ssize_t i = 0; i < n; i++) {
            if (buf[i] == '\n') {
                gotNewline = YES;
                break;
            }
            [ackData appendBytes:&buf[i] length:1];
        }
    }

    close(sock);

    NSString* ack = [[NSString alloc] initWithData:ackData encoding:NSUTF8StringEncoding] ?: @"";
    ack = [ack stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    CDVPluginResult* res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:ack];
    [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
}

- (NSString*)getWiFiAddress {
    NSString *address = @"127.0.0.1";
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        struct ifaddrs *best = ms_best_interface(interfaces);
        if (best != NULL) {
            address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)best->ifa_addr)->sin_addr)];
            NSLog(@"[LocalWebserver] address from %s: %@", best->ifa_name, address);
        }
        freeifaddrs(interfaces);
    }
    return address;
}

// The subnet-directed broadcast address for the WiFi interface (e.g. 192.168.1.255 for a
// 192.168.1.x/24 network), computed as (ip & netmask) | ~netmask. Used instead of the "limited
// broadcast" address 255.255.255.255 for RealBoard discovery - iOS/macOS frequently has no route
// for 255.255.255.255 at all (even from a bound socket), while the directed broadcast address
// corresponds to a real local-subnet route through the interface and reliably works.
- (NSString*)getWiFiBroadcastAddress {
    NSString *broadcast = nil;
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        // the same interface getWiFiAddress() picks - the discovery socket is bound to that address
        struct ifaddrs *best = ms_best_interface(interfaces);
        if (best != NULL && best->ifa_netmask != NULL) {
            struct in_addr addr = ((struct sockaddr_in *)best->ifa_addr)->sin_addr;
            struct in_addr mask = ((struct sockaddr_in *)best->ifa_netmask)->sin_addr;
            struct in_addr bcast;
            bcast.s_addr = (addr.s_addr & mask.s_addr) | ~mask.s_addr;
            broadcast = [NSString stringWithUTF8String:inet_ntoa(bcast)];
            // inet_ntoa() uses one static buffer - the two addresses in two steps
            NSString* ipTxt = [NSString stringWithUTF8String:inet_ntoa(addr)];
            NSString* maskTxt = [NSString stringWithUTF8String:inet_ntoa(mask)];
            NSLog(@"**RealBoard** [iOS] interface=%s ip=%@ netmask=%@ -> broadcast=%@",
                  best->ifa_name, ipTxt, maskTxt, broadcast);
        }
        freeifaddrs(interfaces);
    }
    return broadcast;
}

@end


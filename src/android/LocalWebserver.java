package com.benkesmith.localwebserver;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import fi.iki.elonen.NanoHTTPD;
import fi.iki.elonen.NanoHTTPD.IHTTPSession;
import fi.iki.elonen.NanoHTTPD.Response;
import fi.iki.elonen.NanoHTTPD.Response.IStatus;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public class LocalWebserver extends CordovaPlugin {

    private NanoHTTPD server;
    private CallbackContext requestCallback;
    private Map<String, HttpRequest> pendingRequests = new ConcurrentHashMap<>();

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {
        switch (action) {
            case "start":
                int port = args.getInt(0);
                startServer(port, callbackContext);
                return true;
            case "stop":
                stopServer(callbackContext);
                return true;
            case "onRequest":
                onRequest(callbackContext);
                return true;
            case "sendResponse":
                String requestId = args.getString(0);
                JSONObject response = args.getJSONObject(1);
                sendResponse(requestId, response, callbackContext);
                return true;
            case "sendTcpImage":
                String tcpIp = args.getString(0);
                int tcpPort = args.getInt(1);
                String base64Image = args.getString(2);
                sendTcpImage(tcpIp, tcpPort, base64Image, callbackContext);
                return true;
            case "discoverBoard":
                discoverBoard(callbackContext);
                return true;
            default:
                return false;
        }
    }

    // UDP discovery of a RealBoard on the local network - broadcasts "DRAWING_APP_DISCOVERY" on
    // port 8889 and waits (2s) for a unicast "DRAWING_APP_SERVER:<tcpPort>" reply. See
    // docs/RealBoard_WiFi_Protocol.md §3. Known to be unreliable on some phone hotspots (broadcast
    // doesn't always propagate) - callers should fall back to a manually-entered IP on failure.
    private static final int REALBOARD_DISCOVERY_PORT = 8889;
    private static final String REALBOARD_DISCOVERY_MESSAGE = "DRAWING_APP_DISCOVERY";
    private static final String REALBOARD_SERVER_IDENTIFIER = "DRAWING_APP_SERVER";

    private void discoverBoard(final CallbackContext callback) {
        cordova.getThreadPool().execute(new Runnable() {
            @Override
            public void run() {
                java.net.DatagramSocket socket = null;
                try {
                    socket = new java.net.DatagramSocket();
                    socket.setBroadcast(true);
                    socket.setReuseAddress(true);
                    socket.setSoTimeout(2000);

                    byte[] sendData = REALBOARD_DISCOVERY_MESSAGE.getBytes("UTF-8");
                    java.net.DatagramPacket sendPacket = new java.net.DatagramPacket(
                            sendData, sendData.length,
                            java.net.InetAddress.getByName("255.255.255.255"), REALBOARD_DISCOVERY_PORT);
                    socket.send(sendPacket);

                    byte[] recvBuf = new byte[1024];
                    java.net.DatagramPacket recvPacket = new java.net.DatagramPacket(recvBuf, recvBuf.length);
                    socket.receive(recvPacket);

                    String reply = new String(recvPacket.getData(), 0, recvPacket.getLength(), "UTF-8");
                    String[] parts = reply.split(":");
                    if (parts.length == 2 && parts[0].equals(REALBOARD_SERVER_IDENTIFIER)) {
                        JSONObject result = new JSONObject();
                        result.put("ip", recvPacket.getAddress().getHostAddress());
                        result.put("port", Integer.parseInt(parts[1].trim()));
                        callback.success(result);
                    } else {
                        callback.error("Unexpected discovery reply: " + reply);
                    }
                } catch (java.net.SocketTimeoutException e) {
                    callback.error("Discovery timed out - no board responded");
                } catch (Exception e) {
                    callback.error("Discovery failed: " + e.getMessage());
                } finally {
                    if (socket != null) socket.close();
                }
            }
        });
    }

    // Outbound raw TCP client (not the NanoHTTPD server above): connects out to a device
    // speaking the RealBoard wire protocol - 4-byte big-endian length header, then the raw
    // JPEG bytes, then a single ACK text line ("IMAGE_RECEIVED\n") read back on the same
    // socket. See docs/RealBoard_WiFi_Protocol.md. Runs off the WebView thread since it's
    // blocking network I/O.
    private void sendTcpImage(final String ip, final int port, final String base64Image, final CallbackContext callback) {
        cordova.getThreadPool().execute(new Runnable() {
            @Override
            public void run() {
                java.net.Socket socket = null;
                try {
                    byte[] imageBytes = android.util.Base64.decode(base64Image, android.util.Base64.NO_WRAP);

                    socket = new java.net.Socket();
                    socket.connect(new java.net.InetSocketAddress(ip, port), 5000);
                    socket.setSoTimeout(15000);

                    java.io.DataOutputStream out = new java.io.DataOutputStream(socket.getOutputStream());
                    out.writeInt(imageBytes.length);
                    out.write(imageBytes);
                    out.flush();

                    java.io.BufferedReader in = new java.io.BufferedReader(
                            new java.io.InputStreamReader(socket.getInputStream(), "UTF-8"));
                    String ack = in.readLine();

                    callback.success(ack != null ? ack : "");
                } catch (Exception e) {
                    callback.error("TCP send failed: " + e.getMessage());
                } finally {
                    if (socket != null) {
                        try { socket.close(); } catch (Exception ignored) {}
                    }
                }
            }
        });
    }

    private void startServer(int port, CallbackContext callback) {
        try {
            server = new NanoHTTPD(port) {
                @Override
                public Response serve(IHTTPSession session) {
                    String id = UUID.randomUUID().toString();
                    HttpRequest req = new HttpRequest(session, id);
                    pendingRequests.put(id, req);

                    if (requestCallback != null) {
                        try {
                            PluginResult result = new PluginResult(PluginResult.Status.OK, req.toJSON());
                            result.setKeepCallback(true);
                            requestCallback.sendPluginResult(result);
                        } catch (JSONException e) {
                            e.printStackTrace();
                        }
                    }

                    try {
                        boolean gotResponse = req.latch.await(30, TimeUnit.SECONDS);
                        if (gotResponse) {
                            IStatus status = req.responseStatus != null ? req.responseStatus : Response.Status.OK;
                            String mime = (req.responseHeaders != null && req.responseHeaders.has("Content-Type"))
                                    ? req.responseHeaders.optString("Content-Type")
                                    : "text/plain";
                            return NanoHTTPD.newFixedLengthResponse(status, mime, req.responseBody != null ? req.responseBody : "");
                        } else {
                            return NanoHTTPD.newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "Timeout");
                        }
                    } catch (InterruptedException e) {
                        return NanoHTTPD.newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", e.getMessage());
                    }
                }
            };
            server.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false);

            String ip = getLocalIpAddress();
            callback.success(ip + ":" + port);
        } catch (IOException e) {
            callback.error("Failed to start server: " + e.getMessage());
        }
    }

    private void stopServer(CallbackContext callback) {
        if (server != null) {
            server.stop();
            pendingRequests.clear();
            callback.success("Server stopped");
        } else {
            callback.error("Server not running");
        }
    }

    private void onRequest(CallbackContext callback) {
        this.requestCallback = callback;
        PluginResult result = new PluginResult(PluginResult.Status.NO_RESULT);
        result.setKeepCallback(true);
        callback.sendPluginResult(result);
    }

    private void sendResponse(String requestId, JSONObject response, CallbackContext callback) {
        HttpRequest req = pendingRequests.remove(requestId);
        if (req != null) {
            try {
                req.responseStatus = Response.Status.lookup(response.getInt("status"));
                req.responseHeaders = response.optJSONObject("headers");
                req.responseBody = response.optString("body");
                req.latch.countDown();
                callback.success("Response sent for " + requestId);
            } catch (JSONException e) {
                callback.error("Invalid response JSON: " + e.getMessage());
            }
        } else {
            callback.error("Invalid requestId: " + requestId);
        }
    }

    private static class HttpRequest {
        final IHTTPSession session;
        final String id;
        final CountDownLatch latch = new CountDownLatch(1);
        IStatus responseStatus;
        JSONObject responseHeaders;
        String responseBody;

        HttpRequest(IHTTPSession session, String id) {
            this.session = session;
            this.id = id;
        }

        JSONObject toJSON() throws JSONException {
            NanoHTTPD.Method method = session.getMethod();
            String bodyString = "";
            if (NanoHTTPD.Method.POST.equals(method) || NanoHTTPD.Method.PUT.equals(method)) {
                try {
                    Map<String, String> body = new HashMap<>();
                    session.parseBody(body);

                    // Check for raw body content
                    bodyString = body.get("postData");
                    if (bodyString == null) {
                        bodyString = ""; // fallback
                    }
                } catch (Exception e) {
                    bodyString = "";
                }
            }
            JSONObject obj = new JSONObject();
            obj.put("requestId", id);
            obj.put("headers", session.getHeaders());
            obj.put("address", session.getRemoteIpAddress());
            obj.put("method", session.getMethod().name());
            obj.put("path", session.getUri());
            obj.put("query", session.getQueryParameterString());
            obj.put("body", bodyString);
            return obj;
        }
    }

    // Which network interface the server's address comes from: wlan* (Wi-Fi) first, then this phone's
    // own hotspot (swlan* / ap* / softap* - the other phones join it over Wi-Fi). NEVER cellular
    // (rmnet* / ccmni* ...), VPN or anything else: other phones can't reach those. -1 = not a candidate.
    // Taking the FIRST non-loopback address returned the cellular one while the phone was on Wi-Fi
    // (rmnet_data* is usually listed before wlan0).
    private int interfacePriority(java.net.NetworkInterface intf) {
        String name = intf.getName() != null ? intf.getName().toLowerCase() : "";
        if (name.startsWith("wlan")) return 0;
        if (name.startsWith("swlan") || name.startsWith("ap") || name.startsWith("softap")) return 1;
        return -1;
    }

    // The Wi-Fi (or own hotspot) address; 127.0.0.1 if there is none - the app then shows
    // "please connect to a Wi-Fi network" instead of an address (websocket.js).
    private String getLocalIpAddress() {
        String best = "127.0.0.1";
        int bestPriority = 99;
        try {
            for (java.util.Enumeration<java.net.NetworkInterface> en = java.net.NetworkInterface.getNetworkInterfaces(); en.hasMoreElements();) {
                java.net.NetworkInterface intf = en.nextElement();
                if (!intf.isUp() || intf.isLoopback()) continue;
                int priority = interfacePriority(intf);
                if (priority < 0 || priority >= bestPriority) continue;
                for (java.util.Enumeration<java.net.InetAddress> enumIpAddr = intf.getInetAddresses(); enumIpAddr.hasMoreElements();) {
                    java.net.InetAddress inetAddress = enumIpAddr.nextElement();
                    if (inetAddress instanceof java.net.Inet4Address && !inetAddress.isLinkLocalAddress()) {
                        best = inetAddress.getHostAddress();
                        bestPriority = priority;
                        break;
                    }
                }
            }
        } catch (Exception ex) {
            ex.printStackTrace();
        }
        return best;
    }

}

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
            default:
                return false;
        }
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
                    session.parseBody(new HashMap<>());
                    bodyString = session.getQueryParameterString();
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

    private String getLocalIpAddress() {
        try {
            for (java.util.Enumeration<java.net.NetworkInterface> en = java.net.NetworkInterface.getNetworkInterfaces(); en.hasMoreElements();) {
                java.net.NetworkInterface intf = en.nextElement();
                for (java.util.Enumeration<java.net.InetAddress> enumIpAddr = intf.getInetAddresses(); enumIpAddr.hasMoreElements();) {
                    java.net.InetAddress inetAddress = enumIpAddr.nextElement();
                    if (!inetAddress.isLoopbackAddress() && inetAddress instanceof java.net.Inet4Address) {
                        return inetAddress.getHostAddress();
                    }
                }
            }
        } catch (Exception ex) {
            ex.printStackTrace();
        }
        return "127.0.0.1";
    }

}

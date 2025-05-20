package com.benkesmith.localwebserver;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import fi.iki.elonen.NanoHTTPD;

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
                JSONObject resp = args.getJSONObject(1);
                sendResponse(requestId, resp, callbackContext);
                return true;
            default:
                return false;
        }
    }

    private void startServer(int port, CallbackContext callbackContext) {
        try {
            server = new NanoHTTPD(port) {
                @Override
                public Response serve(IHTTPSession session) {
                    try {
                        String id = UUID.randomUUID().toString();
                        HttpRequest req = new HttpRequest(session, id);
                        pendingRequests.put(id, req);
                        // notify JS
                        if (requestCallback != null) {
                            PluginResult pr = new PluginResult(PluginResult.Status.OK, req.toJSON());
                            pr.setKeepCallback(true);
                            requestCallback.sendPluginResult(pr);
                        }
                        // wait for JS response
                        if (req.latch.await(30, TimeUnit.SECONDS)) {
                            return NanoHTTPD.newFixedLengthResponse(
                                req.responseStatus,
                                req.responseHeaders.optString("Content-Type", "text/plain"),
                                req.responseBody
                            );
                        } else {
                            return NanoHTTPD.newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "Timeout");
                        }
                    } catch (Exception e) {
                        return NanoHTTPD.newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", e.getMessage());
                    }
                }
            };
            server.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false);
            callbackContext.success("Server started on port " + port);
        } catch (Exception e) {
            callbackContext.error(e.getMessage());
        }
    }

    private void stopServer(CallbackContext callbackContext) {
        if (server != null) {
            server.stop();
            pendingRequests.clear();
            callbackContext.success("Server stopped");
        } else {
            callbackContext.error("Server not running");
        }
    }

    private void onRequest(CallbackContext callbackContext) {
        this.requestCallback = callbackContext;
        PluginResult result = new PluginResult(PluginResult.Status.NO_RESULT);
        result.setKeepCallback(true);
        callbackContext.sendPluginResult(result);
    }

    private void sendResponse(String requestId, JSONObject response, CallbackContext callbackContext) {
        HttpRequest req = pendingRequests.remove(requestId);
        if (req != null) {
            try {
                req.responseStatus = Response.Status.lookup(response.getInt("status"));
                req.responseHeaders = response.optJSONObject("headers");
                req.responseBody = response.getString("body");
                req.latch.countDown();
                callbackContext.success("Response sent for " + requestId);
            } catch (Exception e) {
                callbackContext.error(e.getMessage());
            }
        } else {
            callbackContext.error("Invalid requestId");
        }
    }

    private static class HttpRequest {
        final IHTTPSession session;
        final String id;
        final CountDownLatch latch = new CountDownLatch(1);
        int responseStatus;
        JSONObject responseHeaders;
        String responseBody;

        HttpRequest(IHTTPSession session, String id) {
            this.session = session;
            this.id = id;
        }

        JSONObject toJSON() throws JSONException {
            JSONObject obj = new JSONObject();
            obj.put("requestId", id);
            obj.put("method", session.getMethod().name());
            obj.put("path", session.getUri());
            obj.put("query", session.getQueryParameterString());
            return obj;
        }
    }
}

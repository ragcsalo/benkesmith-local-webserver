# benkesmith-local-webserver

A lightweight, multiplatform Cordova plugin that lets your mobile app run a local HTTP server entirely offline, useful for inter-app communication or talking to local companion devices (e.g. a watch).

Inspired by `cordova-plugin-webserver`, but with minimal dependencies and direct Objective-C/Java code — no CocoaPods or Swift required.

## Plugin ID
```
com.benkesmith.localwebserver
```

## Installation

```
cordova plugin add https://github.com/ragcsalo/benkesmith-local-webserver
```

### Optional: Allow file URL access in WebView

To enable your local webserver to access files via `file://` and `http://localhost`, you may need to patch the `WebView` settings in your `MainActivity.java`.

Add the following method to your `MainActivity` class:

```java
@Override
protected void onStart() {
    super.onStart();

    if (this.appView != null) {
        WebView webView = (WebView) this.appView.getView();
        webView.getSettings().setAllowUniversalAccessFromFileURLs(true);
        webView.getSettings().setAllowFileAccessFromFileURLs(true);
        Log.d("LocalWebserver", "WebView settings patched");
    } else {
        Log.w("LocalWebserver", "appView is null in onStart()");
    }
}

## API

### `LocalWebserver.start(port, success, error)`
Starts the local HTTP server on the specified port.

```js
LocalWebserver.start(8069, () => {
  console.log("Server started");
}, console.error);
```

### `LocalWebserver.stop(success, error)`
Stops the local HTTP server.

```js
LocalWebserver.stop(() => {
  console.log("Server stopped");
}, console.error);
```

### `LocalWebserver.onRequest(callback)`
Sets up a listener for incoming HTTP requests.

```js
LocalWebserver.onRequest(function (request) {
  console.log("Received request:", request);

  LocalWebserver.sendResponse(request.requestId, {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ success: true })
  });
});
```

Request object format:

```json
{
  "requestId": "abc123",
  "method": "GET",
  "path": "/hello",
  "query": "a=1&b=2",
  "body": "...",
  "headers": {...}
}
```

### `LocalWebserver.sendResponse(requestId, responseObj, success, error)`
Sends a response to a pending request.

```js
LocalWebserver.sendResponse(requestId, {
  status: 200,
  headers: {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*"
  },
  body: JSON.stringify({ success: true })
}, success, error);
```

Response object:

```json
{
  "status": 200,
  "body": "string or JSON",
  "headers": {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*"
  }
}
```

## Supported Platforms

- Android (Java)
- iOS (Objective-C)

## License

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Author

Benke Smith (https://github.com/ragcsalo)

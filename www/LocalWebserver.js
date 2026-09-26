var exec = require('cordova/exec');

var LocalWebserver = {
  start: function (port, successCallback, errorCallback) {
    exec(successCallback, errorCallback, 'LocalWebserver', 'start', [port]);
  },

  stop: function (successCallback, errorCallback) {
    exec(successCallback, errorCallback, 'LocalWebserver', 'stop', []);
  },

  onRequest: function (callback) {
    exec(callback, null, 'LocalWebserver', 'onRequest', []);
  },

  sendResponse: function (requestId, response, successCallback, errorCallback) {
    exec(successCallback, errorCallback, 'LocalWebserver', 'sendResponse', [requestId, response]);
  },

  sendTcpImage: function (ip, port, base64Image, successCallback, errorCallback) {
    exec(successCallback, errorCallback, 'LocalWebserver', 'sendTcpImage', [ip, port, base64Image]);
  },

  discoverBoard: function (successCallback, errorCallback) {
    exec(successCallback, errorCallback, 'LocalWebserver', 'discoverBoard', []);
  }
};

module.exports = LocalWebserver;

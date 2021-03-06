// Generated by LiveScript 1.5.0
/**
 * @package WebTorrent DHT
 * @author  Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @license 0BSD
 */
(function(){
  var bencode, debug, ref$, EventEmitter, http, inherits, isIP, fetch, simplePeer, wrtc, PEER_CONNECTION_TIMEOUT, SIMPLE_PEER_OPTS, x$, slice$ = [].slice, arrayFrom$ = Array.from || function(x){return slice$.call(x);};
  bencode = require('bencode');
  debug = (typeof (ref$ = require('debug')) == 'function' ? ref$('webtorrent-dht') : void 8) || function(){};
  EventEmitter = require('events').EventEmitter;
  http = require('http');
  inherits = require('inherits');
  isIP = require('isipaddress').test;
  fetch = require('node-fetch');
  simplePeer = require('simple-peer');
  wrtc = require('wrtc');
  module.exports = webrtcSocket;
  PEER_CONNECTION_TIMEOUT = 30;
  SIMPLE_PEER_OPTS = {
    trickle: false,
    wrtc: wrtc
  };
  /**
   * WebRTC socket implements a minimal subset of `dgram` interface necessary for `k-rpc-socket` while using WebRTC as transport layer instead of UDP
   *
   * @constructor
   */
  function webrtcSocket(options){
    options == null && (options = {});
    if (!(this instanceof webrtcSocket)) {
      return new webrtcSocket(options);
    }
    this._peer_connection_timeout = (options.peer_connection_timeout || PEER_CONNECTION_TIMEOUT) * 1000;
    this._simple_peer_opts = Object.assign({}, SIMPLE_PEER_OPTS, options.simple_peer_opts);
    this._simple_peer_constructor = options.simple_peer_constructor || simplePeer;
    this._http_address = options.http_address;
    this._extensions = options.extensions || [];
    this._peer_connections = {};
    this._all_peer_connections = new Set;
    this._http_connections_aliases = {};
    this._pending_peer_connections = {};
    this._connections_id_mapping = {};
    EventEmitter.call(this);
  }
  inherits(webrtcSocket, EventEmitter);
  x$ = webrtcSocket.prototype;
  x$.address = function(){
    if (this.http_server) {
      return this._http_address;
    } else {
      throw new Error('HTTP server is not running yet');
    }
  };
  x$.bind = function(port, address, callback){
    var x$, this$ = this;
    if (!port || !address || port instanceof Function || address instanceof Function) {
      throw 'Both address and port are required for listen call';
    }
    this.http_server = http.createServer(function(request, response){
      var body;
      if (request.method !== 'POST') {
        response.writeHead(400);
        response.end();
        return;
      }
      body = '';
      request.on('data', function(chunk){
        body += chunk;
      }).on('end', function(){
        var x$, e;
        try {
          x$ = this$._prepare_connection(false);
          x$.once('signal', function(signal){
            debug('got signal for HTTP (server): %s', signal);
            signal.extensions = this$._extensions;
            signal = JSON.stringify(signal);
            if (!response.finished) {
              response.setHeader('Access-Control-Allow-Origin', '*');
              response.write(signal);
              response.end();
            }
          });
          x$.once('connect', function(){
            if (!response.finished) {
              response.writeHead(500);
              response.end();
            }
          });
          x$.once('close', function(){
            if (!response.finished) {
              response.writeHead(500);
              response.end();
            }
          });
          x$.signal(JSON.parse(body));
        } catch (e$) {
          e = e$;
          response.writeHead(400);
          response.end();
        }
      }).setEncoding('utf8');
    });
    x$ = this.http_server;
    x$.listen(port, address, function(){
      debug('listening for HTTP connections on %s:%d', address, port);
      if (!this$._http_address) {
        this$._http_address = {
          address: address,
          port: port
        };
      }
      this$.emit('listening');
      if (typeof callback == 'function') {
        callback();
      }
    });
    x$.on('error', function(e){
      this$.emit('error', e);
    });
  };
  x$.close = function(){
    this._all_peer_connections.forEach(function(peer){
      peer.destroy();
    });
    if (this.http_server) {
      this.http_server.close();
    }
  };
  x$.send = function(buffer, offset, length, port, address, callback){
    var peer_connection, this$ = this;
    if (this._peer_connections[address + ":" + port]) {
      this._peer_connections[address + ":" + port].send(buffer);
      callback();
    } else if (this._http_connections_aliases[address + ":" + port]) {
      peer_connection = this._http_connections_aliases[address + ":" + port];
      this.emit('update_http_request_peer', address, port, {
        host: peer_connection.remoteAddress,
        port: peer_connection.remotePort
      });
      peer_connection.send(buffer);
      callback();
    } else if (this._pending_peer_connections[address + ":" + port]) {
      this._pending_peer_connections[address + ":" + port].then(function(peer){
        this$.send(buffer, offset, length, port, address, callback);
      })['catch'](function(){});
    } else {
      this._pending_peer_connections[address + ":" + port] = new Promise(function(resolve, reject){
        var x$, peer_connection, timeout;
        x$ = peer_connection = this$._prepare_connection(true);
        x$.once('signal', function(signal){
          var init;
          debug('got signal for HTTP (client): %s', signal);
          signal.extensions = this$._extensions;
          init = {
            method: 'POST',
            body: JSON.stringify(signal)
          };
          fetch("https://" + address + ":" + port, init)['catch'](function(e){
            if (typeof location === 'undefined' || location.protocol === 'http:') {
              return fetch("http://" + address + ":" + port, init);
            } else {
              throw e;
            }
          }).then(function(response){
            return response.json();
          }).then(function(signal){
            if (peer_connection.destroyed) {
              reject();
              return;
            }
            peer_connection.signal(signal);
          })['catch'](function(e){
            reject();
            this$.emit('error', e);
          });
        });
        x$.once('connect', function(){
          var remote_peer_info;
          remote_peer_info = {
            address: peer_connection.remoteAddress,
            port: peer_connection.remotePort
          };
          this$._register_http_connection_alias(remote_peer_info.address, remote_peer_info.port, address, port);
          if (peer_connection.destroyed) {
            reject();
            return;
          }
          this$.send(buffer, offset, length, port, address, callback);
          delete this$._pending_peer_connections[address + ":" + port];
          resolve(remote_peer_info);
        });
        x$.once('close', function(){
          clearTimeout(timeout);
        });
        timeout = setTimeout(function(){
          delete this$._pending_peer_connections[address + ":" + port];
          if (!peer_connection.connected) {
            reject();
          }
        }, this$._peer_connection_timeout);
      });
      this._pending_peer_connections[address + ":" + port]['catch'](function(){});
    }
  };
  /**
   * @param {boolean} initiator
   *
   * @return {SimplePeer}
   */
  x$._prepare_connection = function(initiator){
    var x$, peer_connection, timeout, this$ = this;
    debug('prepare connection, initiator: %s', initiator);
    x$ = peer_connection = this._simple_peer_constructor(Object.assign({}, this._simple_peer_opts, {
      initiator: initiator
    }));
    x$.once('connect', function(){
      var address, data;
      debug('peer connected: %s:%d', peer_connection.remoteAddress, peer_connection.remotePort);
      this$._register_connection(peer_connection);
      if (this$.http_server) {
        address = this$.address();
        data = JSON.stringify({
          http_server: {
            host: address.address,
            port: address.port
          }
        });
        this$.send(Buffer.from(data), 0, data.length, peer_connection.remotePort, peer_connection.remoteAddress, function(){});
      }
      peer_connection.once('close', function(){
        debug('peer disconnected: %s:%d', peer_connection.remoteAddress, peer_connection.remotePort);
      });
    });
    x$.on('data', function(data){
      var data_decoded;
      if (debug.enabled) {
        debug('got data: %o, %s', data, data.toString());
      }
      if (data instanceof Uint8Array) {
        data = Buffer.from(data);
      }
      if (!peer_connection._http_info_checked) {
        peer_connection._http_info_checked = true;
        try {
          data_decoded = JSON.parse(data);
          if (data_decoded.http_server) {
            peer_connection.http_server = {
              host: data_decoded.http_server.host.toString(),
              port: data_decoded.http_server.port
            };
            return;
          }
        } catch (e$) {}
      }
      data_decoded = bencode.decode(data);
      if (Buffer.isBuffer(data)) {
        if (peer_connection.connected) {
          this$.emit('message', data, {
            address: peer_connection.remoteAddress,
            port: peer_connection.remotePort
          });
        } else {
          peer_connection.once('connected', function(){
            this$.emit('message', data, {
              address: peer_connection.remoteAddress,
              port: peer_connection.remotePort
            });
          });
        }
      }
    });
    x$.on('error', function(){
      debug('peer error: %o', arguments);
      this$.emit.apply(this$, ['error'].concat(arrayFrom$(arguments)));
    });
    x$.once('close', function(){
      clearTimeout(timeout);
      this$._all_peer_connections['delete'](peer_connection);
    });
    x$.setMaxListeners(0);
    x$.signal = function(signal){
      signal.sdp = String(signal.sdp);
      signal.type = String(signal.type);
      if (signal.extensions) {
        signal.extensions = signal.extensions.map(function(extension){
          return extension + "";
        });
        if (signal.extensions.length) {
          this$.emit('extensions_received', peer_connection, signal.extensions);
        }
      }
      this$._simple_peer_constructor.prototype.signal.call(peer_connection, signal);
    };
    x$._tags = new Set;
    this._all_peer_connections.add(peer_connection);
    timeout = setTimeout(function(){
      if (!peer_connection.connected || !peer_connection._tags.size) {
        peer_connection.destroy();
      }
    }, this._peer_connection_timeout);
    return peer_connection;
  };
  /**
   * @param {string}	id
   * @param {!Object}	peer_connection
   */
  x$._add_id_mapping = function(id, peer_connection){
    var ip, port, this$ = this;
    if (!(peer_connection instanceof this._simple_peer_constructor)) {
      ip = peer_connection.host || peer_connection.address;
      port = peer_connection.port;
      if (!this._peer_connections[ip + ":" + port]) {
        debug('bad peer specified for id mapping: %s => %o', id, {
          ip: ip,
          port: port
        });
        return;
      }
      peer_connection = this._peer_connections[ip + ":" + port];
    }
    if (this._connections_id_mapping[id]) {
      if (this._connections_id_mapping[id] !== peer_connection) {
        peer_connection.destroy();
      }
      return;
    }
    this._connections_id_mapping[id] = peer_connection;
    peer_connection.id = id;
    peer_connection.once('close', function(){
      this$._del_id_mapping(id);
    });
    this.emit('node_connected', id);
  };
  /**
   * @param {string} id
   */
  x$._del_id_mapping = function(id){
    var peer_connection;
    if (!this._connections_id_mapping[id]) {
      return;
    }
    peer_connection = this._connections_id_mapping[id];
    if (peer_connection._tags.size && !peer_connection.destroyed) {
      return;
    }
    delete this._connections_id_mapping[id];
    if (!peer_connection.destroyed) {
      peer_connection.destroy();
    }
    this.emit('node_disconnected', id);
  };
  /**
   * @param {string} id
   *
   * @return {SimplePeer}
   */
  x$.get_id_mapping = function(id){
    return this._connections_id_mapping[id];
  };
  /**
   * @param {string} id
   * @param {string} tag
   */
  x$.add_tag = function(id, tag){
    var peer_connection;
    peer_connection = this.get_id_mapping(id);
    if (peer_connection) {
      peer_connection._tags.add(tag);
    }
  };
  /**
   * @param {string} id
   * @param {string} tag
   */
  x$.del_tag = function(id, tag){
    var peer_connection;
    if (!this._connections_id_mapping[id]) {
      return;
    }
    peer_connection = this._connections_id_mapping[id];
    peer_connection._tags['delete'](tag);
    this._del_id_mapping(id);
  };
  x$.known_http_servers = function(){
    var peer_connection;
    return (function(){
      var ref$, results$ = [];
      for (peer_connection in ref$ = this._peer_connections) {
        peer_connection = ref$[peer_connection];
        results$.push(peer_connection.http_server);
      }
      return results$;
    }.call(this)).filter(Boolean);
  };
  /**
   * @param {SimplePeer} peer_connection
   */
  x$._register_connection = function(peer_connection){
    var ip, port, this$ = this;
    ip = peer_connection.remoteAddress;
    port = peer_connection.remotePort;
    this._peer_connections[ip + ":" + port] = peer_connection;
    peer_connection.once('close', function(){
      delete this$._peer_connections[ip + ":" + port];
    });
  };
  x$._register_http_connection_alias = function(webrtc_host, webrtc_port, http_host, http_port){
    var peer_connection, this$ = this;
    peer_connection = this._peer_connections[webrtc_host + ":" + webrtc_port];
    this._http_connections_aliases[http_host + ":" + http_port] = peer_connection;
    peer_connection.once('close', function(){
      delete this$._http_connections_aliases[http_host + ":" + http_port];
    });
    this.emit('http_peer_connection_alias', http_host, http_port, peer_connection);
  };
}).call(this);

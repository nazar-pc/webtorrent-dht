// Generated by LiveScript 1.5.0
/**
 * @package   WebTorrent DHT
 * @author    Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @copyright Copyright (c) 2017, Nazar Mokrynskyi
 * @license   MIT License, see license.txt
 */
(function(){
  var bencode, debug, EventEmitter, inherits, simplePeer, wrtc, ws, PEER_CONNECTION_TIMEOUT, SIMPLE_PEER_OPTS, x$, slice$ = [].slice;
  bencode = require('bencode');
  debug = require('debug')('webtorrent-dht');
  EventEmitter = require('events').EventEmitter;
  inherits = require('inherits');
  simplePeer = require('simple-peer');
  wrtc = require('wrtc');
  ws = require('ws');
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
    this._ws_address = options.ws_address;
    this._extensions = options.extensions || [];
    this._listeners = [];
    this._peer_connections = {};
    this._all_peer_connections = new Set;
    this._ws_connections_aliases = {};
    this._pending_peer_connections = {};
    this._connections_id_mapping = {};
    EventEmitter.call(this);
  }
  inherits(webrtcSocket, EventEmitter);
  x$ = webrtcSocket.prototype;
  x$.address = function(){
    if (this.ws_server) {
      return this._ws_address;
    } else {
      throw new Error('WebSocket connection is not established yet');
    }
  };
  x$.bind = function(port, address, callback){
    var x$, this$ = this;
    if (!port || !address || port instanceof Function || address instanceof Function) {
      throw 'Both address and port are required for listen call';
    }
    x$ = this.ws_server = new ws.Server({
      port: port
    });
    x$.on('listening', function(){
      debug('listening for WebSocket connections on %s:%d', address, port);
      if (!this$._ws_address) {
        this$._ws_address = {
          address: address,
          port: port
        };
      }
      this$.emit('listening');
      if (typeof callback == 'function') {
        callback();
      }
    });
    x$.on('error', function(){
      this$.emit.apply(this$, ['error'].concat(slice$.call(arguments)));
    });
    x$.on('connection', function(ws_connection){
      var x$, peer_connection, y$, timeout;
      debug('accepted WS connection');
      x$ = peer_connection = this$._prepare_connection(true);
      x$.on('signal', function(signal){
        debug('got signal for WS (server): %s', signal);
        signal.extensions = this$._extensions;
        signal = bencode.encode(signal);
        ws_connection.send(signal);
      });
      x$.on('connect', function(){
        if (ws_connection.readyState === 1) {
          ws_connection.close();
        }
      });
      y$ = ws_connection;
      y$.on('message', function(data){
        var signal, e;
        try {
          signal = bencode.decode(data);
          debug('got signal message from WS (server): %s', signal);
          peer_connection.signal(signal);
        } catch (e$) {
          e = e$;
          this$.emit('error', e);
          ws_connection.close();
        }
      });
      y$.on('close', function(){
        clearTimeout(timeout);
      });
      timeout = setTimeout(function(){
        ws_connection.close();
      }, this$._peer_connection_timeout);
    });
  };
  x$.close = function(){
    this._all_peer_connections.forEach(function(peer){
      peer.destroy();
    });
    if (this.ws_server) {
      this.ws_server.close();
    }
  };
  x$.send = function(buffer, offset, length, port, address, callback){
    var this$ = this;
    if (this._peer_connections[address + ":" + port]) {
      this._peer_connections[address + ":" + port].send(buffer);
      callback();
    } else if (this._ws_connections_aliases[address + ":" + port]) {
      this._ws_connections_aliases[address + ":" + port].send(buffer);
      callback();
    } else if (this._pending_peer_connections[address + ":" + port]) {
      this._pending_peer_connections[address + ":" + port].then(function(peer){
        this$.send(buffer, offset, length, port, address, callback);
      })['catch'](function(){});
    } else {
      this._pending_peer_connections[address + ":" + port] = new Promise(function(resolve, reject){
        (function(WebSocket){
          var x$, ws_connection, this$ = this;
          x$ = ws_connection = new WebSocket("ws://" + address + ":" + port);
          x$.binaryType = 'arraybuffer';
          x$.onerror = function(e){
            reject();
            this$.emit('error', e);
          };
          x$.onclose = function(){
            debug('closed WS connection');
          };
          x$.onopen = function(){
            var x$, peer_connection, timeout;
            debug('opened WS connection');
            x$ = peer_connection = this$._prepare_connection(false);
            x$.on('signal', function(signal){
              debug('got signal for WS (client): %s', signal);
              signal.extensions = this$._extensions;
              signal = bencode.encode(signal);
              ws_connection.send(signal);
            });
            x$.on('connect', function(){
              var remote_peer_info;
              if (ws_connection.readyState === 1) {
                ws_connection.close();
              }
              remote_peer_info = {
                address: peer_connection.remoteAddress,
                port: peer_connection.remotePort
              };
              this$._register_ws_connection_alias(remote_peer_info.address, remote_peer_info.port, address, port);
              if (peer_connection.destroyed) {
                reject();
                return;
              }
              this$.send(buffer, offset, length, remote_peer_info.port, remote_peer_info.address, callback);
              resolve(remote_peer_info);
            });
            x$.on('close', function(){
              clearTimeout(timeout);
            });
            ws_connection.onmessage = function(arg$){
              var data, signal, e;
              data = arg$.data;
              try {
                signal = bencode.decode(data);
                debug('got signal message from WS (client): %s', signal);
                peer_connection.signal(signal);
              } catch (e$) {
                e = e$;
                this$.emit('error', e);
                ws_connection.close();
              }
            };
            timeout = setTimeout(function(){
              ws_connection.close();
              delete this$._pending_peer_connections[address + ":" + port];
              if (!peer_connection.connected) {
                reject();
              }
            }, this$._peer_connection_timeout);
          };
        }.call(this$, typeof WebSocket !== 'undefined' ? WebSocket : ws));
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
    var timeout, x$, peer_connection, this$ = this;
    debug('prepare connection, initiator: %s', initiator);
    timeout = setTimeout(function(){
      if (!peer_connection.connected || !peer_connection._tags.size) {
        peer_connection.destroy();
      }
    }, this._peer_connection_timeout);
    x$ = peer_connection = this._simple_peer_constructor(Object.assign({}, this._simple_peer_opts, {
      initiator: initiator
    }));
    x$.on('connect', function(){
      var address, data;
      debug('peer connected: %s:%d', peer_connection.remoteAddress, peer_connection.remotePort);
      this$._register_connection(peer_connection);
      if (this$.ws_server) {
        address = this$.address();
        data = bencode.encode({
          ws_server: {
            host: address.address,
            port: address.port
          }
        });
        this$.send(Buffer.from(data), 0, data.length, peer_connection.remotePort, peer_connection.remoteAddress, function(){});
      }
      peer_connection.on('close', function(){
        debug('peer disconnected: %s:%d', peer_connection.remoteAddress, peer_connection.remotePort);
      });
    });
    x$.on('data', function(data){
      var data_decoded;
      if (debug.enabled) {
        debug('got data: %o, %s', data, data.toString());
      }
      if (!peer_connection._ws_info_checked) {
        peer_connection._ws_info_checked = true;
        try {
          data_decoded = bencode.decode(data);
          if (data_decoded.ws_server) {
            peer_connection.ws_server = {
              host: data_decoded.ws_server.host.toString(),
              port: data_decoded.ws_server.port
            };
            return;
          }
        } catch (e$) {}
      }
      if (Buffer.isBuffer(data)) {
        this$.emit('message', data, {
          address: peer_connection.remoteAddress,
          port: peer_connection.remotePort
        });
      }
    });
    x$.on('error', function(){
      debug('peer error: %o', arguments);
      this$.emit.apply(this$, ['error'].concat(slice$.call(arguments)));
    });
    x$.on('close', function(){
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
    return peer_connection;
  };
  /**
   * @param {string}	id
   * @param {!Object}	peer_connection
   */
  x$._add_id_mapping = function(id, peer_connection){
    var ip, port, this$ = this;
    if (!(peer_connection instanceof simplePeer)) {
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
    peer_connection.on('close', function(){
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
    if (peer_connection._tags.size) {
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
  x$.known_ws_servers = function(){
    var peer_connection;
    return (function(){
      var ref$, results$ = [];
      for (peer_connection in ref$ = this._peer_connections) {
        peer_connection = ref$[peer_connection];
        results$.push(peer_connection.ws_server);
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
    peer_connection.on('close', function(){
      delete this$._peer_connections[ip + ":" + port];
    });
  };
  x$._register_ws_connection_alias = function(webrtc_host, webrtc_port, websocket_host, websocket_port){
    var peer_connection, this$ = this;
    peer_connection = this._peer_connections[webrtc_host + ":" + webrtc_port];
    this._ws_connections_aliases[websocket_host + ":" + websocket_port] = peer_connection;
    peer_connection.on('close', function(){
      delete this$._ws_connections_aliases[websocket_host + ":" + websocket_port];
    });
    this.emit('websocket_peer_connection_alias', websocket_host, websocket_port, peer_connection);
  };
}).call(this);

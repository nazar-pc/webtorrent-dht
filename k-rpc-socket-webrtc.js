// Generated by LiveScript 1.5.0
/**
 * @package WebTorrent DHT
 * @author  Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @license 0BSD
 */
(function(){
  var debug, inherits, isIP, kRpcSocket, webrtcSocket, noop, x$, slice$ = [].slice;
  debug = require('debug')('webtorrent-dht');
  inherits = require('inherits');
  isIP = require('isipaddress').test;
  kRpcSocket = require('k-rpc-socket');
  webrtcSocket = require('./webrtc-socket');
  module.exports = kRpcSocketWebrtc;
  noop = function(){};
  function parse_nodes(buffer, id_length){
    var nodes, res$, i$, step$, to$, i;
    res$ = [];
    for (i$ = 0, to$ = buffer.length, step$ = id_length + 6; step$ < 0 ? i$ > to$ : i$ < to$; i$ += step$) {
      i = i$;
      res$.push(parse_node(buffer.slice(i, i + id_length + 6), id_length));
    }
    nodes = res$;
    return nodes.filter(Boolean);
  }
  function parse_node(buffer, id_length){
    var id, ref$, host, port;
    id = buffer.slice(0, id_length);
    ref$ = parse_info(buffer.slice(id_length, id_length + 6)), host = ref$.host, port = ref$.port;
    return {
      id: id,
      host: host,
      port: port
    };
  }
  function parse_info(buffer){
    var host, port;
    host = buffer[0] + '.' + buffer[1] + '.' + buffer[2] + '.' + buffer[3];
    port = buffer.readUInt16BE(4);
    return {
      host: host,
      port: port
    };
  }
  /**
   * @param {Buffer}	id
   * @param {string}	ip
   * @param {number}	port
   *
   * @return {Buffer}
   */
  function encode_node(id, ip, port){
    var info;
    id = Buffer.from(id);
    info = encode_info(ip, port);
    return Buffer.concat([id, info]);
  }
  /**
   * @param {string}	ip
   * @param {number}	port
   *
   * @return {Buffer}
   */
  function encode_info(ip, port){
    var x$;
    ip = Buffer.from(ip.split('.').map(function(octet){
      return parseInt(octet, 10);
    }));
    port = (x$ = Buffer.alloc(2), x$.writeUInt16BE(port), x$);
    return Buffer.concat([ip, port]);
  }
  /**
   * k-rpc-socket modified to work with WebRTC
   *
   * @constructor
   */
  function kRpcSocketWebrtc(options){
    var this$ = this;
    options == null && (options = {});
    if (!(this instanceof kRpcSocketWebrtc)) {
      return new kRpcSocketWebrtc(options);
    }
    options = Object.assign({}, options);
    if (!options.k) {
      throw new Error('k-rpc-socket-webrtc requires options.k to be specified explicitly');
    }
    this._k = options.k;
    if (!options.id) {
      throw new Error('k-rpc-socket-webrtc requires options.id to be specified explicitly');
    }
    if (Buffer.isBuffer(options.id)) {
      this.id = options.id;
    } else {
      this.id = Buffer.from(options.id, 'hex');
    }
    options.socket = options.socket || webrtcSocket(options);
    options.socket.on('update_websocket_request_peer', function(host, port, peer){
      var i$, ref$, len$, request;
      for (i$ = 0, len$ = (ref$ = this$._reqs).length; i$ < len$; ++i$) {
        request = ref$[i$];
        if (request && request.peer.host === host && request.peer.port === port) {
          request.peer = peer;
        }
      }
    });
    options.isIP = isIP;
    this._id_length = options.id.length;
    this._info_length = this._id_length + 6;
    this._extensions = options.extensions || [];
    kRpcSocket.call(this, options);
  }
  /**
   * Multi-level inheritance: k-rpc-socket-webrtc inherits from noop (which will contain additional methods) and noop inherits from k-rpc-socket
   */
  inherits(noop, kRpcSocket);
  inherits(kRpcSocketWebrtc, noop);
  x$ = kRpcSocketWebrtc.prototype;
  x$.send = function(peer, message, callback){
    debug('send to peer: %o', arguments);
    kRpcSocket.prototype.send.call(this, peer, message, callback);
  };
  x$.response = function(peer, query, response, callback){
    var signals, peers, this$ = this;
    debug('response: %o', arguments);
    response = Object.assign({}, response);
    switch (query.q.toString()) {
    case 'find_node':
    case 'get_peers':
    case 'get':
      /**
       * Before sending response we'll send signaling data to selected nodes and will pass signaling data back to querying node so that it can then
       * establish connection if needed
       */
      signals = query.a.signals;
      if (!Array.isArray(signals)) {
        return;
      }
      if (response.nodes) {
        if (response.nodes.length / this._info_length > signals.length) {
          response.nodes = response.nodes.slice(0, signals.length * this._info_length);
        }
        peers = parse_nodes(response.nodes, this._id_length);
      } else if (response.values) {
        if (response.values.length > signals.length) {
          response.values = response.values(0, signals.length);
        }
        peers = response.values.map(parse_info);
      } else {
        kRpcSocket.prototype.response.call(this, peer, query, response, callback);
        break;
      }
      Promise.all((function(){
        var i$, ref$, len$, results$ = [];
        for (i$ = 0, len$ = (ref$ = peers).length; i$ < len$; ++i$) {
          results$.push((fn$.call(this, i$, ref$[i$])));
        }
        return results$;
        function fn$(i, peer){
          var this$ = this;
          return new Promise(function(resolve){
            var signal, query;
            signal = signals[i];
            query = {
              q: 'peer_connection',
              a: {
                id: this$.id,
                signal: signal
              }
            };
            this$.query(peer, query, function(error, response){
              resolve({
                error: error,
                response: response
              });
            });
          });
        }
      }.call(this))).then(function(replies){
        var res$, i$, to$, i, ref$;
        res$ = [];
        for (i$ = 0, to$ = peers.length; i$ < to$; ++i$) {
          i = i$;
          if (replies[i].error) {
            res$.push(null);
          } else {
            res$.push(((ref$ = replies[i].response.r) != null ? ref$.signal : void 8) || null);
          }
        }
        response.signals = res$;
        kRpcSocket.prototype.response.call(this$, peer, query, response, callback);
      });
      break;
    default:
      kRpcSocket.prototype.response.call(this, peer, query, response, callback);
    }
  };
  x$.query = function(peer, query, callback){
    var i, this$ = this;
    debug('query: %o', arguments);
    query = Object.assign({}, query);
    switch (query.q.toString()) {
    case 'find_node':
    case 'get_peers':
    case 'get':
      Promise.all((function(){
        var i$, to$, results$ = [];
        for (i$ = 0, to$ = this._k; i$ < to$; ++i$) {
          i = i$;
          results$.push(new Promise(fn$));
        }
        return results$;
        function fn$(resolve){
          var x$, peer_connection;
          x$ = peer_connection = this$.socket._prepare_connection(true);
          x$.once('signal', function(signal){
            signal.id = this$.id;
            signal.extensions = this$._extensions;
            resolve({
              peer_connection: peer_connection,
              signal: signal
            });
          });
          x$.once('error', function(error){
            resolve(null);
          });
        }
      }.call(this))).then(function(connections){
        var peer_connections, signals, i$, len$, connection;
        connections = connections.filter(Boolean);
        /**
         * Inject signal data for K connections for queried node to pass them to target nodes and get signal data from them, so that we can afterwards
         * establish direct connection to target nodes
         */
        peer_connections = [];
        signals = [];
        for (i$ = 0, len$ = connections.length; i$ < len$; ++i$) {
          connection = connections[i$];
          peer_connections.push(connection.peer_connection);
          signals.push(connection.signal);
        }
        query.a.signals = signals;
        kRpcSocket.prototype.query.call(this$, peer, query, function(error, response){
          var args, res$, i$, to$, host_id;
          res$ = [];
          for (i$ = 2, to$ = arguments.length; i$ < to$; ++i$) {
            res$.push(arguments[i$]);
          }
          args = res$;
          if (!(!error && Array.isArray(response.r.signals))) {
            callback.apply(null, [error, response].concat(slice$.call(args)));
            return;
          }
          /**
           * Use signal data from response to establish connections to target nodes and re-pack nodes using address and port from
           * newly established connection rather than what queried node gave us (also not all connections might be established, so
           * nodes list might be shorter than what queried node returned)
           */
          host_id = query.a.id.toString('hex');
          Promise.all((function(){
            var i$, ref$, len$, results$ = [];
            for (i$ = 0, len$ = (ref$ = response.r.signals).length; i$ < len$; ++i$) {
              results$.push((fn$.call(this, i$, ref$[i$])));
            }
            return results$;
            function fn$(i, signal){
              var signal_id_hex, peer_connection, this$ = this;
              if (signal) {
                signal_id_hex = signal.id.toString('hex');
                if (signal_id_hex === host_id) {
                  return null;
                } else {
                  peer_connection = this.socket.get_id_mapping(signal_id_hex);
                  if (peer_connection) {
                    peer_connections[i].destroy();
                    return encode_info(peer_connection.remoteAddress, peer_connection.remotePort);
                  } else if (!response.r.nodes && !response.r.values) {
                    return null;
                  } else {
                    return new Promise(function(resolve){
                      var peer_connection, x$;
                      peer_connection = peer_connections[i];
                      if (peer_connection.destroyed) {
                        resolve(null);
                        return;
                      }
                      x$ = peer_connection;
                      x$.once('connect', function(){
                        this$.socket._add_id_mapping(signal_id_hex, peer_connection);
                        if (response.r.nodes) {
                          resolve(encode_node(response.r.nodes.slice(i * this$._info_length, i * this$._info_length + this$._id_length), peer_connection.remoteAddress, peer_connection.remotePort));
                        } else if (response.r.values) {
                          resolve(encode_info(peer_connection.remoteAddress, peer_connection.remotePort));
                        }
                      });
                      x$.once('close', function(){
                        resolve(null);
                      });
                      x$.signal(signal);
                    });
                  }
                }
              } else {
                return null;
              }
            }
          }.call(this$))).then(function(peers){
            peers = peers.filter(Boolean);
            if (response.r.nodes) {
              response.r.nodes = Buffer.concat(peers, peers.length * this$._info_length);
            } else if (response.r.values) {
              response.r.values = peers;
            }
            callback.apply(null, [error, response].concat(slice$.call(args)));
          });
        });
      });
      break;
    default:
      kRpcSocket.prototype.query.call(this, peer, query, callback);
    }
  };
  x$.emit = function(event){
    var args, res$, i$, to$, message, peer, ref$, ref1$, ref2$, signal, signal_id_hex, done, x$, peer_connection, ref3$, this$ = this;
    res$ = [];
    for (i$ = 1, to$ = arguments.length; i$ < to$; ++i$) {
      res$.push(arguments[i$]);
    }
    args = res$;
    switch (event) {
    case 'query':
      message = args[0], peer = args[1];
      if ((ref$ = message.a) != null && ref$.id) {
        this.socket._add_id_mapping(message.a.id.toString('hex'), peer);
      }
      switch ((ref1$ = message.q) != null && (typeof ref1$.toString == 'function' && ref1$.toString())) {
      case 'peer_connection':
        if ((ref2$ = message.a) != null && ref2$.signal) {
          signal = message.a.signal;
          signal_id_hex = signal.id.toString('hex');
          if (signal_id_hex === this.id.toString('hex') || this.socket.get_id_mapping(signal_id_hex)) {
            this.response(peer, message, {
              id: this.id,
              signal: {
                id: this.id
              }
            });
          } else {
            done = false;
            x$ = peer_connection = this.socket._prepare_connection(false);
            x$.once('connect', function(){
              this$.socket._add_id_mapping(signal_id_hex, peer_connection);
            });
            x$.once('signal', function(signal){
              if (done) {
                return;
              }
              done = true;
              signal.id = this$.id;
              signal.extensions = this$._extensions;
              this$.response(peer, message, {
                id: this$.id,
                signal: signal
              });
            });
            x$.once('close', function(error){
              if (done) {
                return;
              }
              done = true;
              this$.error(peer, message, [201, error]);
            });
            x$.signal(signal);
          }
        }
        return;
      }
      break;
    case 'response':
      message = args[0], peer = args[1];
      if ((ref3$ = message.r) != null && ref3$.id) {
        this.socket._add_id_mapping(message.r.id.toString('hex'), peer);
      }
    }
    return kRpcSocket.prototype.emit.apply(this, arguments);
  };
}).call(this);

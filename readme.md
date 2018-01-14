# webtorrent-dht
This is an example implementation of something that might become WebTorrent DHT. It is based on BitTorrent DHT and is extended in a way that will work both in Node.js and modern browsers while keeping BitTorrent DHT interface.

This project is WIP and not ready for production use.

## How to use
Assuming you're familiar with [bittorrent-dht](https://github.com/webtorrent/bittorrent-dht) usage is the same with 2 differences: bootstrap nodes are WebSocket nodes and by binding to address and port effectively WebSocket server is started. Everything else is happening under the hood.

Also `K` in WebTorrent DHT defaults to `2`, which is much more reasonable for WebRTC realities.

Additional options specific to WebTorrent DHT are:
* `extensions` - Array of strings with extensions supported by current node
* `simple_peer_opts` - Object as in [simple-peer constructor](https://github.com/feross/simple-peer#peer--new-simplepeeropts), used by `webrtc-socket`
* `simple_peer_constructor` - Custom implementation of `simple-peer`, in case it is necessary
* `ws_address` - Object with keys `address` and `port` that corresponds to running WebSocket server (specify this in case when publicly accessible address/port are different from those where WebSocket server is listening on), used by `webrtc-socket`

There are simple demos in `demo` directory, you can run them in browser and on the server and then use `dht` key on `window` or `global` for DHT queries.

For debugging purposes run on Node as following:
```bash
DEBUG=webtorrent-dht node demo/node-server.js 
```
And set on client `debug` localStorage key as following:
```javascript
localStorage.debug = 'webtorrent-dht'
```

This will output a lot of useful debugging information.

## How it works
This project in composed of 4 components as following:
* `webtorrent-dht` inherits `bittorrent-dht`
* `k-rpc-webrtc` inherits `k-rpc`
* `k-rpc-socket-webrtc` inherits `k-rpc-socket`
* `webrtc-socket` (superset of the subset of `dgram` interface implemented from scratch)

For high level protocol extension description in form of potential BEP take a look at bep.rts file in this repository.

### webtorrent-dht
Uses `k-rpc-webrtc` instance instead of `k-rpc` in constructor.

Patches its `toJSON()` method of `bittorrent-dht` so that `nodes` property of returned object contains WebSockets nodes only. This ensures that bootstrapping will be possible from those nodes in future (WebRTC-only nodes can't be used for this since they require 2-way signaling before connection can be established).

Also `listen()` method is now used to start WebSocket server, but this will be detailed in `webrtc-socket` component.

Other than mentioned changes `webtorrent-dht` API is exactly the same as `bittorrent-dht`.

This is the components exported by this package.

### k-rpc-webrtc
Uses `k-rpc-socket-webrtc` instance instead of `k-rpc-socket` in constructor.

Uses other default bootstrap nodes than `k-rpc`.

Forgets about disconnected nodes as soon as disconnection happens (since we know when this happens exactly).

### k-rpc-socket-webrtc
Uses `socket-webrtc` instance instead of `dgram` in constructor.

Patches `send()` method for logging in debug mode.

Patches `query()` method for `find_node`, `get_peer` and `get` queries by injecting `signals` argument with WebRTC `offer` signaling data before making query and establishes WebRTC connection when response to the query with WebRTC `answer` signaling data is received.
Also each peer in `nodes` and `values` keys from response is updated with IP address and port of the actual established WebRTC connection (since response will contain details of the queried node and those details will likely be slightly different).

Patches `response()` method for `find_node`, `get_peer` and `get` queries by re-sending WebRTC `offer` signaling data to the peers queried node is about to respond with (using `peer_connection` query) and injects `signals` key into the response with WebRTC `answer` signaling data and same number of entries and order as corresponding `nodes` or `values` key.

Patches `emit` method to capture firing `query` event for `peer_connection` query and handles it itself (while not canceling `query` event as such) by consuming WebRTC `offer` signaling data and responding with WebRTC `answer` signaling data.
Also associates nodes IDs with corresponding WebRTC peers connections.

### webrtc-socket
Implements the subset of `dgram` interface (`address`, `bind`, `close`, `emit`, `on` and `send` methods) as used by `k-rpc-socket` (exactly what is used, nothing more) and superset on top of it with features used by `k-rpc-socket-webrtc` and `webtorrent-dht`.

* `address` method returns information about where WebSocket server is listening, object with keys `address` and `port`
* `bind` method starts WebSocket server on specified address and port (both should be specified explicitly)
* `close` method closes all WebRTC connections and stops WebSocket server if it is running
* `emit` method emits an event with arguments
* `on` method adds handler for an event
* `send` method first checks if there is an established WebRTC connection to specified address and port, if not - assumes WebSocket address and port were specified, so that it will establish WebSocket connection, use it for establishing WebRTC connection, will close WebSocket connection and create an alias to use WebRTC connection instead next time

There are a few of public methods exposed by `webrtc-socket`:
* `get_id_mapping(id : string)` - Allows to get `simple-peer` instance by node's ID if connection is already established
* `add_tag(id : string, association : string)` - Allows to tag connection to specified node ID so that connection will not be closed until at least one tag is left
* `del_tag(id : string, association : string)` - Remove tag from connection to specified node ID, if no tags left on connection - it will be closed

There are also a few events exposed by `webrtc-socket`:
* `node_connected` with string argument `id` - Is fired when there is a new connection established
* `node_disconnected` with string argument `id` - Is fired when there is a connection was closed
* `extensions_received` with arguments `peer_connection` (`simple-peer` instance) and an array `extensions` - If fired when extensions are received from the other peer
* `websocket_peer_connection_alias` with arguments `host`, `port` and `peer_connection` - Is fired when peer connection is aliased by websocket host and port (from bootstrap node)

## Contribution
Feel free to create issues and send pull requests (for big changes create an issue first and link it from the PR), they are highly appreciated!

## License
Free Public License 1.0.0 / Zero Clause BSD License

https://opensource.org/licenses/FPL-1.0.0

https://tldrlegal.com/license/bsd-0-clause-license

/**
 * @package WebTorrent DHT
 * @author  Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @license 0BSD
 */
bencode					= require('bencode')
debug					= require('debug')('webtorrent-dht')
EventEmitter			= require('events').EventEmitter
inherits				= require('inherits')
simple-peer				= require('simple-peer')
wrtc					= require('wrtc')
ws						= require('ws')
module.exports			= webrtc-socket
PEER_CONNECTION_TIMEOUT	= 30
SIMPLE_PEER_OPTS		= {
	trickle	: false
	wrtc	: wrtc
}
/**
 * WebRTC socket implements a minimal subset of `dgram` interface necessary for `k-rpc-socket` while using WebRTC as transport layer instead of UDP
 *
 * @constructor
 */
!function webrtc-socket (options = {})
	if !(@ instanceof webrtc-socket)
		return new webrtc-socket(options)
	@_peer_connection_timeout	= (options.peer_connection_timeout || PEER_CONNECTION_TIMEOUT) * 1000 # needs to be in ms
	@_simple_peer_opts			= Object.assign({}, SIMPLE_PEER_OPTS, options.simple_peer_opts)
	@_simple_peer_constructor	= options.simple_peer_constructor || simple-peer
	@_ws_address				= options.ws_address
	@_extensions				= options.extensions || []
	@_peer_connections			= {}
	@_all_peer_connections		= new Set
	@_all_ws_connections		= new Set
	@_ws_connections_aliases	= {}
	@_pending_peer_connections	= {}
	@_connections_id_mapping	= {}

	EventEmitter.call(@)

inherits(webrtc-socket, EventEmitter)

webrtc-socket::
	..address = ->
		if @ws_server
			@_ws_address
		else
			throw new Error('WebSocket connection is not established yet')
	..bind = (port, address, callback) !->
		if !port || !address || port instanceof Function || address instanceof Function
			throw 'Both address and port are required for listen call'
		@ws_server = new ws.Server({port})
			..once('listening', !~>
				debug('listening for WebSocket connections on %s:%d', address, port)
				if !@_ws_address
					@_ws_address = {address, port}
				@emit('listening')
				callback?()
			)
			..on('error', !~>
				@emit('error', ...&)
			)
			..on('connection', (ws_connection) !~>
				debug('accepted WS connection')
				peer_connection = @_prepare_connection(true)
					..once('signal', (signal) !~>
						debug('got signal for WS (server): %s', signal)
						# Append any supplied extensions
						signal.extensions	= @_extensions
						signal				= bencode.encode(signal)
						ws_connection.send(signal)
					)
					..once('connect', !~>
						if ws_connection.readyState == 1 # OPEN
							ws_connection.close()
					)
				ws_connection
					..once('message', (data) !~>
						try
							signal	= bencode.decode(data)
							debug('got signal message from WS (server): %s', signal)
							peer_connection.signal(signal)
						catch e
							@emit('error', e)
							ws_connection.close()
					)
					..once('close', !->
						clearTimeout(timeout)
					)
				timeout	= setTimeout (!->
					ws_connection.close()
				), @_peer_connection_timeout
			)
	..close = !->
		# Closing all active WebRTC connections and stopping WebSocket server (if running)
		@_all_peer_connections.forEach (peer) !->
			peer.destroy()
		@_all_ws_connections.forEach (ws_connection) !->
			ws_connection.close()
		if @ws_server
			@ws_server.close()
	..send = (buffer, offset, length, port, address, callback) !->
		if @_peer_connections["#address:#port"]
			@_peer_connections["#address:#port"].send(buffer)
			callback()
		else if @_ws_connections_aliases["#address:#port"]
			peer_connection	= @_ws_connections_aliases["#address:#port"]
			@emit('update_websocket_request_peer', address, port, {
				host	: peer_connection.remoteAddress
				port	: peer_connection.remotePort
			})
			peer_connection.send(buffer)
			callback()
		else if @_pending_peer_connections["#address:#port"]
			@_pending_peer_connections["#address:#port"]
				.then (peer) !~>
					@send(buffer, offset, length, port, address, callback)
				.catch(->)
		else
			# If connection not found - assume WebSocket and try to establish WebRTC connection using it
			@_pending_peer_connections["#address:#port"] = new Promise (resolve, reject) !~>
				let WebSocket = (if typeof WebSocket != 'undefined' then WebSocket else ws)
					ws_connection = new WebSocket("ws://#address:#port")
						..binaryType = 'arraybuffer'
						..onerror = (e) !~>
							reject()
							@emit('error', e)
						..onclose = !~>
							debug('closed WS connection')
							@_all_ws_connections.delete(ws_connection)
						..onopen = !~>
							debug('opened WS connection')
							peer_connection = @_prepare_connection(false)
								..once('signal', (signal) !~>
									debug('got signal for WS (client): %s', signal)
									# Append any supplied extensions
									signal.extensions	= @_extensions
									signal				= bencode.encode(signal)
									ws_connection.send(signal)
								)
								..once('connect', !~>
									if ws_connection.readyState == 1 # OPEN
										ws_connection.close()
									remote_peer_info	=
										address	: peer_connection.remoteAddress
										port	: peer_connection.remotePort
									# Create alias for WebSocket connection
									@_register_ws_connection_alias(remote_peer_info.address, remote_peer_info.port, address, port)
									if peer_connection.destroyed
										reject()
										return
									@send(buffer, offset, length, port, address, callback)
									resolve(remote_peer_info)
								)
								..once('close', !->
									clearTimeout(timeout)
								)
							ws_connection.onmessage = ({data}) !~>
								try
									signal	= bencode.decode(data)
									debug('got signal message from WS (client): %s', signal)
									peer_connection.signal(signal)
								catch e
									@emit('error', e)
									ws_connection.close()
							timeout = setTimeout (!~>
								ws_connection.close()
								delete @_pending_peer_connections["#address:#port"]
								if !peer_connection.connected
									reject()
							), @_peer_connection_timeout
					@_all_ws_connections.add(ws_connection)
			@_pending_peer_connections["#address:#port"].catch(->)
	/**
	 * @param {boolean} initiator
	 *
	 * @return {SimplePeer}
	 */
	.._prepare_connection = (initiator) ->
		debug('prepare connection, initiator: %s', initiator)
		# We're creating some connections upfront, while they might not be ever used, so let's drop them after timeout
		timeout			= setTimeout (!~>
			if !peer_connection.connected || !peer_connection._tags.size
				peer_connection.destroy()
		), @_peer_connection_timeout
		peer_connection	= @_simple_peer_constructor(Object.assign({}, @_simple_peer_opts, {initiator}))
			..once('connect', !~>
				debug('peer connected: %s:%d', peer_connection.remoteAddress, peer_connection.remotePort)
				@_register_connection(peer_connection)
				if @ws_server
					address	= @address()
					data	= bencode.encode(
						ws_server	:
							host	: address.address
							port	: address.port
					)
					@send(Buffer.from(data), 0, data.length, peer_connection.remotePort, peer_connection.remoteAddress, ->)
				peer_connection.once('close', !~>
					debug('peer disconnected: %s:%d', peer_connection.remoteAddress, peer_connection.remotePort)
				)
			)
			..on('data', (data) !~>
				if debug.enabled
					debug('got data: %o, %s', data, data.toString())
				if !peer_connection._ws_info_checked
					peer_connection._ws_info_checked	= true
					try
						data_decoded = bencode.decode(data)
						if data_decoded.ws_server
							# Peer says it has WebSockets server running, so we can connect to it later directly
							peer_connection.ws_server = {
								host	: data_decoded.ws_server.host.toString()
								port	: data_decoded.ws_server.port
							}
							return
				# Only `Buffer` format is used for DHT
				if Buffer.isBuffer(data)
					# Peer might be not yet marked as connected, be prepared for this and wait for remote peer info to become available
					if peer_connection.connected
						@emit('message', data, {
							address	: peer_connection.remoteAddress
							port	: peer_connection.remotePort
						})
					else
						peer_connection.once('connected', !~>
							@emit('message', data, {
								address	: peer_connection.remoteAddress
								port	: peer_connection.remotePort
							})
						)
			)
			..on('error', !~>
				debug('peer error: %o', &)
				@emit('error', ...&)
			)
			..once('close', !~>
				clearTimeout(timeout)
				@_all_peer_connections.delete(peer_connection)
			)
			..setMaxListeners(0)
			..signal = (signal) !~>
				signal.sdp	= String(signal.sdp)
				signal.type	= String(signal.type)
				if signal.extensions
					signal.extensions	= signal.extensions.map (extension) ->
						"#extension"
					if signal.extensions.length
						@emit('extensions_received', peer_connection, signal.extensions)
				@_simple_peer_constructor::signal.call(peer_connection, signal)
			.._tags = new Set
		@_all_peer_connections.add(peer_connection)
		peer_connection
	/**
	 * @param {string}	id
	 * @param {!Object}	peer_connection
	 */
	.._add_id_mapping = (id, peer_connection) !->
		if !(peer_connection instanceof simple-peer)
			ip		= peer_connection.host || peer_connection.address
			port	= peer_connection.port
			if !@_peer_connections["#ip:#port"]
				debug('bad peer specified for id mapping: %s => %o', id, {ip, port})
				return
			peer_connection = @_peer_connections["#ip:#port"]
		if @_connections_id_mapping[id]
			if @_connections_id_mapping[id] != peer_connection
				peer_connection.destroy()
			return
		@_connections_id_mapping[id]	= peer_connection
		peer_connection.id				= id
		peer_connection.once('close', !~>
			@_del_id_mapping(id)
		)
		@emit('node_connected', id)
	/**
	 * @param {string} id
	 */
	.._del_id_mapping = (id) !->
		if !@_connections_id_mapping[id]
			return
		peer_connection	= @_connections_id_mapping[id]
		if peer_connection._tags.size && !peer_connection.destroyed
			# Do not disconnect while there are still some tags
			return
		delete @_connections_id_mapping[id]
		if !peer_connection.destroyed
			peer_connection.destroy()
		@emit('node_disconnected', id)
	/**
	 * @param {string} id
	 *
	 * @return {SimplePeer}
	 */
	..get_id_mapping = (id) ->
		@_connections_id_mapping[id]
	/**
	 * @param {string} id
	 * @param {string} tag
	 */
	..add_tag = (id, tag) !->
		peer_connection	= @get_id_mapping(id)
		if peer_connection
			peer_connection._tags.add(tag)
	/**
	 * @param {string} id
	 * @param {string} tag
	 */
	..del_tag = (id, tag) !->
		if !@_connections_id_mapping[id]
			return
		peer_connection	= @_connections_id_mapping[id]
		peer_connection._tags.delete(tag)
		@_del_id_mapping(id)
	..known_ws_servers = ->
		(
			for peer_connection, peer_connection of @_peer_connections
				peer_connection.ws_server
		)
		.filter(Boolean)
	/**
	 * @param {SimplePeer} peer_connection
	 */
	.._register_connection = (peer_connection) !->
		ip								= peer_connection.remoteAddress
		port							= peer_connection.remotePort
		@_peer_connections["#ip:#port"]	= peer_connection
		peer_connection.once('close', !~>
			delete @_peer_connections["#ip:#port"]
		)
	.._register_ws_connection_alias = (webrtc_host, webrtc_port, websocket_host, websocket_port) !->
		peer_connection												= @_peer_connections["#webrtc_host:#webrtc_port"]
		@_ws_connections_aliases["#websocket_host:#websocket_port"]	= peer_connection
		peer_connection.once('close', !~>
			delete @_ws_connections_aliases["#websocket_host:#websocket_port"]
		)
		@emit('websocket_peer_connection_alias', websocket_host, websocket_port, peer_connection)

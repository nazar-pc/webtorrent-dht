/**
 * @package   WebTorrent DHT
 * @author    Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @copyright Copyright (c) 2017, Nazar Mokrynskyi
 * @license   MIT License, see license.txt
 */
bencode					= require('bencode')
debug					= require('debug')('webtorrent-dht')
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
	@_listeners					= []
	@_peer_connections			= {}
	@_ws_connections_aliases	= {}
	@_pending_peer_connections	= {}
	@_connections_id_mapping	= {}
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
			..on('listening', !~>
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
				peer_connection = @prepare_connection(true)
					..on('signal', (signal) !~>
						debug('got signal for WS (server): %s', signal)
						# Append any supplied extensions
						signal.extensions	= @_extensions
						signal				= bencode.encode(signal)
						ws_connection.send(signal)
					)
					..on('connect', !~>
						if ws_connection.readyState == 1 # OPEN
							ws_connection.close()
					)
				ws_connection.on('message', (data) !~>
					try
						signal = bencode.decode(data)
						debug('got signal message from WS (server): %s', signal)
						peer_connection.signal(signal)
					catch e
						@emit('error', e)
						ws_connection.close()
				)
				setTimeout (!->
					ws_connection.close()
				), @_peer_connection_timeout
			)
	..close = !->
		for peer, peer of @_peer_connections
			peer.destroy()
		if @ws_server
			@ws_server.close()
	..emit = (eventName, ...args) ->
		if @_listeners[eventName]
			for listener in @_listeners[eventName]
				listener(...args)
	..on = (eventName, listener) !->
		@_listeners.[][eventName].push(listener)
	..send = (buffer, offset, length, port, address, callback) !->
		if @_peer_connections["#address:#port"]
			@_peer_connections["#address:#port"].send(buffer)
			callback()
		else if @_ws_connections_aliases["#address:#port"]
			@_ws_connections_aliases["#address:#port"].send(buffer)
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
						..onopen = !~>
							debug('opened WS connection')
							peer_connection = @prepare_connection(false)
								..on('signal', (signal) !~>
									debug('got signal for WS (client): %s', signal)
									# Append any supplied extensions
									signal.extensions	= @_extensions
									signal				= bencode.encode(signal)
									ws_connection.send(signal)
								)
								..on('connect', !~>
									if ws_connection.readyState == 1 # OPEN
										ws_connection.close()
									remote_peer_info	=
										address	: peer_connection.remoteAddress
										port	: peer_connection.remotePort
									# Create alias for WebSocket connection
									@_register_ws_connection_alias(remote_peer_info.address, remote_peer_info.port, address, port)
									@send(buffer, offset, length, remote_peer_info.port, remote_peer_info.address, callback)
									resolve(remote_peer_info)
								)
							ws_connection.onmessage = ({data}) !~>
								try
									signal	= bencode.decode(data)
									debug('got signal message from WS (client): %s', signal)
									peer_connection.signal(signal)
								catch e
									@emit('error', e)
									ws_connection.close()
							setTimeout (!~>
								ws_connection.close()
								delete @_pending_peer_connections["#address:#port"]
								if !peer_connection.connected
									reject()
							), @_peer_connection_timeout
			@_pending_peer_connections["#address:#port"].catch(->)
	/**
	 * @param {boolean} initiator
	 *
	 * @return {SimplePeer}
	 */
	..prepare_connection = (initiator) ->
		debug('prepare connection, initiator: %s', initiator)
		# We're creating some connections upfront, while they might not be ever used, so let's drop them after timeout
		setTimeout (!~>
			if !peer_connection.connected || !peer_connection._associations.size()
				peer_connection.destroy()
		), @_peer_connection_timeout
		peer_connection = @_simple_peer_constructor(Object.assign({}, @_simple_peer_opts, {initiator}))
			..on('connect', !~>
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
				peer_connection.on('close', !~>
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
								host	: data_decoded.ws_server.toString()
								port	: data_decoded.ws_server.port
							}
							return
				# Only `Buffer` format is used for DHT
				if Buffer.isBuffer(data)
					@emit('message', data, {
						address	: peer_connection.remoteAddress
						port	: peer_connection.remotePort
					})
			)
			..on('error', !~>
				debug('peer error: %o', &)
				@emit('error', ...&)
			)
			..setMaxListeners(0)
			..signal = (signal) !~>
				if signal.extensions
					extensions	= signal.extensions.map (extension) ->
						"#extension"
					if extensions.length
						@emit('extensions_received', peer_connection, extensions)
				@_simple_peer_constructor::signal.call(peer_connection, signal)
			.._associations = new Set
	/**
	 * @param {string}	id
	 * @param {!Object}	peer_connection
	 */
	..add_id_mapping = (id, peer_connection) !->
		if !(peer_connection instanceof simple-peer)
			ip		= peer_connection.host || peer_connection.address
			port	= peer_connection.port
			if !@_peer_connections["#ip:#port"]
				debug('bad peer specified for id mapping: %s => %o', id, {ip, port})
				return
			peer_connection = @_peer_connections["#ip:#port"]
		@_connections_id_mapping[id]	= peer_connection
		peer_connection.id				= id
		@emit('node_connected', id)
		peer_connection.on('close', !~>
			@del_id_mapping(id)
		)
	/**
	 * @param {string} id
	 *
	 * @return {SimplePeer}
	 */
	..get_id_mapping = (id) ->
		@_connections_id_mapping[id]
	/**
	 * @param {string} id
	 * @param {string} association
	 */
	..add_association = (id, association) !->
		peer_connection	= @get_id_mapping(id)
		if peer_connection
			peer_connection._associations.add(association)
	/**
	 * @param {string} id
	 * @param {string} association
	 */
	..del_association = (id, association) !->
		if !@_connections_id_mapping[id]
			return
		peer_connection	= @_connections_id_mapping[id]
		peer_connection._associations.delete(association)
		if peer_connection._associations.size()
			# Do not disconnect while there are still some associations
			return
		delete @_connections_id_mapping[id]
		if !peer_connection.destroyed
			peer_connection.destroy()
		@emit('node_disconnected', id)
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
		peer_connection.on('close', !~>
			delete @_peer_connections["#ip:#port"]
		)
	.._register_ws_connection_alias = (webrtc_host, webrtc_port, websocket_host, websocket_port) !->
		peer_connection												= @_peer_connections["#webrtc_host:#webrtc_port"]
		@_ws_connections_aliases["#websocket_host:#websocket_port"]	= peer_connection
		peer_connection.on('close', !~>
			delete @_ws_connections_aliases["#websocket_host:#websocket_port"]
		)

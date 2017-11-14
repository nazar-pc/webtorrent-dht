/**
 * @package   WebTorrent DHT
 * @author    Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @copyright Copyright (c) 2017, Nazar Mokrynskyi
 * @license   MIT License, see license.txt
 */
bencode					= require('bencode')
debug					= require('debug')('webtorrent-dht')
#lz-string				= require('lz-string')
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
 */
!function webrtc-socket (options = {})
	if !(@ instanceof webrtc-socket)
		return new webrtc-socket(options)
	@peer_connection_timeout	= (options.peer_connection_timeout || PEER_CONNECTION_TIMEOUT) * 1000 # needs to be in ms
	@simple_peer_opts			= Object.assign({}, SIMPLE_PEER_OPTS, options.simple_peer_opts)
	@_simple_peer_constructor	= options.simple_peer_constructor || simple-peer
	@ws_address					= options.ws_address
	@listeners					= []
	@peer_connections			= {}
	@ws_connections_aliases		= {}
	@pending_peer_connections	= {}
	@connections_id_mapping		= {}
webrtc-socket::
	..address = ->
		if @ws_server
			@ws_address
		else
			throw new Error('WebSocket connection is not established yet')
	..bind = (port, address, callback) !->
		if !port || !address || port instanceof Function || address instanceof Function
			throw 'Both address and port are required for listen call'
		@ws_server = new ws.Server({port})
			..on('listening', !~>
				debug('listening for WebSocket connections on %s:%d', address, port)
				if !@ws_address
					@ws_address = {address, port}
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
						signal = bencode.encode(signal)
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
				), @peer_connection_timeout
			)
	..close = !->
		for peer, peer of @peer_connections
			peer.destroy()
		if @ws_server
			@ws_server.close()
	..emit = (eventName, ...args) ->
		if @listeners[eventName]
			for listener in @listeners[eventName]
				listener(...args)
	..on = (eventName, listener) !->
		@listeners.[][eventName].push(listener)
	..send = (buffer, offset, length, port, address, callback) !->
		if @peer_connections["#address:#port"]
#			buffer = @__compress(buffer)
			@peer_connections["#address:#port"].send(buffer)
			callback()
		else if @ws_connections_aliases["#address:#port"]
#			buffer = @__compress(buffer)
			@ws_connections_aliases["#address:#port"].send(buffer)
			callback()
		else if @pending_peer_connections["#address:#port"]
			@pending_peer_connections["#address:#port"]
				.then (peer) !~>
					@send(buffer, offset, length, port, address, callback)
				.catch(->)
		else
			# If connection not found - assume WebSocket and try to establish WebRTC connection using it
			@pending_peer_connections["#address:#port"] = new Promise (resolve, reject) !~>
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
									signal = bencode.encode(signal)
									ws_connection.send(signal)
								)
								..on('connect', !~>
									if ws_connection.readyState == 1 # OPEN
										ws_connection.close()
									remote_peer_info	=
										address	: peer_connection.remoteAddress
										port	: peer_connection.remotePort
									# Create alias for WebSocket connection
									@__register_ws_connection_alias(remote_peer_info.address, remote_peer_info.port, address, port)
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
								delete @pending_peer_connections["#address:#port"]
								if !peer_connection.connected
									reject()
							), @peer_connection_timeout
			@pending_peer_connections["#address:#port"].catch(->)
	/**
	 * @param {boolean} initiator
	 *
	 * @return {SimplePeer}
	 */
	..prepare_connection = (initiator) ->
		debug('prepare connection, initiator: %s', initiator)
		# We're creating some connections upfront, while they might not be ever used, so let's drop them after timeout
		setTimeout (!~>
			if !peer_connection.connected || !peer_connection.id
				peer_connection.destroy()
		), @peer_connection_timeout
		peer_connection = @_simple_peer_constructor(Object.assign({}, @simple_peer_opts, {initiator}))
			..on('connect', !~>
				debug('peer connected: %s:%d', peer_connection.remoteAddress, peer_connection.remotePort)
				@__register_connection(peer_connection)
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
#				data = @__decompress(data)
				if debug.enabled
					debug('got data: %o, %s', data, data.toString())
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
	/**
	 * @param {string}	id
	 * @param {string}	ip
	 * @param {number}	port
	 */
	..add_id_mapping = (id, ip, port) !->
		if !@peer_connections["#ip:#port"]
			debug('bad peer specified for id mapping: %s => %o', id, {ip, port})
			return
		peer_connection				= @peer_connections["#ip:#port"]
		@connections_id_mapping[id]	= peer_connection
		peer_connection.id			= id
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
		@connections_id_mapping[id]
	/**
	 * @param {string} id
	 */
	..del_id_mapping = (id) !->
		if !@connections_id_mapping[id]
			return
		peer_connection	= @connections_id_mapping[id]
		delete @connections_id_mapping[id]
		if !peer_connection.destroyed
			peer_connection.destroy()
		@emit('node_disconnected', id)
	..known_ws_servers = ->
		(
			for peer_connection, peer_connection of @peer_connections
				peer_connection.ws_server
		)
		.filter(Boolean)
	/**
	 * @param {SimplePeer} peer_connection
	 */
	..__register_connection = (peer_connection) !->
		@peer_connections["#{peer_connection.remoteAddress}:#{peer_connection.remotePort}"]	= peer_connection
		peer_connection.on('close', !~>
			delete @peer_connections["#host:#port"]
		)
	..__register_ws_connection_alias = (webrtc_host, webrtc_port, websocket_host, websocket_port) !->
		peer_connection												= @peer_connections["#webrtc_host:#webrtc_port"]
		@ws_connections_aliases["#websocket_host:#websocket_port"]	= peer_connection
		peer_connection.on('close', !~>
			delete @ws_connections_aliases["#websocket_host:#websocket_port"]
		)
# TODO: some optional mechanism for exchanging supported compression methods and other metadata would be useful, possibly send them alongside signaling
#	..__compress = (buffer) ->
#		if lz-string # Allows building without lz-string if compression is not desired
#			# TODO: should be straight binary
#			data	= buffer.toString('hex')
#			data	= lz-string.compressToUint8Array(data)
#			data	= (
#				new Uint8Array(data.length + 2)
#					..set(Buffer.from('lz')) # add a mark that this is lz-compressed data
#					..set(data, 2)
#			)
#		data
#	..__decompress = (data) ->
#		if Buffer.from(data.slice(0, 2)).toString() == 'lz' # compression was used, but be ready for no compression
#			data	= lz-string.decompressFromUint8Array(data.slice(2))
#			# TODO: should be straight binary
#			data	= Buffer.from(data, 'hex')
#		data

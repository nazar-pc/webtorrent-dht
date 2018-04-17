/**
 * @package WebTorrent DHT
 * @author  Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @license 0BSD
 */
bencode					= require('bencode')
debug					= require('debug')?('webtorrent-dht') || ->
EventEmitter			= require('events').EventEmitter
http					= require('http')
inherits				= require('inherits')
isIP					= require('isipaddress').test
fetch					= require('node-fetch')
simple-peer				= require('simple-peer')
wrtc					= require('wrtc')
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
	@_http_address				= options.http_address
	@_extensions				= options.extensions || []
	@_peer_connections			= {}
	@_all_peer_connections		= new Set
	@_http_connections_aliases	= {}
	@_pending_peer_connections	= {}
	@_connections_id_mapping	= {}

	EventEmitter.call(@)

inherits(webrtc-socket, EventEmitter)

webrtc-socket::
	..address = ->
		if @http_server
			@_http_address
		else
			throw new Error('HTTP server is not running yet')
	..bind = (port, address, callback) !->
		if !port || !address || port instanceof Function || address instanceof Function
			throw 'Both address and port are required for listen call'
		@http_server = http.createServer (request, response) !~>
			if request.method != 'POST'
				response.writeHead(400)
				response.end()
				return
			body	= ''
			request
				.on('data', (chunk) !->
					body	+= chunk
				)
				.on('end', !~>
					try
						@_prepare_connection(false)
							..once('signal', (signal) !~>
								debug('got signal for HTTP (server): %s', signal)
								# Append any supplied extensions
								signal.extensions	= @_extensions
								signal				= JSON.stringify(signal)
								if !response.finished
									response.setHeader('Access-Control-Allow-Origin', '*')
									response.write(signal)
									response.end()
							)
							..once('connect', !~>
								if !response.finished
									response.writeHead(500)
									response.end()
							)
							..once('close', !->
								if !response.finished
									response.writeHead(500)
									response.end()
							)
							..signal(JSON.parse(body))
					catch
						response.writeHead(400)
						response.end()
				)
				.setEncoding('utf8')
		@http_server
			..listen(port, address, !~>
				debug('listening for HTTP connections on %s:%d', address, port)
				if !@_http_address
					@_http_address = {address, port}
				@emit('listening')
				callback?()
			)
			..on('error', (e) !~>
				@emit('error', e)
			)
	..close = !->
		# Closing all active WebRTC connections and stopping HTTP server (if running)
		@_all_peer_connections.forEach (peer) !->
			peer.destroy()
		if @http_server
			@http_server.close()
	..send = (buffer, offset, length, port, address, callback) !->
		if @_peer_connections["#address:#port"]
			@_peer_connections["#address:#port"].send(buffer)
			callback()
		else if @_http_connections_aliases["#address:#port"]
			peer_connection	= @_http_connections_aliases["#address:#port"]
			@emit('update_http_request_peer', address, port, {
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
			# If connection not found - assume HTTP and try to establish WebRTC connection using it
			@_pending_peer_connections["#address:#port"] = new Promise (resolve, reject) !~>
				peer_connection = @_prepare_connection(true)
					..once('signal', (signal) !~>
						debug('got signal for HTTP (client): %s', signal)
						# Append any supplied extensions
						signal.extensions	= @_extensions
						init				=
							method	: 'POST'
							body	: JSON.stringify(signal)
						# Prefer HTTPS connection if possible, otherwise fallback to insecure
						fetch("https://#address:#port", init)
							.catch (e) ->
								if location.protocol == 'http:'
									fetch("http://#address:#port", init)
								else
									throw e
							.then (response) ->
								response.json()
							.then (signal) !->
								if peer_connection.destroyed
									reject()
									return
								peer_connection.signal(signal)
							.catch (e) !~>
								reject()
								@emit('error', e)
					)
					..once('connect', !~>
						remote_peer_info	=
							address	: peer_connection.remoteAddress
							port	: peer_connection.remotePort
						# Create alias for HTTP connection
						@_register_http_connection_alias(remote_peer_info.address, remote_peer_info.port, address, port)
						if peer_connection.destroyed
							reject()
							return
						@send(buffer, offset, length, port, address, callback)
						delete @_pending_peer_connections["#address:#port"]
						resolve(remote_peer_info)
					)
					..once('close', !->
						clearTimeout(timeout)
					)
				timeout = setTimeout (!~>
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
	.._prepare_connection = (initiator) ->
		debug('prepare connection, initiator: %s', initiator)
		peer_connection	= @_simple_peer_constructor(Object.assign({}, @_simple_peer_opts, {initiator}))
			..once('connect', !~>
				debug('peer connected: %s:%d', peer_connection.remoteAddress, peer_connection.remotePort)
				@_register_connection(peer_connection)
				if @http_server
					address	= @address()
					data	= JSON.stringify(
						http_server	:
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
				if data instanceof Uint8Array
					data = Buffer.from(data)
				if !peer_connection._http_info_checked
					peer_connection._http_info_checked	= true
					try
						data_decoded = JSON.parse(data)
						if data_decoded.http_server
							# Peer says it has HTTP server running, so we can connect to it later directly
							peer_connection.http_server = {
								host	: data_decoded.http_server.host.toString()
								port	: data_decoded.http_server.port
							}
							return
				data_decoded = bencode.decode(data)
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
		# We're creating some connections upfront, while they might not be ever used, so let's drop them after timeout
		timeout			= setTimeout (!~>
			if !peer_connection.connected || !peer_connection._tags.size
				peer_connection.destroy()
		), @_peer_connection_timeout
		peer_connection
	/**
	 * @param {string}	id
	 * @param {!Object}	peer_connection
	 */
	.._add_id_mapping = (id, peer_connection) !->
		if !(peer_connection instanceof @_simple_peer_constructor)
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
	..known_http_servers = ->
		(
			for peer_connection, peer_connection of @_peer_connections
				peer_connection.http_server
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
	.._register_http_connection_alias = (webrtc_host, webrtc_port, http_host, http_port) !->
		peer_connection												= @_peer_connections["#webrtc_host:#webrtc_port"]
		@_http_connections_aliases["#http_host:#http_port"]	= peer_connection
		peer_connection.once('close', !~>
			delete @_http_connections_aliases["#http_host:#http_port"]
		)
		@emit('http_peer_connection_alias', http_host, http_port, peer_connection)

/**
 * @package WebTorrent DHT
 * @author  Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @license 0BSD
 */
debug			= require('debug')('webtorrent-dht')
inherits		= require('inherits')
k-rpc-socket	= require('k-rpc-socket')
webrtc-socket	= require('./webrtc-socket')
module.exports	= k-rpc-socket-webrtc
noop			= ->
function parse_nodes (buffer, id_length)
	nodes	=
		for i from 0 til buffer.length by id_length + 6
			parse_node(buffer.slice(i, i + id_length + 6), id_length)
	nodes.filter(Boolean)
function parse_node (buffer, id_length)
	id				= buffer.slice(0, id_length)
	{host, port}	= parse_info(buffer.slice(id_length, id_length + 6))
	{id, host, port}
function parse_info (buffer)
	host	= buffer[0] + '.' + buffer[1] + '.' + buffer[2] + '.' + buffer[3]
	port	= buffer.readUInt16BE(4)
	{host, port}
/**
 * @param {Buffer}	id
 * @param {string}	ip
 * @param {number}	port
 *
 * @return {Buffer}
 */
function encode_node (id, ip, port)
	id		= Buffer.from(id)
	info	= encode_info(ip, port)
	Buffer.concat([id, info])
/**
 * @param {string}	ip
 * @param {number}	port
 *
 * @return {Buffer}
 */
function encode_info (ip, port)
	ip		= Buffer.from(
		ip
			.split('.')
			.map (octet) ->
				parseInt(octet, 10)
	)
	port	= (
		Buffer.alloc(2)
			..writeUInt16BE(port)
	)
	Buffer.concat([ip, port])
/**
 * k-rpc-socket modified to work with WebRTC
 *
 * @constructor
 */
!function k-rpc-socket-webrtc (options = {})
	if !(@ instanceof k-rpc-socket-webrtc)
		return new k-rpc-socket-webrtc(options)
	options	= Object.assign({}, options)
	if !options.k
		throw new Error('k-rpc-socket-webrtc requires options.k to be specified explicitly')
	# Internal option, defines how much WebRTC connections will be prepared for DHT request, use log2(bucket size) in order to prevent number from growing too
	# fast with bucket size
	@_k	= Math.max(2, Math.floor(Math.log2(options.k)))
	if !options.id
		throw new Error('k-rpc-socket-webrtc requires options.id to be specified explicitly')
	if Buffer.isBuffer(options.id)
		@id	= options.id
	else
		@id	= Buffer.from(options.id, 'hex')
	options.socket	= options.socket || webrtc-socket(options)
	options.socket.on('update_websocket_request_peer', (host, port, peer) !~>
		for request in @_reqs
			if request && request.peer.host == host && request.peer.port == port
				request.peer	= peer
	)
	# DNS resolver doesn't work in browser, so always return false, we'll only encounter this for WebSocket bootstrap nodes anyway and it will not be an issue
	options.isIP	= -> true
	@_id_length		= options.id.length
	@_info_length	= @_id_length + 6
	@_extensions	= options.extensions || []
	k-rpc-socket.call(@, options)
/**
 * Multi-level inheritance: k-rpc-socket-webrtc inherits from noop (which will contain additional methods) and noop inherits from k-rpc-socket
 */
inherits(noop, k-rpc-socket)
inherits(k-rpc-socket-webrtc, noop)

k-rpc-socket-webrtc::
	..send = (peer, message, callback) !->
		debug('send to peer: %o', &)
		k-rpc-socket::send.call(@, peer, message, callback)
	..response = (peer, query, response, callback) !->
		debug('response: %o', &)
		response = Object.assign({}, response)
		switch query.q.toString()
			case 'find_node', 'get_peers', 'get'
				/**
				 * Before sending response we'll send signaling data to selected nodes and will pass signaling data back to querying node so that it can then
				 * establish connection if needed
				 */
				signals = query.a.signals
				if !Array.isArray(signals)
					return
				# We might get less signals than needed (different K, issues during WebRTC offer generation), so let's limit similarly number of nodes or values
				if response.nodes
					if response.nodes.length / @_info_length > signals.length
						response.nodes = response.nodes.slice(0, signals.length * @_info_length)
					peers = parse_nodes(response.nodes, @_id_length)
				else if response.values
					if response.values.length > signals.length
						response.values = response.values(0, signals.length)
					peers = response.values.map(parse_info)
				else
					k-rpc-socket::response.call(@, peer, query, response, callback)
					break
				Promise.all(
					for let peer, i in peers
						new Promise (resolve) !~>
							signal	= signals[i]
							query	=
								q	: 'peer_connection'
								a	: {@id, signal}
							@query(peer, query, (error, response) !->
								resolve({error, response})
							)
				).then (replies) !~>
					response.signals =
						for i from 0 til peers.length
							if replies[i].error
								null
							else
								replies[i].response.r?.signal || null
					k-rpc-socket::response.call(@, peer, query, response, callback)
			else
				k-rpc-socket::response.call(@, peer, query, response, callback)
	..query = (peer, query, callback) !->
		debug('query: %o', &)
		query = Object.assign({}, query)
		switch query.q.toString()
			case 'find_node', 'get_peers', 'get'
				Promise.all(
					for i from 0 til @_k
						new Promise (resolve) !~>
							peer_connection = @socket._prepare_connection(true)
								..once('signal', (signal) !~>
									# Append node id, it is used to avoid creating unnecessary connections
									signal.id			= @id
									# Append any supplied extensions
									signal.extensions	= @_extensions
									resolve({peer_connection, signal})
								)
								..once('error', (error) !~>
									resolve(null)
								)
				).then (connections) !~>
					connections	= connections.filter(Boolean)
					/**
					 * Inject signal data for K connections for queried node to pass them to target nodes and get signal data from them, so that we can afterwards
					 * establish direct connection to target nodes
					 */
					peer_connections	= []
					signals				= []
					for connection in connections
						peer_connections.push(connection.peer_connection)
						signals.push(connection.signal)
					query.a.signals = signals
					k-rpc-socket::query.call(@, peer, query, (error, response, ...args) !~>
						if !(
							!error &&
							Array.isArray(response.r.signals)
						)
							callback(error, response, ...args)
							return
						/**
						 * Use signal data from response to establish connections to target nodes and re-pack nodes using address and port from
						 * newly established connection rather than what queried node gave us (also not all connections might be established, so
						 * nodes list might be shorter than what queried node returned)
						 */
						host_id = query.a.id.toString('hex')
						Promise.all(
							for let signal, i in response.r.signals
								if signal
									signal_id_hex = signal.id.toString('hex')
									# Do not connect to itself
									if signal_id_hex == host_id
										null
									else
										peer_connection = @socket.get_id_mapping(signal_id_hex)
										result			= (peer_connection_real) ~>
											if response.r.nodes
												encode_node(
													response.r.nodes.slice(i * @_info_length, i * @_info_length + @_id_length)
													peer_connection_real.remoteAddress
													peer_connection_real.remotePort
												)
											else if response.r.values
												encode_info(
													peer_connection_real.remoteAddress
													peer_connection_real.remotePort
												)
											else
												null
										if peer_connection
											peer_connections[i].destroy()
											result(peer_connection)
										else if !response.r.nodes && !response.r.values
											null
										else
											new Promise (resolve) !~>
												peer_connection	= peer_connections[i]
												# In case peer connection have been closed already
												if peer_connection.destroyed
													resolve(null)
													return
												peer_connection
													..once('connect', !~>
														@socket._add_id_mapping(signal_id_hex, peer_connection)
														/**
														 * Above line might cause connection to close as everything is asynchronous and connection might
														 * be established in the time frame between signal insertion and `connect` event firing
														 */
														if !peer_connection.destroyed
															resolve(result(peer_connection))
													)
													..once('close', !~>
														peer_connection_real	= @socket.get_id_mapping(signal_id_hex)
														# Connection is closed, but we might still have existing connection to interested node
														if peer_connection_real
															resolve(result(peer_connection_real))
														else
															resolve(null)
													)
													..signal(signal)
								else
									null
						).then (peers) !~>
							peers	= peers.filter(Boolean)
							if response.r.nodes
								response.r.nodes	= Buffer.concat(peers, peers.length * @_info_length)
							else if response.r.values
								response.r.values	= peers
							callback(error, response, ...args)
					)
			else
				k-rpc-socket::query.call(@, peer, query, callback)
	..emit = (event, ...args) ->
		# Here we capture some events that are fired when data come from peers
		switch event
			case 'query'
				[message, peer]	= args
				if message.a?.id
					@socket._add_id_mapping(message.a.id.toString('hex'), peer)
				switch message.q?.toString?()
					case 'peer_connection'
						if message.a?.signal
							signal			= message.a.signal
							signal_id_hex	= signal.id.toString('hex')
							# If either querying for itself or connection is already established to interested peer
							if signal_id_hex == @id.toString('hex') || @socket.get_id_mapping(signal_id_hex)
								@response(peer, message, {
									id		: @id
									signal	: {@id}
								})
							else
								done	= false
								peer_connection = @socket._prepare_connection(false)
									..once('connect', !~>
										@socket._add_id_mapping(signal_id_hex, peer_connection)
									)
									..once('signal', (signal) !~>
										# Make sure either response or error is sent, not both
										if done
											return
										done := true
										# Append node id, it is used to avoid creating unnecessary connections
										signal.id			= @id
										# Append any supplied extensions
										signal.extensions	= @_extensions
										@response(peer, message, {@id, signal})
									)
									..once('error' (error) !~>
										# Make sure either response or error is sent, not both
										if done
											return
										done := true
										@error(peer, message, [201, error])
									)
									..signal(signal)
						# Don't fire `query` here, we've processed it already
						return
			case 'response'
				[message, peer]	= args
				if message.r?.id
					@socket._add_id_mapping(message.r.id.toString('hex'), peer)
		k-rpc-socket::emit.apply(@, &)

/**
 * @package   WebTorrent DHT
 * @author    Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @copyright Copyright (c) 2017, Nazar Mokrynskyi
 * @license   MIT License, see license.txt
 */
bencode			= require('bencode')
debug			= require('debug')('webtorrent-dht')
inherits		= require('inherits')
isIP			= require('isipaddress').test
k-rpc-socket	= require('k-rpc-socket')
webrtc-socket	= require('./webrtc-socket')
module.exports	= k-rpc-socket-webrtc
noop			= ->
function parse_nodes (buffer, id_space)
	nodes	=
		for i from 0 til buffer.length by id_space + 6
			parse_node(buffer.slice(i, i + id_space + 6), id_space)
	nodes.filter(Boolean)
function parse_node (buffer, id_space)
	id				= buffer.slice(0, id_space)
	{host, port}	= parse_info(buffer.slice(id_space, id_space + 6))
	{id, host, port}
function parse_info (buffer)
	host	= buffer[0] + '.' + buffer[1] + '.' + buffer[2] + '.' + buffer[3]
	port	= buffer.readUInt16BE(4)
	{host, port}
function encode_node (id, ip, port)
	id		= Buffer.from(id) # Either buffer or string
	info	= encode_info(ip, port)
	Buffer.concat([id, info])
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
	Buffer.concat([ip, port], 6)
/**
 * k-rpc-socket modified to work with WebRTC
 */
!function k-rpc-socket-webrtc (options = {})
	if !(@ instanceof k-rpc-socket-webrtc)
		return new k-rpc-socket-webrtc(options)
	if !options.k
		throw new Error('k-rpc-socket-webrtc requires options.k to be specified explicitly')
	@k	= options.k
	if !options.id
		throw new Error('k-rpc-socket-webrtc requires options.id to be specified explicitly')
	if Buffer.isBuffer(options.id)
		@id	= options.id
	else
		@id	= Buffer.from(options.id, 'hex')
	@_id_space		= options.id.length
	options.socket	= options.socket || webrtc-socket(options)
	options.isIP	= isIP
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
					if response.nodes.length / (@_id_space + 6) > signals.length
						response.nodes.length = signals.length * (@_id_space + 6)
					peers = parse_nodes(response.nodes, )
				else if response.values
					if response.values.length > signals.length
						response.values.length = signals.length
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
				break
			else
				k-rpc-socket::response.call(@, peer, query, response, callback)
	..query = (peer, query, callback) !->
		debug('query: %o', &)
		query = Object.assign({}, query)
		switch query.q.toString()
			case 'find_node', 'get_peers', 'get'
				Promise.all(
					for i from 0 til @k
						new Promise (resolve) !~>
							peer_connection = @socket.prepare_connection(true)
								..on('signal', (signal) !~>
									# Append node id, it is used to avoid creating unnecessary connections
									signal.id	= @id
									resolve({peer_connection, signal})
								)
								..on('error', (error) !~>
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
							return callback(error, response, ...args)
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
										if peer_connection
											peer_connections[i].destroy()
											encode_info(
												peer_connection.remoteAddress
												peer_connection.remotePort
											)
										else
											new Promise (resolve) !~>
												peer_connection	= peer_connections[i]
													..on('connect', !~>
														@socket.add_id_mapping(signal_id_hex, peer_connection)
														if response.r.nodes
															resolve(encode_node(
																response.r.nodes.slice(i * @_id_space + 6, i * (@_id_space + 6) + @_id_space)
																peer_connection.remoteAddress
																peer_connection.remotePort
															))
														else if response.r.values
															resolve(encode_info(
																peer_connection.remoteAddress
																peer_connection.remotePort
															))
													)
													..on('error', !->
														resolve(null)
													)
													..signal(signal)
								else
									null
						).then (peers) !~>
							peers	= peers.filter(Boolean)
							if response.r.nodes
								response.r.nodes	= Buffer.concat(peers, peers.length * (@_id_space + 6))
							else if response.r.values
								response.r.values	= peers
							callback(error, response, ...args)
					)
				break
			else
				k-rpc-socket::query.call(@, peer, query, callback)
	..emit = (event, ...args) ->
		# Here we capture some events that are fired when data come from peers
		switch event
			case 'query'
				[message, peer]	= args
				if message.a?.id
					@socket.add_id_mapping(message.a.id.toString('hex'), peer)
				switch message.q?.toString?()
					case 'peer_connection'
						if message.a?.signal?
							signal			= message.a.signal
							signal_id_hex	= signal.id.toString('hex')
							# If either querying for itself or connection is already established to interested peer
							if signal_id_hex == @id.toString('hex') || @socket.get_id_mapping(signal_id_hex)
								@response(peer, message, {
									id		: @id
									signal	: {@id}
								})
							else
								peer_connection = @socket.prepare_connection(false)
									..on('connect', !~>
										@socket.add_id_mapping(signal_id_hex, peer_connection)
									)
									..on('signal', (signal) !~>
										# Append node id, it is used to avoid creating unnecessary connections
										signal.id	= @id
										@response(peer, message, {@id, signal})
									)
									..on('error', (error) !~>
										@error(peer, message, [201, error])
									)
									..signal(signal)
						break
				break
			case 'response'
				[message, peer]	= args
				if message.r?.id
					@socket.add_id_mapping(message.r.id.toString('hex'), peer)
				break
		k-rpc-socket::emit.apply(@, &)

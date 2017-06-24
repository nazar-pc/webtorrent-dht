/**
 * @package   WebTorrent DHT
 * @author    Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @copyright Copyright (c) 2017, Nazar Mokrynskyi
 * @license   MIT License, see license.txt
 */
inherits			= require('inherits')
k-rpc				= require('k-rpc')
k-rpc-socket-webrtc	= require('./k-rpc-socket-webrtc')
randombytes			= require('randombytes')
module.exports		= k-rpc-webrtc
noop				= ->
# TODO: Hopefully when things settle down we'll have some public bootstrap nodes here
BOOTSTRAP_NODES		= [
	# If some node is already running locally - use it as bootstrap node
	{
		host	: '127.0.0.1'
		port	: 16881
	}
]
/**
 * k-rpc modified to work with WebRTC
 */
!function k-rpc-webrtc (options = {})
	if !(@ instanceof k-rpc-webrtc)
		return new k-rpc-webrtc(options)
	options				= Object.assign({}, options)
	options.id			= options.id || options.nodeId || randombytes(20)
	options.krpcSocket	= options.krpcSocket || k-rpc-socket-webrtc(options)
	options.bootstrap	= options.nodes || options.bootstrap || BOOTSTRAP_NODES
	k-rpc.call(@, options)
	# Avoid querying disconnected nodes
	@socket.socket.on('node_disconnected', (id) !~>
		@nodes.remove(Buffer.from(id, 'hex'))
	)

inherits(noop, k-rpc)
inherits(k-rpc-webrtc, noop)

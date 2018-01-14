/**
 * @package WebTorrent DHT
 * @author  Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @license 0BSD
 */
bittorrent-dht	= require('bittorrent-dht')
inherits		= require('inherits')
k-rpc-webrtc	= require('./k-rpc-webrtc')
module.exports	= webtorrent-dht
noop			= ->

/**
 * k-rpc modified to work with WebRTC
 *
 * @constructor
 */
!function webtorrent-dht (options = {})
	if !(@ instanceof webtorrent-dht)
		return new webtorrent-dht(options)
	options			= Object.assign({}, options)
	if options.hash
		options.idLength	= options.hash(Buffer.from('')).length
	options.krpc	= options.krpc || k-rpc-webrtc(options)
	bittorrent-dht.call(@, options)

inherits(noop, bittorrent-dht)
inherits(webtorrent-dht, noop)

webtorrent-dht::
	..listen = (port = 16881, address = '127.0.0.1', callback) !->
		@_rpc.bind(port, address, callback)
	..toJSON = ->
		{
			nodes	: @_rpc.socket.socket.known_ws_servers() # Hack: there is a nicer way to do this, but probably doesn't worth the effort
			values	: bittorrent-dht::toJSON.call(@).values
		}

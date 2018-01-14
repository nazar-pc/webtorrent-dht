/**
 * @package WebTorrent DHT
 * @author  Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @license 0BSD
 */
DHT = require('../webtorrent-dht')

global.dht = new DHT(
	nodes				: [] # Default bootstrap node is 127.0.0.1:16881, which in this case is the node itself, so let's not connect to itself
	simple_peer_opts	:
		config	:
			iceServers	: [] # No ICE servers for faster local testing
)

dht.listen(16881, '127.0.0.1', !->
	console.log('now listening')
)

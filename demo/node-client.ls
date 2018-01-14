/**
 * @package WebTorrent DHT
 * @author  Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @license 0BSD
 */
DHT = require('../webtorrent-dht')

global.dht = new DHT(
	nodes				: [
		{
			host	: '127.0.0.1'
			port	: 16881
		}
	]
	simple_peer_opts	:
		config	:
			iceServers	: [] # No ICE servers for faster local testing
)

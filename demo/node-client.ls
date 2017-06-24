/**
 * @package   WebTorrent DHT
 * @author    Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @copyright Copyright (c) 2017, Nazar Mokrynskyi
 * @license   MIT License, see license.txt
 */
DHT = require('../webtorrent-dht')

global.dht = new DHT(
	k					: 3
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

/**
 * @package WebTorrent DHT
 * @author  Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @license 0BSD
 */
window.dht = new webtorrent_dht(
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

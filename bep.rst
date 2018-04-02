:BEP: 00??
:Title: WebTorrent DHT protocol extension
:Version: $Revision$
:Last-Modified: $Date$
:Author: Nazar Mokrynskyi <nazar@mokrynskyi.com>
:Status:  ??
:Type:    Standards Track
:Content-Type: text/x-rst
:Created: 24-Jun-2017
:Post-History:

Abstract
========

This document describes an alternative flavor of the BitTorrent DHT that can be used not only in standalone apps, but also in modern web browsers.

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL
NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED",  "MAY", and
"OPTIONAL" in this document are to be interpreted as described in
IETF `RFC 2119`_.

Rationale
=========

BitTorrent DHT `BEP 0005`_ requires a way to establish direct P2P connections to function, which is not currently possible in modern browsers.
The closest thing we have in browsers right now is WebRTC, which while is useful and does allow to establish P2P connections requires some signaling service before actual P2P connection can be established.

The architecture proposed here includes 2 kinds of nodes:

- nodes of the first type are only capable of using WebRTC connections and can connect to nodes of the second type as WebSocket clients

- nodes of the second type are running WebSocket server in addition to what is supported by the nodes of the first type

Having WebSocket nodes in the network allows to use them for bootstrapping while using WebRTC connections for everything else.

WebSocket server/client
=======================

WebSocket server on the node of the second type is listening on specific address and port for incoming connections, this is used by WebSocket clients for bootstrap process.

As soon as new WebSocket connection is established it is only used for exchanging signaling data necessary for WebRTC.
More specifically:

- node that is running WebSocket server is creating `RTCPeerConnection`_ and sends to the WebSocket client bencoded SDP offer message. Message is a dictionary with key "type" with value "offer" and key "sdp" with session description and optional key "extensions" with an array of extensions supported (see next section for details)

- after WebSocket client receives SDP offer message it will send SPD answer message

- as soon as WebRTC connection is established WebSocket server closes WebSocket connection to the client

::

  Offer = {"type" : "offer", "sdp" : "<session description>", "extensions" : []}


  Answer = {"type" : "answer", "sdp" : "<session description>", "extensions" : []}

After establishing WebRTC connection a node that is also running WebSocket server should send a bencoded message containing a dictionary with key "ws_server" which in turn contains a dictionary with keys "host" and "port" that correspond to the publicly accessible host and port of running WebSocket server.
This information can be used to establish direct connection later, for instance, to use host and port as bootstrap node:

Example

::

  WebSocket server info = {"ws_server" : {"host" : "127.0.0.1" , "port" : 16881}}

  bencoded = d9:ws_serverd4:host9:127.0.0.14:porti16881eee

NOTE: When connecting to bootstrap node, secure WebSocket connection attempt should be made and if it fails then fallback to insecure.

Extensions
==========
"extensions" key sent alongside WebRTC signaling data is an array of arbitrary strings (depends on extension implementation), each of which represents a single extension.
When node supports an extension (unsupported extensions are silently ignored) sent with SDP offer message and is willing to use it, node will add corresponding extension to "extensions" array of SDP answer message.

When connection is established, communication between nodes might differ from communication between nodes that do not use any extensions.

Compression is an example of useful feature implemented as an extension. As soon as both nodes support some specific compression method they will send compressed messages instead of raw messages in order to reduce payload size.

Extensions are not limited to transport layer and can be used to extend DHT protocol with additional methods and other features. However, each node must support operation without any extensions being used.

BitTorrent DHT protocol extension
=================================

First of all, WebTorrent DHT works similarly to `BEP 0005`_, but uses WebRTC transport instead of UDP and IP address/port associated with remote address and port of connected WebRTC node.
For bootstrap nodes node should keep an alias to established WebRTC connection in order to avoid repeated WebSocket connections to the same node when WebRTC connection is already present.

find_node, get_peers and get queries and responses
--------------------------------------------------

"find_node", "get_peers" and "get" queries can return in response list of remote nodes (in keys "nodes" or "values") to which the querying node may then need to connect.
However, before this can happen with WebRTC the querying node and target remote node need to exchange signalling messages.

To make this process faster and easier, to each of mentioned queries the querying node must add an argument "signals" with an array of SDP offer signaling messages (``log2(k)`` is recommended).
Each signaling message is a dictionary with keys "id" (node ID of the querying node), "type" (with value "offer"), "sdp" (session description) and optional "extensions" (array of supported extensions).

Queried node after collecting the list of remote nodes in "nodes" or "values" keys of the response must send a "peer_connection" query to each of them.
"peer_connection" query has two arguments, "id" containing the node ID of the querying node, and "signal" which corresponds to the single item from "signals" array of the original query.
In response to the "peer_connection" query queried node should respond with 2 keys, "id" containing the node ID of the queried node and "signal" with SDP answer signalling message.

When responses to "peer_connection" queries are collected they will form an array that will be added under "signals" key to the response.
This way querying node will be able to immediately establish connections to the remote nodes if necessary.

::

  peer_connection Query = {"id" : "<querying node id>", "signal" : {"id" : "<original querying node id>", "type" : "offer", "sdp" : "<session description>", "extensions" : []}}

  Response = {"id" : "<querying node id>", "signal" : {"id" : "<queried node id>", "type" : "answer", "sdp" : "<session description>", "extensions" : []}}

It might sometimes happen that remote node and original querying node already have direct connection.
In this case remote node might skip signaling message and only put its node ID into "signal" key in response to the "peer_connection" query and this will tell original querying node to look for an existing established connection to this node:

::

  Response = {"id" : "<querying node id>", "signal" : {"id" : "<queried node id>"}}

References
==========

.. _`RFC 2119`: http://www.ietf.org/rfc/rfc2119.txt

.. _`BEP 0005`: http://www.bittorrent.org/beps/bep_0005.html

.. _`RTCPeerConnection`: https://www.w3.org/TR/webrtc/#rtcpeerconnection-interface

Copyright
=========

This document has been placed in the public domain.

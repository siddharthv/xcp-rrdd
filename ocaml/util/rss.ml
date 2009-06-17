(*
 * Copyright (c) 2007 XenSource Ltd
 * Author Vincent Hanquez <vincent@xensource.com>
 * 
 * RSS v2 writer code
 *)

type item_info = {
	item_title: string;
	item_link: string option;
	item_description: string;
	item_pubdate: string;
}

type channel_info = {
	chan_title: string;
	chan_description: string;
	chan_language: string;
	chan_pubdate: string;
	chan_items: item_info list;
}

let to_xml chans =
	let simple_node nodename pcdata =
		Xml.Element (nodename, [], [ Xml.PCData pcdata ])
		in
	let simple_optional_node nodename pcdata =
		match pcdata with
		| None -> []
		| Some pcdata -> [ simple_node nodename pcdata ]
		in
	let item_to_xml item =
		let itemchildren =
			[ simple_node "title" item.item_title ] @
			(simple_optional_node "link" item.item_link) @
			[ simple_node "description" item.item_description ] @
			[ simple_node "pubDate" item.item_pubdate ] @
			[]
			in
		Xml.Element ("item", [], itemchildren)
		in
	let channel_to_xml chan =
		let infos_xml =
			[ simple_node "title" chan.chan_title ] @
			[ simple_node "description" chan.chan_description ] @
			[ simple_node "language" chan.chan_language ] @
			[ simple_node "pubDate" chan.chan_pubdate ] @
			[ simple_node "generator" "Xapi alerts generator" ] @
			[]
			in
		let items_xml = List.map item_to_xml chan.chan_items in
		Xml.Element ("channel", [], infos_xml @ items_xml)
		in
	Xml.Element ("rss", [ ("version", "2.0") ],
	             List.map channel_to_xml chans)

let to_stream rsschans outchan =
	output_string outchan "<?xml version=\"1.0\"?>\n";
	output_string outchan (Xml.to_string (to_xml rsschans));
	flush outchan;
	()
# Garage's privacy levels as policy (docs/plans/access-policies.md, "Privacy levels"): five steps, each
# turning on more of what may reach this node and keeping everything below it. The levels are Rick's
# (2026-11-12): private node, private cluster, private with end-to-end remote, private with public
# providers, augmented.
#
# A level is a base policy, and a stored module modifies it (Rick, 2026-11-25: "one sets a base policy
# and can modify it") by adding to these sets in package garage.privacy, which are empty until one does:
#
#     package garage.privacy
#
#     import data.garage.privacy.levels
#
#     open_routes contains "web" if levels.level >= 3         # hosted assistants a level early
#     close_routes contains "sealed" if levels.level < 5      # no phones until augmented
#     deny contains {"corpus_class": "communication"} if levels.route == "web"
#     withhold_tools contains "rag_agent" if levels.route == "web"
#     grant_tools contains "rag_ask" if levels.route == "sealed"   # a phone may run the node's model
#
# `close_routes` wins over `open_routes`, and `withhold_tools` over `grant_tools`; nothing closes the
# node to itself. `deny` holds a caller whose route is open to more: a stored rule by name
# ({"rule": "<name>"}) or a metadata matcher. The levels themselves are this package's, which no stored
# module may take, and its entry point, data.garage.privacy.levels.decision, reads only those five
# sets. The service adds the decision's boundaries to every read's decision, whatever package
# garage.access decided, and the tool decision (tools.rego) withholds every tool from a caller whose
# route is shut, so only a modification changes what a level allows; the Access page's Test shows it.
#
# The level in effect is the node's own (data.garage.settings.privacy_level, the privacy.level
# setting), lowered by the level a caller reports from Garage Door (its garage-door-privacy attribute,
# set by the node's end of the tunnel from the account's level). A caller's attributes can only lower
# the level or narrow its route: an MCP client on this node that sends them closes its own door. Door
# enforces the account's level at the gateway as well, so a modification here never opens a route
# the account keeps shut there.
package garage.privacy.levels

# The levels, most private first.
table := [
	{"level": 1, "name": "node", "title": "Private node"},
	{"level": 2, "name": "cluster", "title": "Private cluster"},
	{"level": 3, "name": "remote", "title": "Private with end-to-end remote"},
	{"level": 4, "name": "providers", "title": "Private with public providers"},
	{"level": 5, "name": "augmented", "title": "Augmented"},
]

# What each level turns on, by the lowest level that turns it on (door/lib/garage_door/privacy.rb's
# FEATURES, in its order).
features := [
	# Linked Garages: the account's own nodes share with each other.
	{"name": "linked_nodes", "level": 2},
	# Garage Remote over the sealed stream, end to end: Door relays it and cannot read it.
	{"name": "remote_access", "level": 3},
	# Public AI services: hosted assistants through Door, and model keys sealed to the nodes.
	{"name": "public_providers", "level": 4},
	# Garage's servers and Door's vault.
	{"name": "hosted_vault", "level": 5},
]

# What each way of reaching this node needs. A caller on the node itself (the app, `garage`, an
# assistant over stdio or loopback HTTP) needs nothing: no level closes the node to itself.
route_needs := {
	"linked": "linked_nodes",
	"sealed": "remote_access",
	"web": "public_providers",
}

# The tools that run this node's own model.
inference_tools := {"rag_ask", "rag_generate", "rag_agent"}

attribute(name) := value if {
	value := input.caller.attributes[name]
	is_string(value)
}

# How the caller reached this node. The node's end of Door names the route; a Garage Door connector's
# registration with no route is a hosted assistant's (web MCP). A route this module does not know is
# kept as given, and opens at no level.
route := given if {
	given := attribute("garage-door-route")
	given != ""
} else := "web" if {
	input.caller.registration.client == "garage-door"
} else := "local"

# The node's own level; anything but 1 to 5 reads as the most private.
node_level := n if {
	n := data.garage.settings.privacy_level
	n in {1, 2, 3, 4, 5}
} else := 1

# The level a caller reports from Door: 1 to 5, and anything else it sends reads as 1.
reported contains to_number(text) if {
	text := attribute("garage-door-privacy")
	regex.match(`^[1-5]$`, text)
}

reported contains 1 if {
	text := attribute("garage-door-privacy")
	not regex.match(`^[1-5]$`, text)
}

level := min(reported | {node_level})

allows(feature) if {
	some f in features
	f.name == feature
	level >= f.level
}

base_open if route == "local"

base_open if allows(route_needs[route])

# The modifications, each a set or not defined at all; anything else leaves the decision undefined,
# which fails every read and every tool closed.
open_routes_set := v if {
	v := data.garage.privacy.open_routes
	is_set(v)
} else := set() if not data.garage.privacy.open_routes

close_routes_set := v if {
	v := data.garage.privacy.close_routes
	is_set(v)
} else := set() if not data.garage.privacy.close_routes

deny_set := v if {
	v := data.garage.privacy.deny
	is_set(v)
} else := set() if not data.garage.privacy.deny

withhold_tools_set := v if {
	v := data.garage.privacy.withhold_tools
	is_set(v)
} else := set() if not data.garage.privacy.withhold_tools

grant_tools_set := v if {
	v := data.garage.privacy.grant_tools
	is_set(v)
} else := set() if not data.garage.privacy.grant_tools

valid if {
	is_set(open_routes_set)
	is_set(close_routes_set)
	is_set(deny_set)
	is_set(withhold_tools_set)
	is_set(grant_tools_set)
}

# The node is never closed to itself, whatever a modification says.
open if route == "local"

open if {
	base_open
	not route in close_routes_set
}

open if {
	route in open_routes_set
	not route in close_routes_set
}

# A phone may run the node's model only with the ask scope and the node's remote inference switch on
# (door/docs/e2e.md); otherwise it gets the retrieval tools alone.
remote_inference if {
	attribute("garage-door-scope") == "ask"
	attribute("garage-door-inference") == "1"
}

base_withheld contains name if {
	route == "sealed"
	not remote_inference
	some name in inference_tools
}

withheld contains name if {
	some name in base_withheld
	not name in grant_tools_set
}

withheld contains name if some name in withhold_tools_set

level_features := [f.name | some f in features; level >= f.level]

decision := {
	"level": level,
	"name": table[level - 1].name,
	"title": table[level - 1].title,
	"features": level_features,
	"route": route,
	"open": open_value,
	"boundaries": boundaries,
	"withheld_tools": sort(withheld),
} if valid

open_value := true if open
else := false

# A shut route sees no document: a boundary with a deny default and nothing it allows. An open one is
# held to the modifications' `deny`, if any.
boundaries := [{"target": target, "default": "deny", "deny": [], "allow": []}] if {
	not open
} else := [] if {
	count(deny_set) == 0
} else := [{"target": target, "default": "allow", "deny": deny_conditions, "allow": []}]

target := concat(":", ["privacy", route])

deny_conditions := [c | some c in deny_set]

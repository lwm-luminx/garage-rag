# Which MCP tools a caller may list and call (docs/plans/access-policies.md, "Tools"): the same engine
# and input as data.garage.access, plus input.tools, the tools the MCP server offers.
#
# The entry point is data.garage.tools.decision, and this module owns it. A stored policy withholds a
# tool by adding its name to `deny` in this package:
#
#     package garage.tools
#
#     deny contains "rag_agent" if input.caller.kind == "mcp"
#
# A tool no policy denies stays available, so with no stored policy every caller has every tool that
# the privacy level (privacy.rego) gives it: none, when the level keeps the caller's route shut, and
# not the node's own model for a phone without remote inference.
package garage.tools

decision := {"allowed": allowed} if {
	valid
	allowed := [name | some name in input.tools; not denied(name)]
}

# `deny` is a set of names, or not defined at all; anything else leaves the decision undefined, which
# fails closed.
valid if not data.garage.tools.deny

valid if is_set(data.garage.tools.deny)

denied(name) if data.garage.tools.deny[name]

denied(_) if not data.garage.privacy.levels.decision.open

denied(name) if name in data.garage.privacy.levels.decision.withheld_tools

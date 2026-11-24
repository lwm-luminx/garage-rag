# The stored rules (docs/plans/access-policies.md) as a Rego policy: the targets, defaults and
# "a DENY always wins" written over data.garage.rules and data.garage.defaults, which the service fills
# from access_rules and access_defaults on every read (docs/plans/access-policies.md).
#
# The entry point is data.garage.access.decision. With no stored policy declaring package
# garage.access, the service's default module makes it this package's decision; a stored policy can
# build on it (data.garage.access.rules.decision) or ignore it.
package garage.access.rules

# One boundary per target the caller is checked against, outermost first: a door's grant is held to
# its door and then to itself, and a document must pass every boundary.
decision := {"boundaries": [boundary(target) | some target in input.targets]}

boundary(target) := {
	"target": target,
	"default": default_for(target),
	"deny": [{"rule": name} | some name in sort(applicable(target, "deny"))],
	"allow": [{"rule": name} | some name in sort(applicable(target, "allow"))],
}

# The enabled rules of `effect` naming `target`, by name.
applicable(target, effect) := {rule.name |
	some rule in data.garage.rules
	rule.enabled
	rule.effect == effect
	some pattern in rule.targets
	pattern_matches(pattern, target)
}

# `*` is every target, `prefix*` every target starting with it, anything else that target alone.
pattern_matches(pattern, target) if {
	endswith(pattern, "*")
	startswith(target, trim_suffix(pattern, "*"))
}

pattern_matches(pattern, target) if {
	not endswith(pattern, "*")
	pattern == target
}

# An exact name first, then the longest prefix pattern, then `*`; with none, allow, so a corpus with
# no rules reads as it did before.
default_for(target) := exact[0] if {
	exact := [d.effect | some d in data.garage.defaults; d.target == target]
	count(exact) > 0
} else := longest_prefix(target) if {
	count(prefixes(target)) > 0
} else := "allow"

prefixes(target) := [d |
	some d in data.garage.defaults
	endswith(d.target, "*")
	pattern_matches(d.target, target)
]

longest_prefix(target) := effect if {
	longest := max([count(d.target) | some d in prefixes(target)])
	effect := [d.effect | some d in prefixes(target); count(d.target) == longest][0]
}

//! Access: `garage access policies|rules|defaults …` and `garage access test`, over GarageService's
//! access calls (`docs/plans/access-policies.md`). A change applies to the next read.

use std::io::Read;

use garage_facade::proto;

use super::{Command, Context, Group};
use crate::args::Opt;
use crate::backend::Failure;
use crate::out::{self, Table};

pub static ACCESS: Group = Group {
    name: "access",
    help: "Who may read what: Rego policies, rules and defaults, and what a caller would see.",
    commands: &[TEST],
    groups: &[&POLICIES, &RULES, &DEFAULTS],
};

static POLICIES: Group = Group {
    name: "policies",
    help: "Rego modules, evaluated on every read with the rules and defaults as their data.",
    commands: &[POLICIES_LIST, POLICIES_SHOW, POLICIES_PUT, POLICIES_CHECK, POLICIES_REMOVE, POLICIES_BUILTIN],
    groups: &[],
};

static RULES: Group = Group {
    name: "rules",
    help: "ALLOW and DENY rules over documents, by metadata or content.",
    commands: &[RULES_LIST, RULES_PUT, RULES_REMOVE],
    groups: &[],
};

static DEFAULTS: Group = Group {
    name: "defaults",
    help: "What a target sees when no rule decides.",
    commands: &[DEFAULTS_LIST, DEFAULTS_SET],
    groups: &[],
};

/// A file's text, or stdin's for `-`.
fn read_source(path: &str) -> Result<String, Failure> {
    if path == "-" {
        let mut text = String::new();
        std::io::stdin().read_to_string(&mut text).map_err(|e| Failure::failed(format!("stdin: {e}")))?;
        Ok(text)
    } else {
        std::fs::read_to_string(path).map_err(|e| Failure::failed(format!("{path}: {e}")))
    }
}

fn list_policies(context: &mut Context) -> Result<proto::ListAccessPoliciesResponse, Failure> {
    let listed = context
        .backend()?
        .call(|mut client| async move { client.list_access_policies(proto::ListAccessPoliciesRequest {}).await })?;
    if !listed.editable {
        return Err(Failure::failed(format!(
            "[yellow]this build's access policy ({}) is not edited with these commands[/yellow]",
            listed.engine
        )));
    }
    Ok(listed)
}

const POLICIES_LIST: Command = Command {
    name: "list",
    opts: &[],
    help: "List the stored policies.",
    run: |context, _| {
        let listed = list_policies(context)?;
        if listed.policies.is_empty() {
            out::print("no stored policies: the built-in one decides from the rules and defaults");
            return Ok(());
        }
        let mut table = Table::new(None);
        table.columns(&["name", "state", "updated"]);
        for policy in &listed.policies {
            table.row(&[
                policy.name.as_str(),
                if policy.enabled { "enabled" } else { "disabled" },
                policy.updated_at.as_str(),
            ]);
        }
        table.print();
        Ok(())
    },
};

const POLICIES_SHOW: Command = Command {
    name: "show",
    opts: &[],
    help: "Print a stored policy's Rego.",
    run: |context, parsed| {
        let name = parsed.arg(0, "NAME").map_err(Failure::usage)?.to_owned();
        let listed = list_policies(context)?;
        let policy = listed
            .policies
            .iter()
            .find(|p| p.name == name)
            .ok_or_else(|| Failure::failed(format!("[red]no policy named {name}[/red]")))?;
        print!("{}", policy.rego);
        Ok(())
    },
};

const POLICIES_BUILTIN: Command = Command {
    name: "builtin",
    opts: &[],
    help: "Print the built-in policy (package garage.access.rules), which a policy can build on.",
    run: |context, _| {
        print!("{}", list_policies(context)?.builtin_rego);
        Ok(())
    },
};

fn put_policy(context: &mut Context, parsed: &crate::args::Parsed, check_only: bool) -> Result<(), Failure> {
    let name = parsed.arg(0, "NAME").map_err(Failure::usage)?.to_owned();
    let rego = read_source(parsed.arg(1, "FILE").map_err(Failure::usage)?)?;
    let request = proto::PutAccessPolicyRequest {
        policy: Some(proto::AccessPolicy { name, rego, enabled: !parsed.has("disabled"), ..Default::default() }),
        check_only,
    };
    let reply = context.backend()?.call(|mut client| async move { client.put_access_policy(request).await })?;
    out::echo(&reply.message);
    Ok(())
}

const POLICIES_PUT: Command = Command {
    name: "put",
    opts: &[Opt::flag("disabled")],
    help: "Save NAME from FILE (- for stdin) once it compiles with the other enabled policies.",
    run: |context, parsed| put_policy(context, parsed, false),
};

const POLICIES_CHECK: Command = Command {
    name: "check",
    opts: &[],
    help: "Compile NAME from FILE (- for stdin) with the other enabled policies; save nothing.",
    run: |context, parsed| put_policy(context, parsed, true),
};

const POLICIES_REMOVE: Command = Command {
    name: "remove",
    opts: &[],
    help: "Remove a stored policy.",
    run: |context, parsed| {
        let name = parsed.arg(0, "NAME").map_err(Failure::usage)?.to_owned();
        let reply = context.backend()?.call(|mut client| async move {
            client.remove_access_policy(proto::RemoveAccessPolicyRequest { name }).await
        })?;
        out::echo(&reply.message);
        Ok(())
    },
};

const RULES_LIST: Command = Command {
    name: "list",
    opts: &[],
    help: "List the rules, as JSON lines.",
    run: |context, _| {
        let listed = context
            .backend()?
            .call(|mut client| async move { client.list_access_rules(proto::ListAccessRulesRequest {}).await })?;
        for rule in &listed.rules {
            if rule.pending > 0 {
                out::echo(&format!("{}\t{} documents not yet evaluated", rule.rule_json, rule.pending));
            } else {
                out::echo(&rule.rule_json);
            }
        }
        Ok(())
    },
};

const RULES_PUT: Command = Command {
    name: "put",
    opts: &[],
    help: "Save a rule from FILE (- for stdin): {name, effect, targets, match, enabled?} as JSON.",
    run: |context, parsed| {
        let rule_json = read_source(parsed.arg(0, "FILE").map_err(Failure::usage)?)?;
        let reply = context.backend()?.call(|mut client| async move {
            client.put_access_rule(proto::PutAccessRuleRequest { rule_json }).await
        })?;
        out::echo(&format!("{} (id {})", reply.message, reply.id));
        Ok(())
    },
};

const RULES_REMOVE: Command = Command {
    name: "remove",
    opts: &[],
    help: "Remove a rule.",
    run: |context, parsed| {
        let name = parsed.arg(0, "NAME").map_err(Failure::usage)?.to_owned();
        let reply = context.backend()?.call(|mut client| async move {
            client.remove_access_rule(proto::RemoveAccessRuleRequest { name }).await
        })?;
        out::echo(&reply.message);
        Ok(())
    },
};

const DEFAULTS_LIST: Command = Command {
    name: "list",
    opts: &[],
    help: "List the defaults.",
    run: |context, _| {
        let listed = context
            .backend()?
            .call(|mut client| async move { client.list_access_defaults(proto::ListAccessDefaultsRequest {}).await })?;
        for default in &listed.defaults {
            out::echo(&format!("{}\t{}", default.target, default.effect));
        }
        Ok(())
    },
};

const DEFAULTS_SET: Command = Command {
    name: "set",
    opts: &[],
    help: "Set TARGET's default to allow, deny or clear.",
    run: |context, parsed| {
        let target = parsed.arg(0, "TARGET").map_err(Failure::usage)?.to_owned();
        let effect = parsed.arg(1, "EFFECT").map_err(Failure::usage)?.to_owned();
        let request = proto::SetAccessDefaultRequest { target, effect };
        let reply = context.backend()?.call(|mut client| async move { client.set_access_default(request).await })?;
        out::echo(&reply.message);
        Ok(())
    },
};

const TEST: Command = Command {
    name: "test",
    opts: &[Opt::value("as"), Opt::value("transport"), Opt::value("draft")],
    help: "What a caller's reads would be held to (--as CALLER; --draft NAME=FILE tries an unsaved policy).",
    run: |context, parsed| {
        let caller = parsed.get("as").ok_or_else(|| Failure::usage("Missing option '--as'."))?.to_owned();
        let draft = match parsed.get("draft") {
            None => None,
            Some(spec) => {
                let (name, path) = spec.split_once('=').ok_or_else(|| Failure::usage("--draft takes NAME=FILE"))?;
                Some(proto::AccessPolicy {
                    name: name.to_owned(),
                    rego: read_source(path)?,
                    enabled: true,
                    ..Default::default()
                })
            }
        };
        let request = proto::TestAccessRequest {
            caller,
            transport: parsed.get("transport").unwrap_or_default().to_owned(),
            draft,
        };
        let r = context.backend()?.call(|mut client| async move { client.test_access(request).await })?;
        let registration =
            if r.registration_name.is_empty() { String::new() } else { format!(" ({})", r.registration_name) };
        out::echo(&format!("caller:   {} over {}{registration}", r.caller_kind, r.transport));
        out::echo(&format!("targets:  {}", r.targets.join(", ")));
        out::echo(&format!(
            "policies: {}",
            if r.policies.is_empty() { "built-in (the rules)".to_owned() } else { r.policies.join(", ") }
        ));
        out::echo(&format!("decision:\n{}", r.decision_json));
        if !r.content_rules.is_empty() {
            out::echo("content rules (evaluated ahead of a read; a DENY hides what it has not yet seen):");
            for rule in &r.content_rules {
                out::echo(&format!("  {}: {} documents not yet evaluated", rule.name, rule.pending));
            }
        }
        if r.sees_everything {
            out::echo("filter:   none; this caller sees every document");
        } else {
            out::echo(&format!("filter:\n  {}", r.filter_sql));
            for (index, value) in r.filter_params.iter().enumerate() {
                out::echo(&format!("  ${} = {value}", index + 1));
            }
        }
        Ok(())
    },
};

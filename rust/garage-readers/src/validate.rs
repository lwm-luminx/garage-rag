//! Structural checks a document must pass before its parser reads it: limits no real document
//! comes near, which keep a hostile or broken file from taking the parser (and, before parsers had
//! their own stack, the app) down. A file that fails one is recorded as failed with the reason.
//! See docs/plans/parser-isolation.md.

use std::collections::HashSet;

use pdf_oxide::PdfDocument;
use pdf_oxide::object::{Object, ObjectRef};

/// How deep a PDF's page tree may nest. Most files nest a handful of levels, but some tools chain
/// every page one level below the last: the 160-page file that overflowed the Mac app's 512 KB ingest
/// thread on 2026-11-11 nests 161 deep, and reads fine on the parser's own stack. The parser spends
/// about 3 KB of stack a level, so 4,096 levels stay well inside `PARSER_STACK_BYTES` (64 MB).
pub const PDF_MAX_TREE_DEPTH: usize = 4_096;
/// How many nodes a PDF's page tree may have.
pub const PDF_MAX_TREE_NODES: usize = 200_000;

/// Why a PDF's page tree fails the checks, or `None` when it passes or cannot be walked (the
/// parser then reports what it makes of the file). The tree is walked iteratively with a visited
/// set, so the check itself recurses into nothing and stops at a cycle.
#[must_use]
pub fn pdf_problem(bytes: &[u8]) -> Option<String> {
    pdf_problem_with(bytes, PDF_MAX_TREE_DEPTH, PDF_MAX_TREE_NODES)
}

fn pdf_problem_with(bytes: &[u8], max_depth: usize, max_nodes: usize) -> Option<String> {
    let document = PdfDocument::from_bytes(bytes.to_vec()).ok()?;
    let catalog = document.catalog().ok()?;
    let root = catalog.as_dict()?.get("Pages")?.as_reference()?;
    let mut visited: HashSet<ObjectRef> = HashSet::new();
    let mut stack: Vec<(ObjectRef, usize)> = vec![(root, 1)];
    while let Some((node, depth)) = stack.pop() {
        if !visited.insert(node) {
            continue;
        }
        if depth > max_depth {
            return Some(format!("its page tree nests more than {max_depth} levels deep"));
        }
        if visited.len() > max_nodes {
            return Some(format!("its page tree has more than {max_nodes} nodes"));
        }
        let Ok(object) = document.load_object(node) else { continue };
        let Some(kids) = object.as_dict().and_then(|dict| dict.get("Kids")) else { continue };
        let kids = match kids {
            Object::Reference(reference) => document.load_object(*reference).ok(),
            other => Some(other.clone()),
        };
        for kid in kids.as_ref().and_then(Object::as_array).into_iter().flatten() {
            if let Some(reference) = kid.as_reference() {
                stack.push((reference, depth + 1));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::deep_page_tree_pdf;

    #[test]
    fn a_shallow_tree_passes_and_a_deep_one_is_named() {
        assert_eq!(pdf_problem(&deep_page_tree_pdf(3)), None);
        assert_eq!(
            pdf_problem_with(&deep_page_tree_pdf(20), 10, 1000).as_deref(),
            Some("its page tree nests more than 10 levels deep")
        );
        assert_eq!(pdf_problem(&deep_page_tree_pdf(3_000)), None, "deep, but within the parser's stack");
        assert_eq!(
            pdf_problem(&deep_page_tree_pdf(5_000)).as_deref(),
            Some("its page tree nests more than 4096 levels deep")
        );
        assert_eq!(pdf_problem(b"not a pdf"), None, "the parser reports what is not a PDF");
    }
}

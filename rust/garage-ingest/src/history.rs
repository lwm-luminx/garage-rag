//! Reading a repository's history for attribution, ported from `attribute/git.py`'s
//! `load_repo_attribution` and `cached_repo_attribution`: one pass over each repository through
//! libgit2 ([`garage_git`]), never one per file, kept for the rest of the run.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::attribution::{AuthorTally, GitHistory, RepoAttribution};

/// `load_repo_attribution`: the origin remote and each path's contributors, from one walk of the
/// history. A part that cannot be read is left empty, as Python logs and leaves it.
#[must_use]
pub fn load_repo_attribution(root: &Path, max_commits: Option<usize>) -> RepoAttribution {
    let remote = garage_git::remote_url(root, "origin").ok().flatten();
    let mut attribution = RepoAttribution { remote, ..RepoAttribution::default() };
    let Ok(commits) = garage_git::commit_paths(root, max_commits) else { return attribution };
    for commit in commits {
        if commit.name.is_empty() {
            continue;
        }
        let key = commit.email.to_lowercase();
        for path in commit.paths {
            let tallies = attribution.by_path.entry(path).or_default();
            // Keyed on the name and the lowercased address; the first spelling of the address stays.
            match tallies.iter_mut().find(|tally| tally.name == commit.name && tally.email.to_lowercase() == key) {
                Some(tally) => tally.commits += 1,
                None => {
                    tallies.push(AuthorTally { name: commit.name.clone(), email: commit.email.clone(), commits: 1 });
                }
            }
        }
    }
    attribution
}

/// `count_tracked_files`: tracked files (`git ls-files`), or `None` when `root` is not a git work
/// tree or its index cannot be read.
#[must_use]
pub fn count_tracked_files(root: &Path) -> Option<usize> {
    garage_git::index_entry_count(root).ok()
}

/// How many repositories [`LibGitHistory`] keeps, as `cached_repo_attribution`'s `maxsize`.
const CACHED_REPOSITORIES: usize = 128;

/// [`GitHistory`] read through libgit2, each repository once (`cached_repo_attribution`), keyed on
/// the root exactly as given.
#[derive(Default)]
pub struct LibGitHistory {
    cache: Mutex<HashMap<PathBuf, RepoAttribution>>,
}

impl LibGitHistory {
    /// An empty cache.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Forgets every repository read so far, so the next attribution reads history afresh.
    pub fn clear(&self) {
        self.cache.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clear();
    }
}

impl GitHistory for LibGitHistory {
    fn repository(&self, root: &Path) -> Option<RepoAttribution> {
        let mut cache = self.cache.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(repo) = cache.get(root) {
            return Some(repo.clone());
        }
        let repo = load_repo_attribution(root, None);
        if cache.len() >= CACHED_REPOSITORIES {
            cache.clear();
        }
        cache.insert(root.to_path_buf(), repo.clone());
        Some(repo)
    }
}

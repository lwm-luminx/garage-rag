use std::path::Path;

use super::*;

/// The shape of the system's rich-text importer's Info.plist.
const RICH_TEXT: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.apple.metadata.importer.RichText</string>
    <key>CFBundleVersion</key><string>1234</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key><string>MDImporter</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.rtf</string>
                <string>com.microsoft.word.doc</string>
                <string>public.RTF</string>
            </array>
        </dict>
        <dict>
            <key>LSItemContentTypes</key>
            <array><string>org.oasis-open.opendocument.text</string></array>
        </dict>
    </array>
    <key>CFPlugInFactories</key>
    <dict><key>E1F1D0A2-0000-0000-0000-000000000000</key><string>MetadataImporterPluginFactory</string></dict>
    <key>CFPlugInTypes</key>
    <dict>
        <key>8b08c4bf-415b-11d8-b3f9-0003936726fc</key>
        <array><string>E1F1D0A2-0000-0000-0000-000000000000</string></array>
    </dict>
</dict>
</plist>"#;

#[test]
fn an_importer_is_read_from_its_info_plist() {
    let bundle = Path::new("/System/Library/Spotlight/RichText.mdimporter");
    let importer = Importer::from_info_plist(bundle, RICH_TEXT.as_bytes()).unwrap();
    assert_eq!(importer.path, bundle);
    assert_eq!(importer.identifier, "com.apple.metadata.importer.RichText");
    assert_eq!(importer.version, "1234");
    // In order, each once, whatever its case.
    assert_eq!(importer.content_types, ["public.rtf", "com.microsoft.word.doc", "org.oasis-open.opendocument.text"]);
}

#[test]
fn a_bundle_that_is_no_importer_is_skipped() {
    let bundle = Path::new("/System/Library/Spotlight/Other.mdimporter");
    let other_type = RICH_TEXT.replace("8b08c4bf-415b-11d8-b3f9-0003936726fc", "00000000-0000-0000-0000-000000000000");
    assert_eq!(Importer::from_info_plist(bundle, other_type.as_bytes()), None);
    assert_eq!(Importer::from_info_plist(bundle, b"not a plist"), None);
}

#[test]
fn an_importer_with_no_types_is_skipped() {
    let bundle = Path::new("/System/Library/Spotlight/Empty.mdimporter");
    let start = RICH_TEXT.find("<key>CFBundleDocumentTypes</key>").unwrap();
    let end = RICH_TEXT.find("<key>CFPlugInFactories</key>").unwrap();
    let no_types = format!("{}{}", &RICH_TEXT[..start], &RICH_TEXT[end..]);
    assert_eq!(Importer::from_info_plist(bundle, no_types.as_bytes()), None);
}

#[test]
fn an_importer_without_an_identifier_is_named_by_its_bundle() {
    let bundle = Path::new("/System/Library/Spotlight/RichText.mdimporter");
    let anonymous = RICH_TEXT.replace("<key>CFBundleIdentifier</key>", "<key>Unused</key>");
    assert_eq!(Importer::from_info_plist(bundle, anonymous.as_bytes()).unwrap().identifier, "RichText");
}

#[test]
fn importers_are_found_in_a_folder_by_name() {
    let directory = std::env::temp_dir().join(format!("garage-spotlight-{}", std::process::id()));
    for name in ["B.mdimporter", "A.mdimporter", "C.bundle"] {
        let contents = directory.join(name).join("Contents");
        std::fs::create_dir_all(&contents).unwrap();
        std::fs::write(
            contents.join("Info.plist"),
            RICH_TEXT.replace("RichText</string>", &format!("{name}</string>")),
        )
        .unwrap();
    }
    let found = importers_in(&directory);
    std::fs::remove_dir_all(&directory).unwrap();
    let names: Vec<_> = found.iter().map(|importer| importer.path.file_name().unwrap().to_owned()).collect();
    assert_eq!(names, ["A.mdimporter", "B.mdimporter"]);
    assert!(importers_in(Path::new("/nonexistent/garage-spotlight")).is_empty());
}

#[test]
fn the_revision_names_this_crate_and_the_system() {
    assert!(revision().starts_with(&format!("{VERSION}+")));
}

#[cfg(not(target_os = "macos"))]
#[test]
fn off_the_mac_nothing_is_imported() {
    assert!(extensions().is_empty());
    assert!(!available());
    assert!(matches!(import(Path::new("/tmp/letter.rtf")), Outcome::NoImporter(_)));
    assert_eq!(revision(), "1+unavailable");
}

#[test]
fn importers_of_personal_records_are_never_loaded() {
    assert!(excluded_importer(Path::new("/System/Library/Spotlight/Mail.mdimporter")));
    assert!(excluded_importer(Path::new("/System/Library/Spotlight/vcard.mdimporter")));
    assert!(!excluded_importer(Path::new("/System/Library/Spotlight/RichText.mdimporter")));
}

#[cfg(target_os = "macos")]
#[test]
fn the_system_imports_rich_text() {
    // Some importers list types with no extension (audiobooks): reading the list must not trip on them.
    let extensions = extensions();
    assert!(extensions.iter().any(|extension| extension == ".rtf"), "{extensions:?}");
    assert!(!extensions.iter().any(|extension| extension == ".emlxpart" || extension == ".vcf"), "{extensions:?}");
    let folder = std::env::temp_dir().join(format!("garage-spotlight-{}", std::process::id()));
    std::fs::create_dir_all(&folder).unwrap();
    let rtf = folder.join("letter.rtf");
    std::fs::write(&rtf, b"{\\rtf1\\ansi Hello from Spotlight.}").unwrap();
    match import(&rtf) {
        Outcome::Imported(imported) => assert_eq!(imported.text.trim(), "Hello from Spotlight."),
        other => panic!("{other:?}"),
    }
    let junk = folder.join("old.doc");
    std::fs::write(&junk, b"x").unwrap();
    assert!(matches!(import(&junk), Outcome::NoText(_) | Outcome::Failed(_)));
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn personal_records_are_never_taken_from_the_index() {
    let tree = |types: &[&str]| types.iter().map(|&uti| uti.to_owned()).collect::<Vec<_>>();
    assert!(index::private_content_type(&tree(&["com.apple.mail.emlx", "public.email-message", "public.content"])));
    assert!(index::private_content_type(&tree(&["public.vcard", "public.contact"])));
    assert!(index::private_content_type(&tree(&["com.apple.ical.ics", "public.calendar-event"])));
    assert!(index::private_content_type(&tree(&["com.apple.ichat.transcript"])));
    assert!(index::private_content_type(&tree(&["com.apple.Photos.library", "com.apple.package"])));
    assert!(!index::private_content_type(&tree(&["com.adobe.pdf", "public.data", "public.content"])));
    assert!(!index::private_content_type(&tree(&["net.daringfireball.markdown", "public.plain-text"])));
    assert!(!index::private_content_type(&[]));
}

#[test]
fn a_source_query_narrows_the_default_and_never_replaces_it() {
    assert_eq!(index::query_string(None), index::DEFAULT_QUERY);
    assert_eq!(index::query_string(Some("  ")), index::DEFAULT_QUERY);
    assert_eq!(
        index::query_string(Some("kMDItemLastUsedDate >= $time.today(-30)")),
        format!("({}) && (kMDItemLastUsedDate >= $time.today(-30))", index::DEFAULT_QUERY)
    );
}

#[cfg(not(target_os = "macos"))]
#[test]
fn the_index_is_a_mac_feature() {
    assert!(index::search(Path::new("/tmp"), index::DEFAULT_QUERY).is_err());
    assert!(index::attributes(Path::new("/tmp/a.pdf")).is_empty());
}

/// Spotlight on this Mac, over this crate's own folder: whatever the index holds of it is searched
/// and described. The index is the system's and may hold none of a fresh checkout (CI runners often
/// turn it off, and Bazel's sandbox is never indexed), so an empty answer skips rather than fails.
#[cfg(target_os = "macos")]
#[test]
fn the_index_is_searched_and_described_on_this_mac() {
    let Ok(scope) = std::fs::canonicalize(env!("CARGO_MANIFEST_DIR")) else {
        eprintln!("skipped: manifest dir {} is unavailable at test runtime", env!("CARGO_MANIFEST_DIR"));
        return;
    };
    // A malformed query is refused, not run.
    assert!(index::search(&scope, "kMDItemDisplayName ==").is_err());
    let items = match index::search(&scope, index::DEFAULT_QUERY) {
        Ok(items) if !items.is_empty() => items,
        outcome => {
            eprintln!("skipped: Spotlight holds nothing of {} ({outcome:?})", scope.display());
            return;
        }
    };
    assert!(items.iter().all(|item| item.path.starts_with(&scope)), "{items:?}");
    assert!(items.iter().all(|item| !index::private_content_type(&item.content_types)), "{items:?}");
    assert!(items.iter().all(|item| item.content_types.iter().any(|uti| uti == "public.content")), "{items:?}");
    assert!(items.windows(2).all(|pair| pair[0].path < pair[1].path), "not sorted and unique: {items:?}");
    let first = &items[0];
    let attributes = index::attributes(&first.path);
    let name = first.path.file_name().unwrap().to_string_lossy().into_owned();
    let stem = name.split('.').next().unwrap_or_default().to_owned();
    let display = attributes.iter().find(|(key, _)| key == "kMDItemDisplayName").map(|(_, value)| value);
    assert!(matches!(display, Some(index::Value::Text(shown)) if shown.starts_with(&stem)), "{attributes:?}");
    // Nothing is described for a file the index does not hold.
    assert!(index::attributes(&scope.join("no such file.pdf")).is_empty());
}

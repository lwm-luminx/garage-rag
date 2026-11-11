//! Standard base64 (RFC 4648, padded) for the bytes the Dropbox host calls carry in JSON.

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// `bytes` as base64.
pub fn encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let triple =
            chunk.iter().enumerate().fold(0u32, |acc, (index, &byte)| acc | u32::from(byte) << (16 - 8 * index));
        for index in 0..4 {
            if index <= chunk.len() {
                out.push(char::from(ALPHABET[(triple >> (18 - 6 * index)) as usize & 63]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// The bytes `text` encodes; whitespace is ignored.
///
/// # Errors
///
/// A character outside the alphabet, or a length that is not whole.
#[allow(clippy::cast_possible_truncation)] // Masked to a byte first.
pub fn decode(text: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let (mut buffer, mut bits) = (0u32, 0u32);
    for character in text.bytes().filter(|byte| !byte.is_ascii_whitespace()) {
        if character == b'=' {
            break;
        }
        let value = match character {
            b'A'..=b'Z' => character - b'A',
            b'a'..=b'z' => character - b'a' + 26,
            b'0'..=b'9' => character - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return Err(format!("the host's reply is not base64 ({:?})", char::from(character))),
        };
        buffer = buffer << 6 | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buffer >> bits) & 0xff) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    if bits >= 6 {
        return Err("the host's reply is truncated base64".to_owned());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_rfc_4648_vectors() {
        for (plain, encoded) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(encode(plain.as_bytes()), encoded);
            assert_eq!(decode(encoded).unwrap(), plain.as_bytes());
        }
        let bytes: Vec<u8> = (0..=255).collect();
        assert_eq!(decode(&encode(&bytes)).unwrap(), bytes);
        assert!(decode("Zm9v!").is_err());
        assert!(decode("Z").is_err());
    }
}
